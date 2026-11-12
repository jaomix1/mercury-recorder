import AVFoundation
import Foundation

/// Anuncios en voz alta ("Grabación iniciada", "Grabación detenida").
@MainActor
final class Announcer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Announcer()

    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Dice el texto y espera a que termine (máximo 4 s), para que el anuncio de inicio
    /// suene antes de empezar a grabar y no quede en la transcripción.
    func say(_ text: String) async {
        synthesizer.stopSpeaking(at: .immediate)
        finished?.resume()
        finished = nil

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-MX") ?? AVSpeechSynthesisVoice(language: "es-ES")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05

        await withCheckedContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                self.finished?.resume()
                self.finished = nil
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finished?.resume()
            self.finished = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finished?.resume()
            self.finished = nil
        }
    }
}
