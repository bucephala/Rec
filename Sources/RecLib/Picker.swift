import Cocoa
import ScreenCaptureKit

protocol PickerDelegate: AnyObject {
    func picker(_ picker: Picker, didPick target: CaptureTarget, content: SCShareableContent)
    func pickerDidCancel(_ picker: Picker)
}

/// Full screen overlay on every display. Drag a region, click a window, option click a whole display.
final class Picker {
    weak var delegate: PickerDelegate?
    private var windows: [NSWindow] = []
    private var content: SCShareableContent?

    var isShowing: Bool { !windows.isEmpty }

    func show(content: SCShareableContent) {
        close()
        self.content = content
        guard !NSScreen.screens.isEmpty else {
            delegate?.pickerDidCancel(self)
            return
        }
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .statusBar + 1
            w.isOpaque = false
            w.backgroundColor = .clear
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = PickerView(frame: screen.frame, screen: screen, content: content)
            view.picker = self
            w.contentView = view
            w.makeKeyAndOrderFront(nil)
            if screen == NSScreen.main { w.makeFirstResponder(view) }
            windows.append(w)
        }
        NSCursor.crosshair.push()
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        if !windows.isEmpty { NSCursor.pop() }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        content = nil
    }

    fileprivate func finish(_ target: CaptureTarget) {
        guard let c = content else { return }
        close()
        delegate?.picker(self, didPick: target, content: c)
    }

    fileprivate func cancel() {
        close()
        delegate?.pickerDidCancel(self)
    }
}

private final class PickerView: NSView {
    weak var picker: Picker?
    private let screen: NSScreen
    private let content: SCShareableContent
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    init(frame: NSRect, screen: NSScreen, content: SCShareableContent) {
        self.screen = screen
        self.content = content
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        if let a = dragStart, let b = dragCurrent {
            let rect = rectFrom(a, b)
            if rect.width > 10, rect.height > 10 {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: rect).setClip()
                NSColor.clear.setFill()
                rect.fill(using: .copy)
                NSGraphicsContext.current?.restoreGraphicsState()
                NSColor.systemRed.setStroke()
                let p = NSBezierPath(rect: rect)
                p.lineWidth = 2
                p.stroke()
                let scale = screen.backingScaleFactor
                pill("\(Int(rect.width * scale)) × \(Int(rect.height * scale))",
                     at: NSPoint(x: rect.midX, y: max(rect.minY - 30, 10)), mono: true)
            }
        }
        pill("drag region  ·  click window  ·  ⌥click whole display  ·  esc cancel",
             at: NSPoint(x: bounds.midX, y: 40), mono: false)
    }

    private func pill(_ text: String, at center: NSPoint, mono: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: mono ? NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
                        : NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let r = NSRect(x: center.x - size.width / 2 - 12, y: center.y, width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: r.minX + 12, y: r.minY + 6), withAttributes: attrs)
    }

    private func rectFrom(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            pickDisplay()
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let a = dragStart, let b = dragCurrent else { return }
        let rect = rectFrom(a, b)
        dragStart = nil
        dragCurrent = nil
        if rect.width > 10, rect.height > 10 {
            pickRegion(rect)
        } else {
            pickWindow(at: convert(event.locationInWindow, from: nil))
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { picker?.cancel() }
    }

    private var display: SCDisplay? {
        content.displays.first { $0.displayID == screen.displayID }
    }

    private func pickRegion(_ viewRect: NSRect) {
        guard let d = display else { return picker?.cancel() ?? () }
        let scale = screen.backingScaleFactor
        let rect = CGRect(x: viewRect.origin.x * scale,
                          y: (screen.frame.height - viewRect.origin.y - viewRect.height) * scale,
                          width: viewRect.width * scale,
                          height: viewRect.height * scale)
        picker?.finish(.region(display: d, rect: rect))
    }

    private func pickWindow(at point: NSPoint) {
        let global = NSPoint(x: point.x + screen.frame.origin.x, y: point.y + screen.frame.origin.y)
        let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? screen.frame.height
        let hit = content.windows.first { win in
            guard win.isOnScreen, win.frame.width > 0, win.frame.height > 0, win.windowLayer == 0 else { return false }
            let f = CGRect(x: win.frame.origin.x, y: totalHeight - win.frame.origin.y - win.frame.height,
                           width: win.frame.width, height: win.frame.height)
            return f.contains(global)
        }
        if let w = hit, let d = display {
            picker?.finish(.window(w, d))
        } else {
            picker?.cancel()
        }
    }

    private func pickDisplay() {
        guard let d = display else { return picker?.cancel() ?? () }
        picker?.finish(.display(d))
    }
}
