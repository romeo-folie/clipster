import SwiftUI

@main
struct ClipsterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar apps don't use a WindowGroup.
        Settings {
            EmptyView()
        }
    }
}
