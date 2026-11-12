import AVFoundation
import CoreMedia

/// Graba el micrófono con AVAudioEngine (independiente de ScreenCaptureKit, que solo
/// se usa para el audio del sistema). Entrega copias de los bloques en `queue`, con
/// la marca de tiempo del reloj del sistema para alinearlos con la otra pista.
final class MicrophoneCapture {
    enum CaptureError: LocalizedError {
        case noInputDevice

        var errorDescription: String? {
            "No se encontró ningún micrófono. Conecta uno o revisa Ajustes del Sistema › Sonido › Entrada."
        }
    }

    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var handler: ((AVAudioPCMBuffer, CMTime) -> Void)?
    private var queue: DispatchQueue?

    func start(queue: DispatchQueue, handler: @escaping (AVAudioPCMBuffer, CMTime) -> Void) throws {
        self.queue = queue
        self.handler = handler
        try startEngine()
        // Si cambia el micrófono (p. ej. se conectan audífonos), el motor se detiene: se rearma.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.engine = AVAudioEngine()
            do {
                try self.startEngine()
            } catch {
                NSLog("mercury-recorder: no se pudo reanudar el micrófono: \(error.localizedDescription)")
            }
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        let bufferSize = AVAudioFrameCount(format.sampleRate / 10) // 100 ms
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            guard let self, let queue = self.queue, let copy = Self.copy(buffer) else { return }
            let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
            let pts = CMClockMakeHostTimeFromSystemUnits(hostTime)
            queue.async { self.handler?(copy, pts) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        handler = nil
    }

    /// El motor reutiliza su buffer después del tap: se copia antes de pasarlo a otra cola.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
