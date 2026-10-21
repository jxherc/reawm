import AppKit
import Core

struct Tab {
    let id: WinID
    let title: String
    let icon: NSImage
    let active: Bool
}

// the browser-style tab bar floating just above a group's window. it's its own
// rounded piece: a square edge against the window's rounded corners never lines up.
// solid, not see-through: tab titles have to read the same over any window.
final class Strip: NSPanel {
    let tabs = TabsView(frame: .zero)
    private let bar = Bar()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.ignoresCycle, .fullScreenNone]
        contentView = bar
        tabs.autoresizingMask = [.width, .height]
        bar.addSubview(tabs)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // r is in global top-left coords. the strip sits right above window `above`.
    func show(_ r: CGRect, _ list: [Tab], above: WinID) {
        move(r)
        tabs.set(list)
        order(.above, relativeTo: Int(above))
    }

    // just follow the window, nothing redrawn
    func move(_ r: CGRect) {
        let f = Display.toAppKit(r)
        guard frame != f else { return }
        if frame.size == f.size {
            setFrameOrigin(f.origin)
        } else {
            setFrame(f, display: true)
            tabs.frame = bar.bounds
        }
    }
}

// window-chrome colour with the faint rim macOS windows have
final class Bar: NSView {
    static let radius: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.cornerRadius = Self.radius
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.12)).cgColor
    }
}

final class TabsView: NSView {
    var onPick: ((WinID) -> Void)?
    var onClose: ((WinID) -> Void)?
    var onMove: ((WinID, Int) -> Void)?
    var onTear: ((WinID) -> Void)?   // dragged off the strip

    private(set) var list: [Tab] = []
    private var hover: Int?
    private var press: (i: Int, at: NSPoint, dragged: Bool)?
    private var closing: Int?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    func set(_ l: [Tab]) {
        list = l
        needsDisplay = true
    }

    var tabWidth: CGFloat { bounds.width / CGFloat(max(1, list.count)) }

    func index(at x: CGFloat) -> Int {
        min(max(0, Int(x / tabWidth)), max(0, list.count - 1))
    }

    func rect(_ i: Int) -> NSRect {
        NSRect(x: CGFloat(i) * tabWidth, y: 0, width: tabWidth, height: bounds.height)
    }

    func closeRect(_ i: Int) -> NSRect {
        let r = rect(i)
        return NSRect(x: r.maxX - 24, y: r.midY - 8, width: 16, height: 16)
    }

    override func draw(_ dirty: NSRect) {
        let n = list.count
        for (i, t) in list.enumerated() {
            let r = rect(i)
            let chip = r.insetBy(dx: 3, dy: 3)
            if t.active || hover == i {
                NSColor.labelColor.withAlphaComponent(t.active ? 0.13 : 0.06).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7).fill()
            }
            // a divider only between two quiet tabs
            if i < n - 1, !t.active, !list[i + 1].active, hover != i, hover != i + 1 {
                NSColor.separatorColor.setFill()
                NSRect(x: r.maxX - 0.5, y: r.minY + 8, width: 1, height: r.height - 16).fill()
            }

            let showClose = hover == i
            let room = chip.insetBy(dx: showClose ? 26 : 10, dy: 0)
            let font = NSFont.systemFont(ofSize: 12, weight: t.active ? .medium : .regular)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: t.active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ]
            let title = t.title.isEmpty ? " " : t.title
            let tw = min(ceil((title as NSString).size(withAttributes: attrs).width), max(0, room.width - 22))
            let total = 16 + 6 + tw
            let x = room.midX - total / 2
            t.icon.draw(in: NSRect(x: x, y: r.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver,
                        fraction: t.active ? 1 : 0.75, respectFlipped: true, hints: nil)
            let th = font.ascender - font.descender
            (title as NSString).draw(in: NSRect(x: x + 22, y: r.midY - th / 2 - 1, width: tw, height: th + 2), withAttributes: attrs)

            if showClose {
                let c = closeRect(i)
                if closing == i {
                    NSColor.labelColor.withAlphaComponent(0.12).setFill()
                    NSBezierPath(ovalIn: c).fill()
                }
                let x = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
                if let x {
                    let tinted = x.tinted(.secondaryLabelColor)
                    tinted.draw(in: NSRect(x: c.midX - tinted.size.width / 2, y: c.midY - tinted.size.height / 2,
                                           width: tinted.size.width, height: tinted.size.height),
                                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        let h = list.isEmpty ? nil : index(at: convert(e.locationInWindow, from: nil).x)
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        guard !list.isEmpty else { return }
        let p = convert(e.locationInWindow, from: nil)
        let i = index(at: p.x)
        if hover == i, closeRect(i).insetBy(dx: -3, dy: -3).contains(p) {
            closing = i
        } else {
            press = (i, p, false)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard var pr = press, pr.i < list.count else { return }
        let p = convert(e.locationInWindow, from: nil)
        if !pr.dragged, hypot(p.x - pr.at.x, p.y - pr.at.y) < 4 { return }
        pr.dragged = true
        let id = list[pr.i].id
        // pulled clearly off the strip: it becomes its own window again
        if p.y < -18 || p.y > bounds.height + 18 || p.x < -30 || p.x > bounds.width + 30 {
            press = nil
            hover = nil
            onTear?(id)
            return
        }
        let j = index(at: p.x)
        if j != pr.i {
            onMove?(id, j)
            pr.i = j
            hover = j
        }
        press = pr
    }

    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let c = closing {
            closing = nil
            if c < list.count, closeRect(c).insetBy(dx: -3, dy: -3).contains(p) { onClose?(list[c].id) }
        } else if let pr = press, !pr.dragged, pr.i < list.count {
            onPick?(list[pr.i].id)
        }
        press = nil
        needsDisplay = true
    }
}

extension NSImage {
    func tinted(_ c: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { r in
            self.draw(in: r)
            c.set()
            r.fill(using: .sourceAtop)
            return true
        }
        return img
    }
}

// the outline that says "drop here to make a tab"
final class Hint: NSPanel {
    private let box = NSView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.borderWidth = 3
        box.autoresizingMask = [.width, .height]
        contentView = NSView()
        contentView?.addSubview(box)
    }

    func show(_ r: CGRect?) {
        guard let r else { orderOut(nil); return }
        let a = NSColor.controlAccentColor
        box.layer?.borderColor = a.withAlphaComponent(0.9).cgColor
        box.layer?.backgroundColor = a.withAlphaComponent(0.12).cgColor
        setFrame(Display.toAppKit(r.insetBy(dx: -3, dy: -3)), display: true)
        box.frame = contentView?.bounds ?? .zero
        orderFrontRegardless()
    }
}
