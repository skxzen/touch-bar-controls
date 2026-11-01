import AppKit

private let spotifyGreen = NSColor(srgbRed: 0.12, green: 0.84, blue: 0.38, alpha: 1)

final class TransportButton: NSButton {
    var ring = false
    override func draw(_ dirtyRect: NSRect) {
        if ring {
            spotifyGreen.withAlphaComponent(isEnabled ? 1 : 0.35).setStroke()
            let p = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)); p.lineWidth = 1.6; p.stroke()
        }
        super.draw(dirtyRect)
    }
}
// Draw the entire control ourselves. NSSlider has a separate Touch Bar renderer;
// mixing its automatic fill with a custom cell can produce a second, wrong fill.
final class TrackedSlider: NSControl {
    var tracking = false
    var beginTracking: (() -> Void)?
    private var value: Double = 0
    private var initialValue: Double = 0
    override var doubleValue: Double {
        get { value }
        set {
            value = newValue.isFinite ? min(1, max(0, newValue)) : 0
            setAccessibilityValue(NSNumber(value: value))
            needsDisplay = true
        }
    }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    var trackRect: NSRect { NSRect(x: 7, y: bounds.midY - 1.5, width: max(1, bounds.width - 14), height: 3) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = NSActionCell()
        allowedTouchTypes = [.direct]
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityMinValue(0); setAccessibilityMaxValue(1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        // Clear old pixels even when AppKit supplies only a dirty subregion.
        NSColor.black.setFill(); bounds.fill()
        let r = trackRect, x = r.minX + CGFloat(value) * r.width
        NSColor(white: 0.23, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        if value > 0 {
            spotifyGreen.withAlphaComponent(isEnabled ? 1 : 0.3).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: x - r.minX, height: r.height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.3).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
    }
    func setPosition(_ point: NSPoint) { doubleValue = Double((point.x - trackRect.minX) / trackRect.width) }
    private func begin(_ point: NSPoint) {
        guard isEnabled, !tracking else { return }
        initialValue = value; tracking = true; beginTracking?(); setPosition(point)
    }
    private func finish(_ point: NSPoint) {
        guard tracking else { return }
        setPosition(point)
        // Keep tracking true during the action so seeks use the captured track URI.
        sendAction(action, to: target)
        tracking = false
    }
    override func mouseDown(with event: NSEvent) { begin(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { if tracking { setPosition(convert(event.locationInWindow, from: nil)) } }
    override func mouseUp(with event: NSEvent) { finish(convert(event.locationInWindow, from: nil)) }
    override func touchesBegan(with event: NSEvent) {
        if let touch = event.touches(matching: .began, in: self).first(where: { $0.type == .direct }) { begin(touch.location(in: self)) }
    }
    override func touchesMoved(with event: NSEvent) {
        if tracking, let touch = event.touches(matching: .moved, in: self).first(where: { $0.type == .direct }) { setPosition(touch.location(in: self)) }
    }
    override func touchesEnded(with event: NSEvent) {
        if let touch = event.touches(matching: .ended, in: self).first(where: { $0.type == .direct }) { finish(touch.location(in: self)) }
    }
    override func touchesCancelled(with event: NSEvent) { if tracking { doubleValue = initialValue; tracking = false } }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }; doubleValue += 0.02; sendAction(action, to: target); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }; doubleValue -= 0.02; sendAction(action, to: target); return true
    }
}
final class PlayerStrip: NSView {
    let mark = NSImageView()
    let brand = NSTextField(labelWithString: "Spotify")
    let artwork = NSImageView()
    let title = NSTextField(labelWithString: "Spotify déconnecté")
    let artist = NSTextField(labelWithString: "Ouvre Spotify pour commencer")
    let elapsed = NSTextField(labelWithString: "0:00")
    let remaining = NSTextField(labelWithString: "−0:00")
    let previous = TransportButton(), play = TransportButton(), next = TransportButton()
    let progress = TrackedSlider()
    var command: ((String, Double?, String?) -> Void)?
    var uri = "", seekURI = "", imageURL = "__initial__"
    var imageTask: URLSessionDataTask?
    var duration: Double = 0
    var separators: [CGFloat] = []
    var lastSeek = Date.distantPast
    override var intrinsicContentSize: NSSize { NSSize(width: 640, height: 30) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        for v in [mark, brand, artwork, title, artist, elapsed, remaining, previous, play, next, progress] { addSubview(v) }
        mark.image = Bundle.main.image(forResource: "Spotify_icon")
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.setAccessibilityLabel("Spotify")
        brand.font = .systemFont(ofSize: 12, weight: .semibold); brand.textColor = .white
        title.font = .systemFont(ofSize: 11, weight: .semibold); title.textColor = .white
        artist.font = .systemFont(ofSize: 9); artist.textColor = NSColor(white: 0.65, alpha: 1)
        for label in [brand, title, artist, elapsed, remaining] { label.lineBreakMode = .byTruncatingTail }
        for label in [elapsed, remaining] { label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular); label.textColor = .lightGray; label.alignment = .center }
        artwork.wantsLayer = true; artwork.layer?.cornerRadius = 3; artwork.layer?.masksToBounds = true; artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.contentTintColor = .gray
        for (b, symbol, label, action) in [(previous,"backward.end.fill","Précédent","previous"), (play,"play.fill","Lecture / pause","play"), (next,"forward.end.fill","Suivant","next")] {
            b.isBordered = false; b.imagePosition = .imageOnly; b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            b.contentTintColor = .white; b.identifier = .init(action); b.target = self; b.action = #selector(pressed(_:)); b.setAccessibilityLabel(label)
        }
        play.ring = true
        for (s, label) in [(progress,"Progression du morceau")] {
            s.isContinuous = false; s.target = self; s.setAccessibilityLabel(label)
        }
        progress.action = #selector(seek(_:))
        progress.beginTracking = { [weak self] in self?.seekURI = self?.uri ?? "" }
        toolTip = "Progression directe. Favoris, aléatoire et répétition dans le menu ♪."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let w = bounds.width, wide = w >= 850
        var x: CGFloat = 4
        mark.frame = NSRect(x: x, y: 0, width: 28, height: 30); x += 30
        brand.isHidden = !wide
        if wide { brand.frame = NSRect(x: x, y: 7, width: 51, height: 17); x += 57 }
        separators = [x + 3]; x += 14
        artwork.frame = NSRect(x: x, y: 2, width: 26, height: 26); x += 34
        let tw: CGFloat = wide ? 175 : 115
        title.frame = NSRect(x: x, y: 15, width: tw, height: 14)
        artist.frame = NSRect(x: x, y: 2, width: tw, height: 13); x += tw + 12
        previous.frame = NSRect(x: x, y: 1, width: 28, height: 28); x += 32
        play.frame = NSRect(x: x, y: 0, width: 30, height: 30); x += 34
        next.frame = NSRect(x: x, y: 1, width: 28, height: 28); x += 38
        remaining.frame = NSRect(x: w - 43, y: 8, width: 37, height: 14)
        elapsed.frame = NSRect(x: x, y: 8, width: 35, height: 14); x += 38
        progress.frame = NSRect(x: x, y: 2, width: max(35, remaining.frame.minX - x - 6), height: 26)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        NSColor(white: 0.25, alpha: 1).setStroke()
        for x in separators { let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: 5)); p.line(to: NSPoint(x: x, y: 25)); p.lineWidth = 0.5; p.stroke() }
    }
    func update(_ state: [String: Any], online: Bool) {
        uri = state["uri"] as? String ?? ""
        title.stringValue = online ? (state["title"] as? String ?? "Aucun titre") : "Spotify déconnecté"
        artist.stringValue = online ? (state["artist"] as? String ?? "") : "Ouvre Spotify pour commencer"
        title.toolTip = title.stringValue; artist.toolTip = artist.stringValue
        play.image = NSImage(systemSymbolName: state["playing"] as? Bool == true ? "pause.fill" : "play.fill", accessibilityDescription: "Lecture / pause")
        for b in [previous, play, next] { b.isEnabled = online }
        duration = max(0, state["duration"] as? Double ?? 0)
        let position = min(duration, max(0, state["position"] as? Double ?? 0))
        if !progress.tracking && Date().timeIntervalSince(lastSeek) > 1 { progress.doubleValue = duration > 0 ? position / duration : 0 }
        progress.isEnabled = online && duration > 0
        func time(_ ms: Double) -> String { let s = Int(ms / 1000); return String(format: "%d:%02d", s / 60, s % 60) }
        elapsed.stringValue = time(position); remaining.stringValue = "−" + time(duration - position)
        loadArtwork(state["artwork"] as? String ?? "")
    }
    func loadArtwork(_ source: String) {
        guard source != imageURL else { return }
        imageURL = source; imageTask?.cancel()
        artwork.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Pochette")
        guard let url = URL(string: source), url.scheme == "https", url.host == "i.scdn.co" else { return }
        var request = URLRequest(url: url); request.timeoutInterval = 8
        imageTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let data = data, data.count < 2_000_000, (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { guard let self = self, self.imageURL == source else { return }; self.artwork.image = image }
        }
        imageTask?.resume()
    }
    @objc func pressed(_ sender: NSButton) { command?(sender.identifier!.rawValue, nil, nil) }
    @objc func seek(_ sender: TrackedSlider) { lastSeek = Date(); command?("seek", sender.doubleValue, progress.tracking ? seekURI : uri) }
}
