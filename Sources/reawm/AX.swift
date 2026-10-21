import AppKit
import ApplicationServices
import Core

// private but used by every mac window manager: AX element -> CGWindowID
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func get<T>(_ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attr as CFString, &v) == .success else { return nil }
        return v as? T
    }

    func set(_ attr: String, _ v: CFTypeRef) {
        AXUIElementSetAttributeValue(self, attr as CFString, v)
    }

    var point: CGPoint? {
        guard let v: AXValue = get(kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(v, .cgPoint, &p)
        return p
    }

    var size: CGSize? {
        guard let v: AXValue = get(kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        AXValueGetValue(v, .cgSize, &s)
        return s
    }

    var winID: WinID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(self, &id) == .success, id != 0 else { return nil }
        return id
    }
}

// one real window of another app
final class Win {
    let id: WinID
    let el: AXUIElement
    let pid: pid_t
    let bundle: String

    // last frame we set, so our own moves don't look like user drags
    var placed: CGRect?
    // fixed-size windows (WeChat, settings panes) can be moved but never tabbed
    var resizable = true

    init(id: WinID, el: AXUIElement, pid: pid_t, bundle: String) {
        self.id = id
        self.el = el
        self.pid = pid
        self.bundle = bundle
    }

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var title: String { el.get(kAXTitleAttribute) ?? "" }
    var minimized: Bool { el.get(kAXMinimizedAttribute) ?? false }
    var fullscreen: Bool { el.get("AXFullScreen") ?? false }

    var frame: CGRect? {
        guard let p = el.point, let s = el.size else { return nil }
        return CGRect(origin: p, size: s)
    }

    func setFrame(_ r: CGRect) {
        // round, don't use .integral: that grows the size when the origin is fractional
        let r = CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
        placed = r
        var p = r.origin, s = r.size
        // size, move, size again: apps clamp size to the screen they're on, so the
        // first size can be wrong when crossing displays
        if let sv = AXValueCreate(.cgSize, &s) { el.set(kAXSizeAttribute, sv) }
        if let pv = AXValueCreate(.cgPoint, &p) { el.set(kAXPositionAttribute, pv) }
        if let sv = AXValueCreate(.cgSize, &s) { el.set(kAXSizeAttribute, sv) }
    }

    func move(to p: CGPoint) {
        var p = p
        if let pv = AXValueCreate(.cgPoint, &p) { el.set(kAXPositionAttribute, pv) }
        placed = frame
    }

    func raise() {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }

    func focus() {
        raise()
        app?.activate()
    }

    func close() {
        guard let b: AXUIElement = el.get(kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
    }

    func minimize() { el.set(kAXMinimizedAttribute, kCFBooleanTrue) }

    // standard, user-facing windows we can at least move
    var manageable: Bool {
        let role: String? = el.get(kAXRoleAttribute)
        let sub: String? = el.get(kAXSubroleAttribute)
        guard role == kAXWindowRole, sub == kAXStandardWindowSubrole else { return false }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXPositionAttribute as CFString, &settable)
        return settable.boolValue
    }

    var sizeSettable: Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue
    }
}

enum Access {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func ask() {
        let k = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([k: true] as CFDictionary)
    }
}
