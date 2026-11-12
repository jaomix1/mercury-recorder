import AppKit
import CoreAudio
import Foundation

/// Detecta cuándo una app de reuniones (Zoom, Teams, Meet en el navegador…) empieza
/// a usar el micrófono. Revisa cada 3 s la lista de procesos de audio de macOS.
final class MeetingDetector {
    /// Apps conocidas: prefijo del bundle ID → nombre para mostrar.
    /// Los navegadores usan procesos auxiliares (p. ej. com.google.Chrome.helper).
    static let knownApps: [(prefix: String, name: String)] = [
        ("us.zoom.", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webex", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("company.thebrowser", "Arc"),
        ("org.mozilla.firefox", "Firefox"),
    ]

    /// Se llama en la cola principal con el nombre de la app que empezó a usar el micrófono.
    var onMeetingStarted: ((String) -> Void)?
    /// Se llama cuando ninguna app de reuniones está usando ya el micrófono.
    var onAllMeetingsEnded: (() -> Void)?

    private var timer: Timer?
    private var activeApps: Set<String> = []

    func start() {
        guard timer == nil else { return }
        activeApps = Set(Self.appsUsingMicrophone())  // lo que ya estaba abierto no avisa
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
        // Modo .common: sigue revisando aunque el menú de la barra esté abierto.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let now = Set(Self.appsUsingMicrophone())
        for app in now.subtracting(activeApps).sorted() { onMeetingStarted?(app) }
        if now.isEmpty, !activeApps.isEmpty { onAllMeetingsEnded?() }
        activeApps = now
    }

    /// Nombres de las apps conocidas que están usando el micrófono (sin contar esta app).
    static func appsUsingMicrophone() -> [String] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for process in audioProcessObjects() {
            guard isRunningInput(process), pid(of: process) != ownPID,
                  let bundleID = bundleID(of: process),
                  let app = knownApps.first(where: { bundleID.hasPrefix($0.prefix) })
            else { continue }
            if !names.contains(app.name) { names.append(app.name) }
        }
        return names
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioProcessObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func pid(of process: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value)
        return value
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue()
        else { return nil }
        let id = string as String
        return id.isEmpty ? nil : id
    }
}
