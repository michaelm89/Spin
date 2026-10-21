import AppKit
import CryptoKit
import Network
import Security

/// Optional Spotify Web API connection (Authorization Code + PKCE, no client secret)
/// used for the account's top tracks and recently played history.
final class SpotifyAccount: ObservableObject {
    static let shared = SpotifyAccount()

    static let redirectPort: UInt16 = 8765
    static let redirectURI = "http://127.0.0.1:8765/callback"
    private static let scopes = "user-top-read user-read-recently-played"

    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var topAlbums: [AlbumRef] = []
    @Published private(set) var recentlyPlayed: [(album: AlbumRef, date: Date)] = []

    var clientID: String {
        get { UserDefaults.standard.string(forKey: "spotifyClientID") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "spotifyClientID") }
    }

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var refreshToken: String? {
        get { Keychain.read("refreshToken") }
        set { if let newValue { Keychain.write("refreshToken", newValue) } else { Keychain.delete("refreshToken") } }
    }

    private var listener: NWListener?
    private var pendingVerifier: String?
    private var pendingState: String?
    private var refreshTimer: Timer?

    private init() {
        isConnected = refreshToken != nil && !clientID.isEmpty
    }

    func start() {
        guard isConnected else { return }
        reload()
        // Top tracks change slowly; recently played is also covered by local history.
        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.reload() }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: Sign-in

    func connect() {
        guard !clientID.isEmpty else { return }
        lastError = nil
        let verifier = Self.randomURLSafe(64)
        let state = Self.randomURLSafe(16)
        pendingVerifier = verifier
        pendingState = state
        do {
            try startCallbackListener()
        } catch {
            lastError = "Couldn't listen on port \(Self.redirectPort): \(error.localizedDescription)"
            return
        }
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
        ]
        NSWorkspace.shared.open(components.url!)
    }

    func disconnect() {
        refreshToken = nil
        accessToken = nil
        isConnected = false
        topAlbums = []
        recentlyPlayed = []
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func startCallbackListener() throws {
        listener?.cancel()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.redirectPort)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let ok = self?.handleCallback(request) ?? false
                let body = ok
                    ? "<h2>Spin is connected to Spotify.</h2><p>You can close this tab.</p>"
                    : "<h2>Spin couldn't connect.</h2><p>Try again from the Spin menu.</p>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<html><body style=\"font-family: -apple-system; padding: 40px\">\(body)</body></html>"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// Returns true when the request carried a valid authorization code.
    private func handleCallback(_ request: String) -> Bool {
        guard let path = request.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1" + path),
              components.path == "/callback" else { return false }
        listener?.cancel()
        listener = nil
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let code = items["code"], items["state"] == pendingState, let verifier = pendingVerifier else {
            lastError = items["error"].map { "Spotify said: \($0)" } ?? "Sign-in was cancelled."
            return false
        }
        requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]) { [weak self] success in
            guard let self, success else { return }
            self.isConnected = true
            self.start()
        }
        return true
    }

    // MARK: Tokens

    private func requestToken(_ form: [String: String], completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard let token = json?["access_token"] as? String else {
                    self.lastError = (json?["error_description"] as? String) ?? "Couldn't get a Spotify token."
                    if json?["error"] as? String == "invalid_grant" { self.disconnect() }
                    completion(false)
                    return
                }
                self.accessToken = token
                self.accessTokenExpiry = Date().addingTimeInterval((json?["expires_in"] as? Double ?? 3600) - 60)
                if let refresh = json?["refresh_token"] as? String { self.refreshToken = refresh }
                self.lastError = nil
                completion(true)
            }
        }.resume()
    }

    private func withAccessToken(_ body: @escaping (String) -> Void) {
        if let accessToken, Date() < accessTokenExpiry { body(accessToken); return }
        guard let refreshToken else { return }
        requestToken(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]) { [weak self] ok in
            if ok, let token = self?.accessToken { body(token) }
        }
    }

    private func get(_ path: String, completion: @escaping ([String: Any]?) -> Void) {
        withAccessToken { token in
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request) { data, _, _ in
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async { completion(json) }
            }.resume()
        }
    }

    // MARK: Data

    func reload() {
        guard isConnected else { return }
        // Long-term top tracks first, then medium and short term to fill the wall.
        var collected: [AlbumRef] = []
        let ranges = ["long_term", "medium_term", "short_term"]
        func fetch(_ index: Int) {
            guard index < ranges.count else { return }
            get("/me/top/tracks?limit=50&time_range=\(ranges[index])") { [weak self] json in
                guard let self else { return }
                let items = json?["items"] as? [[String: Any]] ?? []
                for item in items {
                    guard let album = Self.album(from: item["album"]),
                          !collected.contains(where: { $0.artworkURL == album.artworkURL }) else { continue }
                    collected.append(album)
                }
                self.topAlbums = collected
                if collected.count < 40 { fetch(index + 1) }
            }
        }
        fetch(0)

        get("/me/player/recently-played?limit=50") { [weak self] json in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let items = json?["items"] as? [[String: Any]] ?? []
            self?.recentlyPlayed = items.compactMap { item in
                guard let track = item["track"] as? [String: Any],
                      let album = Self.album(from: track["album"]),
                      let played = item["played_at"] as? String,
                      let date = formatter.date(from: played) ?? ISO8601DateFormatter().date(from: played)
                else { return nil }
                return (album, date)
            }
        }
    }

    private static func album(from value: Any?) -> AlbumRef? {
        guard let album = value as? [String: Any],
              let images = album["images"] as? [[String: Any]],
              let url = images.first?["url"] as? String else { return nil }
        let artist = ((album["artists"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
        return AlbumRef(artworkURL: SpotifyMonitor.canonicalArtworkURL(url), name: album["name"] as? String ?? "", artist: artist)
    }

    // MARK: Helpers

    private static func randomURLSafe(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private enum Keychain {
    private static let service = "com.personal.Spin"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        delete(account)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: account, kSecValueData: Data(value.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}
