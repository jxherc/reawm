import AppKit
import Carbon

// one event tap that watches the left mouse button (window drags)
final class Tap {
    // return a point to move the event there before any app sees it (the bar's wall)
    var onMouse: ((CGEventType, CGPoint) -> CGPoint?)?
    private var port: CFMachPort?

    func start() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: tapCallback, userInfo: me) else { return false }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            let p = e.location
            // the app resizing or moving its window reads this event, so the limit has to
            // be in the event itself: moving the pointer afterwards is a frame too late
            if let q = onMouse?(type, p), q != p {
                e.location = q
                if q.y != p.y { e.setIntegerValueField(.mouseEventDeltaY, value: 0) }
                if q.x != p.x { e.setIntegerValueField(.mouseEventDeltaX, value: 0) }
            }
        default:
            break
        }
    }
}

private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ e: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon { Unmanaged<Tap>.fromOpaque(refcon).takeUnretainedValue().handle(type, e) }
    return Unmanaged.passUnretained(e)
}

// the tab shortcuts, caught before any app sees the key: some apps get keys ahead of
// Carbon hotkeys, so those didn't fire everywhere. return true from onKey to take it.
final class KeyTap {
    var onKey: ((Int, CGEventFlags, Bool) -> Bool)?   // key code, modifiers, is a repeat
    private var port: CFMachPort?
    private var taken: Set<Int64> = []   // keys whose key-up we swallow too

    func start() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: keyCallback, userInfo: me) else { return false }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let k = e.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown:
            let rep = e.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if onKey?(Int(k), e.flags, rep) == true { taken.insert(k); return true }
        case .keyUp:
            if taken.remove(k) != nil { return true }
        default:
            break
        }
        return false
    }
}

private func keyCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ e: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(e) }
    return Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, e) ? nil : Unmanaged.passUnretained(e)
}

// global shortcuts through Carbon, which needs no extra permission
final class Hotkeys {
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var next: UInt32 = 1

    static let ctrlOpt = UInt32(controlKey | optionKey)
    static let opt = UInt32(optionKey)
    static let optShift = UInt32(optionKey | shiftKey)
    static let optCmd = UInt32(optionKey | cmdKey)

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, refcon in
            guard let ev, let refcon else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue()
            me.actions[hk.id]?()
            return noErr
        }, 1, &spec, me, nil)
    }

    func add(_ key: Int, _ mods: UInt32, _ f: @escaping () -> Void) {
        let id = next
        next += 1
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x7265_6177), id: id)  // 'reaw'
        guard RegisterEventHotKey(UInt32(key), mods, hk, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return }
        refs.append(ref)
        actions[id] = f
    }

    func removeAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actions.removeAll()
    }

    static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
}
