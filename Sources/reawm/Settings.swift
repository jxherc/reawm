import Foundation

// everything lives in UserDefaults under the app's bundle id
enum Settings {
    static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            "stripHeight": 30.0,
            "titleBand": 52.0,   // how far down a window's top a drop still counts as its title bar
            "dropHold": 0.25,    // seconds to rest on a target before a drop would join it
            "excluded": [String](),
            "paused": false,
        ])
    }

    static var stripHeight: Double { d.double(forKey: "stripHeight") }
    static var titleBand: Double { d.double(forKey: "titleBand") }
    static var dropHold: Double { d.double(forKey: "dropHold") }

    static var excluded: Set<String> {
        get { Set(d.stringArray(forKey: "excluded") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "excluded") }
    }

    static var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }
}
