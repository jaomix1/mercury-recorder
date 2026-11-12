import Foundation
import FoundationModels

/// Resumen de una reunión, guardado aparte en resumen.md. Dos motores:
/// 1. Apple Intelligence: corre en el Mac, nada sale del equipo (preferido).
/// 2. Claude, con la CLI `claude` y la suscripción del usuario (sin clave de API).
///    La transcripción (texto) se envía a Anthropic; el audio no sale del Mac.
enum Summarizer {
    enum Engine {
        case apple
        case claude(URL)

        var name: String {
            switch self {
            case .apple: "Apple Intelligence"
            case .claude: "Claude"
            }
        }
    }

    enum SummaryError: LocalizedError {
        case unavailable(String)
        case emptyTranscript
        case claudeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .emptyTranscript: "La transcripción no tiene frases para resumir."
            case .claudeFailed(let detail): "Claude no pudo generar el resumen. \(detail)"
            }
        }
    }

    /// Motor elegido con los botones "Resumir con Apple" / "Resumir con Claude".
    enum Choice {
        case apple
        case claude

        var name: String {
            switch self {
            case .apple: "Apple Intelligence"
            case .claude: "Claude"
            }
        }
    }

    /// nil si ese motor se puede usar; si no, el motivo.
    static func unavailableReason(for choice: Choice) -> String? {
        switch choice {
        case .apple: appleUnavailableReason
        case .claude: claudeExecutable == nil
            ? "No se encontró la herramienta «claude» (Claude Code). Instálala para resumir con Claude." : nil
        }
    }

    // MARK: Motor disponible

    /// Motor que se usará: Apple Intelligence si está listo; si no, Claude si está instalado.
    static var engine: Engine? {
        if appleUnavailableReason == nil { return .apple }
        if let claude = claudeExecutable { return .claude(claude) }
        return nil
    }

    /// nil si hay algún motor disponible; si no, el motivo en español.
    static var unavailableReason: String? {
        guard engine == nil else { return nil }
        return (appleUnavailableReason ?? "") + " Tampoco se encontró la herramienta «claude» (Claude Code) para resumir con Claude."
    }

    /// Texto corto para la interfaz: con qué se resumirá y qué implica.
    static var engineDescription: String {
        switch engine {
        case .apple: "Se resume con Apple Intelligence, sin salir de este Mac."
        case .claude: "Apple Intelligence no está listo: se resume con Claude. La transcripción (texto) se envía a Anthropic; el audio no sale del Mac."
        case nil: unavailableReason ?? ""
        }
    }

    static var appleUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return SystemLanguageModel.default.supportsLocale(Locale(identifier: "es_CO"))
                ? nil : "El modelo de Apple Intelligence no admite español en este Mac."
        case .unavailable(.deviceNotEligible):
            return "Este Mac no es compatible con Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence no está activado en Ajustes del Sistema."
        case .unavailable(.modelNotReady):
            return "El modelo de Apple Intelligence aún no está listo."
        case .unavailable:
            return "Apple Intelligence no está disponible en este momento."
        }
    }

    /// Ubicaciones habituales de la CLI (las apps no heredan el PATH de la terminal).
    static var claudeExecutable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: Resumen

    /// Caracteres por fragmento para Apple Intelligence (contexto corto, ~4.000 tokens).
    static let chunkSize = 5_000

    private static let instructions = """
        Eres un asistente que redacta actas de reuniones de trabajo en español de Colombia. \
        Usa solo la información de la transcripción; no inventes nombres, fechas ni datos. \
        "Yo" es la persona que grabó la reunión y "Participantes" son las demás personas.
        """

    private static let format = """
        Escribe el resumen en Markdown con exactamente estas secciones:
        ## Resumen
        (3 a 5 frases)
        ## Decisiones
        (viñetas)
        ## Tareas
        (viñetas con el formato: tarea — responsable — fecha; si no se mencionan, escribe "sin definir")
        ## Temas pendientes
        (viñetas)
        Si una sección no tiene elementos, escribe "Ninguno".
        """

    /// Genera resumen.md (siempre un solo resumen por reunión: se reemplaza el anterior).
    /// Sin `choice` usa Apple Intelligence si está listo y, si no, Claude.
    @discardableResult
    static func summarize(folder: URL, using choice: Choice? = nil) async throws -> URL {
        let engine: Engine
        switch choice {
        case nil:
            guard let automatic = self.engine else { throw SummaryError.unavailable(unavailableReason ?? "") }
            engine = automatic
        case .apple:
            if let reason = appleUnavailableReason { throw SummaryError.unavailable(reason) }
            engine = .apple
        case .claude:
            guard let executable = claudeExecutable else {
                throw SummaryError.unavailable(unavailableReason(for: .claude) ?? "")
            }
            engine = .claude(executable)
        }

        let markdown = try String(contentsOf: folder.appending(path: MeetingFiles.transcript), encoding: .utf8)
        let lines = transcriptLines(markdown)
        guard !lines.isEmpty else { throw SummaryError.emptyTranscript }

        let body: String
        let footer: String
        switch engine {
        case .apple:
            body = try await summarizeWithApple(lines)
            footer = "_Generado en este Mac con Apple Intelligence. Revísalo antes de compartirlo._"
        case .claude(let executable):
            body = try await summarizeWithClaude(lines, executable: executable)
            footer = "_Generado con Claude (Anthropic) a partir de la transcripción. Revísalo antes de compartirlo._"
        }

        let info = MeetingInfo.load(from: folder)
        let header = Transcription.header(title: info?.title, startDate: info?.startDate)
            .replacingOccurrences(of: "# ", with: "# Resumen: ", options: .anchored)
        let output = folder.appending(path: MeetingFiles.summary)
        let text = """
            \(header)

            \(body.trimmingCharacters(in: .whitespacesAndNewlines))

            ---
            \(footer)

            """
        // Si se canceló, no se toca el resumen anterior.
        try Task.checkCancellation()
        try text.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    // MARK: Apple Intelligence

    private static func summarizeWithApple(_ lines: [String]) async throws -> String {
        let chunks = makeChunks(lines, size: chunkSize)
        var material: String
        if chunks.count == 1 {
            material = chunks[0]
        } else {
            // Primero notas de cada parte, luego el resumen a partir de las notas.
            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: """
                    Esta es la parte \(index + 1) de \(chunks.count) de la transcripción de una reunión. \
                    Escribe viñetas breves con los temas tratados, las decisiones y las tareas \
                    (con responsable y fecha si se mencionan).

                    \(chunk)
                    """)
                notes.append(response.content)
            }
            material = notes.joined(separator: "\n")
            if material.count > chunkSize * 2 { material = String(material.prefix(chunkSize * 2)) }
        }

        try Task.checkCancellation()
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: """
            Con base en el siguiente material de una reunión, \(format)

            \(material)
            """)
        return response.content
    }

    // MARK: Claude

    /// Llama a `claude -p` sin herramientas: la transcripción va por la entrada estándar
    /// y la respuesta (Markdown) sale por la salida estándar. Corre en una carpeta temporal
    /// vacía para que no lea archivos de ningún proyecto.
    private static func summarizeWithClaude(_ lines: [String], executable: URL) async throws -> String {
        let prompt = """
            \(instructions)

            La entrada estándar contiene la transcripción de una reunión, con marcas de tiempo. \
            \(format)
            Responde solo con el Markdown de esas cuatro secciones, sin títulos adicionales ni comentarios.
            """
        let transcript = lines.joined(separator: "\n")

        let workDir = FileManager.default.temporaryDirectory.appending(path: "grabadora-resumen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = executable
        // Sin herramientas, sin conectores MCP y sin guardar la sesión en el historial de Claude.
        process.arguments = ["-p", prompt, "--output-format", "text", "--tools", "",
                             "--strict-mcp-config", "--no-session-persistence"]
        process.currentDirectoryURL = workDir
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(executable.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Al cancelar el resumen se detiene el proceso de Claude.
        let result: (status: Int32, out: Data, err: Data) = try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            // Se leen las salidas en paralelo para que el proceso no se bloquee con mucho texto.
            var outData = Data(), errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { outData = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { errData = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }

            process.terminationHandler = { finished in
                group.notify(queue: .global()) {
                    continuation.resume(returning: (finished.terminationStatus, outData, errData))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: SummaryError.claudeFailed(error.localizedDescription))
                return
            }
            DispatchQueue.global().async {
                input.fileHandleForWriting.write(Data(transcript.utf8))
                try? input.fileHandleForWriting.close()
            }
            // Límite de 5 minutos.
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                if process.isRunning { process.terminate() }
            }
          }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()

        let text = String(data: result.out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard result.status == 0, !text.isEmpty else {
            let detail = String(data: result.err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hint = detail.localizedCaseInsensitiveContains("log") || detail.localizedCaseInsensitiveContains("auth")
                ? "Abre una terminal y ejecuta «claude» para iniciar sesión." : String(detail.prefix(300))
            throw SummaryError.claudeFailed(hint.isEmpty ? "Código de salida \(result.status)." : hint)
        }
        return text
    }

    // MARK: Utilidades

    /// Frases de la transcripción sin encabezado, avisos ni marcas de Markdown.
    static func transcriptLines(_ markdown: String) -> [String] {
        markdown.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("**["), !trimmed.contains("📷") else { return nil }
            return trimmed.replacingOccurrences(of: "**", with: "")
        }
    }

    static func makeChunks(_ lines: [String], size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count + 1 > size {
                chunks.append(current)
                current = ""
            }
            // Una frase muy larga se corta para que quepa.
            current += (current.isEmpty ? "" : "\n") + String(line.prefix(size))
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
