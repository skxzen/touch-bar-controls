import AppKit
import Network

final class Bridge {
    let token: String
    var listener: NWListener?
    var commands: [[String: Any]] = []
    var state: [String: Any] = [:]
    var lastSeen = Date.distantPast
    var onUpdate: (() -> Void)?
    var online: Bool { Date().timeIntervalSince(lastSeen) < 4 }
    init(token: String) { self.token = token }
    func enqueue(_ action: String, value: Double? = nil, uri: String? = nil) {
        guard online else { return }
        if action == "volume" || action == "seek" { commands.removeAll { $0["action"] as? String == action } }
        guard commands.count < 32 else { return }
        var c: [String: Any] = ["action": action, "expires": Date().timeIntervalSince1970 + 3]
        if let value = value { c["value"] = value }
        if action == "seek" { c["uri"] = uri ?? (state["uri"] as? String ?? "") }
        commands.append(c)
    }
    func start() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43821)
        listener = try NWListener(using: p)
        listener?.stateUpdateHandler = { status in
            if case .failed(let error) = status {
                self.state = ["error": "Serveur local indisponible : \(error.localizedDescription)"]
                self.onUpdate?()
            }
        }
        listener?.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { c.cancel() }
            self?.receive(c, buffer: Data())
        }
        listener?.start(queue: .main)
    }
    func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self = self else { c.cancel(); return }
            var all = buffer
            if let data = data { all.append(data) }
            guard all.count <= 65536 else { c.cancel(); return }
            if let split = all.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: all[..<split.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                let length = Int(headers["content-length"] ?? "0") ?? -1
                guard length >= 0 && length <= 60000 else { c.cancel(); return }
                if all.count - split.upperBound >= length {
                    self.handle(c, request: lines.first ?? "", headers: headers,
                        body: all.subdata(in: split.upperBound..<(split.upperBound + length)))
                    return
                }
            }
            if complete || error != nil { c.cancel() } else { self.receive(c, buffer: all) }
        }
    }
    func handle(_ c: NWConnection, request: String, headers: [String: String], body: Data) {
        let origins = ["https://xpui.app.spotify.com", "https://zlink.app.spotify.com"]
        let origin = headers["origin"] ?? ""
        guard origin.isEmpty || origins.contains(origin) else { reply(c, code: 403, object: [:]); return }
        guard request == "POST /sync HTTP/1.1" || request == "OPTIONS /sync HTTP/1.1" else {
            reply(c, code: 404, object: [:]); return
        }
        if request.hasPrefix("OPTIONS ") { reply(c, code: 200, object: [:], origin: origin); return }
        guard headers["x-stb-token"] == token else { reply(c, code: 403, object: [:], origin: origin); return }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["title"] is String, object["playing"] is Bool else {
            reply(c, code: 400, object: [:], origin: origin); return
        }
        state = object; lastSeen = Date()
        let pending = commands.filter { ($0["expires"] as? Double ?? 0) > Date().timeIntervalSince1970 }
        commands.removeAll()
        reply(c, code: 200, object: ["commands": pending], origin: origin)
        onUpdate?()
    }
    func reply(_ c: NWConnection, code: Int, object: [String: Any], origin: String = "") {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var header = "HTTP/1.1 \(code) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if !origin.isEmpty {
            header += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-STB-Token\r\nAccess-Control-Allow-Private-Network: true\r\n"
        }
        var response = Data((header + "\r\n").utf8); response.append(body)
        c.send(content: response, completion: .contentProcessed { _ in c.cancel() })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    var bridge: Bridge!
    let account = SpotifyAccount()
    var status: NSStatusItem!
    var bar = NSTouchBar()
    var window: NSWindow!
    var info = NSTextField(labelWithString: tr("Connexion à Spotify…", "Connecting to Spotify…"))
    var detail = NSTextField(labelWithString: "")
    var buttons: [String: [NSButton]] = [:]
    var strips: [PlayerStrip] = []
    var trackButton: NSButton?
    var seekSlider: NSSlider?
    var volumeSlider: NSSlider?
    var timeLabel: NSTextField?
    let brightnessSlider = NSSlider(value: 50, minValue: 1, maxValue: 100, target: nil, action: nil)
    let brightnessValue = NSTextField(labelWithString: "— %")
    let brightnessStatus = NSTextField(wrappingLabelWithString: tr("Recherche de la Touch Bar…", "Looking for the Touch Bar…"))
    let brightnessHold = NSButton(checkboxWithTitle: tr("Maintenir ce niveau tant que l’app est ouverte", "Hold this level while the app is open"), target: nil, action: nil)
    let brightnessSync = NSButton(checkboxWithTitle: tr("Synchroniser avec la luminosité de l’écran principal", "Sync with the main display brightness"), target: nil, action: nil)
    let accountButton = NSButton(title: tr("Lier mon compte Spotify", "Link my Spotify account"), target: nil, action: nil)
    let accountStatus = NSTextField(labelWithString: tr("Compte Spotify non lié", "Spotify account not linked"))
    let playlistButton = NSButton(title: tr("Ajouter à une playlist…", "Add to playlist…"), target: nil, action: nil)
    var brightnessOriginal = -1.0
    var brightnessModified = false
    var brightnessSyncInFlight = false
    // The Touch Bar's OLED contrast makes an equal numeric level look brighter
    // than the main display. Keep the match perceptual rather than electrical.
    let brightnessSyncScale = 0.80
    var barShown = false
    let prefix = "local.spotifytouchbar."
    func id(_ s: String) -> NSTouchBarItem.Identifier { .init(prefix + s) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = Bundle.main.url(forResource: "pairing", withExtension: "txt"),
              let token = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            let a = NSAlert(); a.messageText = "Exécute Installer.command pour associer l’extension."; a.runModal(); NSApp.terminate(nil); return
        }
        bridge = Bridge(token: token)
        bridge.onUpdate = { [weak self] in self?.refresh() }
        account.onChange = { [weak self] in
            // Spotify Web API callbacks arrive on URLSession queues; all AppKit
            // controls and Touch Bar presentation must be changed on main.
            DispatchQueue.main.async { self?.refresh() }
        }
        bar.delegate = self
        bar.defaultItemIdentifiers = [id("strip")]
        bar.principalItemIdentifier = id("strip")
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Spotify Touch Bar")
        let menu = NSMenu()
        for (title, selector) in [(tr("Afficher la Touch Bar", "Show Touch Bar"), #selector(showBar)), (tr("Panneau et luminosité", "Panel and brightness"), #selector(showWindow)), (tr("Ouvrir Spotify", "Open Spotify"), #selector(openSpotify)), (tr("Masquer la Touch Bar", "Hide Touch Bar"), #selector(hideBar)), (tr("Quitter", "Quit"), #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        for (title, action) in [(tr("Ajouter / retirer des favoris", "Like / unlike"), "heart"), (tr("Aléatoire", "Shuffle"), "shuffle"), (tr("Répétition", "Repeat"), "repeat")] {
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action; menu.insertItem(item, at: 3)
        }
        status.menu = menu
        makeWindow()
        connectBrightness()
        account.start()
        do { try bridge.start() } catch { detail.stringValue = "Impossible de démarrer : \(error.localizedDescription)" }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh(); self?.brightnessTick() }
        showWindow()
    }
    func makeButton(_ key: String, _ title: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(command(_:)))
        b.identifier = .init(key); b.bezelStyle = .rounded
        buttons[key, default: []].append(b)
        return b
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 390), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Touch Bar Control"; window.isReleasedWhenClosed = false; window.center(); window.touchBar = bar
        info.font = .systemFont(ofSize: 19, weight: .semibold); info.lineBreakMode = .byTruncatingTail
        info.widthAnchor.constraint(equalToConstant: 570).isActive = true
        detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 12)
        detail.widthAnchor.constraint(equalToConstant: 570).isActive = true
        let row = NSStackView(views: [makeButton("previous", "⏮"), makeButton("play", "▶"), makeButton("next", "⏭"), makeButton("heart", "♡"), makeButton("shuffle", tr("Aléatoire", "Shuffle")), makeButton("repeat", tr("Répétition", "Repeat")), makeButton("mute", tr("Son", "Sound"))])
        row.spacing = 8
        let show = NSButton(title: tr("Afficher les commandes sur la Touch Bar", "Show controls on the Touch Bar"), target: self, action: #selector(showBar))
        accountButton.target = self; accountButton.action = #selector(accountAction(_:))
        playlistButton.target = self; playlistButton.action = #selector(playlistAction(_:))
        accountStatus.textColor = .secondaryLabelColor; accountStatus.font = .systemFont(ofSize: 11)
        let preview = makeStrip()
        preview.widthAnchor.constraint(equalToConstant: 640).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let divider = NSBox(); divider.boxType = .separator; divider.widthAnchor.constraint(equalToConstant: 640).isActive = true
        let brightnessTitle = NSTextField(labelWithString: tr("Luminosité de la Touch Bar", "Touch Bar brightness"))
        brightnessTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        brightnessValue.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        brightnessValue.alignment = .right; brightnessValue.widthAnchor.constraint(equalToConstant: 58).isActive = true
        brightnessSlider.target = self; brightnessSlider.action = #selector(brightnessChanged(_:)); brightnessSlider.isContinuous = true
        brightnessSlider.setAccessibilityLabel("Luminosité de la Touch Bar en pourcentage")
        brightnessSlider.widthAnchor.constraint(equalToConstant: 440).isActive = true
        brightnessHold.target = self; brightnessHold.action = #selector(brightnessHoldChanged(_:))
        brightnessSync.target = self; brightnessSync.action = #selector(brightnessSyncChanged(_:))
        brightnessStatus.textColor = .secondaryLabelColor; brightnessStatus.font = .systemFont(ofSize: 11)
        brightnessStatus.widthAnchor.constraint(equalToConstant: 640).isActive = true
        let reconnect = NSButton(title: tr("Reconnecter la Touch Bar", "Reconnect Touch Bar"), target: self, action: #selector(reconnectBrightness(_:)))
        let restore = NSButton(title: tr("Rendre la main à macOS", "Return control to macOS"), target: self, action: #selector(restoreBrightness(_:)))
        let brightnessRow = NSStackView(views: [brightnessTitle, brightnessSlider, brightnessValue]); brightnessRow.spacing = 12; brightnessRow.alignment = .centerY
        let brightnessActions = NSStackView(views: [restore, reconnect]); brightnessActions.spacing = 10
        let accountRow = NSStackView(views: [accountButton, playlistButton, accountStatus]); accountRow.spacing = 12; accountRow.alignment = .centerY
        let stack = NSStackView(views: [info, detail, preview, row, show, accountRow, divider, brightnessRow, brightnessSync, brightnessHold, brightnessStatus, brightnessActions]); stack.orientation = .vertical; stack.spacing = 11; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 25)])
    }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let key = String(identifier.rawValue.dropFirst(prefix.count))
        guard key == "strip" else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let strip = makeStrip()
        strip.heightAnchor.constraint(equalToConstant: 30).isActive = true
        // Reserve room for macOS Control Strip and the system close button.
        // A 1000pt custom view is clipped rather than compressed by this host.
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.widthAnchor.constraint(equalToConstant: 640).isActive = true
        item.view = strip
        return item
    }
    func makeStrip() -> PlayerStrip {
        let strip = PlayerStrip(frame: NSRect(x: 0, y: 0, width: 640, height: 30))
        strip.command = { [weak self] action, value, uri in
            guard let self else { return }
            if action == "playlist" { self.showPlaylistMenu(); return }
            self.bridge.enqueue(action, value: value, uri: uri)
        }
        strips.append(strip)
        strip.update(bridge.state, online: bridge.online)
        return strip
    }
    func refresh() {
        guard bridge != nil else { return }
        let s = bridge.online ? bridge.state : account.playback
        let online = bridge.online || !account.playback.isEmpty
        for strip in strips { strip.update(s, online: online) }
        let playing = s["playing"] as? Bool == true
        if online && playing && !barShown { showBar() }
        if (!online || !playing) && barShown { hideBar() }
        let title = s["title"] as? String ?? "Aucun titre"
        let artist = s["artist"] as? String ?? ""
        let track = artist.isEmpty ? title : "\(title) — \(artist)"
        info.stringValue = online ? track : "Spotify déconnecté"
        trackButton?.title = online ? track : "Ouvre Spotify…"
        let device = s["device"] as? String ?? ""
        let connection = device.isEmpty ? tr("Lecture sur ce Mac", "Playing on this Mac") : tr("Lecture sur : \(device)", "Playing on: \(device)")
        detail.stringValue = (s["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (online ? connection : tr("Spotify fermé ou aucune lecture active.", "Spotify closed or no active playback."))
        accountStatus.stringValue = account.status
        accountButton.title = account.linked ? "Délier mon compte Spotify" : "Lier mon compte Spotify"
        playlistButton.isEnabled = account.linked && online && !((s["uri"] as? String) ?? "").isEmpty
        let repeatMode = s["repeat"] as? Int ?? 0
        let names = ["play": (s["playing"] as? Bool == true ? "⏸" : "▶"), "heart": (s["heart"] as? Bool == true ? "♥" : "♡"), "repeat": repeatMode == 2 ? "↻¹" : "↻", "mute": (s["muted"] as? Bool == true ? "🔇" : "♫")]
        for (key, list) in buttons {
            for b in list {
                b.isEnabled = online
                if let name = names[key] { b.title = name }
                let selected = (key == "heart" && s["heart"] as? Bool == true) || (key == "shuffle" && s["shuffle"] as? Bool == true) || (key == "repeat" && repeatMode > 0)
                b.contentTintColor = selected ? .systemGreen : nil
            }
        }
        let duration = s["duration"] as? Double ?? 0, position = s["position"] as? Double ?? 0
        if NSApp.currentEvent?.type != .leftMouseDragged {
            seekSlider?.doubleValue = duration > 0 ? min(1, max(0, position / duration)) : 0
            volumeSlider?.doubleValue = s["volume"] as? Double ?? 0
        }
        seekSlider?.isEnabled = online && duration > 0; volumeSlider?.isEnabled = online
        func time(_ ms: Double) -> String { let n = max(0, Int(ms / 1000)); return String(format: "%d:%02d", n / 60, n % 60) }
        timeLabel?.stringValue = "\(time(position)) / \(time(duration))"
    }
    @objc func playlistAction(_ sender: NSButton) {
        showPlaylistMenu(anchor: sender)
    }
    func showPlaylistMenu(anchor: NSView? = nil) {
        let menu = NSMenu(); menu.addItem(withTitle: tr("Chargement…", "Loading…"), action: nil, keyEquivalent: "")
        if let anchor { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor) }
        else { status.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: status.button) }
        account.fetchPlaylists { [weak self] playlists in
            guard let self else { return }
            let m = NSMenu();
            if playlists.isEmpty { m.addItem(withTitle: tr("Aucune playlist disponible", "No playlists available"), action: nil, keyEquivalent: "") }
            for playlist in playlists { let item = NSMenuItem(title: playlist.name, action: #selector(self.addToPlaylist(_:)), keyEquivalent: ""); item.target = self; item.representedObject = playlist.id; m.addItem(item) }
            if let anchor { m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor) }
            else { m.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self.status.button) }
        }
    }
    @objc func addToPlaylist(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        account.addCurrentTrack(to: id) { [weak self] ok in
            DispatchQueue.main.async { self?.detail.stringValue = ok ? tr("Titre ajouté à la playlist.", "Track added to playlist.") : tr("Impossible d’ajouter le titre.", "Could not add the track.") }
        }
    }
    @objc func menuCommand(_ sender: NSMenuItem) { if let key = sender.representedObject as? String { bridge.enqueue(key) } }
    @objc func accountAction(_ sender: NSButton) { account.linked ? account.unlink() : account.login() }
    @objc func command(_ sender: NSButton) { if let key = sender.identifier?.rawValue { bridge.enqueue(key) } }
    @objc func seek(_ sender: NSSlider) { bridge.enqueue("seek", value: sender.doubleValue) }
    @objc func volume(_ sender: NSSlider) { bridge.enqueue("volume", value: sender.doubleValue) }
    func connectBrightness() {
        let connected = STBBrightnessConnect()
        let current = connected ? STBBrightnessCurrent() : -1
        let available = connected && current >= 0
        brightnessSlider.isEnabled = available; brightnessHold.isEnabled = available
        guard available else {
            brightnessValue.stringValue = "— %"
            brightnessStatus.stringValue = "Touch Bar inaccessible. Clique sur Reconnecter après un réveil ou si macOS a refusé la connexion."
            return
        }
        if brightnessOriginal < 0 { brightnessOriginal = current }
        let saved = UserDefaults.standard.object(forKey: "brightnessLevel") as? Double
        brightnessSlider.doubleValue = saved ?? max(1, current * 100)
        brightnessHold.state = UserDefaults.standard.bool(forKey: "brightnessHold") ? .on : .off
        brightnessSync.state = UserDefaults.standard.object(forKey: "brightnessSync") == nil || UserDefaults.standard.bool(forKey: "brightnessSync") ? .on : .off
        brightnessHold.isEnabled = available && brightnessSync.state != .on
        updateBrightnessLabel()
        brightnessStatus.stringValue = "Touch Bar détectée. Déplace le curseur pour ajuster sa luminosité."
    }
    func updateBrightnessLabel() { brightnessValue.stringValue = String(format: "%.0f %%", brightnessSlider.doubleValue) }
    func applyBrightness() {
        guard STBBrightnessDisplayState() == 2 else { brightnessStatus.stringValue = "Touch Bar en veille : le réglage sera appliqué à son prochain réveil."; return }
        guard STBBrightnessSet(brightnessSlider.doubleValue / 100) else { brightnessStatus.stringValue = "macOS a refusé le réglage. Reconnecte la Touch Bar."; return }
        brightnessModified = true; brightnessStatus.stringValue = "Luminosité appliquée."
    }
    @objc func brightnessChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "brightnessLevel")
        updateBrightnessLabel(); applyBrightness()
    }
    @objc func brightnessHoldChanged(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on, forKey: "brightnessHold"); if sender.state == .on { applyBrightness() } }
    @objc func brightnessSyncChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "brightnessSync")
        brightnessHold.isEnabled = sender.state != .on
        if sender.state == .on { syncBrightness() }
    }
    @objc func reconnectBrightness(_ sender: NSButton) { connectBrightness() }
    @objc func restoreBrightness(_ sender: Any?) {
        brightnessHold.state = .off; UserDefaults.standard.set(false, forKey: "brightnessHold")
        guard brightnessModified, brightnessOriginal >= 0, STBBrightnessSet(brightnessOriginal) else { brightnessStatus.stringValue = "Maintien désactivé. macOS peut gérer la luminosité."; return }
        brightnessModified = false; brightnessSlider.doubleValue = max(1, brightnessOriginal * 100); updateBrightnessLabel(); brightnessStatus.stringValue = "Niveau initial restauré."
    }
    func brightnessTick() {
        if brightnessSync.state == .on { syncBrightness(); return }
        guard brightnessHold.state == .on, STBBrightnessDisplayState() == 2 else { return }
        let current = STBBrightnessCurrent(), wanted = brightnessSlider.doubleValue / 100
        if current < 0 { connectBrightness() } else if abs(current - wanted) > 0.01 { applyBrightness() }
    }
    func syncBrightness() {
        guard !brightnessSyncInFlight else { return }
        brightnessSyncInFlight = true
        let scale = brightnessSyncScale
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = STBBrightnessDisplayState()
            let screen = state == 2 ? STBMainDisplayBrightness() : -1
            let current = state == 2 ? STBBrightnessCurrent() : -1
            var applied = false
            let target = screen >= 0 ? max(0.01, min(1, screen * scale)) : -1
            if target >= 0 && (current < 0 || abs(current - target) > 0.01) { applied = STBBrightnessSet(target) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.brightnessSyncInFlight = false
                guard screen >= 0 else {
                    self.brightnessStatus.stringValue = "Luminosité de l’écran principal indisponible sur ce Mac."
                    return
                }
                let wanted = max(1, screen * 100 * self.brightnessSyncScale)
                if abs(self.brightnessSlider.doubleValue - wanted) > 0.5 { self.brightnessSlider.doubleValue = wanted; self.updateBrightnessLabel() }
                if applied { self.brightnessStatus.stringValue = String(format: "Synchronisée à 80 %% de l’écran principal : %.0f %%.", wanted) }
            }
        }
    }
    @objc func showBar() {
        if STBPresent(bar) { barShown = true }
        else { detail.stringValue = "Affichage global indisponible sur cette version de macOS. Utilise le panneau." }
    }
    @objc func hideBar() { STBDismiss(bar); barShown = false }
    @objc func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func openSpotify() { NSWorkspace.shared.open(URL(string: "spotify:")!) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { STBDismiss(bar); bridge.listener?.cancel(); restoreBrightness(nil) }
}
let app = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
    let strip = PlayerStrip(frame: NSRect(x: 0, y: 0, width: 640, height: 30))
    strip.update(["title": "Nights", "artist": "Frank Ocean", "playing": true, "duration": 301000.0, "position": 97000.0, "volume": 0.72], online: true)
    strip.layoutSubtreeIfNeeded()
    if let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) {
        strip.cacheDisplay(in: strip.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
    }
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
