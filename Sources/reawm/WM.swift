import AppKit
import Core

// tab groups for any windows: drop a window on another one's title bar and they
// become tabs in one frame, with a browser-style strip on top
@MainActor
final class WM {
    let tracker = Tracker()
    let tap = Tap()
    let keys = Hotkeys()
    var groups = Groups()
    var onChange: (() -> Void)?

    private var strips: [UUID: Strip] = [:]
    private var frames: [UUID: CGRect] = [:]   // each group's frame, for when its shown window is gone
    private var parked: Set<WinID> = []
    private var parkedAt: [WinID: Date] = [:]
    private var icons: [pid_t: NSImage] = [:]
    private let hint = Hint()
    private var grab: Grab?
    private var tear: Tear?
    private var timer: Timer?
    private var saveSoon: DispatchWorkItem?
    private var started = false
    private var quietUntil = Date.distantPast   // focus reports right after our own switch are stale
    private var homes: [String: UUID] = [:]      // display + Space -> the bar every window there joins
    private var orig: [WinID: CGRect] = [:]      // where a window was before it became a tab
    private var loose: Set<WinID> = []           // pulled out by hand, so auto tabbing leaves it alone
    private var ready = false
    private var cameFrom: [UUID: WinID] = [:]   // the tab shown before the current one, per group
    private var seen: [UUID: (f: CGRect, since: Date)] = [:]   // shown window's frame and how long it's held

    private var cand: (t: Target, at: CGPoint)?
    private var armed: Target?
    private var armSoon: DispatchWorkItem?

    // a press on a window that may turn into a title-bar drag
    struct Grab {
        var win: Win
        var start: CGRect
        var at: CGPoint   // pointer at the press
        var moving = false
        var resizing = false
        var edges: Set<Settings.Side> = []   // which edges a resize is dragging
    }

    // a tab pulled off its strip, following the mouse
    struct Tear {
        var win: Win
        var grip: CGPoint
    }

    // where a dragged window would become a tab
    struct Target {
        var win: WinID
        var index: Int?
        var rect: CGRect
    }

    // MARK: start

