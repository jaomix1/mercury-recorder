import AVFoundation
import CoreMedia

/// Escribe una pista de audio (micrófono o sistema) en un .m4a mono.
/// Rellena con silencio los huecos de la señal para que la línea de tiempo
/// del archivo coincida con el reloj real y las dos pistas queden alineadas.
/// Además guarda un respaldo recuperable y mide el nivel de la señal.
/// No es thread-safe: se usa solo desde la cola de captura (salvo `level`).
final class AudioTrackWriter {
    let url: URL
    private(set) var firstPTS: CMTime?
    /// Recibe cada bloque de audio escrito (también el silencio de relleno),
    /// para la transcripción en vivo.
    var onAudio: ((AVAudioPCMBuffer) -> Void)?

    private var file: AVAudioFile?
    private let backup: BackupWriter?
    private var resampler: StreamingResampler?
    private var targetFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private let meter = LevelMeter()

    /// Nivel actual (0…1) y momento en que hubo sonido por última vez. Thread-safe.
    var level: Float { meter.level }
    var lastSoundDate: Date? { meter.lastSoundDate }

    /// Frecuencia de las pistas guardadas.
    static let sampleRate: Double = 48_000

    init(url: URL, backupURL: URL?) {
        self.url = url
        backup = backupURL.flatMap { try? BackupWriter(url: $0) }
    }

    /// Audio de ScreenCaptureKit (sistema).
    func append(_ sampleBuffer: CMSampleBuffer) throws {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return }
        let pts = sampleBuffer.presentationTimeStamp
        try sampleBuffer.withAudioBufferList { bufferList, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList.unsafePointer)
            else { return }
            try append(input, at: pts)
        }
    }

    /// Bloque PCM con su marca de tiempo (reloj del sistema). Lo usa el micrófono.
    func append(_ input: AVAudioPCMBuffer, at pts: CMTime) throws {
        guard input.frameLength > 0 else { return }
        if firstPTS == nil { firstPTS = pts }

        if file == nil {
            // La pista se guarda mono a 48 kHz, sin importar la frecuencia del dispositivo.
            // (Con 16 kHz, p. ej. un micrófono en modo llamada, el codificador AAC rechaza
            // 64 kbps y todo el audio se perdía.)
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                       channels: 1, interleaved: false)!
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: target.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            targetFormat = target
            resampler = StreamingResampler(outputFormat: target)
        }
        guard let targetFormat, let resampler else { return }

        try padSilence(until: pts, sampleRate: targetFormat.sampleRate)

        // Convierte a mono y, si el dispositivo cambió de frecuencia, la ajusta.
        guard let output = resampler.convert(input) else { return }
        meter.measure(output)
        try write(output)
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        try file?.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        backup?.append(buffer)
        onAudio?(buffer)
    }

    /// Si llegó un buffer más tarde de lo esperado, escribe silencio en el hueco.
    private func padSilence(until pts: CMTime, sampleRate: Double) throws {
        guard let firstPTS, let targetFormat else { return }
        let expected = Double(framesWritten) / sampleRate
        let actual = (pts - firstPTS).seconds
        var missing = AVAudioFramePosition((actual - expected) * sampleRate)
        guard missing > AVAudioFramePosition(sampleRate * 0.05) else { return }

        let chunk: AVAudioFrameCount = 48_000
        while missing > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), missing))
            // Un buffer nuevo por bloque: el transcriptor lo usa después, en otro hilo.
            guard let silence = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: n) else { return }
            silence.frameLength = n
            if let data = silence.floatChannelData?[0] { data.initialize(repeating: 0, count: Int(n)) }
            try write(silence)
            missing -= AVAudioFramePosition(n)
        }
    }

    var hasAudio: Bool { framesWritten > 0 }

    /// Cierra el .m4a. El respaldo se borra solo si el .m4a quedó bien cerrado.
    func close() {
        file?.close()
        file = nil
        backup?.close()
        if let backup { try? FileManager.default.removeItem(at: backup.url) }
    }
}

/// Mide el nivel (RMS en dB, normalizado a 0…1) de los bloques de audio.
final class LevelMeter {
    private let lock = NSLock()
    private var _level: Float = 0
    private var _lastSoundDate: Date?

    /// Por encima de este nivel (≈ -45 dBFS) se considera que hay sonido.
    static let soundThreshold: Float = 0.25

    var level: Float { lock.withLock { _level } }
    var lastSoundDate: Date? { lock.withLock { _lastSoundDate } }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = min(1, max(0, (db + 60) / 60)) // -60 dB → 0, 0 dB → 1
        lock.withLock {
            // Sube rápido y baja despacio, para que las barras no parpadeen.
            _level = normalized > _level ? normalized : _level * 0.85 + normalized * 0.15
            if normalized >= Self.soundThreshold { _lastSoundDate = Date() }
        }
    }
}
