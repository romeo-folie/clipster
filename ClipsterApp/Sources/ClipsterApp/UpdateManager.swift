import Sparkle

/// Wraps Sparkle's `SPUStandardUpdaterController` for in-app update checking.
///
/// Usage:
///   1. Keep a strong reference on AppDelegate: `private let updater = UpdateManager()`
///   2. Call `updater.checkForUpdates()` from the "Check for Updates…" menu item.
///   3. Automatic checks are configured via Info.plist keys:
///        SUEnableAutomaticChecks = YES
///        SUFeedURL = https://github.com/romeo-folie/clipster/releases/latest/download/appcast.xml
///        SUPublicEDKey = <generated Ed25519 public key>
///
/// Key generation (run once before shipping):
///   Download the Sparkle release from https://github.com/sparkle-project/Sparkle/releases
///   and run: ./bin/generate_keys
///   Copy the public key into Info.plist under SUPublicEDKey.
///   Store the private key securely — it is used to sign each release archive.
final class UpdateManager: NSObject, SPUUpdaterDelegate {
    private let controller: SPUStandardUpdaterController

    override init() {
        // Guard: if SUPublicEDKey is still the placeholder value, do not start
        // automatic update checks. Sparkle logs Ed25519 validation errors on every
        // launch when the key is absent or invalid, which pollutes dev console output
        // and misleads developers. Automatic checks are benign to skip in dev builds;
        // manual "Check for Updates…" still works once a real key is set.
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let startUpdater = !publicKey.isEmpty && !publicKey.hasPrefix("PLACEHOLDER")

        // SPUStandardUpdaterController reads SUFeedURL and SUPublicEDKey from Info.plist.
        // updaterDelegate=nil uses default Sparkle UI; userDriverDelegate=nil uses default sheet.
        controller = SPUStandardUpdaterController(
            startingUpdater: startUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Trigger a user-initiated update check (bound to "Check for Updates…" menu item).
    @objc func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether the updater can currently check for updates.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
