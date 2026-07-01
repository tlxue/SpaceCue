import Carbon.HIToolbox
import Foundation

final class HotKeyManager {
    private var refs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var onPressed: ((Int) -> Void)?
    private let signature = FourCharCode("SCue")

    func register(maximumOrdinal: Int, onPressed: @escaping (Int) -> Void) {
        unregister()
        self.onPressed = onPressed

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr else {
                    return status
                }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                SpaceCueLog.write("hotkey pressed ordinal=\(hotKeyID.id) source=carbon")
                manager.onPressed?(Int(hotKeyID.id))
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )

        let count = min(max(maximumOrdinal, 1), 9)
        for ordinal in 1...count {
            guard let keyCode = KeyboardFallback.keyCode(for: ordinal) else {
                continue
            }

            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: UInt32(ordinal))
            let modifiers = UInt32(optionKey)
            var usedExclusive = true
            var status = RegisterEventHotKey(
                UInt32(keyCode),
                modifiers,
                hotKeyID,
                GetEventDispatcherTarget(),
                UInt32(kEventHotKeyExclusive),
                &ref
            )

            if status == noErr {
                refs.append(ref)
                SpaceCueLog.write("hotkey registered ordinal=\(ordinal) modifiers=option exclusive=\(usedExclusive)")
            } else {
                SpaceCueLog.write("hotkey exclusive registration failed ordinal=\(ordinal) status=\(status); retrying nonexclusive")
                usedExclusive = false
                status = RegisterEventHotKey(
                    UInt32(keyCode),
                    modifiers,
                    hotKeyID,
                    GetEventDispatcherTarget(),
                    0,
                    &ref
                )

                if status == noErr {
                    refs.append(ref)
                    SpaceCueLog.write("hotkey registered ordinal=\(ordinal) modifiers=option exclusive=\(usedExclusive)")
                } else {
                    SpaceCueLog.write("hotkey registration failed ordinal=\(ordinal) status=\(status)")
                }
            }
        }
    }

    func unregister() {
        for ref in refs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        refs.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }

    deinit {
        unregister()
    }
}

private func FourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}
