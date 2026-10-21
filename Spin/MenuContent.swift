import ServiceManagement
import SwiftUI

struct MenuContent: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var monitor: SpotifyMonitor
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var account: SpotifyAccount

    var body: some View {
        nowPlaying
        Divider()
        Picker("Style", selection: $prefs.style) {
            ForEach(DisplayStyle.allCases) { Text($0.title).tag($0) }
        }
        if prefs.style == .floating {
            Picker("Size", selection: $prefs.size) {
                ForEach(RecordSize.allCases) { Text($0.title).tag($0) }
            }
            Picker("Position", selection: $prefs.position) {
                ForEach(RecordPosition.allCases) { Text($0.title).tag($0) }
            }
        }
        Toggle("Show Tonearm", isOn: $prefs.showTonearm)
        Divider()
        if account.isConnected {
            Text("Album wall: your Spotify top tracks")
            Button("Refresh Album Wall") { account.reload() }
            Button("Disconnect Spotify Account") { account.disconnect() }
        } else {
            Text("Album wall: songs Spin has seen finish")
            Button("Connect Spotify Account…") { SpotifyConnectPrompt.show(account: account) }
        }
        if let error = account.lastError { Text("⚠︎ \(error)") }
        Divider()
        Toggle("Launch at Login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
        Divider()
        Button("Quit Spin") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var nowPlaying: some View {
        let state = monitor.state
        if state.status == .stopped || state.name.isEmpty {
            Text("Spotify isn't playing")
        } else {
            Text(state.status == .playing ? "▶︎ \(state.displayName)" : "❚❚ \(state.displayName)")
            if !state.artist.isEmpty { Text(state.artist) }
        }
    }
}

/// Asks for a Spotify developer Client ID, then starts the browser sign-in.
enum SpotifyConnectPrompt {
    static func show(account: SpotifyAccount) {
        let alert = NSAlert()
        alert.messageText = "Connect your Spotify account"
        alert.informativeText = """
        Spin uses Spotify's Web API to put your most-played albums on the wall. It needs a free Client ID:

        1. Open developer.spotify.com/dashboard and click Create app.
        2. Add this Redirect URI: \(SpotifyAccount.redirectURI)
        3. Tick "Web API", save, then copy the app's Client ID.
        4. Paste it below. Your browser will open to approve access.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Client ID"
        field.stringValue = account.clientID
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Open Dashboard")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            account.clientID = field.stringValue
            account.connect()
        case .alertSecondButtonReturn:
            account.clientID = field.stringValue
            NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
        default:
            break
        }
    }
}

final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Spin: couldn't update login item: %@", error.localizedDescription)
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
