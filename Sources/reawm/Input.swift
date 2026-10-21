import AppKit
import Carbon

// one event tap that watches the left mouse button (window drags)
final class Tap {
    var onMouse: ((CGEventType, CGPoint) -> Void)?
    private var port: CFMachPort?

    func start() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
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
            onMouse?(type, e.location)
        default:
            break
        }
    }
}

private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ e: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon { Unmanaged<Tap>.fromOpaque(refcon).takeUnretainedValue().handle(type, e) }
    return Unmanaged.passUnretained(e)
}

// global shortcuts through Carbon, which needs no extra permission
final class Hotkeys {
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var next: UInt32 = 1

    static let ctrlOpt = UInt32(controlKey | optionKey)

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
