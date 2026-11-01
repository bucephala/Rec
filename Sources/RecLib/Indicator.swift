import Cocoa

/// Floating pill at the top of the recorded display. Shows elapsed time, live
/// audio meters, and any warning. Clicking it stops the recording.
final class Indicator {
    private var window: NSWindow?
    private var view: IndicatorView?
    var onClick: (() -> Void)?

    func show(on screen: NSScreen) {
        hide()
        let width: CGFloat = 250
        let height: CGFloat = 32
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.visibleFrame.maxY - height - 6,
                           width: width, height: height)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = IndicatorView(frame: NSRect(origin: .zero, size: frame.size))
        v.onClick = { [weak self] in self?.onClick?() }
        w.contentView = v
        w.orderFrontRegardless()
        window = w
        view = v
    }

    func update(elapsed: TimeInterval, system: Float, mic: Float?, warning: String?) {
        guard let v = view else { return }
        let s = max(0, Int(elapsed))
        v.time = String(format: "%d:%02d", s / 60, s % 60)
        v.systemLevel = AudioMeter.meterLevel(peak: system)
        v.micLevel = mic.map { AudioMeter.meterLevel(peak: $0) }
        v.warning = warning
        v.tick.toggle()
        v.needsDisplay = true
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        view = nil
    }
}

private final class IndicatorView: NSView {
    var time = "0:00"
    var systemLevel: Float = 0
    var micLevel: Float? = 0
    var warning: String?
    var tick = false
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (warning == nil ? NSColor(red: 0.80, green: 0.10, blue: 0.12, alpha: 0.94)
                        : NSColor(red: 0.85, green: 0.50, blue: 0.0, alpha: 0.94)).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        bg.lineWidth = 0.5
        bg.stroke()

        // pulsing dot
        let dot = NSRect(x: 12, y: (bounds.height - 9) / 2, width: 9, height: 9)
        NSColor.white.withAlphaComponent(tick ? 1 : 0.35).setFill()
        NSBezierPath(ovalIn: dot).fill()

        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
        let mono: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)]
        let tiny: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.8)]

        ("REC" as NSString).draw(at: NSPoint(x: 27, y: 9), withAttributes: bold)
        (time as NSString).draw(at: NSPoint(x: 58, y: 9), withAttributes: mono)

        if let warning = warning {
            (warning.uppercased() as NSString).draw(at: NSPoint(x: 104, y: 9), withAttributes: bold)
            return
        }

        meter(label: "SYS", level: systemLevel, x: 108, attrs: tiny)
        if let m = micLevel {
            meter(label: "MIC", level: m, x: 178, attrs: tiny)
        } else {
            ("NO MIC" as NSString).draw(at: NSPoint(x: 178, y: 11), withAttributes: tiny)
        }
    }

    private func meter(label: String, level: Float, x: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        (label as NSString).draw(at: NSPoint(x: x, y: 11), withAttributes: attrs)
        let track = NSRect(x: x + 20, y: 12, width: 44, height: 8)
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        var fill = track
        fill.size.width = track.width * CGFloat(level)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }
}
