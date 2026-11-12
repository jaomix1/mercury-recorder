import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case stopping
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var transcribing: Set<URL> = []
    @Published var errorMessage: String?
    @Published private(set) var screenshotCount = 0
    @Published private(set) var isCapturing = false
    @Published private(set) var lastScreenshotName: String?
    /// true si la grabación actual se está transcribiendo en vivo.
    @Published private(set) var isLive = false
    /// Aumenta cada vez que se reescribe la transcripción en vivo (refresca la vista).
    @Published private(set) var liveUpdates = 0

    /// Avisos informativos (no errores), p. ej. una reunión recuperada.
    @Published var notice: String?

    // Niveles de audio durante la grabación (0…1) y avisos de pista sin sonido.
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micSilent = false
    /// true si después de unos segundos no ha llegado ningún audio del micrófono.
    @Published private(set) var micNotReceiving = false
    @Published private(set) var systemSilent = false

    /// Reuniones a las que se les está generando el resumen.
    @Published private(set) var summarizing: Set<URL> = []

    /// Texto del buscador de la ventana Reuniones.
    @Published var searchText = ""

    /// Avisar cuando una app de reuniones empieza a usar el micrófono.
    @Published var detectMeetings: Bool {
        didSet {
            UserDefaults.standard.set(detectMeetings, forKey: "detectarReuniones")
            detectMeetings ? detector.start() : detector.stop()
        }
    }
    /// Abrir la app automáticamente al iniciar sesión en el Mac.
    @Published var launchAtLogin: Bool = false {
        didSet {
            guard launchAtLogin != oldValue, !isSyncingLoginItem else { return }
            setLaunchAtLogin(launchAtLogin)
        }
    }
    private var isSyncingLoginItem = false

    /// Decir en voz alta "Grabación iniciada" / "Grabación detenida".
    @Published var announceWithVoice: Bool {
        didSet { UserDefaults.standard.set(announceWithVoice, forKey: "anunciarConVoz") }
    }

    /// nil mientras no se sabe; false si macOS no deja mostrar notificaciones.
    @Published private(set) var notificationsAllowed: Bool?

    /// Última app de reuniones detectada (se muestra en el menú con un botón Grabar).
    @Published private(set) var detectedMeetingApp: String?

    private var recorder: Recorder?
    private var currentFolder: URL?
    private var levelTimer: Timer?
    private let detector = MeetingDetector()
    private var transcriptCache: [URL: String] = [:]

    init() {
        let defaults = UserDefaults.standard
        detectMeetings = defaults.object(forKey: "detectarReuniones") as? Bool ?? true
        announceWithVoice = defaults.object(forKey: "anunciarConVoz") as? Bool ?? true
        reload()
        setUpServices()
        AppDelegate.model = self
    }

    /// Detiene la grabación (si hay una) antes de cerrar la app.
    func finishBeforeQuit() async {
        while state == .starting || state == .stopping {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if isRecording { await stop() }
    }

    // MARK: Inicio de sesión

    private func setUpLoginItem() {
        let defaults = UserDefaults.standard
        // La primera vez se activa sola (se pidió que la app arranque con el sistema).
        if !defaults.bool(forKey: "inicioConfigurado") {
            defaults.set(true, forKey: "inicioConfigurado")
            setLaunchAtLogin(true)
        }
        syncLoginItem()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "No se pudo cambiar el inicio automático: \(error.localizedDescription)"
        }
        syncLoginItem()
        if SMAppService.mainApp.status == .requiresApproval {
            notice = "Para abrir la app al iniciar sesión, apruébala en Ajustes del Sistema › General › Ítems de inicio."
        }
    }

    /// Refleja en el interruptor el estado real del sistema.
    private func syncLoginItem() {
        isSyncingLoginItem = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isSyncingLoginItem = false
    }

    private func setUpServices() {
        setUpLoginItem()
        HotKeys.shared.registerDefaults(
            record: { [weak self] in self?.toggleRecording() },
            screenshot: { [weak self] in self?.captureScreenshot() }
        )
        Notifier.shared.setUp()
        Notifier.shared.onRecordRequested = { [weak self] in
            guard let self, self.state == .idle else { return }
            self.toggleRecording()
        }
        detector.onMeetingStarted = { [weak self] app in
            guard let self, self.state == .idle else { return }
            self.detectedMeetingApp = app
            Notifier.shared.notifyMeetingStarted(in: app)
        }
        detector.onAllMeetingsEnded = { [weak self] in
            self?.detectedMeetingApp = nil
            Notifier.shared.clear()
        }
        // El permiso se pide al abrir la app (no hasta la primera reunión), para que
        // el diálogo de macOS aparezca de una vez y el menú avise si está bloqueado.
        Notifier.shared.requestAuthorization { [weak self] granted in
            self?.notificationsAllowed = granted
        }
        if detectMeetings { detector.start() }
        recoverInterruptedMeetings()
    }

    /// Vuelve a consultar el permiso de notificaciones (p. ej. al abrir el menú).
    func refreshNotificationPermission() {
        Notifier.shared.isAuthorized { [weak self] ok in self?.notificationsAllowed = ok }
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "local.grabadora.reuniones"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Recuperación

    /// Si la app se cerró durante una grabación, rearma los audios desde los respaldos
    /// y transcribe la reunión.
    private func recoverInterruptedMeetings() {
        let folders = MeetingRecovery.interruptedFolders()
        guard !folders.isEmpty else { return }
        var recovered = 0
        for folder in folders {
            do {
                if try MeetingRecovery.recover(folder) {
                    recovered += 1
                    transcribe(folder)
                }
            } catch {
                errorMessage = "No se pudo recuperar una reunión interrumpida: \(error.localizedDescription)"
            }
        }
        if recovered > 0 {
            notice = recovered == 1
                ? "Se recuperó una reunión que se interrumpió al cerrarse la app."
                : "Se recuperaron \(recovered) reuniones que se interrumpieron al cerrarse la app."
        }
        reload()
    }

    var recordTitle: String {
        switch state {
        case .idle: "Iniciar grabación"
        case .starting: "Iniciando…"
        case .recording: "Detener grabación"
        case .stopping: isLive ? "Terminando transcripción…" : "Guardando…"
        }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func reload() {
        meetings = Meeting.loadAll()
        transcriptCache = [:]
        for meeting in meetings {
            transcriptCache[meeting.folder] = try? String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        }
    }

    // MARK: Búsqueda

    struct SearchMatch: Identifiable, Hashable {
        /// Índice del párrafo dentro de la transcripción (para saltar a él).
        let id: Int
        let timestamp: String
        let snippet: String
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Reuniones cuyo nombre o transcripción contienen el texto buscado.
    var filteredMeetings: [Meeting] {
        guard !query.isEmpty else { return meetings }
        return meetings.filter { meeting in
            Self.contains(meeting.title, query) || !matches(in: meeting).isEmpty
        }
    }

    /// Párrafos de la transcripción que contienen el texto buscado.
    func matches(in meeting: Meeting) -> [SearchMatch] {
        guard !query.isEmpty, let text = transcriptCache[meeting.folder] else { return [] }
        return Transcription.paragraphs(text).enumerated().compactMap { index, paragraph in
            guard Self.contains(paragraph, query) else { return nil }
            let plain = paragraph.replacingOccurrences(of: "**", with: "")
            let timestamp = plain.hasPrefix("[") ? String(plain.dropFirst().prefix(8)) : ""
            return SearchMatch(id: index, timestamp: timestamp, snippet: Self.snippet(plain, around: query))
        }
    }

    nonisolated static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Fragmento de unos 100 caracteres alrededor de la coincidencia.
    nonisolated static func snippet(_ text: String, around query: String) -> String {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(100))
        }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }

    func toggleRecording() {
        switch state {
        case .idle: Task { await start() }
        case .recording: Task { await stop() }
        default: break
        }
    }

    private func start() async {
        errorMessage = nil
        state = .starting
        var createdFolder: URL?
        do {
            let folder = try Meeting.newFolder()
            createdFolder = folder
            let recorder = Recorder()
            recorder.onUnexpectedStop = { [weak self] error in
                self?.errorMessage = "La grabación se detuvo: \(error.localizedDescription)"
                Task { await self?.stop() }
            }
            recorder.onLiveUpdate = { [weak self] in
                self?.liveUpdates += 1
                self?.reload()
            }
            // El modelo de español se descarga la primera vez. Si falla, se graba
            // igual y la transcripción se hace al final.
            let locale = try? await Transcription.prepareSpanish()
            // El anuncio suena antes de empezar a grabar, para que no quede en la transcripción.
            if announceWithVoice { await Announcer.shared.say("Grabación iniciada") }
            try await recorder.start(in: folder, liveLocale: locale)
            self.recorder = recorder
            self.currentFolder = folder
            screenshotCount = 0
            lastScreenshotName = nil
            isLive = recorder.isTranscribingLive
            state = .recording(since: Date())
            detectedMeetingApp = nil
            Notifier.shared.clear()
            startLevelTimer()
            reload()
            selection = folder
        } catch {
            if let createdFolder { try? FileManager.default.removeItem(at: createdFolder) }
            errorMessage = error.localizedDescription
            state = .idle
        }
    }

    private func stop() async {
        guard let recorder, let folder = currentFolder else { return }
        state = .stopping
        var complete = false
        do {
            complete = try await recorder.stop()
        } catch {
            errorMessage = "No se pudo cerrar la grabación: \(error.localizedDescription)"
        }
        self.recorder = nil
        currentFolder = nil
        isLive = false
        stopLevelTimer()
        state = .idle
        liveUpdates += 1
        reload()
        // Si la transcripción en vivo no quedó completa, se transcribe el audio guardado.
        if announceWithVoice { Task { await Announcer.shared.say("Grabación detenida") } }
        if !complete { transcribe(folder) }
    }

    // MARK: Niveles de audio

    /// Segundos sin sonido tras los cuales se avisa que una pista parece vacía.
    static let silenceWarning: TimeInterval = 20

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLevels() }
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        micLevel = 0
        systemLevel = 0
        micSilent = false
        systemSilent = false
        micNotReceiving = false
    }

    private func updateLevels() {
        guard let recorder, case .recording(let since) = state else { return }
        let levels = recorder.levels()
        micLevel = levels.mic
        systemLevel = levels.system
        let now = Date()
        func silent(_ last: Date?) -> Bool {
            now.timeIntervalSince(last ?? since) > Self.silenceWarning
        }
        micSilent = silent(levels.micLastSound)
        systemSilent = silent(levels.systemLastSound)
        micNotReceiving = !levels.micReceiving && now.timeIntervalSince(since) > 5
    }

    /// Carpeta de la reunión que se está grabando (nil si no hay grabación).
    var recordingFolder: URL? { currentFolder }

    /// Captura la pantalla. Solo funciona mientras se está grabando.
    func captureScreenshot() {
        guard isRecording, !isCapturing, let recorder else { return }
        isCapturing = true
        Task {
            do {
                let shot = try await recorder.captureScreenshot()
                screenshotCount += 1
                lastScreenshotName = shot.file
                NSSound(named: "Grab")?.play()
            } catch {
                errorMessage = "No se pudo capturar la pantalla: \(error.localizedDescription)"
            }
            isCapturing = false
        }
    }

    func transcribe(_ folder: URL) {
        guard !transcribing.contains(folder) else { return }
        transcribing.insert(folder)
        Task {
            do {
                try await Transcription.transcribeMeeting(at: folder)
            } catch {
                errorMessage = "No se pudo transcribir: \(error.localizedDescription)"
            }
            transcribing.remove(folder)
            reload()
        }
    }

    // MARK: Resumen

    /// Motor con el que se está resumiendo cada reunión (para el texto de progreso).
    @Published private(set) var summarizingEngine: [URL: String] = [:]
    private var summaryTasks: [URL: Task<Void, Never>] = [:]

    /// Cancela el resumen en curso. El resumen anterior (si había) queda intacto.
    func cancelSummary(_ folder: URL) {
        summaryTasks[folder]?.cancel()
    }

    /// Genera el resumen con el motor elegido y lo guarda aparte, en resumen.md.
    /// Hay un solo resumen por reunión: si ya existe, pide confirmación y lo reemplaza.
    func summarize(_ folder: URL, using choice: Summarizer.Choice) {
        guard !summarizing.contains(folder) else { return }
        if let reason = Summarizer.unavailableReason(for: choice) {
            errorMessage = reason
            return
        }
        let summaryURL = folder.appending(path: MeetingFiles.summary)
        if FileManager.default.fileExists(atPath: summaryURL.path) {
            let alert = NSAlert()
            alert.messageText = "¿Reemplazar el resumen?"
            alert.informativeText = "Cada reunión tiene un solo resumen. El actual se reemplazará por uno nuevo hecho con \(choice.name)."
            alert.addButton(withTitle: "Reemplazar")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        summarizing.insert(folder)
        summarizingEngine[folder] = choice.name
        summaryTasks[folder] = Task {
            do {
                try await Summarizer.summarize(folder: folder, using: choice)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    notice = "Se canceló el resumen. Se conservó el resumen anterior, si había uno."
                } else {
                    errorMessage = "No se pudo generar el resumen con \(choice.name): \(error.localizedDescription)"
                }
            }
            summarizing.remove(folder)
            summarizingEngine[folder] = nil
            summaryTasks[folder] = nil
            liveUpdates += 1
            reload()
        }
    }

    func summaryUnavailableReason(for choice: Summarizer.Choice) -> String? {
        Summarizer.unavailableReason(for: choice)
    }

    var summaryUnavailableReason: String? { Summarizer.unavailableReason }
    /// Con qué motor se resumirá y qué implica (para mostrar en la interfaz).
    var summaryEngineDescription: String { Summarizer.engineDescription }

    // MARK: Exportar

    /// Pide dónde guardar y exporta a PDF la transcripción (con capturas) o el resumen.
    func exportPDF(_ meeting: Meeting, kind: PDFExporter.Kind = .transcript) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let safeTitle = meeting.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = kind == .summary ? "Resumen - \(safeTitle).pdf" : "Transcripción - \(safeTitle).pdf"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFExporter.export(meeting, kind: kind, to: url)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = "No se pudo exportar el PDF: \(error.localizedDescription)"
        }
    }

    // MARK: Renombrar y eliminar

    /// Reunión que se está renombrando o por eliminar (controlan los diálogos).
    @Published var meetingToRename: Meeting?
    @Published var renameText = ""
    @Published var meetingToDelete: Meeting?
    /// Reunión seleccionada en la ventana Reuniones.
    @Published var selection: URL?

    func askRename(_ meeting: Meeting) {
        renameText = meeting.customTitle ?? ""
        meetingToRename = meeting
    }

    /// Guarda el nombre en info.json y actualiza el encabezado de la transcripción.
    /// Un nombre vacío vuelve a mostrar la fecha.
    func rename(_ meeting: Meeting, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var info = MeetingInfo.load(from: meeting.folder)
            ?? MeetingInfo(startDate: meeting.startDate, endDate: meeting.endDate ?? meeting.startDate)
        info.title = trimmed.isEmpty ? nil : trimmed
        do {
            try info.save(in: meeting.folder)
            try Transcription.updateHeader(at: meeting.folder, title: info.title, startDate: info.startDate)
        } catch {
            errorMessage = "No se pudo cambiar el nombre: \(error.localizedDescription)"
        }
        reload()
    }

    func canDelete(_ meeting: Meeting) -> Bool {
        meeting.folder != currentFolder && !transcribing.contains(meeting.folder) && !summarizing.contains(meeting.folder)
    }

    /// Mueve la carpeta de la reunión a la Papelera (se puede recuperar desde ahí).
    func delete(_ meeting: Meeting) {
        guard canDelete(meeting) else {
            errorMessage = "No se puede eliminar una reunión que se está grabando, transcribiendo o resumiendo."
            return
        }
        do {
            try FileManager.default.trashItem(at: meeting.folder, resultingItemURL: nil)
        } catch {
            errorMessage = "No se pudo eliminar la reunión: \(error.localizedDescription)"
        }
        reload()
    }

    func openRoot() {
        try? FileManager.default.createDirectory(at: MeetingFiles.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingFiles.root)
    }

    func reveal(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.hasTranscript ? meeting.transcriptURL : meeting.folder])
    }
}
