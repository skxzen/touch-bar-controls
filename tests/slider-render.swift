import AppKit
let app = NSApplication.shared
for width in [65.0, 100.0, 340.0, 600.0] {
    let slider = TrackedSlider(frame: NSRect(x: 0, y: 0, width: width, height: 26))
    slider.isEnabled = true
    // Include backwards movement to detect stale fill left by a partial redraw.
    for fraction in [0.0, 0.25, 0.5, 0.75, 1.0, 0.2, 0.0] {
        slider.doubleValue = fraction
        let rep = slider.bitmapImageRepForCachingDisplay(in: slider.bounds)!
        slider.cacheDisplay(in: slider.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / width
        let expected = (7 + fraction * (width - 14)) * scale
        var whites: [Double] = []
        for x in 0..<rep.pixelsWide {
            let color = rep.colorAt(x: x, y: rep.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
            if color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9 { whites.append(Double(x)) }
            if color.greenComponent > 0.65 && color.redComponent < 0.4 {
                precondition(Double(x) <= expected + scale, "Green fill overshoots knob")
            }
        }
        precondition(!whites.isEmpty, "Knob missing")
        let center = whites.reduce(0, +) / Double(whites.count)
        precondition(abs(center - expected) <= 2 * scale, "Knob position differs from fraction")
        slider.setPosition(NSPoint(x: 7 + fraction * (width - 14), y: 13))
        precondition(abs(slider.doubleValue - fraction) < 0.00001, "Hit mapping differs from rendering")
    }
}
print("PASS: 28 pixel render checks, green fill, knob alignment, backward redraw, touch coordinate mapping")

// Integration check: use the real host width, not only isolated slider widths.
let strip = PlayerStrip(frame: NSRect(x: 0, y: 0, width: 640, height: 30))
strip.update(["title": "Every Breath You Take", "artist": "The Police", "position": 65000.0, "duration": 253000.0, "volume": 0.5], online: true)
strip.layoutSubtreeIfNeeded()
for view in strip.subviews where !view.isHidden {
    precondition(view.frame.minX >= 0 && view.frame.maxX <= 640, "Control clipped at Touch Bar width: \(view)")
}
precondition(strip.progress.frame.maxX < strip.remaining.frame.minX, "Timeline overlaps remaining time")
precondition(strip.remaining.frame.maxX < strip.mute.frame.minX, "Remaining time overlaps volume")
precondition(strip.mute.frame.maxX < strip.volume.frame.minX, "Volume controls overlap")
precondition(abs(strip.progress.doubleValue - 65.0 / 253.0) < 0.00001)
print("PASS: full 640pt strip fits, remaining time and volume visible, photo case = 25.69%")
