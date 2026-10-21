import SwiftUI

@main
struct SpinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Spin", systemImage: "record.circle") {
            MenuContent(prefs: .shared, monitor: .shared, loginItem: .shared, account: .shared)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: DesktopWindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = SpotifyMonitor.shared
        monitor.onTrackCompleted = { track, artworkURL in
            ListeningHistory.shared.record(track, artworkURL: artworkURL)
        }
        windowManager = DesktopWindowManager(monitor: monitor, prefs: .shared, library: .shared)
        monitor.start()
        SpotifyAccount.shared.start()
    }
}
