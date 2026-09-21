import AppKit
import Carbon.HIToolbox

/// System-wide hotkey (default ⌃⌥F) that summons Fleet from any app.
/// Carbon's RegisterEventHotKey needs no Accessibility permission.
enum Hotkey {
    nonisolated(unsafe) private static var handler: EventHandlerRef?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?
    nonisolated(unsafe) private static var action: (() -> Void)?

    @discardableResult
    static func register(keyCode: Int = kVK_ANSI_F, modifiers: Int = controlKey | optionKey, _ onPress: @escaping () -> Void) -> Bool {
        action = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: OSType(0x464C5431), id: 1)   // 'FLT1'
        return RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    /// Show and focus the main window, un-hiding it if the app was tucked away.
    @MainActor static func summon() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.canBecomeMain || w.title == "fleet" {
            w.makeKeyAndOrderFront(nil)
        }
    }
}
