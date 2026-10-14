import Carbon.HIToolbox
import Foundation

/// System-wide keyboard shortcuts via Carbon, which needs no Accessibility permission.
final class Hotkeys {
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var actions: [ShortcutAction] = []
    private var onAction: ((ShortcutAction) -> Void)?
    /// Shortcuts another app already owns, so the menu can flag them.
    private(set) var failed: Set<ShortcutAction> = []

    func register(_ actions: [ShortcutAction], onAction: @escaping (ShortcutAction) -> Void) {
        self.actions = actions
        self.onAction = onAction
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            guard let event, let ctx else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<Hotkeys>.fromOpaque(ctx).takeUnretainedValue()
            let index = Int(id.id)
            if index < me.actions.count {
                let action = me.actions[index]
                DispatchQueue.main.async { me.onAction?(action) }
            }
            return noErr
        }, 1, &spec, ctx, &handler)

        for (i, action) in actions.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5852_4541), id: UInt32(i)) // 'XREA'
            let status = RegisterEventHotKey(UInt32(action.keyCode), Hotkeys.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status != noErr {
                failed.insert(action)
                Log.info("shortcut \(action.display) unavailable (\(status))")
            }
            refs.append(ref)
        }
    }
}
