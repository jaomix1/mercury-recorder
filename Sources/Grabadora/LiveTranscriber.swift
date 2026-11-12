import AVFoundation
import Foundation
import Speech

/// Transcribe una pista mientras se graba. Recibe el mismo audio que se escribe
/// en el .m4a (incluido el silencio de relleno), así que los tiempos de las frases
/// coinciden con los del archivo.
final class LiveTranscriber {
    let speaker: String

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Error>?
    private let resampler: StreamingResampler

    private let lock = NSLock()
    private var _segments: [TranscriptSegment] = []
    private var _failure: Error?

    /// Frases confirmadas hasta ahora (tiempos relativos al inicio de la pista).
    var segments: [TranscriptSegment] { lock.withLock { _segments } }
    var failure: Error? { lock.withLock { _failure } }

    init(speaker: String, locale: Locale) async throws {
        self.speaker = speaker
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [], attributeOptions: [.audioTimeRange])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.unsupportedLanguage
        }
        analyzerFormat = format
        resampler = StreamingResampler(outputFormat: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = continuation
        analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)

        let transcriber = self.transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, let self else { continue }
                    let segment = TranscriptSegment(speaker: speaker, start: result.range.start.seconds,
                                                    end: result.range.end.seconds, text: text)
                    self.lock.withLock { self._segments.append(segment) }
                }
            } catch {
                self?.lock.withLock { self?._failure = error }
            }
        }
    }

    /// Recibe audio de la cola de captura. Lo convierte al formato del motor y lo encola.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let output = resampler.convert(buffer) else { return }
        lock.withLock { _receivedAudio = true }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    private var _receivedAudio = false

    /// Segundos máximos de espera al cerrar; después se guarda lo confirmado hasta ahí.
    static let finishTimeout: TimeInterval = 120

    /// Termina el audio y espera a que el motor confirme las últimas frases.
    func finish() async -> [TranscriptSegment] {
        continuation.finish()
        // Si la pista nunca recibió audio, el motor se quedaría esperando: se cancela.
        guard lock.withLock({ _receivedAudio }) else {
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
            return segments
        }

        let analyzer = self.analyzer
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.finishTimeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if finished {
            _ = try? await resultsTask?.value
        } else {
            NSLog("Grabadora: el motor de voz no terminó a tiempo; se guarda lo confirmado")
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
        }
        return segments
    }
}
