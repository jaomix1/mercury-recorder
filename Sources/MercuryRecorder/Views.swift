import AppKit
import SwiftUI

// MARK: - Menú de la barra

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let app = model.detectedMeetingApp, model.state == .idle {
                DetectedMeetingBanner(app: app)
            }

            recordButton

            if model.isRecording {
                AudioLevels(compact: false)
            }

            Button {
                model.captureScreenshot()
            } label: {
                Label(model.isCapturing ? "Capturando…" : "Capturar pantalla  \(HotKeys.screenshotLabel)",
                      systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!model.isRecording || model.isCapturing)
            .help(model.isRecording ? "Guarda una captura y la marca en la transcripción"
                                    : "Disponible solo mientras se graba")

            if model.isRecording, model.screenshotCount > 0 {
                Text("\(model.screenshotCount) \(model.screenshotCount == 1 ? "captura" : "capturas") en esta reunión")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let notice = model.notice {
                HStack(alignment: .top) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.transcribing.isEmpty || !model.summarizing.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.transcribing.isEmpty ? "Generando resumen…" : "Transcribiendo…")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.transcribing.isEmpty {
                        Button("Cancelar") {
                            for folder in model.summarizing { model.cancelSummary(folder) }
                        }
                        .controlSize(.small)
                        .help("Cancela el resumen en curso; se conserva el anterior")
                    }
                }
            }

            Divider()

            Text("Recientes").font(.caption).foregroundStyle(.secondary)
            if model.meetings.isEmpty {
                Text("Aún no hay reuniones grabadas.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.meetings.prefix(5)) { meeting in
                Button {
                    showMeetings(meeting)
                } label: {
                    HStack {
                        Image(systemName: meeting.hasTranscript ? "doc.text" : "waveform")
                        Text(meeting.title)
                        Spacer()
                        if let duration = meeting.durationText {
                            Text(duration).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    // Los diálogos viven en la ventana Reuniones: se abre con la reunión elegida.
                    Button("Cambiar nombre…") {
                        showMeetings(meeting)
                        model.askRename(meeting)
                    }
                    Button("Mover a la Papelera…", role: .destructive) {
                        showMeetings(meeting)
                        model.meetingToDelete = meeting
                    }
                    .disabled(!model.canDelete(meeting))
                }
            }
            if !model.meetings.isEmpty {
                Text("Clic derecho en una reunión para cambiarle el nombre o eliminarla.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            Toggle("Avisar cuando empiece una reunión", isOn: $model.detectMeetings)
                .font(.callout)
                .help("Muestra una notificación cuando Zoom, Teams, Meet, Discord u otra app empieza a usar el micrófono")
            if model.detectMeetings, model.notificationsAllowed == false {
                VStack(alignment: .leading, spacing: 4) {
                    Label("macOS no está dejando que mercury-recorder muestre notificaciones. Igual verás el aviso aquí y el ícono cambiará.",
                          systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Activar notificaciones…") { model.openNotificationSettings() }
                        .controlSize(.small)
                }
            }
            Toggle("Anunciar con voz al iniciar y detener", isOn: $model.announceWithVoice)
                .font(.callout)
                .help("Dice «Grabación iniciada» y «Grabación detenida»")
            Toggle("Abrir al iniciar sesión", isOn: $model.launchAtLogin)
                .font(.callout)
                .help("La app arranca sola en la barra de menú cuando enciendes el Mac")

            HStack {
                Button("Ver reuniones") { showMeetings() }
                Button("Abrir carpeta") { model.openRoot() }
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            model.reload()
            model.refreshNotificationPermission()
        }
    }

    @ViewBuilder private var recordButton: some View {
        Button {
            model.toggleRecording()
        } label: {
            HStack {
                Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.recordTitle).font(.headline)
                    if case .recording(let since) = model.state {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text(Transcription.timestamp(context.date.timeIntervalSince(since)))
                                .monospacedDigit()
                                .font(.callout)
                        }
                        Text(model.isLive ? "Transcribiendo en vivo · se guarda cada 30 s"
                                          : "Se transcribirá al detener")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(HotKeys.recordLabel).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(model.isRecording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(model.isRecording ? Color.red : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(model.state == .starting || model.state == .stopping)
    }

    private func showMeetings(_ meeting: Meeting? = nil) {
        if let meeting { model.selection = meeting.id }
        openWindow(id: "reuniones")
        NSApp.activate()
    }
}

/// "Zoom está usando el micrófono — ¿Grabar?"
struct DetectedMeetingBanner: View {
    @EnvironmentObject var model: AppModel
    let app: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "person.wave.2").foregroundStyle(Color.accentColor)
            Text("\(app) está usando el micrófono. ¿Grabar la reunión?")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Grabar") { model.toggleRecording() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Nivel de audio

/// Barras de nivel del micrófono y del sistema, con aviso si una pista lleva rato sin sonido.
struct AudioLevels: View {
    @EnvironmentObject var model: AppModel
    /// Versión pequeña para la barra de herramientas de la ventana.
    let compact: Bool

    var body: some View {
        if compact {
            HStack(spacing: 10) {
                LevelBar(icon: "mic.fill", level: model.micLevel, warning: model.micSilent, segments: 8)
                LevelBar(icon: "speaker.wave.2.fill", level: model.systemLevel, warning: model.systemSilent, segments: 8)
            }
            .help(helpText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                row("Micrófono", icon: "mic.fill", level: model.micLevel, warning: model.micSilent || model.micNotReceiving,
                    warningText: model.micNotReceiving
                        ? "No está llegando audio del micrófono. Revisa Ajustes del Sistema › Privacidad y seguridad › Micrófono (mercury-recorder activada) y Sonido › Entrada."
                        : "No se oye el micrófono. Revisa que esté conectado y que no esté silenciado.")
                row("Sistema", icon: "speaker.wave.2.fill", level: model.systemLevel, warning: model.systemSilent,
                    warningText: "No suena nada en el Mac. Normal si nadie más ha hablado aún.")
            }
        }
    }

    private var helpText: String {
        var parts = ["Micrófono y audio del sistema"]
        if model.micSilent { parts.append("sin sonido del micrófono") }
        if model.systemSilent { parts.append("sin sonido del sistema") }
        return parts.joined(separator: " · ")
    }

    private func row(_ title: String, icon: String, level: Float, warning: Bool, warningText: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.caption).frame(width: 64, alignment: .leading)
                LevelBar(icon: icon, level: level, warning: warning, segments: 16)
            }
            if warning {
                Label(warningText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LevelBar: View {
    let icon: String
    let level: Float
    let warning: Bool
    let segments: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(warning ? Color.orange : Color.secondary)
                .frame(width: 14)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { index in
                    let threshold = Float(index + 1) / Float(segments)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(level >= threshold ? color(for: threshold) : Color.secondary.opacity(0.2))
                        .frame(width: 5, height: 10)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(warning ? "Sin sonido" : "Nivel \(Int(level * 100)) por ciento")
    }

    private func color(for threshold: Float) -> Color {
        threshold > 0.9 ? .red : threshold > 0.75 ? .yellow : .green
    }
}

// MARK: - Ventana Reuniones

struct MeetingsWindow: View {
    @EnvironmentObject var model: AppModel
    private var selection: Meeting.ID? { model.selection }
    private var isSearching: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationSplitView {
            List(model.filteredMeetings, selection: $model.selection) { meeting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                    HStack(spacing: 6) {
                        if meeting.customTitle != nil { Text(meeting.dateText) }
                        if let duration = meeting.durationText { Text(meeting.customTitle != nil ? "· \(duration)" : duration) }
                        if meeting.folder == model.recordingFolder {
                            Text("· grabando").foregroundStyle(.red)
                        } else if model.transcribing.contains(meeting.folder) {
                            Text("· transcribiendo…")
                        } else if !meeting.hasTranscript {
                            Text("· sin transcripción")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if isSearching {
                        let count = model.matches(in: meeting).count
                        Text(count == 1 ? "1 coincidencia" : "\(count) coincidencias")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu { MeetingActions(meeting: meeting) }
            }
            .searchable(text: $model.searchText, placement: .sidebar, prompt: "Buscar en las reuniones")
            .overlay {
                if isSearching, model.filteredMeetings.isEmpty {
                    Text("Sin resultados para «\(model.searchText)»")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
            .onDeleteCommand {
                if let meeting = model.meetings.first(where: { $0.id == selection }) {
                    model.meetingToDelete = meeting
                }
            }
        } detail: {
            if let meeting = model.meetings.first(where: { $0.id == selection }) {
                MeetingDetail(meeting: meeting)
            } else {
                Text("Elige una reunión").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if case .recording(let since) = model.state {
                    AudioLevels(compact: true)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Label(Transcription.timestamp(context.date.timeIntervalSince(since)),
                              systemImage: "record.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }
                    .help(model.isLive ? "Transcribiendo en vivo · se guarda cada 30 s" : "Se transcribirá al detener")
                }
                Button {
                    model.captureScreenshot()
                } label: {
                    Label(model.isCapturing ? "Capturando…" : "Capturar pantalla", systemImage: "camera.viewfinder")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!model.isRecording || model.isCapturing)
                .help(model.isRecording ? "Guarda una captura y la marca en la transcripción (\(HotKeys.screenshotLabel))"
                                        : "Disponible solo mientras se graba")
                Button {
                    model.toggleRecording()
                } label: {
                    Label(model.recordTitle, systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .accentColor)
                .disabled(model.state == .starting || model.state == .stopping)
                .help("Atajo: \(HotKeys.recordLabel)")
            }
        }
        .alert("mercury-recorder", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Cambiar nombre", isPresented: Binding(
            get: { model.meetingToRename != nil },
            set: { if !$0 { model.meetingToRename = nil } }
        )) {
            TextField("Nombre de la reunión", text: $model.renameText)
            Button("Guardar") {
                if let meeting = model.meetingToRename { model.rename(meeting, to: model.renameText) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Déjalo vacío para mostrar la fecha de la reunión.")
        }
        .alert("¿Eliminar esta reunión?", isPresented: Binding(
            get: { model.meetingToDelete != nil },
            set: { if !$0 { model.meetingToDelete = nil } }
        )) {
            Button("Mover a la Papelera", role: .destructive) {
                if let meeting = model.meetingToDelete { model.delete(meeting) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("El audio, las capturas, la transcripción y el resumen de «\(model.meetingToDelete?.title ?? "")» se moverán a la Papelera. Puedes recuperarlos desde ahí.")
        }
        .onAppear {
            model.reload()
            if model.selection == nil { model.selection = model.meetings.first?.id }
        }
    }
}

/// Acciones de una reunión (menú contextual de la lista).
struct MeetingActions: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting

    var body: some View {
        Button("Cambiar nombre…") { model.askRename(meeting) }
        Button("Exportar transcripción en PDF…") { model.exportPDF(meeting, kind: .transcript) }
            .disabled(!meeting.hasTranscript)
        Button("Exportar resumen en PDF…") { model.exportPDF(meeting, kind: .summary) }
            .disabled(!meeting.hasSummary)
        Button("Mostrar en Finder") { model.reveal(meeting) }
        Divider()
        Button("Mover a la Papelera…", role: .destructive) { model.meetingToDelete = meeting }
            .disabled(!model.canDelete(meeting))
    }
}

// MARK: - Detalle de una reunión

struct MeetingDetail: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting

    private let transcriptState = State<String>(initialValue: "")
    private var transcript: String {
        get { transcriptState.wrappedValue }
        nonmutating set { transcriptState.wrappedValue = newValue }
    }
    private let summaryState = State<String>(initialValue: "")
    private var summary: String {
        get { summaryState.wrappedValue }
        nonmutating set { summaryState.wrappedValue = newValue }
    }
    /// Pestaña visible: transcripción o resumen (documentos separados).
    private let tabState = State<DetailTab>(initialValue: .transcript)
    private var tab: DetailTab {
        get { tabState.wrappedValue }
        nonmutating set { tabState.wrappedValue = newValue }
    }

    private var isRecordingThis: Bool { meeting.folder == model.recordingFolder }
    private var isSummarizing: Bool { model.summarizing.contains(meeting.folder) }
    private var paragraphs: [String] { Transcription.paragraphs(transcript) }
    private var query: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
            Picker("Documento", selection: tabState.projectedValue) {
                Text("Transcripción").tag(DetailTab.transcript)
                Text(meeting.hasSummary || isSummarizing ? "Resumen" : "Resumen (sin generar)").tag(DetailTab.summary)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 10)
            Divider()
            if tab == .summary {
                summaryContent
            } else {
                ScrollViewReader { proxy in
                    if model.transcribing.contains(meeting.folder) {
                        ProgressView("Transcribiendo en tu Mac…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            let matches = model.matches(in: meeting)
                            if !query.isEmpty, !matches.isEmpty {
                                MatchesPanel(matches: matches) { id in
                                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                                }
                                Divider()
                            }
                            content
                        }
                    }
                }
            }
        }
        .task(id: "\(meeting.id)-\(model.transcribing.contains(meeting.folder))-\(isSummarizing)-\(model.liveUpdates)") {
            load()
        }
    }

    // MARK: Encabezado

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.title3.bold())
                if meeting.customTitle != nil {
                    Text(meeting.dateText).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    model.askRename(meeting)
                } label: {
                    Label("Cambiar nombre", systemImage: "pencil")
                }
                if !meeting.hasTranscript, !isRecordingThis {
                    Button {
                        model.transcribe(meeting.folder)
                    } label: {
                        Label("Transcribir", systemImage: "text.bubble")
                    }
                    .disabled(model.transcribing.contains(meeting.folder))
                }
                summaryButton(.apple, title: "Resumir con Apple", icon: "apple.logo",
                              help: "Se resume en este Mac; nada sale del equipo.")
                summaryButton(.claude, title: "Resumir con Claude", icon: "sparkles",
                              help: "La transcripción (texto) se envía a Anthropic; el audio no sale del Mac.")
                Button {
                    model.exportPDF(meeting, kind: tab == .summary ? .summary : .transcript)
                } label: {
                    Label(tab == .summary ? "Exportar resumen PDF" : "Exportar PDF", systemImage: "doc.richtext")
                }
                .disabled(isRecordingThis || (tab == .summary ? !meeting.hasSummary : !meeting.hasTranscript))
                .help(tab == .summary ? "Guarda el resumen en un PDF"
                                      : "Guarda la transcripción con las capturas en un PDF")
                Menu {
                    Button("Copiar transcripción") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    }
                    .disabled(transcript.isEmpty)
                    Button("Copiar resumen") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }
                    .disabled(summary.isEmpty)
                    Button("Mostrar en Finder") { model.reveal(meeting) }
                    Button("Transcribir de nuevo") { model.transcribe(meeting.folder) }
                        .disabled(!meeting.hasTranscript || model.transcribing.contains(meeting.folder) || isRecordingThis)
                } label: {
                    Label("Más", systemImage: "ellipsis.circle")
                }
                .fixedSize()
                Spacer()
                Button(role: .destructive) {
                    model.meetingToDelete = meeting
                } label: {
                    Label("Eliminar", systemImage: "trash")
                }
                .disabled(!model.canDelete(meeting))
            }
        }
    }

    /// Botón de resumen con un motor. Ambos escriben el mismo resumen.md (uno solo por reunión).
    private func summaryButton(_ choice: Summarizer.Choice, title: String, icon: String, help: String) -> some View {
        let reason = model.summaryUnavailableReason(for: choice)
        return Button {
            tab = .summary
            model.summarize(meeting.folder, using: choice)
        } label: {
            Label(title, systemImage: icon)
        }
        .disabled(reason != nil || !meeting.hasTranscript || isRecordingThis || isSummarizing
                  || model.transcribing.contains(meeting.folder))
        .help(reason ?? (help + (meeting.hasSummary ? " Reemplaza el resumen actual." : " Se guarda en resumen.md.")))
    }

    // MARK: Contenido

    @ViewBuilder private var content: some View {
        if transcript.isEmpty {
            Text(isRecordingThis
                 ? "La transcripción aparecerá aquí cada 30 segundos mientras grabas."
                 : "Esta reunión aún no tiene transcripción.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        let isMatch = !query.isEmpty && AppModel.contains(paragraph, query)
                        Text(Self.renderParagraph(paragraph, folder: meeting.folder, highlight: query))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isMatch ? Color.yellow.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .id(index)
                    }
                }
                .padding()
            }
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
        }
    }

    /// Resumen: documento aparte (resumen.md), solo se genera con el botón Resumir.
    @ViewBuilder private var summaryContent: some View {
        if isSummarizing {
            VStack(spacing: 12) {
                ProgressView("Generando el resumen con \(model.summarizingEngine[meeting.folder] ?? "IA")…")
                Button(role: .cancel) {
                    model.cancelSummary(meeting.folder)
                } label: {
                    Label("Cancelar resumen", systemImage: "xmark.circle")
                }
                Text("Si cancelas, se conserva el resumen anterior (si había uno).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if summary.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
                Text("Esta reunión aún no tiene resumen.").foregroundStyle(.secondary)
                Text("Pulsa «Resumir con Apple» o «Resumir con Claude». Se guarda aparte, en resumen.md.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                if let reason = model.summaryUnavailableReason(for: .apple) {
                    Text("Apple: \(reason)").font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                if let reason = model.summaryUnavailableReason(for: .claude) {
                    Text("Claude: \(reason)").font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                SummaryView(markdown: summary)
                    .padding()
            }
        }
    }

    // MARK: Render

    /// Convierte una línea de Markdown y cambia los links relativos (capturas) por URLs
    /// absolutas de archivo, para que al hacer clic se abra el PNG en Vista Previa.
    /// Si hay búsqueda, resalta el texto buscado.
    static func renderParagraph(_ markdown: String, folder: URL, highlight: String = "") -> AttributedString {
        var text = renderMarkdown(markdown, folder: folder)
        guard !highlight.isEmpty else { return text }
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text[searchStart...].range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = .yellow.opacity(0.6)
            searchStart = range.upperBound
        }
        return text
    }

    static func renderMarkdown(_ markdown: String, folder: URL) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var text = try? AttributedString(markdown: markdown, options: options) else {
            return AttributedString(markdown)
        }
        for run in text.runs {
            guard let link = run.link, link.scheme == nil else { continue }
            let name = link.relativeString.removingPercentEncoding ?? link.relativeString
            text[run.range].link = folder.appending(path: name)
            text[run.range].underlineStyle = .single
        }
        return text
    }

    private func load() {
        transcript = (try? String(contentsOf: meeting.transcriptURL, encoding: .utf8)) ?? ""
        summary = (try? String(contentsOf: meeting.summaryURL, encoding: .utf8)) ?? ""
    }
}

enum DetailTab: Hashable {
    case transcript
    case summary
}

/// Lista de coincidencias de la búsqueda; al hacer clic salta a ese momento.
struct MatchesPanel: View {
    let matches: [AppModel.SearchMatch]
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(matches.count == 1 ? "1 coincidencia" : "\(matches.count) coincidencias")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { match in
                        Button {
                            onSelect(match.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(match.timestamp.isEmpty ? "—" : match.timestamp)
                                    .monospacedDigit()
                                    .foregroundStyle(Color.accentColor)
                                Text(match.snippet).lineLimit(1)
                                Spacer()
                            }
                            .font(.callout)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.06))
    }
}

/// Muestra resumen.md: "## Título" en negrita y viñetas.
struct SummaryView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(line.dropFirst(3)).font(.subheadline.bold()).padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    Text("•  " + inline(String(line.dropFirst(2))))
                        .padding(.leading, 8)
                } else if line.hasPrefix("_"), line.hasSuffix("_") {
                    Text(line.dropFirst().dropLast()).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                } else {
                    Text(inline(line))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [String] {
        markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("# ") && $0 != "---" }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