    func start() {
        guard !started else { return }
        started = true
        load()
        tracker.onEvent = { [weak self] e, w in self?.event(e, w) }
        tracker.onDestroyed = { [weak self] in self?.reapSoon() }
        tracker.start()
        // AX only lists windows on the current Space, so ask the window server what still exists
        groups.prune(keeping: existing())

        if !tap.start() { NSLog("reawm: event tap failed, dragging windows into tabs is off") }
        tap.onMouse = { [weak self] t, p in self?.mouse(t, p) }
        bindKeys()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.hidden(app.processIdentifier) }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.activated(app.processIdentifier) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.glueAll() }
        }
        if !Settings.paused { groups.all.forEach { show($0, at: frames[$0.id]) } }
        ready = true
        adoptAll()
        changed()
    }

    // MARK: events from windows

    func event(_ e: WinEvent, _ w: Win) {
        guard !Settings.paused else { return }
        switch e {
        case .gone:
            parked.remove(w.id)
            guard let g = groups.group(of: w.id) else { return }
            let shown = g.active == w.id
            groups.remove(w.id)
            settle(g, shownLeft: shown)
        case .focused:
            // a hidden tab you reach some other way (⌘`, the Dock, Window menu) comes to the front
            guard tear == nil, let g = groups.group(of: w.id), w.frame != nil else { return }
            if g.active == w.id { glue(g); return }
            // only the app in front can pull its window forward: apps in the back re-report
            // focus when we move their windows, and following that flips tabs back and forth
            guard Date() >= quietUntil, NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid else { return }
            switchTo(w.id, in: g, focus: false)
        case .moved, .resized:
            guard let g = groups.group(of: w.id) else { return }
            if g.active == w.id { follow(g) } else { summoned(w.id, in: g, at: w.frame) }
        case .titled:
            if let g = groups.group(of: w.id) { glue(g) }
        case .minimized:
            // a minimized tab leaves the bar (it comes back when un-minimized), and
            // the tab you came from shows, or the frame would just be empty
            guard let g = groups.group(of: w.id) else { return }
            note("minimized \(w.id), leaves its bar")
            let shown = g.active == w.id
            groups.remove(w.id)
            settle(g, shownLeft: shown)
        case .unminimized:
            if let g = groups.group(of: w.id) { if g.active == w.id { glue(g) } } else { adoptSoon(w) }
        case .appeared:
            adoptSoon(w)
        }
    }

    func spaceChanged() {
        tracker.rescan()
        // groups on the Space we just came to get their hidden tabs tucked away again
        let live = onScreen()
        for g in groups.all where live[g.active] != nil && !parked.contains(g.active) { show(g, at: frames[g.id]) }
        glueAll()
        adoptAll()
    }

    // ⌘H on the app whose window is showing: show another tab instead of an empty frame
    func hidden(_ pid: pid_t) {
        guard !Settings.paused else { return }
        for g in groups.all where tracker.wins[g.active]?.pid == pid {
            let ok = { [tracker] (id: WinID) in tracker.wins[id].map { !($0.app?.isHidden ?? true) } ?? false }
            let back = cameFrom[g.id].flatMap { g.wins.contains($0) && ok($0) ? $0 : nil }
            guard let to = back ?? g.wins.first(where: ok) else { continue }
            note("app \(pid) hidden, showing \(to)")
            switchTo(to, in: g, focus: false)
        }
    }

    // switching apps doesn't change the app's focused window, so no AX event: ask it
    func activated(_ pid: pid_t) {
        guard !Settings.paused else { return }
        let app = AXUIElementCreateApplication(pid)
        if let el: AXUIElement = app.get(kAXFocusedWindowAttribute), let w = tracker.win(for: el, pid: pid) {
            event(.focused, w)
        }
        glueAll()
    }

    // MARK: showing groups

    // the shown tab sits at the group's frame (or `at`), the rest are tucked away
    func show(_ g: Group, at forced: CGRect? = nil) {
        guard let a = tracker.wins[g.active] else { return }
        let live = parked.contains(a.id) ? nil : a.frame.flatMap { visible($0) ? $0 : nil }
        guard let f = forced ?? live ?? frames[g.id] ?? a.frame else { return }
        frames[g.id] = f
        place(a, f)
        for id in g.hidden { if let w = tracker.wins[id] { park(w, near: f) } }
        glue(g)
    }

    func switchTo(_ id: WinID, in g: Group, focus: Bool = true) {
        note("show \(id) (\(tracker.wins[id]?.app?.localizedName ?? "?")) was \(g.active)\(focus ? "" : ", following focus")")
        // frames[g.id] is kept up to date elsewhere. reading the old tab's frame here
        // could catch it mid close animation.
        if g.active != id { cameFrom[g.id] = g.active }
        groups.select(id)
        quietUntil = Date().addingTimeInterval(0.6)
        show(g)
        if focus { tracker.wins[id]?.focus() }
        changed()
    }

    func pick(_ id: WinID) {
        guard let g = groups.group(of: id) else { return }
        if g.active == id { tracker.wins[id]?.focus() } else { switchTo(id, in: g) }
    }

    // a hidden tab back on screen without us (⌘` makes the app pull it in) is
    // the one you want: show it in the group's frame
    func summoned(_ id: WinID, in g: Group, at f: CGRect?) {
        // the window server lags a moment behind our own moves, so a fresh park can still look visible
        guard tear == nil, parked.contains(id), let f, visible(f), Date() >= quietUntil,
              Date().timeIntervalSince(parkedAt[id] ?? .distantPast) > 1,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == tracker.wins[id]?.pid else { return }
        note("hidden tab \(id) came back on screen by itself")
        switchTo(id, in: g, focus: false)
    }

    // after a window left g, show whatever should show now
    private func settle(_ g: Group, shownLeft: Bool) {
        let f = frames[g.id]
        if g.wins.count < 2 {
            strips[g.id]?.orderOut(nil)
            strips[g.id] = nil
            frames[g.id] = nil
            if let last = g.wins.first, let w = tracker.wins[last], parked.contains(last), let f { place(w, f) }
        } else if shownLeft {
            // like a browser closing a tab you just opened: back to where you were.
            // it gets focus too, or the app may hand focus to a hidden tab and you'd type into nothing.
            if let back = cameFrom[g.id], g.wins.contains(back) { groups.select(back) }
            show(g)
            quietUntil = Date().addingTimeInterval(0.6)
            tracker.wins[g.active]?.focus()
        } else {
            glue(g)
        }
        changed()
    }

    // MARK: the strip

    // put g's strip on top of its shown window, with fresh titles
    func glue(_ g: Group) {
        guard !Settings.paused, let a = tracker.wins[g.active], !parked.contains(a.id), !a.minimized, !a.fullscreen,
              let f = a.frame, isOnScreen(a.id) else {
            strips[g.id]?.orderOut(nil)
            return
        }
        let tabs = g.wins.compactMap { tracker.wins[$0] }.map { w in
            let t = w.title
            return Tab(id: w.id, title: t.isEmpty ? (w.app?.localizedName ?? "") : t, icon: icon(w.pid), active: w.id == g.active)
        }
        let s = strips[g.id] ?? makeStrip(g)
        s.show(stripRect(f), tabs, above: a.id)
    }

    // the shown window moved or resized: move the strip along. the window can't
    // grow up into the bar's space (top-edge resize, zoom, macOS fill); a title-bar
    // move is fixed when it's let go instead, pushing mid-drag fights the drag.
    func follow(_ g: Group) {
        if let gr = grab, gr.moving, gr.win.id == g.active { return }   // the drag moves it, from the pointer
        guard let s = strips[g.id], s.isVisible, let a = tracker.wins[g.active], !parked.contains(a.id), let f = a.frame else { return }
        s.move(stripRect(f))
        if roomy(f) != f { clampSoon(a) }
    }

    // once the window stops changing (a zoom animates through many frames), push it
    // back under the bar
    private var clampWork: [WinID: DispatchWorkItem] = [:]
    func clampSoon(_ w: Win) {
        clampWork[w.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, grab == nil, groups.group(of: w.id)?.active == w.id, !w.fullscreen, let f = w.frame else { return }
            let r = roomy(f)
            guard r != f else { return }
            note("pushed \(w.id) back under the bar")
            w.setFrame(r)
            if let g = groups.group(of: w.id) { frames[g.id] = r; strips[g.id]?.move(stripRect(r)) }
        }
        clampWork[w.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // cheap pass for every group: follow moves, hide strips whose window went away
    // (other Space, app hidden, minimized). titles only change through glue().
    func glueAll() {
        guard !Settings.paused else { return }
        reap()
        let live = onScreen()
        for g in groups.all {
            if let t = tear, g.wins.contains(t.win.id) { continue }
            if let gr = grab, gr.moving, gr.win.id == g.active { continue }
            guard let r = live[g.active], !parked.contains(g.active) else {
                strips[g.id]?.orderOut(nil)
                continue
            }
            if let h = g.hidden.first(where: { live[$0].map(visible) ?? false }) {
                summoned(h, in: g, at: live[h])
                continue
            }
            guard let s = strips[g.id], s.isVisible else { glue(g); continue }
            // the group's frame only takes a size that held still for a second, so a
            // closing window's shrink animation never becomes the size of the next tab
            if let sn = seen[g.id], sn.f == r {
                if Date().timeIntervalSince(sn.since) > 1 { frames[g.id] = r }
            } else {
                seen[g.id] = (r, Date())
            }
            s.move(stripRect(r))
            s.order(.above, relativeTo: Int(g.active))
        }
    }

    // macOS doesn't reliably tell us when a window closes, so check grouped
    // windows still exist. a window missing twice in a row is gone.
    private var missing: Set<WinID> = []
    private var reapWork: DispatchWorkItem?

    func reapSoon() {
        reapWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reap(now: true) }
        reapWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    // now: right after macOS said something closed, so one miss is enough
    func reap(now: Bool = false) {
        let ids = groups.all.flatMap(\.wins)
        guard !ids.isEmpty else { return }
        let ptrs: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: Int($0)) }
        guard let arr = ptrs.withUnsafeBufferPointer({ CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), ids.count, nil) }),
              let info = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return }
        let alive = Set(info.compactMap { $0[kCGWindowNumber as String] as? WinID })
        let gone = Set(ids).subtracting(alive)
        for id in gone where now || missing.contains(id) {
            note("closed \(id)")
            parked.remove(id)
            guard let g = groups.group(of: id) else { continue }
            let shown = g.active == id
            tracker.forget(id)
            groups.remove(id)
            settle(g, shownLeft: shown)
        }
        missing = gone
    }

    static let stripGap: CGFloat = 4

    func stripRect(_ f: CGRect) -> CGRect {
        let g = Self.stripGap, h = Settings.stripHeight, w = Settings.sideWidth
        switch Settings.side {
        case .top: return CGRect(x: f.minX, y: f.minY - g - h, width: f.width, height: h)
        case .left: return CGRect(x: f.minX - g - w, y: f.minY, width: w, height: f.height)
        case .right: return CGRect(x: f.maxX + g, y: f.minY, width: w, height: f.height)
        }
    }

    func makeStrip(_ g: Group) -> Strip {
        let s = Strip()
        s.tabs.onPick = { [weak self] id in self?.pick(id) }
        s.tabs.onClose = { [weak self] id in
            // show it first so a "save changes?" sheet isn't stuck on a hidden window
            self?.pick(id)
            self?.tracker.wins[id]?.close()
        }
        s.tabs.onMove = { [weak self] id, i in
            guard let self else { return }
            groups.move(id, to: i)
            if let g = groups.group(of: id) { glue(g) }
            changed()
        }
        s.tabs.onTear = { [weak self] id in self?.tearOff(id) }
        strips[g.id] = s
        return s
    }

    // MARK: dragging

    func mouse(_ t: CGEventType, _ p: CGPoint) {
        guard !Settings.paused else { return }
        if tear != nil { tearMouse(t, p); return }
        switch t {
        case .leftMouseDown:
            guard let w = tracker.win(at: p), let f = w.frame else { grab = nil; return }
            grab = Grab(win: w, start: f, at: p)
        case .leftMouseDragged:
            guard var g = grab else { return }
            var p = p
            if !g.moving, !g.resizing, let f = g.win.frame {
                if f.size != g.start.size { g.resizing = true } else if f.origin != g.start.origin { g.moving = true }
            }
            if g.resizing, let f = g.win.frame {
                if f.minY != g.start.minY { g.edges.insert(.top) }
                if f.minX != g.start.minX { g.edges.insert(.left) }
                if f.maxX != g.start.maxX { g.edges.insert(.right) }
            }
            if g.moving || g.resizing, let gr = groups.group(of: g.win.id), gr.active == g.win.id {
                // the bar is a wall: the window can't be dragged into it. hold the pointer
                // there, so the window simply stops instead of snapping back later.
                let w = wall(g, p)
                if w != p {
                    p = w
                    CGWarpMouseCursorPosition(p)
                    CGAssociateMouseAndMouseCursorPosition(1)   // no input pause after the warp
                }
                // the strip rides along with the pointer. waiting for macOS to report each
                // move makes it trail behind.
                if g.moving, let s = strips[gr.id], s.isVisible {
                    s.move(stripRect(g.start.offsetBy(dx: p.x - g.at.x, dy: p.y - g.at.y)))
                }
            }
            // a grouped window's title bar moves the whole group, it doesn't join anything
            if g.moving, groups.group(of: g.win.id) == nil, !Settings.excluded.contains(g.win.bundle) {
                aim(p, dragging: g.win.id)
            }
            grab = g
        case .leftMouseUp:
            guard let g = grab else { return }
            grab = nil
            if let t = endAim() {
                join(g.win, t)
            } else if let gr = groups.group(of: g.win.id), gr.active == g.win.id, let f = g.win.frame, f != g.start {
                if roomy(f) != f {
                    show(gr, at: roomy(f))
                } else {
                    frames[gr.id] = f
                    glue(gr)
                }
            }
        default:
            break
        }
    }

    // the window or strip under p that a drop would join. only a window's title
    // bar counts, so ordinary moves over other windows never make tabs.
    func target(at p: CGPoint, dragging w: WinID) -> Target? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let mine = Dictionary(strips.map { (WinID($0.value.windowNumber), $0.key) }, uniquingKeysWith: { a, _ in a })
        for d in info {
            guard (d[kCGWindowLayer as String] as? Int) == 0, let id = d[kCGWindowNumber as String] as? WinID, id != w,
                  let r = bounds(d), r.contains(p) else { continue }
            if let gid = mine[id], let g = groups.all.first(where: { $0.id == gid }), let s = strips[gid] {
                let slot = s.tabs.insertion(at: NSPoint(x: p.x - r.minX, y: p.y - r.minY))
                let f = frames[g.id] ?? r
                return Target(win: g.active, index: min(slot, g.wins.count), rect: f.union(stripRect(f)))
            }
            // something else is on top here
            guard let t = tracker.wins[id], !parked.contains(id), !Settings.excluded.contains(t.bundle),
                  p.y <= r.minY + Settings.titleBand else { return nil }
            return Target(win: id, index: nil, rect: r.union(stripRect(r)))
        }
        return nil
    }

    // a target only counts once the pointer has rested on it a moment, so
    // dragging a window across other title bars never makes tabs by accident
    func aim(_ p: CGPoint, dragging w: WinID) {
        let t = target(at: p, dragging: w)
        if let t, let c = cand, c.t.win == t.win {
            if armed != nil {
                armed = t
                hint.show(t.rect)
                return
            }
            if hypot(p.x - c.at.x, p.y - c.at.y) < 10 { return }
        }
        armSoon?.cancel()
        armed = nil
        hint.show(nil)
        cand = t.map { ($0, p) }
        guard t != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let c = cand else { return }
            armed = c.t
            hint.show(c.t.rect)
        }
        armSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.dropHold, execute: work)
    }

    func endAim() -> Target? {
        armSoon?.cancel()
        armSoon = nil
        defer { armed = nil; cand = nil; hint.show(nil) }
        return armed
    }

    func join(_ w: Win, _ t: Target) {
        guard let tw = tracker.wins[t.win] else { return }
        let old = groups.group(of: t.win).flatMap { frames[$0.id] }
        remember(w)
        remember(tw)
        loose.remove(w.id)
        guard let f0 = old ?? tw.frame, let g = groups.join(w.id, onto: t.win, at: t.index) else { return }
        show(g, at: roomy(f0))
        w.focus()
        checkFitSoon([w.id, tw.id], g)
        changed()
    }

    // pull a tab out of its group; it follows the mouse until let go
    func tearOff(_ id: WinID) {
        guard let g = groups.group(of: id), let w = tracker.wins[id] else { return }
        let f = frames[g.id] ?? w.frame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let shown = g.active == id
        groups.remove(id)
        loose.insert(id)
        orig[id] = nil
        settle(g, shownLeft: shown)
        let p = Display.mouse
        let grip = CGPoint(x: min(f.width / 2, 160), y: 14)
        place(w, CGRect(x: p.x - grip.x, y: p.y - grip.y, width: f.width, height: f.height))
        w.focus()
        tear = Tear(win: w, grip: grip)
    }

    private func tearMouse(_ t: CGEventType, _ p: CGPoint) {
        guard let tr = tear else { return }
        switch t {
        case .leftMouseDragged:
            tr.win.move(to: CGPoint(x: p.x - tr.grip.x, y: p.y - tr.grip.y))
            aim(p, dragging: tr.win.id)
        case .leftMouseUp:
            tear = nil
            if let t = endAim() { join(tr.win, t) }
        default:
            break
        }
    }

    // MARK: putting windows in place

    func place(_ w: Win, _ r: CGRect) {
        parked.remove(w.id)
        if w.fullscreen { return }
        if let f = w.frame, abs(f.minX - r.minX) < 1, abs(f.minY - r.minY) < 1, abs(f.width - r.width) < 1, abs(f.height - r.height) < 1 { return }
        w.setFrame(r)
    }

    // out of sight: past the bottom corner of its display with one point showing.
    // macOS won't let a window go fully off screen.
    func park(_ w: Win, near r: CGRect) {
        if w.fullscreen { return }
        guard let f = w.frame, let d = Display.at(CGPoint(x: r.midX, y: r.midY)) else { return }
        var p = CGPoint(x: d.frame.maxX - 1, y: d.frame.maxY - 1)
        // another display to the right: hide past the bottom left instead
        if Display.all.contains(where: { $0.uuid != d.uuid && $0.frame.contains(CGPoint(x: d.frame.maxX + 2, y: d.frame.maxY - 2)) }) {
            p.x = d.frame.minX - f.width + 1
        }
        if !parked.contains(w.id) { parkedAt[w.id] = Date() }
        parked.insert(w.id)
        if abs(f.minX - p.x) < 1 && abs(f.minY - p.y) < 1 { return }
        w.move(to: p)
    }

    // leave room for the bar between the window and the screen edge
    func roomy(_ f: CGRect) -> CGRect {
        guard let d = Display.at(CGPoint(x: f.midX, y: f.midY)) else { return f }
        let v = d.visible, g = Self.stripGap
        switch Settings.side {
        case .top:
            let top = v.minY + Settings.stripHeight + g
            guard f.minY < top else { return f }
            return CGRect(x: f.minX, y: top, width: f.width, height: max(200, f.maxY - top))
        case .left:
            let left = v.minX + Settings.sideWidth + g
            guard f.minX < left else { return f }
            return CGRect(x: left, y: f.minY, width: max(300, f.maxX - left), height: f.height)
        case .right:
            let right = v.maxX - Settings.sideWidth - g
            guard f.maxX > right else { return f }
            return CGRect(x: f.minX, y: f.minY, width: max(300, right - f.minX), height: f.height)
        }
    }

    // the furthest the pointer may drag a window (or its bar-side edge) before the
    // window would run into its bar
    func wall(_ g: Grab, _ p: CGPoint) -> CGPoint {
        guard let d = Display.at(p) else { return p }
        let v = d.visible, gap = Self.stripGap
        var p = p
        switch Settings.side {
        case .top:
            guard g.moving || g.edges.contains(.top) else { return p }
            p.y = max(p.y, g.at.y + (v.minY + Settings.stripHeight + gap - g.start.minY))
        case .left:
            guard g.moving || g.edges.contains(.left) else { return p }
            p.x = max(p.x, g.at.x + (v.minX + Settings.sideWidth + gap - g.start.minX))
        case .right:
            guard g.moving || g.edges.contains(.right) else { return p }
            p.x = min(p.x, g.at.x + (v.maxX - Settings.sideWidth - gap - g.start.maxX))
        }
        return p
    }

    func setSide(_ side: Settings.Side) {
        Settings.side = side
        note("bar moves to the \(side.rawValue)")
        for g in groups.all {
            guard let f = frames[g.id] else { continue }
            show(g, at: roomy(f))
        }
        onChange?()
    }

    // mostly on some display (a window left parked by a crash isn't)
    func visible(_ r: CGRect) -> Bool {
        let a = Display.all.reduce(0.0) { s, d in
            let i = r.intersection(d.frame)
            return s + (i.isNull ? 0 : i.width * i.height)
        }
        return a > r.width * r.height * 0.5
    }

    // every window that still exists, on any Space
    func existing() -> Set<WinID> {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(info.compactMap { $0[kCGWindowNumber as String] as? WinID })
    }

    func isOnScreen(_ id: WinID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]], let d = info.first else { return false }
        return d[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    func onScreen() -> [WinID: CGRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [WinID: CGRect] = [:]
        for d in info {
            guard (d[kCGWindowLayer as String] as? Int) == 0, let id = d[kCGWindowNumber as String] as? WinID, let r = bounds(d) else { continue }
            out[id] = r
        }
        return out
    }

    private func bounds(_ d: [String: Any]) -> CGRect? {
        guard let b = d[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }

    func icon(_ pid: pid_t) -> NSImage {
        if let i = icons[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(named: NSImage.applicationIconName)!
        icons[pid] = i
        return i
    }

    // MARK: commands

    func command(_ c: String, n: Int? = nil) {
        note("command \(c)\(n.map { " \($0)" } ?? "")")
        switch c {
        case "next", "prev":
            if let g = currentGroup(), let to = groups.step(g.active, by: c == "next" ? 1 : -1) {
                switchTo(to, in: g)
            }
        case "tab":
            // like a browser: 1-8 by position, 9 is always the last tab
            if let n, let g = currentGroup(), n >= 1 {
                let i = n == 9 ? g.wins.count : n
                if i <= g.wins.count { switchTo(g.wins[i - 1], in: g) }
            }
        case "ungroup": ungroupAll()
        case "auto": setAuto(!Settings.autoTab)
        case "pause": setPaused(true)
        case "resume": setPaused(false)
        default: NSLog("reawm: unknown command \(c)")
        }
    }

    // the bar of the focused window, else the bar on the display with the mouse
    func currentGroup() -> Group? {
        if let w = focusedWin(), let g = groups.group(of: w.id) { return g }
        guard let d = Display.at(Display.mouse) else { return nil }
        return home(homeKey(d))
    }

    func focusedWin() -> Win? {
        let sys = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = sys.get(kAXFocusedApplicationAttribute),
              let w: AXUIElement = app.get(kAXFocusedWindowAttribute), let id = w.winID else { return nil }
        return tracker.wins[id]
    }

    // every tab back where it was before it joined (hidden ones with no saved
    // spot come back stacked under the shown one)
    private func restoreAll() {
        for g in groups.all {
            let f = frames[g.id]
            for id in g.wins {
                guard let w = tracker.wins[id] else { continue }
                if let o = orig[id], visible(o) { place(w, o) } else if parked.contains(id), let f { place(w, f) }
            }
            strips[g.id]?.orderOut(nil)
        }
    }

    func ungroupAll() {
        restoreAll()
        strips.removeAll()
        groups.clear()
        frames.removeAll()
        homes.removeAll()
        orig.removeAll()
        loose.removeAll()
        changed()
    }

    func setPaused(_ on: Bool) {
        Settings.paused = on
        if on {
            restoreAll()
        } else {
            groups.all.forEach { show($0, at: frames[$0.id]) }
            adoptAll()
        }
        onChange?()
    }

    func setAuto(_ on: Bool) {
        Settings.autoTab = on
        if on { adoptAll() } else { ungroupAll() }
        onChange?()
    }

    // an app you've just said "no tabs" to: its windows leave their bars and go back where they were
    func release(bundle: String) {
        for w in tracker.wins.values where w.bundle == bundle {
            guard let g = groups.group(of: w.id) else { continue }
            let shown = g.active == w.id
            groups.remove(w.id)
            if let o = orig[w.id], visible(o) { place(w, o) } else if let f = frames[g.id] { place(w, f) }
            orig[w.id] = nil
            settle(g, shownLeft: shown)
        }
    }

    // on quit nothing should stay stuck in a corner. groups are kept for next launch.
    func releaseAll() {
        restoreAll()
        save()
    }

    func bindKeys() {
        keys.removeAll()
        let co = Hotkeys.ctrlOpt
        // ⌃⌥ + arrows never reach a hotkey while an AppKit app is in front, brackets do
        keys.add(30, co) { [weak self] in self?.command("next") }    // ]
        keys.add(33, co) { [weak self] in self?.command("prev") }    // [
        keys.add(48, Hotkeys.opt) { [weak self] in self?.command("next") }               // ⌥⇥
        keys.add(48, Hotkeys.optShift) { [weak self] in self?.command("prev") }          // ⌥⇧⇥
        for (i, k) in Hotkeys.digits.enumerated() {
            keys.add(k, Hotkeys.opt) { [weak self] in self?.command("tab", n: i + 1) }
        }
    }

    // MARK: every window, automatically

    func homeKey(_ d: Display) -> String { "\(d.uuid)#\(Spaces.current(d))" }

    func home(_ k: String) -> Group? {
        homes[k].flatMap { id in groups.all.first { $0.id == id } }
    }

    // a fresh bar fills the display, like a browser window
    func homeFrame(_ d: Display) -> CGRect {
        roomy(d.visible.insetBy(dx: 6, dy: 6))
    }

    func remember(_ w: Win) {
        if orig[w.id] == nil, let f = w.frame, visible(f) { orig[w.id] = f }
    }

    func eligible(_ w: Win) -> Bool {
        !Settings.excluded.contains(w.bundle) && !loose.contains(w.id) && groups.group(of: w.id) == nil
            && !w.minimized && !w.fullscreen && isOnScreen(w.id) && (w.frame.map(visible) ?? false)
    }

    // new windows settle their size and spot first
    func adoptSoon(_ w: Win) {
        guard ready else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.adopt(w) }
    }

    // a new window opens as the shown tab of its display's bar
    func adopt(_ w: Win) {
        guard Settings.autoTab, !Settings.paused, ready, tear == nil, grab == nil, tracker.wins[w.id] != nil,
              eligible(w), let f = w.frame, let d = Display.at(CGPoint(x: f.midX, y: f.midY)) else { return }
        guard let g = home(homeKey(d)) else { adoptAll(); return }
        note("new window \(w.id) (\(w.app?.localizedName ?? "?")) joins the bar")
        remember(w)
        cameFrom[g.id] = g.active
        groups.join(w.id, onto: g.active)
        show(g, at: frames[g.id])
        checkFitSoon([w.id], g)
        changed()
    }

    // every window on screen joins its display's bar. whatever is in front stays shown.
    func adoptAll() {
        guard Settings.autoTab, !Settings.paused, ready, tear == nil, grab == nil else { return }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let order = info.compactMap { d -> Win? in
            guard (d[kCGWindowLayer as String] as? Int) == 0, let id = d[kCGWindowNumber as String] as? WinID else { return nil }
            return tracker.wins[id]
        }.filter(eligible)
        for d in Display.all {
            let ws = order.filter { w in w.frame.map { d.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false }
            guard !ws.isEmpty else { continue }
            let k = homeKey(d)
            var g = home(k)
            if g == nil, ws.count >= 2 {
                remember(ws[0])
                remember(ws[1])
                g = groups.join(ws[1].id, onto: ws[0].id, select: false)
                if let g {
                    homes[k] = g.id
                    frames[g.id] = homeFrame(d)
                }
            }
            guard let g else { continue }
            for w in ws where groups.group(of: w.id) == nil {
                remember(w)
                groups.join(w.id, onto: g.active, select: false)
            }
            show(g, at: frames[g.id])
            // hidden tabs take the bar's size now, so ones that can't are found right away
            if let f = frames[g.id] {
                for w in ws where w.id != g.active && parked.contains(w.id) {
                    var sz = f.size
                    if let v = AXValueCreate(.cgSize, &sz) { w.el.set(kAXSizeAttribute, v) }
                }
            }
            checkFitSoon(ws.map(\.id), g)
        }
        changed()
    }

    // windows that can't take the bar's size (fixed-size settings windows and the
    // like) don't belong in a bar: they go back where they were and stay out
    func checkFitSoon(_ ids: [WinID], _ g: Group) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let f = frames[g.id] else { return }
            for id in ids {
                guard groups.group(of: id) === g, let w = tracker.wins[id], let r = w.frame,
                      abs(r.width - f.width) > 40 || abs(r.height - f.height) > 40 else { continue }
                note("\(id) (\(w.app?.localizedName ?? "?")) can't be \(Int(f.width))x\(Int(f.height)), stays out of the bar")
                let shown = g.active == id
                groups.remove(id)
                loose.insert(id)
                if let o = orig[id], visible(o) { place(w, o) } else { place(w, CGRect(origin: f.origin, size: r.size)) }
                orig[id] = nil
                settle(g, shownLeft: shown)
            }
        }
    }

    // MARK: saving

    struct State: Codable {
        var groups: Groups
        var frames: [UUID: CGRect]
        var homes: [String: UUID]?
        var orig: [WinID: CGRect]?
        var loose: [WinID]?
    }

    static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("reawm")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        groups = s.groups
        frames = s.frames
        homes = s.homes ?? [:]
        orig = s.orig ?? [:]
        loose = Set(s.loose ?? [])
    }

    func changed() {
        saveSoon?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveSoon = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
        onChange?()
    }

    func save() {
        let live = Set(groups.all.map(\.id))
        let known = existing()
        let s = State(groups: groups, frames: frames.filter { live.contains($0.key) },
                      homes: homes.filter { live.contains($0.value) },
                      orig: orig.filter { known.contains($0.key) }, loose: loose.filter { known.contains($0) }.sorted())
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}

// what reawm did and why, for when something looks wrong. ~/Library/Logs/reawm.log, kept small.
func note(_ s: String) {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/reawm.log")
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let line = Data("\(f.string(from: Date())) \(s)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) {
        if (try? h.seekToEnd()) ?? 0 > 512_000 { try? h.truncate(atOffset: 0) }
        try? h.write(contentsOf: line)
        try? h.close()
    } else {
        try? line.write(to: url)
    }
}
