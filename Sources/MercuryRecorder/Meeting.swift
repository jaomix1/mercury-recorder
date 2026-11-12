import Foundation

enum MeetingFiles {
    static let microphone = "microfono.m4a"
    static let system = "sistema.m4a"
    static let info = "info.json"
    static let transcript = "transcripcion.md"
    static let summary = "resumen.md"
    /// Respaldos que sobreviven a un cierre inesperado (se borran al detener).
    static let microphoneBackup = "microfono-respaldo.caf"
    static let systemBackup = "sistema-respaldo.caf"

    static var root: URL {
        URL.documentsDirectory.appending(path: "Reuniones", directoryHint: .isDirectory)
    }
}

/// Datos de una grabación. Los offsets son los segundos entre el inicio de la
/// grabación y la primera muestra de cada pista (nil si la pista quedó vacía).
struct MeetingInfo: Codable {
    var startDate: Date
    var endDate: Date
    var microphoneOffset: Double?
    var systemOffset: Double?
    /// Capturas de pantalla tomadas durante la grabación (nil en reuniones antiguas).
    var screenshots: [ScreenshotInfo]?
    /// Nombre puesto por el usuario. La carpeta no se renombra para no romper los links.
    var title: String?
    /// true mientras se graba. Si la app arranca y lo encuentra en true, la grabación
    /// se interrumpió y hay que recuperarla desde los respaldos.
    var inProgress: Bool?

    func save(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appending(path: MeetingFiles.info))
    }

    static func load(from folder: URL) -> MeetingInfo? {
        guard let data = try? Data(contentsOf: folder.appending(path: MeetingFiles.info)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingInfo.self, from: data)
    }
}

/// Una captura de pantalla: nombre del archivo dentro de la carpeta de la reunión
/// y segundos transcurridos desde el inicio de la grabación.
struct ScreenshotInfo: Codable, Equatable {
    var file: String
    var offset: Double
    /// Momento exacto de la captura (nil en capturas guardadas antes de este campo).
    var takenAt: Date?
}

struct Meeting: Identifiable, Hashable {
    let folder: URL
    let startDate: Date
    let endDate: Date?
    var customTitle: String? = nil

    var id: URL { folder }
    var transcriptURL: URL { folder.appending(path: MeetingFiles.transcript) }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }
    var summaryURL: URL { folder.appending(path: MeetingFiles.summary) }
    var hasSummary: Bool { FileManager.default.fileExists(atPath: summaryURL.path) }

    /// Nombre personalizado, o la fecha si no tiene.
    var title: String { customTitle ?? dateText }

    var dateText: String {
        startDate.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()
            .locale(Locale(identifier: "es_CO")))
    }

    var durationText: String? {
        guard let endDate else { return nil }
        let seconds = Int(endDate.timeIntervalSince(startDate))
        return seconds >= 3600
            ? String(format: "%d h %02d min", seconds / 3600, (seconds % 3600) / 60)
            : String(format: "%d min %02d s", seconds / 60, seconds % 60)
    }

    static func newFolder(for date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = MeetingFiles.root.appending(path: formatter.string(from: date), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func loadAll() -> [Meeting] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: MeetingFiles.root, includingPropertiesForKeys: [.creationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            if let info = MeetingInfo.load(from: folder) {
                return Meeting(folder: folder, startDate: info.startDate, endDate: info.endDate,
                               customTitle: info.title)
            }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Meeting(folder: folder, startDate: created, endDate: nil)
        }
        .sorted { $0.startDate > $1.startDate }
    }
}
