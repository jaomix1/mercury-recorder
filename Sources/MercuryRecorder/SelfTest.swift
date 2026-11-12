import Foundation

/// Pruebas de la lógica pura, ejecutables con `mercury-recorder --autoprueba`
/// (las Command Line Tools no traen XCTest).
enum SelfTest {
    private static var failures = 0

    private static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "✓" : "✗") \(name)")
        if !condition { failures += 1 }
    }

    static func run() -> Bool {
        failures = 0
        let me = Transcription.speakerMe
        let others = Transcription.speakerOthers

        // Eco: la frase del micrófono que repite lo que sonó por el sistema se descarta.
        let echo = Transcription.removeEcho([
            TranscriptSegment(speaker: others, start: 10, end: 14, text: "El módulo de agenda ya está listo."),
            TranscriptSegment(speaker: me, start: 10.4, end: 14.2, text: "el modulo de agenda ya esta listo"),
            TranscriptSegment(speaker: me, start: 20, end: 23, text: "Perfecto, entonces lo probamos el lunes."),
        ])
        check(echo.count == 2, "eco: descarta la frase repetida del micrófono")
        check(echo.contains { $0.speaker == me && $0.text.hasPrefix("Perfecto") }, "eco: conserva la frase propia")

        // Eco: misma frase pero en otro momento (fuera de la ventana) no se descarta.
        let later = Transcription.removeEcho([
            TranscriptSegment(speaker: others, start: 10, end: 14, text: "El módulo de agenda ya está listo."),
            TranscriptSegment(speaker: me, start: 60, end: 64, text: "El módulo de agenda ya está listo."),
        ])
        check(later.count == 2, "eco: no descarta frases iguales en otro momento")

        // Eco: sin pista del sistema no se toca nada.
        let alone = [TranscriptSegment(speaker: me, start: 0, end: 2, text: "Hola a todos")]
        check(Transcription.removeEcho(alone) == alone, "eco: sin sistema no cambia nada")

        // Palabras normalizadas (sin tildes ni mayúsculas).
        check(Transcription.normalizedWords("¡Reunión, MÉDICOS!") == ["reunion", "medicos"], "palabras normalizadas")

        // Párrafos: sin encabezado, vacíos ni separador.
        let markdown = "# Reunión — hoy\n\n**[00:00:01] Yo:** Hola\n\n---\n_aviso_\n"
        check(Transcription.paragraphs(markdown) == ["**[00:00:01] Yo:** Hola", "_aviso_"], "párrafos de la transcripción")

        // Búsqueda: ignora tildes y mayúsculas; fragmento con puntos suspensivos.
        check(AppModel.contains("La Reunión de médicos", "reunion"), "búsqueda sin tildes")
        let snippet = AppModel.snippet(String(repeating: "a ", count: 60) + "presupuesto aprobado", around: "presupuesto")
        check(snippet.hasPrefix("…") && snippet.contains("presupuesto"), "fragmento alrededor de la coincidencia")

        // Fragmentos para el resumen: ninguno supera el tamaño.
        let lines = (1...40).map { "[00:00:\($0)] Yo: " + String(repeating: "palabra ", count: 30) }
        let chunks = Summarizer.makeChunks(lines, size: 1_000)
        check(chunks.count > 1 && chunks.allSatisfy { $0.count <= 1_000 }, "fragmentos del resumen dentro del límite")
        check(Summarizer.transcriptLines("# T\n**[00:00:01] Yo:** Hola\n**[00:00:02] 📷 Captura de pantalla:** [x](x.png)")
              == ["[00:00:01] Yo: Hola"], "líneas para el resumen sin capturas ni Markdown")

        print(failures == 0 ? "Todas las pruebas pasaron." : "\(failures) pruebas fallaron.")
        return failures == 0
    }
}
