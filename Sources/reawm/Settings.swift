import Foundation

// everything lives in UserDefaults under the app's bundle id
enum Settings {
    static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            "stripHeight": 30.0,
            "side": "top",       // where the tab bar sits: top, left or right
            "sideWidth": 220.0,
            "titleBand": 52.0,   // how far down a window's top a drop still counts as its title bar
            "dropHold": 0.25,    // seconds to rest on a target before a drop would join it
            "autoTab": true,     // every window joins its display's bar
            "excluded": [String](),
            "displays": "all",          // which displays get bars: all, main or custom
            "offDisplays": [String](),  // with custom: the ones switched off, by display uuid
            "paused": false,
        ])
    }

    static var stripHeight: Double { d.double(forKey: "stripHeight") }
    static var sideWidth: Double { d.double(forKey: "sideWidth") }

    enum Side: String, CaseIterable { case top, left, right }
    static var side: Side {
        get { Side(rawValue: d.string(forKey: "side") ?? "") ?? .top }
        set { d.set(newValue.rawValue, forKey: "side") }
    }
    static var titleBand: Double { d.double(forKey: "titleBand") }
    static var dropHold: Double { d.double(forKey: "dropHold") }

    static var autoTab: Bool {
        get { d.bool(forKey: "autoTab") }
        set { d.set(newValue, forKey: "autoTab") }
    }

    static var excluded: Set<String> {
        get { Set(d.stringArray(forKey: "excluded") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "excluded") }
    }

    enum Displays: String { case all, main, custom }
    static var displays: Displays {
        get { Displays(rawValue: d.string(forKey: "displays") ?? "") ?? .all }
        set { d.set(newValue.rawValue, forKey: "displays") }
    }

    static var offDisplays: Set<String> {
        get { Set(d.stringArray(forKey: "offDisplays") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "offDisplays") }
    }

    static var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }
}
