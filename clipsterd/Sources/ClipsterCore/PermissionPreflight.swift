import Foundation

// MARK: - CapabilityStatus

/// Result of a single capability permission check.
public enum CapabilityStatus: String, Equatable {
    /// Permission is granted or the API is not restricted on this OS version.
    case granted
    /// Permission has been denied by the user or system policy.
    case denied
    /// Permission has not been requested yet (first-run state).
    case notDetermined
    /// The check is not applicable (e.g. API requires a newer OS).
    case notApplicable
}

// MARK: - CapabilityReport

/// Aggregated result of all permission checks.
public struct CapabilityReport: Equatable {

    /// NSPasteboard access (TCC key: NSPasteboardUsageDescription, macOS 14+).
    public let pasteboardAccess: CapabilityStatus

    /// Accessibility API access (required for future CGEvent monitoring).
    public let accessibilityAccess: CapabilityStatus

    /// Overall readiness: `true` when no *required* capability is explicitly denied.
    ///
    /// `.notDetermined` is treated as "not yet denied" — the daemon starts optimistically
    /// and will encounter a TCC prompt on first pasteboard access (macOS 14+ behaviour).
    public var isReady: Bool {
        pasteboardAccess != .denied
    }

    public init(pasteboardAccess: CapabilityStatus, accessibilityAccess: CapabilityStatus) {
        self.pasteboardAccess = pasteboardAccess
        self.accessibilityAccess = accessibilityAccess
    }

    // MARK: - Diagnostics

    /// User-facing diagnostic lines for blocked capabilities.
    public var diagnostics: [String] {
        var lines: [String] = []

        if pasteboardAccess == .denied {
            lines.append("""
            [Permissions] Pasteboard access denied.
            Fix: System Settings → Privacy & Security → Pasteboard → enable Clipster.
            """)
        }
        if pasteboardAccess == .notDetermined {
            lines.append("""
            [Permissions] Pasteboard access not yet requested.
            Clipster will request access on first clipboard event.
            """)
        }
        if accessibilityAccess == .denied {
            lines.append("""
            [Permissions] Accessibility access denied (required for future CGEvent monitoring).
            Fix: System Settings → Privacy & Security → Accessibility → enable Clipster.
            """)
        }

        return lines
    }
}

// MARK: - PermissionPreflight

/// Lightweight permission preflight runner.
///
/// Design notes:
/// - All permission APIs that require a UI prompt (AXIsProcessTrustedWithOptions,
///   TCC dialog) are called with prompt=false so the preflight never blocks the
///   daemon startup path. Actual prompts are deferred to the first capability use.
/// - The preflight is informational: a failing check logs a warning but does NOT
///   abort startup. PRD §9 specifies graceful degradation for permission failures.
/// - CGEvent tap (global key monitoring) is intentionally NOT gated here — it
///   requires Accessibility and is a Phase 5+ feature. Guarded by a dedicated flag.
public struct PermissionPreflight {

    // MARK: - Run

    /// Run all checks and return a capability report.
    public static func run() -> CapabilityReport {
        let pasteboard = checkPasteboard()
        let accessibility = checkAccessibility()
        return CapabilityReport(
            pasteboardAccess: pasteboard,
            accessibilityAccess: accessibility
        )
    }

    // MARK: - Pasteboard

    /// Check NSPasteboard read access.
    ///
    /// macOS 14+ requires NSPasteboardUsageDescription in Info.plist and shows
    /// a TCC prompt on first pasteboard read. In headless daemon mode (no bundle),
    /// the system typically grants access automatically — but we mark
    /// `notDetermined` to surface any future TCC restrictions cleanly.
    static func checkPasteboard() -> CapabilityStatus {
        // In a headless daemon (no app bundle), pasteboard access is granted
        // implicitly by macOS for all apps except those sandboxed or explicitly
        // denied in Privacy & Security. We check the general macOS version.
        if #available(macOS 14, *) {
            // TCC restriction applies. We cannot probe without triggering a prompt.
            // Return notDetermined so the caller logs an advisory, not an error.
            return .notDetermined
        } else {
            return .granted
        }
    }

    // MARK: - Accessibility

    /// Check Accessibility API access.
    ///
    /// In Phase 4, `clipsterd` runs as a headless daemon and does not use the
    /// Accessibility API. CGEvent monitoring (which requires Accessibility) is
    /// deferred to Phase 5. We return `.notDetermined` as a forward-looking
    /// placeholder; the actual AXIsProcessTrusted() check will be wired in
    /// Phase 5 when the app-bundle target has AppKit linked.
    static func checkAccessibility() -> CapabilityStatus {
        // Phase 5+: AXIsProcessTrusted() will be called here.
        // Returning .notDetermined is safe — it generates an advisory log only.
        return .notDetermined
    }
}

// MARK: - SecurityChecklist

/// Notarisation/signing impact checklist for the LaunchAgent → app-bundle transition.
///
/// This is a documentation artefact, not runtime logic.
/// Each item must be manually verified before a Phase 5 GUI release.
public enum SecurityChecklist {
    public static let items: [(item: String, risk: String)] = [
        (
            "Notarisation",
            "App bundle must be notarised with Apple ID credentials before distribution. " +
            "scripts/sign.sh is prepared; requires active Developer ID cert."
        ),
        (
            "Hardened runtime",
            "Enable com.apple.security.automation.apple-events and " +
            "com.apple.security.files.user-selected.read-write entitlements in app target."
        ),
        (
            "TCC NSPasteboardUsageDescription",
            "Must be present in app bundle Info.plist; LaunchAgent daemon is exempt."
        ),
        (
            "Accessibility entitlement",
            "com.apple.security.temporary-exception.apple-events must be reviewed; " +
            "Accessibility access requires user approval via System Settings."
        ),
        (
            "Gatekeeper path randomisation",
            "App bundle must not be moved post-notarisation; use drag-install to /Applications."
        ),
        (
            "IPC socket path",
            "Socket at ~/Library/Application Support/Clipster/clipster.sock must survive " +
            "app sandbox boundary if app is later sandboxed."
        ),
    ]
}
