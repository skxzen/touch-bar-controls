import AppKit
import CryptoKit
import Network
import Security

final class SpotifyAccount {
    let clientID = "09a08fd0279c4babb78a38d10b6ea753"
    let redirectURI = "http://127.0.0.1:43822/callback"
    let scope = "user-read-playback-state playlist-modify-private playlist-modify-public"
    private let service = "local.spotifytouchbar.oauth"
    private var listener: NWListener?
    private var verifier = ""
    private var oauthState = ""
    private var accessToken = ""
    private var refreshToken = ""
    private var expiresAt = Date.distantPast
    private var pollTimer: Timer?
    private(set) var playback: [String: Any] = [:]
    private(set) var status = tr("Compte Spotify non lié", "Spotify account not linked")
    var onChange: (() -> Void)?
    var linked: Bool { !refreshToken.isEmpty || !accessToken.isEmpty }

    init() {
        accessToken = keychainRead("access") ?? ""
        refreshToken = keychainRead("refresh") ?? ""
        expiresAt = Date(timeIntervalSince1970: Double(keychainRead("expires") ?? "0") ?? 0)
        if linked { status = tr("Compte Spotify lié", "Spotify account linked") }
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43822)
            listener = try NWListener(using: parameters)
            listener?.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                self?.receiveCallback(connection, data: Data())
            }
            listener?.start(queue: .main)
        } catch { status = "Callback Spotify indisponible : \(error.localizedDescription)"; onChange?() }
        if linked { pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }; poll() }
    }

    func login() {
        verifier = randomString(96)
        oauthState = randomString(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: oauthState), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        status = tr("Autorisation Spotify en attente…", "Waiting for Spotify authorization…"); onChange?()
        NSWorkspace.shared.open(components.url!)
    }

    func unlink() {
        accessToken = ""; refreshToken = ""; expiresAt = .distantPast; playback = [:]
        ["access", "refresh", "expires"].forEach(keychainDelete)
        status = tr("Compte Spotify non lié", "Spotify account not linked"); onChange?()
    }

    private func receiveCallback(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] received, _, complete, error in
            guard let self else { connection.cancel(); return }
            var all = data; if let received { all.append(received) }
            if let headerEnd = all.range(of: Data("\r\n\r\n".utf8)), let header = String(data: all[..<headerEnd.lowerBound], encoding: .utf8) {
                let request = header.components(separatedBy: "\r\n").first ?? ""
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/callback"
                self.handleCallback(target, connection: connection); return
            }
            if complete || error != nil { connection.cancel() } else { self.receiveCallback(connection, data: all) }
        }
    }

    private func handleCallback(_ target: String, connection: NWConnection) {
        let components = URLComponents(string: "http://127.0.0.1\(target)")
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let validState = query["state"] == oauthState
        let body: String
        if !validState { status = "Échec de vérification OAuth Spotify"; body = "Échec de vérification. Tu peux fermer cette fenêtre." }
        else if let error = query["error"] { status = "Autorisation refusée : \(error)"; body = "Autorisation refusée. Tu peux fermer cette fenêtre." }
        else if let code = query["code"] { exchange(code); body = tr("Spotify est lié à Touch Bar Control. Tu peux fermer cette fenêtre.", "Spotify is linked to Touch Bar Control. You can close this window.") }
        else { status = "Réponse Spotify invalide"; body = "Réponse invalide. Tu peux fermer cette fenêtre." }
        let data = Data(body.utf8)
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8) + data
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        onChange?()
    }

    private func exchange(_ code: String) {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": verifier])
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let access = object["access_token"] as? String else { self?.status = "Impossible de lier le compte Spotify"; self?.onChange?(); return }
            self.accessToken = access; if let refresh = object["refresh_token"] as? String { self.refreshToken = refresh }
            self.expiresAt = Date().addingTimeInterval(object["expires_in"] as? Double ?? 3600)
            self.saveTokens(); self.status = tr("Compte Spotify lié", "Spotify account linked"); self.startPollingIfNeeded(); self.onChange?()
        }.resume()
    }

    private func startPollingIfNeeded() { if pollTimer == nil { pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll() } }; poll() }

    func poll() {
        guard !accessToken.isEmpty else { return }
        if Date() >= expiresAt { refreshAccessToken { [weak self] in self?.poll() }; return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            if (response as? HTTPURLResponse)?.statusCode == 401 { self.refreshAccessToken { [weak self] in self?.poll() }; return }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.playback = [:]; self.onChange?(); return
            }
            self.playback = Self.normalizedPlayback(object); self.status = tr("Compte Spotify lié · téléphone / Connect", "Spotify account linked · phone / Connect"); self.onChange?()
        }.resume()
    }

    func fetchPlaylists(completion: @escaping ([(id: String, name: String)]) -> Void) {
        guard !accessToken.isEmpty else { completion([]); return }
        requestJSON("https://api.spotify.com/v1/me/playlists?limit=50") { object in
            let items = object["items"] as? [[String: Any]] ?? []
            completion(items.compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                return (id: id, name: name)
            })
        }
    }

    func addCurrentTrack(to playlistID: String, completion: @escaping (Bool) -> Void) {
        guard let uri = playback["uri"] as? String, !uri.isEmpty, !accessToken.isEmpty else { completion(false); return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)/items")!)
        request.httpMethod = "POST"; request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["uris": [uri]])
        URLSession.shared.dataTask(with: request) { data, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 201 || (response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    private func requestJSON(_ urlString: String, completion: @escaping ([String: Any]) -> Void) {
        var request = URLRequest(url: URL(string: urlString)!); request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let object = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            DispatchQueue.main.async { completion(object) }
        }.resume()
    }

    private func refreshAccessToken(completion: @escaping () -> Void) {
        guard !refreshToken.isEmpty else { unlink(); return }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let access = object["access_token"] as? String else { self?.unlink(); return }
            self.accessToken = access; if let refresh = object["refresh_token"] as? String { self.refreshToken = refresh }
            self.expiresAt = Date().addingTimeInterval(object["expires_in"] as? Double ?? 3600); self.saveTokens(); completion()
        }.resume()
    }

    private static func normalizedPlayback(_ object: [String: Any]) -> [String: Any] {
        guard let item = object["item"] as? [String: Any] else { return [:] }
        let artists = (item["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        let album = item["album"] as? [String: Any]; let images = album?["images"] as? [[String: Any]]
        let artwork = images?.first?["url"] as? String ?? ""
        let duration = (item["duration_ms"] as? NSNumber)?.doubleValue ?? 0
        let base = (object["progress_ms"] as? NSNumber)?.doubleValue ?? 0
        let timestamp = (object["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        let playing = object["is_playing"] as? Bool == true
        let position = min(duration, base + (playing ? max(0, Date().timeIntervalSince1970 * 1000 - timestamp) : 0))
        let repeatState = object["repeat_state"] as? String
        let repeatMode = repeatState == "track" ? 2 : repeatState == "context" ? 1 : 0
        let device = object["device"] as? [String: Any]; let volume = ((device?["volume_percent"] as? NSNumber)?.doubleValue ?? 0) / 100
        let deviceName = device?["name"] as? String ?? ""
        return ["title": item["name"] as? String ?? "Spotify", "artist": artists, "artwork": artwork,
                "uri": item["uri"] as? String ?? "", "playing": playing, "position": position,
                "duration": duration, "volume": volume, "heart": false, "shuffle": object["shuffle_state"] as? Bool ?? false,
                "repeat": repeatMode, "muted": false, "device": deviceName]
    }

    private func form(_ values: [String: String]) -> Data { values.map { "\(percent($0.key))=\(percent($0.value))" }.joined(separator: "&").data(using: .utf8)! }
    private func percent(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!.replacingOccurrences(of: "%20", with: "+") }
    private func randomString(_ length: Int) -> String { (0..<length).map { _ in String("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()!) }.joined() }
    private func saveTokens() { keychainSave("access", accessToken); keychainSave("refresh", refreshToken); keychainSave("expires", String(expiresAt.timeIntervalSince1970)) }
    private func keychainSave(_ key: String, _ value: String) { let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]; SecItemDelete(query as CFDictionary); SecItemAdd(query.merging([kSecValueData as String: Data(value.utf8)]) { $1 } as CFDictionary, nil) }
    private func keychainRead(_ key: String) -> String? { let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true]; var item: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }; return String(data: data, encoding: .utf8) }
    private func keychainDelete(_ key: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary) }
}
