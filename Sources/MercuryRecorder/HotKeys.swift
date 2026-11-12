import Carbon
import Foundation

/// Atajos de teclado globales (funcionan aunque la app no esté al frente).
/// Usa la API de Carbon, que no necesita el permiso de Accesibilidad.
final class HotKeys {
    static let shared = HotKeys()

    /// ⌃⌥R: iniciar o detener la grabación.
    static let recordLabel = "⌃⌥R"
    /// ⌃⌥S: capturar pantalla.
    static let screenshotLabel = "⌃⌥S"

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    /// Registra los atajos de la app. Si otro programa ya usa la combinación, se ignora.
    func registerDefaults(record: @escaping () -> Void, screenshot: @escaping () -> Void) {
        let modifiers = UInt32(controlKey | optionKey)
        register(keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers, id: 1, action: record)
        register(keyCode: UInt32(kVK_ANSI_S), modifiers: modifiers, id: 2, action: screenshot)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4752_4142), id: id) // "GRAB"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("mercury-recorder: no se pudo registrar el atajo \(id) (código \(status))")
            return
        }
        refs.append(ref)
        actions[id] = action
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeys.shared.actions[id]?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
