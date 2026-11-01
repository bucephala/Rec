import Cocoa
import ScreenCaptureKit

public enum CaptureTarget {
    case display(SCDisplay)
    case region(display: SCDisplay, rect: CGRect)
    case window(SCWindow, SCDisplay)

    public var displayID: CGDirectDisplayID {
        switch self {
        case .display(let d), .region(let d, _), .window(_, let d): return d.displayID
        }
    }

    public var label: String {
        switch self {
        case .display: return "Display"
        case .region(_, let r): return "Region \(Int(r.width))×\(Int(r.height))"
        case .window(let w, _): return w.owningApplication?.applicationName ?? w.title ?? "Window"
        }
    }

    public func resolved(with content: SCShareableContent) -> CaptureTarget? {
        switch self {
        case .display(let d):
            return content.displays.first { $0.displayID == d.displayID }.map { .display($0) }
        case .region(let d, let rect):
            return content.displays.first { $0.displayID == d.displayID }.map { .region(display: $0, rect: rect) }
        case .window(let w, let d):
            guard let fw = content.windows.first(where: { $0.windowID == w.windowID }) else { return nil }
            let fd = content.displays.first { $0.displayID == d.displayID } ?? d
            return .window(fw, fd)
        }
    }

    /// The display the mouse cursor is currently on, falling back to the main display.
    public static func displayUnderMouse(in content: SCShareableContent) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let id = screen?.displayID ?? CGMainDisplayID()
        return content.displays.first { $0.displayID == id } ?? content.displays.first
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
    }
}
