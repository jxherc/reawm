import AppKit
import Core

struct Tab {
    let id: WinID
    let title: String
    let icon: NSImage
    let active: Bool
}

// the browser-style tab bar floating just above a group's window. it looks like a
// second row of the menu bar: no background of its own, just the wallpaper, with text
// in whichever colour macOS picked for the menu bar over that wallpaper.
final class Strip: NSPanel {
    let tabs = TabsView(frame: .zero)

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
        contentView = tabs
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // r is in global top-left coords. the strip sits right above window `above`.
    // look: the menu bar's appearance, so the text matches it.
    func show(_ r: CGRect, _ list: [Tab], above: WinID, look: NSAppearance?) {
        match(look)
        move(r)
        tabs.vertical = Settings.side != .top
        tabs.set(list)
        order(.above, relativeTo: Int(above))
    }

    // the menu bar's text flips between light and dark with the wallpaper (a dynamic
    // wallpaper going dark at night, or a new picture): follow it
    func match(_ look: NSAppearance?) {
        guard let look, appearance?.name != look.name else { return }
        appearance = look
        tabs.needsDisplay = true
    }

    // just follow the window, nothing redrawn
    func move(_ r: CGRect) {
        let f = Display.toAppKit(r)
        guard frame != f else { return }
        if frame.size == f.size { setFrameOrigin(f.origin) } else { setFrame(f, display: true) }
    }
}

final class TabsView: NSView {
    var onPick: ((WinID) -> Void)?
    var onClose: ((WinID) -> Void)?
    var onMove: ((WinID, Int) -> Void)?
    var onTear: ((WinID) -> Void)?   // dragged off the strip

    private(set) var list: [Tab] = []
    var vertical = false   // a sidebar: one row per tab
    private var hover: Int?
    private var press: (i: Int, at: NSPoint, dragged: Bool)?
    private var closing: Int?
    private var middle: Int?
    private var spring: (i: Int, timer: Timer)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // anything being dragged, so hovering it over a tab can open that tab
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .rtf, .html, .png, .tiff, .pdf, .color]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }
    required init?(coder: NSCoder) { fatalError() }

    // drag something over a tab and hold: that tab opens, so you can drop into it.
    // the bar itself takes no drops.
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { springLoad(s); return [] }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { springLoad(s); return [] }
    override func draggingExited(_ s: NSDraggingInfo?) { unspring() }
    override func draggingEnded(_ s: NSDraggingInfo) { unspring() }

    private func springLoad(_ s: NSDraggingInfo) {
        guard !list.isEmpty else { return }
        let i = index(at: convert(s.draggingLocation, from: nil))
        if hover != i { hover = i; needsDisplay = true }
        guard spring?.i != i else { return }
        spring?.timer.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.springOpen(i) }
        }
        spring = (i, t)
    }

    private func springOpen(_ i: Int) {
        guard i < list.count, !list[i].active else { return }
        onPick?(list[i].id)
    }

    private func unspring() {
        spring?.timer.invalidate()
        spring = nil
        hover = nil
        needsDisplay = true
    }

    func set(_ l: [Tab]) {
        list = l
        needsDisplay = true
    }

    // a top bar splits its width evenly; a sidebar stacks rows, squeezing them when there are many
    static let pad: CGFloat = 6
    var slot: CGFloat {
        let n = CGFloat(max(1, list.count))
        return vertical ? min(32, max(22, (bounds.height - Self.pad * 2) / n)) : bounds.width / n
    }

    private func along(_ p: NSPoint) -> CGFloat { vertical ? p.y - Self.pad : p.x }

    func index(at p: NSPoint) -> Int {
        min(max(0, Int(along(p) / slot)), max(0, list.count - 1))
    }

    // where a dropped window would go: the gap nearest p
    func insertion(at p: NSPoint) -> Int {
        min(max(0, Int((along(p) / slot).rounded())), list.count)
    }

    func rect(_ i: Int) -> NSRect {
        vertical
            ? NSRect(x: 0, y: Self.pad + CGFloat(i) * slot, width: bounds.width, height: slot)
            : NSRect(x: CGFloat(i) * slot, y: 0, width: slot, height: bounds.height)
    }

    func closeRect(_ i: Int) -> NSRect {
        let r = rect(i)
        return NSRect(x: r.maxX - (vertical ? 28 : 24), y: r.midY - 8, width: 16, height: 16)
    }

    override func draw(_ dirty: NSRect) {
        // all but invisible: fully clear pixels would let clicks fall through to the desktop
        NSColor(white: 0.5, alpha: 0.02).setFill()
        bounds.fill()
        let n = list.count
        for (i, t) in list.enumerated() {
            let r = rect(i)
            let chip = vertical ? r.insetBy(dx: 6, dy: 2) : r.insetBy(dx: 3, dy: 3)
            if t.active || hover == i {
                NSColor.labelColor.withAlphaComponent(t.active ? 0.13 : 0.06).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7).fill()
            }
            // a divider only between two quiet tabs, side by side
            if !vertical, i < n - 1, !t.active, !list[i + 1].active, hover != i, hover != i + 1 {
                NSColor.separatorColor.setFill()
                NSRect(x: r.maxX - 0.5, y: r.minY + 8, width: 1, height: r.height - 16).fill()
            }

            let showClose = hover == i
            var room = chip.insetBy(dx: 10, dy: 0)
            if showClose { room.size.width -= 16 }
            if showClose, !vertical { room = chip.insetBy(dx: 26, dy: 0) }
            let font = NSFont.systemFont(ofSize: 13, weight: t.active ? .medium : .regular)   // the menu bar's size
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: t.active ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.72),
                .paragraphStyle: para,
            ]
            let title = t.title.isEmpty ? " " : t.title
            let tw = min(ceil((title as NSString).size(withAttributes: attrs).width), max(0, room.width - 22))
            let total = 16 + 6 + tw
            // centred in a top bar, left-aligned down a sidebar
            let x = vertical ? room.minX : room.midX - total / 2
            t.icon.draw(in: NSRect(x: x, y: r.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver,
                        fraction: t.active ? 1 : 0.85, respectFlipped: true, hints: nil)
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
                    let tinted = x.tinted(NSColor.labelColor.withAlphaComponent(0.72))
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
        let h = list.isEmpty ? nil : index(at: convert(e.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        guard !list.isEmpty else { return }
        let p = convert(e.locationInWindow, from: nil)
        let i = index(at: p)
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
        let m: CGFloat = 24
        if p.y < -m || p.y > bounds.height + m || p.x < -m || p.x > bounds.width + m {
            press = nil
            hover = nil
            onTear?(id)
            return
        }
        let j = index(at: p)
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

    // middle click closes a tab like in a browser: on release, over the tab it went down on
    override func otherMouseDown(with e: NSEvent) {
        guard e.buttonNumber == 2, !list.isEmpty else { return }
        middle = index(at: convert(e.locationInWindow, from: nil))
    }

    override func otherMouseUp(with e: NSEvent) {
        guard e.buttonNumber == 2, let m = middle else { return }
        middle = nil
        let p = convert(e.locationInWindow, from: nil)
        if bounds.contains(p), index(at: p) == m, m < list.count { onClose?(list[m].id) }
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
