import AppKit

// a display in top-left global coords (what AX and CGWindow use)
struct Display {
    let id: CGDirectDisplayID
    let uuid: String
    let frame: CGRect     // whole display
    let visible: CGRect   // minus menu bar and dock
    let screen: NSScreen

    static var all: [Display] {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        func flip(_ r: NSRect) -> CGRect {
            CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
        }
        return NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let uuid = u.map { CFUUIDCreateString(nil, $0) as String } ?? "\(id)"
            return Display(id: id, uuid: uuid, frame: flip(s.frame), visible: flip(s.visibleFrame), screen: s)
        }
    }

    static func at(_ pt: CGPoint) -> Display? {
        let all = all
        return all.first { $0.frame.contains(pt) } ?? all.first
    }

    static var mouse: CGPoint {
        // NSEvent.mouseLocation is bottom-left; CGEvent is top-left
        CGEvent(source: nil)?.location ?? .zero
    }

    // top-left global rect -> AppKit rect for placing our own windows
    static func toAppKit(_ r: CGRect) -> NSRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }
}
