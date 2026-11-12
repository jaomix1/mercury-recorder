import AVFoundation
import Foundation
import Speech

struct TranscriptSegment: Equatable {
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

enum TranscriptionError: LocalizedError {
    case unsupportedLanguage

    var errorDescription: String? {
        "El motor de transcripción de este Mac no admite español."
    }
}

/// Transcripción local con SpeechAnalyzer (macOS 26+). No envía audio a internet.
enum Transcription {
    static let speakerMe = "Yo"
    static let speakerOthers = "Participantes"

    /// Devuelve el idioma español disponible y descarga el modelo si hace falta.
    static func prepareSpanish() async throws -> Locale {
        let preferred = [Locale(identifier: "es-CO"), Locale(identifier: "es-419"), Locale(identifier: "es-MX"),
                         Locale(identifier: "es-US"), Locale(identifier: "es-ES")]
        var locale: Locale?
        for candidate in preferred {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                locale = supported
                break
            }
        }
        guard let locale else { throw TranscriptionError.unsupportedLanguage }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return locale
    }

    /// Transcribe un archivo y devuelve sus frases con tiempos relativos al archivo.
    static func transcribe(file url: URL, speaker: String, locale: Locale) async throws -> [TranscriptSegment] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(speaker: speaker, start: result.range.start.seconds,
                                                  end: result.range.end.seconds, text: text))
            }
            return segments
        }

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    /// Transcribe las dos pistas de una reunión y escribe transcripcion.md.
    @discardableResult
    static func transcribeMeeting(at folder: URL) async throws -> URL {
        let info = MeetingInfo.load(from: folder)
        let locale = try await prepareSpanish()
        let fm = FileManager.default

        var transcribed: [([TranscriptSegment], Double?)] = []
        let tracks: [(String, String, Double?)] = [
            (MeetingFiles.microphone, speakerMe, info?.microphoneOffset),
            (MeetingFiles.system, speakerOthers, info?.systemOffset),
        ]
        for (name, speaker, offset) in tracks {
            let url = folder.appending(path: name)
            guard fm.fileExists(atPath: url.path) else { continue }
            if info != nil && offset == nil { continue } // pista sin audio
            let trackSegments = try await transcribe(file: url, speaker: speaker, locale: locale)
            transcribed.append((trackSegments, offset))
        }
        return try write(tracks: transcribed, info: info, folder: folder, inProgress: false)
    }

    /// Une las pistas (desplazando cada una por su offset), arma el Markdown y lo
    /// guarda en transcripcion.md. Con `inProgress` agrega un aviso al final.
    @discardableResult
    static func write(tracks: [([TranscriptSegment], Double?)], info: MeetingInfo?, folder: URL,
                      inProgress: Bool) throws -> URL {
        var segments: [TranscriptSegment] = []
        for (trackSegments, offset) in tracks {
            segments += trackSegments.map {
                var s = $0
                s.start += offset ?? 0
                s.end += offset ?? 0
                return s
            }
        }
        segments = removeEcho(segments)
        var markdown = render(merge(segments), screenshots: info?.screenshots ?? [],
                              startDate: info?.startDate, title: info?.title, inProgress: inProgress)
        if inProgress {
            let now = Date().formatted(.dateTime.hour().minute().locale(Locale(identifier: "es_CO")))
            markdown += "\n---\n_Grabación en curso. Transcripción actualizada a las \(now); se actualiza cada 30 segundos._\n"
        }
        let output = folder.appending(path: MeetingFiles.transcript)
        try markdown.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    // MARK: Eco

    /// Quita las frases de "Yo" que son eco de los demás: sin audífonos, el micrófono
    /// capta lo que suena por los parlantes y esas frases salen repetidas. Una frase del
    /// micrófono se descarta si la mayoría de sus palabras aparecen en lo que sonó por el
    /// sistema en ese mismo momento (±2 s).
    static func removeEcho(_ segments: [TranscriptSegment], window: Double = 2.0,
                           threshold: Double = 0.6) -> [TranscriptSegment] {
        let others = segments.filter { $0.speaker == speakerOthers }
        guard !others.isEmpty else { return segments }
        return segments.filter { segment in
            guard segment.speaker == speakerMe else { return true }
            let words = normalizedWords(segment.text)
            guard words.count >= 2 else {
                // Una sola palabra: solo se descarta si coincide exactamente con una frase del sistema.
                return !others.contains {
                    abs($0.start - segment.start) <= window && normalizedWords($0.text) == words
                }
            }
            var heard: [String: Int] = [:]
            for other in others where other.end >= segment.start - window && other.start <= segment.end + window {
                for word in normalizedWords(other.text) { heard[word, default: 0] += 1 }
            }
            var matched = 0
            for word in words where (heard[word] ?? 0) > 0 {
                matched += 1
                heard[word]! -= 1
            }
            return Double(matched) / Double(words.count) < threshold
        }
    }

    /// Palabras en minúscula, sin tildes ni signos de puntuación.
    static func normalizedWords(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Ordena por tiempo y une frases seguidas del mismo hablante.
    static func merge(_ segments: [TranscriptSegment], maxGap: Double = 2.0) -> [TranscriptSegment] {
        var merged: [TranscriptSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, last.speaker == segment.speaker, segment.start - last.end <= maxGap {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// Párrafos que se muestran de una transcripción: sin el encabezado "# …", sin
    /// líneas vacías ni separadores. Lo usan la vista y el buscador (mismos índices).
    static func paragraphs(_ markdown: String) -> [String] {
        markdown.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("# ") && trimmed != "---"
        }
    }

    /// Primera línea de transcripcion.md: "# <nombre> — <fecha>".
    static func header(title: String?, startDate: Date?) -> String {
        let date = startDate.map {
            $0.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()
                .locale(Locale(identifier: "es_CO")))
        }
        switch (title, date) {
        case let (title?, date?): return "# \(title) — \(date)"
        case let (title?, nil): return "# \(title)"
        case let (nil, date?): return "# Reunión — \(date)"
        case (nil, nil): return "# Reunión"
        }
    }

    /// Cambia solo el encabezado de una transcripción existente (al renombrar).
    static func updateHeader(at folder: URL, title: String?, startDate: Date?) throws {
        let url = folder.appending(path: MeetingFiles.transcript)
        guard var lines = try? String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n") else { return }
        let newHeader = header(title: title, startDate: startDate)
        if let first = lines.first, first.hasPrefix("# ") {
            lines[0] = newHeader
        } else {
            lines.insert(contentsOf: [newHeader, ""], at: 0)
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Arma el Markdown. Las capturas se intercalan en su momento con un link
    /// relativo al PNG (que está en la misma carpeta que transcripcion.md).
    static func render(_ segments: [TranscriptSegment], screenshots: [ScreenshotInfo] = [],
                       startDate: Date?, title: String? = nil, inProgress: Bool = false) -> String {
        var lines: [String] = []
        lines.append(header(title: title, startDate: startDate))
        lines.append("")
        if segments.isEmpty {
            lines.append(inProgress ? "_Aún no hay frases transcritas._" : "_No se detectó voz en la grabación._")
            lines.append("")
        }

        // Una captura va antes de la primera frase que empieza después de ella.
        var pending = screenshots.sorted { $0.offset < $1.offset }[...]
        func flushScreenshots(before time: Double) {
            while let shot = pending.first, shot.offset <= time {
                lines.append(screenshotLine(shot, startDate: startDate))
                lines.append("")
                pending = pending.dropFirst()
            }
        }
        for segment in segments {
            flushScreenshots(before: segment.start)
            lines.append("**[\(timestamp(segment.start))] \(segment.speaker):** \(segment.text)")
            lines.append("")
        }
        flushScreenshots(before: .infinity)
        return lines.joined(separator: "\n")
    }

    static func screenshotLine(_ shot: ScreenshotInfo, startDate: Date?) -> String {
        let link = shot.file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? shot.file
        var label = shot.file
        if let takenAt = shot.takenAt ?? startDate?.addingTimeInterval(shot.offset) {
            // Sin fracciones de segundo, para que coincida con la hora del nombre del archivo.
            let whole = Date(timeIntervalSince1970: takenAt.timeIntervalSince1970.rounded(.down))
            label = "Captura " + whole.formatted(.dateTime.hour().minute().second()
                .locale(Locale(identifier: "es_CO")))
        }
        return "**[\(timestamp(shot.offset))] 📷 Captura de pantalla:** [\(label)](\(link))"
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
