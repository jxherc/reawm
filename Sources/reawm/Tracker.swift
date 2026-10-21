import AppKit
import ApplicationServices
import Core

enum WinEvent {
    case appeared, gone, moved, resized, minimized, unminimized, focused, titled
}

// keeps a live list of every manageable window through AX observers
final class Tracker {
    private(set) var wins: [WinID: Win] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var appEls: [pid_t: AXUIElement] = [:]
    var onEvent: ((WinEvent, Win) -> Void)?
    var onDestroyed: (() -> Void)?   // something closed that we couldn't match to a window

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // apps aren't ready for AX the moment they launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.watch(app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unwatch(app.processIdentifier)
        }
        for app in NSWorkspace.shared.runningApplications { watch(app) }
    }

    func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 1)
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        // window-level "destroyed" never arrives on macOS 27, the app-level one does
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(obs, el, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
        appEls[pid] = el
        scan(pid)
    }

    func unwatch(_ pid: pid_t) {
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        appEls[pid] = nil
        for w in wins.values where w.pid == pid {
            wins[w.id] = nil
            onEvent?(.gone, w)
        }
    }

    // pick up windows we haven't seen (also used after a Space switch)
    func scan(_ pid: pid_t) {
        guard let el = appEls[pid], let list: [AXUIElement] = el.get(kAXWindowsAttribute) else { return }
        for w in list { add(w, pid: pid) }
    }

    func rescan() {
        for pid in appEls.keys { scan(pid) }
    }

    @discardableResult
    func add(_ el: AXUIElement, pid: pid_t) -> Win? {
        guard let id = el.winID else { return nil }
        if let w = wins[id] { return w }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let w = Win(id: id, el: el, pid: pid, bundle: bundle)
        guard w.manageable else { return nil }
        wins[id] = w
        if let obs = observers[pid] {
            let me = Unmanaged.passUnretained(self).toOpaque()
            for n in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(obs, el, n as CFString, me)
            }
        }
        onEvent?(.appeared, w)
        return w
    }

    func win(for el: AXUIElement, pid: pid_t) -> Win? {
        if let id = el.winID, let w = wins[id] { return w }
        // destroyed elements can't report their id (or pid) any more
        return wins.values.first { CFEqual($0.el, el) }
    }

    // a window that's gone without telling us
    func forget(_ id: WinID) {
        wins[id] = nil
    }

    func handle(_ el: AXUIElement, _ name: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        switch name {
        case kAXWindowCreatedNotification:
            // give the window a moment to settle its role and size
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.add(el, pid: pid) }
        case kAXFocusedWindowChangedNotification:
            // the element here is the newly focused window
            if let w = win(for: el, pid: pid) ?? add(el, pid: pid) {
                onEvent?(.focused, w)
            }
        case kAXUIElementDestroyedNotification:
            if let w = win(for: el, pid: pid) {
                wins[w.id] = nil
                onEvent?(.gone, w)
            } else {
                onDestroyed?()
            }
        case kAXWindowMovedNotification:
            if let w = win(for: el, pid: pid) { onEvent?(.moved, w) }
        case kAXWindowResizedNotification:
            if let w = win(for: el, pid: pid) { onEvent?(.resized, w) }
        case kAXWindowMiniaturizedNotification:
            if let w = win(for: el, pid: pid) { onEvent?(.minimized, w) }
        case kAXWindowDeminiaturizedNotification:
            if let w = win(for: el, pid: pid) { onEvent?(.unminimized, w) }
        case kAXTitleChangedNotification:
            if let w = win(for: el, pid: pid) { onEvent?(.titled, w) }
        default: break
        }
    }

    // the window under a screen point (top-left coords), using the window server's z order
    func win(at pt: CGPoint) -> Win? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for d in info {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? WinID,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.contains(pt) else { continue }
            return wins[id]
        }
        return nil
    }
}

private func axCallback(_ obs: AXObserver, _ el: AXUIElement, _ name: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let t = Unmanaged<Tracker>.fromOpaque(refcon).takeUnretainedValue()
    t.handle(el, name as String)
}
