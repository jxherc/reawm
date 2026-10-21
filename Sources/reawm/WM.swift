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

    private var cand: (t: Target, at: CGPoint)?
    private var armed: Target?
    private var armSoon: DispatchWorkItem?

    // a press on a window that may turn into a title-bar drag
    struct Grab {
        var win: Win
        var start: CGRect
        var at: CGPoint   // pointer at the press
        var moving = false
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
        tracker.start()
        groups.prune(keeping: Set(tracker.wins.keys))

        if !tap.start() { NSLog("reawm: event tap failed, dragging windows into tabs is off") }
        tap.onMouse = { [weak self] t, p in self?.mouse(t, p) }
        bindKeys()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tracker.rescan()
                self?.glueAll()
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.activated(app.processIdentifier) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.glueAll() }
        }
        if !Settings.paused { groups.all.forEach { show($0) } }
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
            if Date() < quietUntil { return }
            switchTo(w.id, in: g, focus: false)
        case .moved, .resized:
            guard let g = groups.group(of: w.id) else { return }
            if g.active == w.id { follow(g) } else { summoned(w.id, in: g, at: w.frame) }
        case .titled, .minimized, .unminimized:
            if let g = groups.group(of: w.id), g.active == w.id { glue(g) }
        case .appeared:
            break
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
        if let old = tracker.wins[g.active], !parked.contains(old.id), let f = old.frame { frames[g.id] = f }
        groups.select(id)
        show(g)
        if focus {
            quietUntil = Date().addingTimeInterval(0.6)
            tracker.wins[id]?.focus()
        }
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
              Date().timeIntervalSince(parkedAt[id] ?? .distantPast) > 1 else { return }
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
            show(g)
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
        frames[g.id] = f
        let tabs = g.wins.compactMap { tracker.wins[$0] }.map {
            Tab(id: $0.id, title: $0.title, icon: icon($0.pid), active: $0.id == g.active)
        }
        let s = strips[g.id] ?? makeStrip(g)
        s.show(stripRect(f), tabs, above: a.id)
    }

    // the shown window moved or resized: just move the strip
    func follow(_ g: Group) {
        if let gr = grab, gr.moving, gr.win.id == g.active { return }   // the drag moves it, from the pointer
        guard let s = strips[g.id], s.isVisible, let a = tracker.wins[g.active], !parked.contains(a.id), let f = a.frame else { return }
        frames[g.id] = f
        s.move(stripRect(f))
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
            frames[g.id] = r
            s.move(stripRect(r))
            s.order(.above, relativeTo: Int(g.active))
        }
    }

    // macOS doesn't reliably tell us when a window closes, so check grouped
    // windows still exist. a window missing twice in a row is gone.
    private var missing: Set<WinID> = []
    func reap() {
        let ids = groups.all.flatMap(\.wins)
        guard !ids.isEmpty else { return }
        let ptrs: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: Int($0)) }
        guard let arr = ptrs.withUnsafeBufferPointer({ CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), ids.count, nil) }),
              let info = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return }
        let alive = Set(info.compactMap { $0[kCGWindowNumber as String] as? WinID })
        let gone = Set(ids).subtracting(alive)
        for id in gone where missing.contains(id) {
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
        CGRect(x: f.minX, y: f.minY - Self.stripGap - Settings.stripHeight, width: f.width, height: Settings.stripHeight)
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
            if !g.moving, let f = g.win.frame, f.size == g.start.size, f.origin != g.start.origin { g.moving = true }
            // a group's strip rides along with the pointer. waiting for macOS to report
            // each move makes it trail behind.
            if g.moving, let gr = groups.group(of: g.win.id), gr.active == g.win.id, let s = strips[gr.id], s.isVisible {
                var f = g.start.offsetBy(dx: p.x - g.at.x, dy: p.y - g.at.y)
                if let d = Display.at(p) { f.origin.y = max(f.minY, d.visible.minY) }   // windows stop at the menu bar
                s.move(stripRect(f))
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
            } else if g.moving, let gr = groups.group(of: g.win.id), let f = g.win.frame {
                if roomy(f) != f { show(gr, at: roomy(f)) } else { glue(gr) }
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
        let h = Settings.stripHeight
        for d in info {
            guard (d[kCGWindowLayer as String] as? Int) == 0, let id = d[kCGWindowNumber as String] as? WinID, id != w,
                  let r = bounds(d), r.contains(p) else { continue }
            if let gid = mine[id], let g = groups.all.first(where: { $0.id == gid }), let s = strips[gid] {
                let slot = Int(((p.x - r.minX) / max(1, s.tabs.tabWidth)).rounded())
                let f = frames[g.id] ?? r
                return Target(win: g.active, index: min(slot, g.wins.count), rect: f.union(stripRect(f)))
            }
            // something else is on top here
            guard let t = tracker.wins[id], !parked.contains(id), !Settings.excluded.contains(t.bundle),
                  p.y <= r.minY + Settings.titleBand else { return nil }
            return Target(win: id, index: nil, rect: CGRect(x: r.minX, y: r.minY - h, width: r.width, height: r.height + h))
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
        guard let f0 = old ?? tw.frame, let g = groups.join(w.id, onto: t.win, at: t.index) else { return }
        show(g, at: roomy(f0))
        w.focus()
        changed()
    }

    // pull a tab out of its group; it follows the mouse until let go
    func tearOff(_ id: WinID) {
        guard let g = groups.group(of: id), let w = tracker.wins[id] else { return }
        let f = frames[g.id] ?? w.frame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let shown = g.active == id
        groups.remove(id)
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

    // leave room above the window for the strip, under the menu bar
    func roomy(_ f: CGRect) -> CGRect {
        guard let d = Display.at(CGPoint(x: f.midX, y: f.midY)) else { return f }
        let top = d.visible.minY + Settings.stripHeight + Self.stripGap
        guard f.minY < top else { return f }
        return CGRect(x: f.minX, y: top, width: f.width, height: max(200, f.maxY - top))
    }

    // mostly on some display (a window left parked by a crash isn't)
    func visible(_ r: CGRect) -> Bool {
        let a = Display.all.reduce(0.0) { s, d in
            let i = r.intersection(d.frame)
            return s + (i.isNull ? 0 : i.width * i.height)
        }
        return a > r.width * r.height * 0.5
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
        switch c {
        case "next", "prev":
            if let w = focusedWin(), let g = groups.group(of: w.id), let to = groups.step(w.id, by: c == "next" ? 1 : -1) {
                switchTo(to, in: g)
            }
        case "tab":
            if let n, let w = focusedWin(), let g = groups.group(of: w.id), n >= 1, n <= g.wins.count {
                switchTo(g.wins[n - 1], in: g)
            }
        case "ungroup": ungroupAll()
        case "pause": setPaused(true)
        case "resume": setPaused(false)
        default: NSLog("reawm: unknown command \(c)")
        }
    }

    func focusedWin() -> Win? {
        let sys = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = sys.get(kAXFocusedApplicationAttribute),
              let w: AXUIElement = app.get(kAXFocusedWindowAttribute), let id = w.winID else { return nil }
        return tracker.wins[id]
    }

    // hidden tabs come back, stacked under the shown one
    private func unparkAll() {
        for g in groups.all {
            guard let f = frames[g.id] else { continue }
            for id in g.hidden { if let w = tracker.wins[id], parked.contains(id) { place(w, f) } }
            strips[g.id]?.orderOut(nil)
        }
    }

    func ungroupAll() {
        unparkAll()
        strips.removeAll()
        groups.clear()
        frames.removeAll()
        changed()
    }

    func setPaused(_ on: Bool) {
        Settings.paused = on
        if on { unparkAll() } else { groups.all.forEach { show($0) } }
        onChange?()
    }

    // on quit nothing should stay stuck in a corner. groups are kept for next launch.
    func releaseAll() {
        unparkAll()
        save()
    }

    func bindKeys() {
        keys.removeAll()
        let co = Hotkeys.ctrlOpt
        // ⌃⌥ + arrows never reach a hotkey while an AppKit app is in front, brackets do
        keys.add(30, co) { [weak self] in self?.command("next") }    // ]
        keys.add(33, co) { [weak self] in self?.command("prev") }    // [
        for (i, k) in Hotkeys.digits.enumerated() {
            keys.add(k, co) { [weak self] in self?.command("tab", n: i + 1) }
        }
    }

    // MARK: saving

    struct State: Codable {
        var groups: Groups
        var frames: [UUID: CGRect]
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
        let s = State(groups: groups, frames: frames.filter { live.contains($0.key) })
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}
