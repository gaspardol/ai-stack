import Carbon

/// System-wide keyboard shortcut (Carbon hot key: works while other apps are in front, no extra permission).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private var reference: EventHotKeyRef?

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4149_534B), id: id) // 'AISK'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            Log.error("Could not register hot key \(id) (status \(status))", "app")
            return nil
        }
        Self.handlers[id] = handler
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let handler = HotKey.handlers[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async(execute: handler)
            return noErr
        }, 1, &spec, nil, nil)
    }
}
