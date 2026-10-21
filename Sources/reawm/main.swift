import AppKit
import Core

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let wm = WM()
    var item: NSStatusItem!
    var waitTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        Settings.register()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(url(_:_:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "reawm")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        wm.onChange = { [weak self] in self?.item.button?.appearsDisabled = Settings.paused }
        wm.menuBarLook = { [weak self] in self?.item.button?.effectiveAppearance }

        if Access.trusted {
            wm.start()
        } else {
            Access.ask()
            // start as soon as accessibility is granted
            waitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard Access.trusted else { return }
                    t.invalidate()
                    self?.wm.start()
                }
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        wm.releaseAll()
    }

    @objc func url(_ e: NSAppleEventDescriptor, _ reply: NSAppleEventDescriptor) {
        guard let s = e.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let u = URLComponents(string: s) else { return }
        let c = u.host ?? u.path
        let n = u.queryItems?.first { $0.name == "n" }?.value.flatMap(Int.init)
        wm.command(c, n: n)
    }

    // the menu is rebuilt each time it opens so it shows current state
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if !Access.trusted {
            m.addItem(entry("Grant Accessibility access…", #selector(grant)))
            m.addItem(.separator())
        }
        let next = entry("Next Tab", #selector(cmd(_:)), "next")
        next.keyEquivalent = "\t"
        next.keyEquivalentModifierMask = [.option]
        let prev = entry("Previous Tab", #selector(cmd(_:)), "prev")
        prev.keyEquivalent = "\t"
        prev.keyEquivalentModifierMask = [.option, .shift]
        m.addItem(next)
        m.addItem(prev)
        m.addItem(.separator())

        if let app = NSWorkspace.shared.frontmostApplication, let b = app.bundleIdentifier, b != Bundle.main.bundleIdentifier {
            let ex = Settings.excluded.contains(b)
            m.addItem(entry(ex ? "Allow Tabs for \(app.localizedName ?? b)" : "No Tabs for \(app.localizedName ?? b)", #selector(exclude(_:)), b))
        }
        let sides = NSMenu()
        for side in Settings.Side.allCases {
            let i = entry(side.rawValue.capitalized, #selector(setSide(_:)), side.rawValue)
            i.state = Settings.side == side ? .on : .off
            sides.addItem(i)
        }
        let si = NSMenuItem(title: "Tab Bar", action: nil, keyEquivalent: "")
        si.submenu = sides
        m.addItem(si)
        let auto = entry("Tab Every Window", #selector(cmd(_:)), "auto")
        auto.state = Settings.autoTab ? .on : .off
        m.addItem(auto)
        // with every window tabbed, ungrouping would just tab them again
        if !Settings.autoTab {
            let ungroup = entry("Ungroup All Windows", #selector(cmd(_:)), "ungroup")
            ungroup.isEnabled = !wm.groups.all.isEmpty
            m.addItem(ungroup)
        }
        m.addItem(entry(Settings.paused ? "Resume" : "Pause", #selector(cmd(_:)), Settings.paused ? "resume" : "pause"))
        m.addItem(.separator())
        m.addItem(entry("Quit reawm", #selector(quit), key: "q"))
    }

    func entry(_ title: String, _ sel: Selector, _ rep: String? = nil, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        i.representedObject = rep
        return i
    }

    @objc func cmd(_ i: NSMenuItem) { if let c = i.representedObject as? String { wm.command(c) } }
    @objc func grant() { Access.ask() }
    @objc func setSide(_ i: NSMenuItem) {
        if let r = i.representedObject as? String, let side = Settings.Side(rawValue: r) { wm.setSide(side) }
    }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func exclude(_ i: NSMenuItem) {
        guard let b = i.representedObject as? String else { return }
        var ex = Settings.excluded
        if ex.contains(b) { ex.remove(b) } else { ex.insert(b) }
        Settings.excluded = ex
        if ex.contains(b) { wm.release(bundle: b) } else { wm.adoptAll() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
