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

// the current macOS Space of each display, through SkyLight (private, read only)
enum Spaces {
    private typealias MainConn = @convention(c) () -> Int32
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64

    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let mainConn: MainConn? = sym("SLSMainConnectionID")
    private static let currentSpace: CurrentSpace? = sym("SLSManagedDisplayGetCurrentSpace")

    private static func sym<T>(_ name: String) -> T? {
        guard let sky, let p = dlsym(sky, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static func current(_ d: Display) -> UInt64 {
        guard let mainConn, let currentSpace else { return 0 }
        return currentSpace(mainConn(), d.uuid as CFString)
    }

    private typealias WindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let windowSpaces: WindowSpaces? = sym("SLSCopySpacesForWindows")

    // the Space a window lives on, nil when SkyLight won't say (minimized, hidden app)
    static func of(_ id: CGWindowID) -> UInt64? {
        guard let mainConn, let windowSpaces,
              let a = windowSpaces(mainConn(), 7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return a.first?.uint64Value
    }

    // false for a window on a Space nobody is looking at right now
    static func showing(_ id: CGWindowID) -> Bool {
        guard let s = of(id) else { return true }
        return Display.all.contains { current($0) == s }
    }
}
