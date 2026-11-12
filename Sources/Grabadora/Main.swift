import AVFoundation
import Foundation
import SwiftUI

/// Al salir (botón Salir, ⌘Q o cerrar sesión) con una grabación en curso, primero
/// la detiene para que los audios queden bien cerrados.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.state != .idle else { return .terminateNow }

        // Hay una grabación: pedir confirmación antes de salir.
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Hay una grabación en curso"
        alert.informativeText = "Si sales, la grabación se detiene y se guarda con su transcripción antes de cerrar la app."
        alert.addButton(withTitle: "Guardar y salir")
        alert.addButton(withTitle: "Seguir grabando")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task { @MainActor in
            await model.finishBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct GrabadoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            // Rojo: grabando. Personas: se detectó una reunión sin grabar. Onda: en espera.
            Image(systemName: model.isRecording ? "record.circle.fill"
                  : (model.detectedMeetingApp != nil ? "person.wave.2.fill" : "waveform.circle"))
        }
        .menuBarExtraStyle(.window)

        Window("Reuniones", id: "reuniones") {
            MeetingsWindow().environmentObject(model)
        }
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // Modo de línea de comandos para probar la transcripción sin la interfaz:
        //   Grabadora --transcribir <archivo de audio>
        //   Grabadora --transcribir-reunion <carpeta>
        // Grabadora --autoprueba: verifica la lógica pura (eco, búsqueda, fragmentos).
        if args.count == 2, args[1] == "--autoprueba" {
            exit(SelfTest.run() ? 0 : 1)
        }
        // Grabadora --recuperar <carpeta>: rearma una reunión interrumpida desde sus respaldos.
        if args.count == 3, args[1] == "--recuperar" {
            do {
                let ok = try MeetingRecovery.recover(URL(fileURLWithPath: args[2], isDirectory: true))
                print(ok ? "Recuperada" : "Sin audio para recuperar")
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(1)
            }
        }
        // Grabadora --pdf <carpeta> <salida.pdf>: exporta el acta.
        if args.count == 4, args[1] == "--pdf" {
            let folder = URL(fileURLWithPath: args[2], isDirectory: true)
            let meeting = Meeting.loadAll().first { $0.folder.standardizedFileURL == folder.standardizedFileURL }
                ?? Meeting(folder: folder, startDate: MeetingInfo.load(from: folder)?.startDate ?? Date(),
                           endDate: MeetingInfo.load(from: folder)?.endDate,
                           customTitle: MeetingInfo.load(from: folder)?.title)
            do {
                try MainActor.assumeIsolated { try PDFExporter.export(meeting, to: URL(fileURLWithPath: args[3])) }
                print("PDF creado")
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(1)
            }
        }
        // Grabadora --probar-microfono <carpeta>: graba 4 s del micrófono con el mismo
        // camino que la app y muestra formato, bloques recibidos y si se escribió audio.
        if args.count == 3, args[1] == "--probar-microfono" {
            let folder = URL(fileURLWithPath: args[2], isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let queue = DispatchQueue(label: "prueba-microfono")
            let writer = AudioTrackWriter(url: folder.appending(path: "microfono.m4a"), backupURL: nil)
            var blocks = 0
            var format = ""
            let mic = MicrophoneCapture()
            do {
                try mic.start(queue: queue) { buffer, pts in
                    blocks += 1
                    if format.isEmpty { format = "\(buffer.format)" }
                    do { try writer.append(buffer, at: pts) } catch { print("error al escribir: \(error)") }
                }
            } catch {
                print("No arrancó el micrófono: \(error.localizedDescription)")
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                mic.stop()
                queue.sync {
                    print("formato: \(format)")
                    print("bloques recibidos: \(blocks)")
                    print("audio escrito: \(writer.hasAudio ? "sí" : "NO")  nivel: \(writer.level)")
                    writer.close()
                }
                exit(0)
            }
            dispatchMain()
        }
        // Grabadora --probar-cancelar <carpeta>: empieza un resumen con Claude y lo cancela a los 2 s.
        if args.count == 3, args[1] == "--probar-cancelar" {
            let folder = URL(fileURLWithPath: args[2], isDirectory: true)
            let task = Task {
                do {
                    try await Summarizer.summarize(folder: folder, using: .claude)
                    print("Terminó sin cancelarse")
                } catch {
                    print("Cancelado: \(Task.isCancelled || error is CancellationError ? "sí" : "no (\(error.localizedDescription))")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { task.cancel() }
            Task {
                _ = await task.value
                exit(0)
            }
            dispatchMain()
        }
        // Grabadora --probar-cierre: cierra un transcriptor en vivo que no recibió audio
        // (antes se quedaba esperando para siempre).
        if args.count == 2, args[1] == "--probar-cierre" {
            Task {
                do {
                    let locale = try await Transcription.prepareSpanish()
                    let live = try await LiveTranscriber(speaker: "Prueba", locale: locale)
                    let start = Date()
                    let segments = await live.finish()
                    print(String(format: "Cierre sin audio: %.1f s, %d frases", Date().timeIntervalSince(start), segments.count))
                    exit(0)
                } catch {
                    print("Error: \(error.localizedDescription)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        // Grabadora --microfono: apps de reuniones que están usando el micrófono ahora.
        if args.count == 2, args[1] == "--microfono" {
            let apps = MeetingDetector.appsUsingMicrophone()
            print(apps.isEmpty ? "Ninguna app de reuniones está usando el micrófono." : apps.joined(separator: ", "))
            exit(0)
        }
        // Grabadora --resumir <carpeta>: genera resumen.md con Apple Intelligence.
        if args.count == 3, args[1] == "--resumir" {
            Task {
                do {
                    let output = try await Summarizer.summarize(folder: URL(fileURLWithPath: args[2], isDirectory: true))
                    print(try String(contentsOf: output, encoding: .utf8))
                    exit(0)
                } catch {
                    print("Error: \(error.localizedDescription)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        // Grabadora --links <carpeta>: muestra a dónde apunta cada link de la transcripción.
        if args.count == 3, args[1] == "--links" {
            let folder = URL(fileURLWithPath: args[2], isDirectory: true)
            let markdown = (try? String(contentsOf: folder.appending(path: MeetingFiles.transcript), encoding: .utf8)) ?? ""
            let text = MeetingDetail.renderMarkdown(markdown, folder: folder)
            for run in text.runs {
                guard let link = run.link else { continue }
                let exists = link.isFileURL && FileManager.default.fileExists(atPath: link.path)
                print("\(String(text[run.range].characters)) -> \(link.absoluteString) [\(exists ? "existe" : "NO EXISTE")]")
            }
            exit(0)
        }
        // Grabadora --probar-vivo <archivo>: alimenta el transcriptor en vivo en bloques de
        // 100 ms (como la grabación) y muestra lo confirmado cada 20 s de audio.
        if args.count == 3, args[1] == "--probar-vivo" {
            Task {
                do {
                    let locale = try await Transcription.prepareSpanish()
                    let live = try await LiveTranscriber(speaker: "Audio", locale: locale)
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
                    let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
                    var seconds = 0.0
                    var nextReport = 20.0
                    while file.framePosition < file.length {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)
                        else { break }
                        try file.read(into: buffer, frameCount: chunk)
                        live.append(buffer)
                        seconds += Double(buffer.frameLength) / file.processingFormat.sampleRate
                        try await Task.sleep(for: .milliseconds(10)) // 10x tiempo real
                        if seconds >= nextReport {
                            print("— a los \(Int(seconds)) s de audio: \(live.segments.count) frases confirmadas")
                            nextReport += 20
                        }
                    }
                    let segments = await live.finish()
                    print(Transcription.render(Transcription.merge(segments), startDate: nil))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        if args.count == 3, args[1] == "--transcribir" || args[1] == "--transcribir-reunion" {
            let url = URL(fileURLWithPath: args[2])
            Task {
                do {
                    if args[1] == "--transcribir" {
                        let locale = try await Transcription.prepareSpanish()
                        print("Idioma: \(locale.identifier)")
                        let segments = try await Transcription.transcribe(file: url, speaker: "Audio", locale: locale)
                        print(Transcription.render(Transcription.merge(segments), startDate: nil))
                    } else {
                        let output = try await Transcription.transcribeMeeting(at: url)
                        print(try String(contentsOf: output, encoding: .utf8))
                    }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        GrabadoraApp.main()
    }
}
