import AppKit
import Carbon

@MainActor
final class GlobalShortcuts {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onComposer: (() -> Void)?
    var onSidebar: (() -> Void)?

    func register() throws {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if id.id == 1 { shortcuts.onComposer?() }
                if id.id == 2 { shortcuts.onSidebar?() }
            }
            return noErr
        }, 1, &event, pointer, &handler)
        guard status == noErr else { throw ShortcutError.registration(status) }
        for (id, key) in [(UInt32(1), kVK_Space), (UInt32(2), kVK_ANSI_H)] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(controlKey | shiftKey),
                                            EventHotKeyID(signature: 0x4D52474E, id: id),
                                            GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else { throw ShortcutError.registration(result) }
            references.append(reference)
        }
    }

    enum ShortcutError: LocalizedError {
        case registration(OSStatus)
        var errorDescription: String? { "Margin could not register its shortcuts (\(self)). Another app may already use them." }
    }
}
