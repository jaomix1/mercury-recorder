import AVFoundation
import CoreMedia
import ImageIO
import ScreenCaptureKit

/// Graba en paralelo el micrófono y el audio del sistema con ScreenCaptureKit.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    enum RecorderError: LocalizedError {
        case microphoneDenied
        case screenCaptureDenied(Error)
        case noDisplay
        case notRecording
        case screenshotFailed

        var errorDescription: String? {
            switch self {
            case .notRecording:
                "Solo se pueden tomar capturas mientras se graba."
            case .screenshotFailed:
                "No se pudo guardar la captura de pantalla."
            case .microphoneDenied:
                "No hay permiso para usar el micrófono. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Micrófono."
            case .screenCaptureDenied:
                "No hay permiso para grabar el audio del sistema. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema, y vuelve a abrir la app."
            case .noDisplay:
                "No se encontró ninguna pantalla para iniciar la captura."
            }
        }
    }

    private let queue = DispatchQueue(label: "mercury-recorder.captura")
    private var stream: SCStream?
    private var micWriter: AudioTrackWriter?
    private var systemWriter: AudioTrackWriter?
    private var startHostTime: CMTime = .zero
    private var folder: URL?
    private var startDate = Date()
    private var screenshots: [ScreenshotInfo] = []
    private var micLive: LiveTranscriber?
    private var systemLive: LiveTranscriber?
    private var liveTimer: DispatchSourceTimer?
    private var microphone: MicrophoneCapture?

    /// Cada cuántos segundos se reescribe transcripcion.md durante la grabación.
    static let liveWriteInterval: TimeInterval = 30

    /// Se llama en la cola principal si la captura se detiene por un error del sistema.
    var onUnexpectedStop: ((Error) -> Void)?
    /// Se llama en la cola principal cada vez que se actualiza la transcripción en vivo.
    var onLiveUpdate: (() -> Void)?

    /// Inicia la captura. Con `liveLocale` también transcribe mientras graba.
    func start(in folder: URL, liveLocale: Locale?) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio),
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        else { throw RecorderError.microphoneDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.screenCaptureDenied(error)
        }
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        // ScreenCaptureKit solo graba el audio del sistema; el micrófono va por AVAudioEngine.
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // El video no se usa: se pide lo mínimo posible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        // Si el motor de voz no arranca, se graba igual y se transcribe al final.
        var micLive: LiveTranscriber?
        var systemLive: LiveTranscriber?
        if let liveLocale {
            do {
                micLive = try await LiveTranscriber(speaker: Transcription.speakerMe, locale: liveLocale)
                systemLive = try await LiveTranscriber(speaker: Transcription.speakerOthers, locale: liveLocale)
            } catch {
                NSLog("mercury-recorder: sin transcripción en vivo: \(error.localizedDescription)")
                micLive = nil
                systemLive = nil
            }
        }

        queue.sync {
            self.folder = folder
            let mic = AudioTrackWriter(url: folder.appending(path: MeetingFiles.microphone),
                                       backupURL: folder.appending(path: MeetingFiles.microphoneBackup))
            let system = AudioTrackWriter(url: folder.appending(path: MeetingFiles.system),
                                          backupURL: folder.appending(path: MeetingFiles.systemBackup))
            if let micLive { mic.onAudio = { micLive.append($0) } }
            if let systemLive { system.onAudio = { systemLive.append($0) } }
            self.micWriter = mic
            self.systemWriter = system
            self.micLive = micLive
            self.systemLive = systemLive
            self.startHostTime = CMClockGetTime(CMClockGetHostTimeClock())
            self.startDate = Date()
            self.screenshots = []
            // Marca la reunión "en curso" desde ya: si la app se cierra, se recupera al abrirla.
            try? self.currentInfo(endDate: self.startDate).save(in: folder)
        }
        try await stream.startCapture()
        self.stream = stream

        let microphone = MicrophoneCapture()
        do {
            try microphone.start(queue: queue) { [weak self] buffer, pts in
                do {
                    try self?.micWriter?.append(buffer, at: pts)
                } catch {
                    NSLog("mercury-recorder: error al escribir el micrófono: \(error.localizedDescription)")
                }
            }
        } catch {
            try? await stream.stopCapture()
            self.stream = nil
            throw error
        }
        self.microphone = microphone
        startPeriodicTimer()
    }

    /// Niveles actuales (0…1) y último momento con sonido de cada pista.
    func levels() -> (mic: Float, system: Float, micLastSound: Date?, systemLastSound: Date?, micReceiving: Bool) {
        let (mic, system, receiving) = queue.sync { (micWriter, systemWriter, micWriter?.hasAudio ?? false) }
        return (mic?.level ?? 0, system?.level ?? 0, mic?.lastSoundDate, system?.lastSoundDate, receiving)
    }

    var isTranscribingLive: Bool { queue.sync { micLive != nil } }

    // MARK: Transcripción en vivo

    /// Cada 30 s: actualiza info.json (para poder recuperar la reunión) y, si hay
    /// transcripción en vivo, reescribe transcripcion.md.
    private func startPeriodicTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.liveWriteInterval, repeating: Self.liveWriteInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let folder = self.folder else { return }
            try? self.currentInfo(endDate: Date()).save(in: folder)
            self.writeLiveTranscript()
        }
        timer.resume()
        liveTimer = timer
    }

    /// Reescribe transcripcion.md con lo confirmado hasta ahora. Corre en `queue`.
    private func writeLiveTranscript() {
        guard let folder, let micLive, let systemLive else { return }
        let info = currentInfo(endDate: Date())
        do {
            try Transcription.write(tracks: [(micLive.segments, info.microphoneOffset),
                                             (systemLive.segments, info.systemOffset)],
                                    info: info, folder: folder, inProgress: true)
            DispatchQueue.main.async { self.onLiveUpdate?() }
        } catch {
            NSLog("mercury-recorder: no se pudo escribir la transcripción en vivo: \(error.localizedDescription)")
        }
    }

    private func currentInfo(endDate: Date, inProgress: Bool = true) -> MeetingInfo {
        func offset(_ writer: AudioTrackWriter?) -> Double? {
            guard let writer, writer.hasAudio, let first = writer.firstPTS else { return nil }
            return max(0, (first - startHostTime).seconds)
        }
        // Conserva el nombre si el usuario renombró la reunión mientras se grababa.
        let title = folder.flatMap { MeetingInfo.load(from: $0)?.title }
        return MeetingInfo(startDate: startDate, endDate: endDate,
                           microphoneOffset: offset(micWriter), systemOffset: offset(systemWriter),
                           screenshots: screenshots, title: title, inProgress: inProgress ? true : nil)
    }

    /// Detiene la captura, cierra los archivos y guarda la información de alineación.
    /// Si había transcripción en vivo, la termina y escribe la versión final.
    /// Devuelve true si la transcripción quedó completa (no hace falta transcribir el archivo).
    func stop() async throws -> Bool {
        microphone?.stop()
        microphone = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let (info, micLive, systemLive) = try queue.sync {
            liveTimer?.cancel()
            liveTimer = nil
            let info = try finishFiles()
            let live = (self.micLive, self.systemLive)
            self.micLive = nil
            self.systemLive = nil
            return (info, live.0, live.1)
        }
        guard let micLive, let systemLive, let folder else { return false }

        let micSegments = await micLive.finish()
        let systemSegments = await systemLive.finish()
        if micLive.failure != nil || systemLive.failure != nil { return false }
        try Transcription.write(tracks: [(micSegments, info.microphoneOffset),
                                         (systemSegments, info.systemOffset)],
                                info: info, folder: folder, inProgress: false)
        return true
    }

    private func finishFiles() throws -> MeetingInfo {
        micWriter?.close()
        systemWriter?.close()
        let info = currentInfo(endDate: Date(), inProgress: false)
        if let folder { try info.save(in: folder) }
        micWriter = nil
        systemWriter = nil
        return info
    }

    // MARK: Capturas de pantalla

    /// Toma una captura de la pantalla principal (sin las ventanas de esta app)
    /// y la guarda como PNG en la carpeta de la reunión con la fecha y hora local.
    func captureScreenshot() async throws -> ScreenshotInfo {
        guard stream != nil, let folder = queue.sync(execute: { self.folder }) else {
            throw RecorderError.notRecording
        }
        let takenAt = Date()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "captura_\(formatter.string(from: takenAt))"
        var name = "\(base).png"
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
            name = "\(base)-\(counter).png"
            counter += 1
        }

        let url = folder.appending(path: name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw RecorderError.screenshotFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RecorderError.screenshotFailed }

        return queue.sync {
            let info = ScreenshotInfo(file: name, offset: max(0, takenAt.timeIntervalSince(startDate)), takenAt: takenAt)
            screenshots.append(info)
            return info
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        do {
            switch type {
            case .audio: try systemWriter?.append(sampleBuffer)
            default: break
            }
        } catch {
            NSLog("mercury-recorder: error al escribir audio: \(error.localizedDescription)")
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onUnexpectedStop?(error) }
    }
}
