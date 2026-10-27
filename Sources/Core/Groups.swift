import Foundation

public typealias WinID = UInt32

// windows that share one frame and show one at a time, like browser tabs
public final class Group: Codable {
    public let id: UUID
    public internal(set) var wins: [WinID]
    public internal(set) var active: WinID

    public init(id: UUID = UUID(), wins: [WinID], active: WinID? = nil) {
        self.id = id
        self.wins = wins
        self.active = active ?? wins[0]
    }

    public var hidden: [WinID] { wins.filter { $0 != active } }
}

public final class Groups: Codable {
    public private(set) var all: [Group] = []

    public init() {}

    public func group(of w: WinID) -> Group? { all.first { $0.wins.contains(w) } }

    // put w into target's group (one is made if target is alone) at index, or at
    // the end. w becomes the shown tab unless select is false.
    @discardableResult
    public func join(_ w: WinID, onto target: WinID, at index: Int? = nil, select: Bool = true) -> Group? {
        guard w != target else { return nil }
        if let g = group(of: w), g.wins.contains(target) {
            if let index { move(w, to: index) }
            if select { g.active = w }
            return g
        }
        remove(w)
        let g = group(of: target) ?? {
            let g = Group(wins: [target])
            all.append(g)
            return g
        }()
        g.wins.insert(w, at: min(max(0, index ?? g.wins.count), g.wins.count))
        if select { g.active = w }
        return g
    }

    // a new window opens right after the tab it came from, like a browser tab
    @discardableResult
    public func open(_ w: WinID, after target: WinID, select: Bool = true) -> Group? {
        let at = group(of: target)?.wins.firstIndex(of: target).map { $0 + 1 } ?? 1
        return join(w, onto: target, at: at, select: select)
    }

    // take w out of its group and return that group. a group left with one
    // window stops being a group (it's no longer in `all`). when the shown tab
    // leaves, the one to its right is shown, like a browser.
    @discardableResult
    public func remove(_ w: WinID) -> Group? {
        guard let g = group(of: w), let i = g.wins.firstIndex(of: w) else { return nil }
        g.wins.remove(at: i)
        if g.active == w, !g.wins.isEmpty { g.active = g.wins[min(i, g.wins.count - 1)] }
        if g.wins.count < 2 { all.removeAll { $0 === g } }
        return g
    }

    public func select(_ w: WinID) {
        group(of: w)?.active = w
    }

    public func move(_ w: WinID, to index: Int) {
        guard let g = group(of: w), let i = g.wins.firstIndex(of: w) else { return }
        g.wins.remove(at: i)
        g.wins.insert(w, at: min(max(0, index), g.wins.count))
    }

    // the tab d steps from w's group's shown tab, wrapping around
    public func step(_ w: WinID, by d: Int) -> WinID? {
        guard let g = group(of: w), let i = g.wins.firstIndex(of: g.active) else { return nil }
        let n = g.wins.count
        return g.wins[((i + d) % n + n) % n]
    }

    // drop windows that no longer exist
    public func prune(keeping live: Set<WinID>) {
        for g in all {
            for w in g.wins where !live.contains(w) { remove(w) }
        }
    }

    public func clear() { all.removeAll() }
}
