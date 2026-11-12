import AVFoundation
import Foundation

/// Convierte audio en bloques continuos (sin cortes entre bloques) a otro formato,
/// incluido otro sample rate. No es thread-safe.
final class StreamingResampler {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.downmix = true // estéreo o más canales → mono
            inputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Copia de respaldo de una pista en .caf PCM 16 kHz. A diferencia del .m4a, este
/// archivo se puede leer aunque la app se cierre de golpe a mitad de la grabación.
/// Se borra al detener normalmente. No es thread-safe.
final class BackupWriter {
    static let sampleRate: Double = 16_000

    let url: URL
    private var file: AVAudioFile?
    private let resampler: StreamingResampler

    init(url: URL) throws {
        self.url = url
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                   channels: 1, interleaved: false)!
        resampler = StreamingResampler(outputFormat: format)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let file, let converted = resampler.convert(buffer) else { return }
        do {
            try file.write(from: converted)
        } catch {
            NSLog("mercury-recorder: no se pudo escribir el respaldo: \(error.localizedDescription)")
        }
    }

    func close() {
        file?.close()
        file = nil
    }
}

/// Recupera reuniones que quedaron a medias porque la app se cerró durante la grabación.
enum MeetingRecovery {
    /// Carpetas de reuniones marcadas "en curso" (la app no está grabando al llamar esto).
    static func interruptedFolders() -> [URL] {
        Meeting.loadAll().compactMap { meeting in
            MeetingInfo.load(from: meeting.folder)?.inProgress == true ? meeting.folder : nil
        }
    }

    /// Convierte los respaldos .caf en .m4a y marca la reunión como terminada.
    /// Devuelve true si quedó al menos una pista con audio.
    static func recover(_ folder: URL) throws -> Bool {
        guard var info = MeetingInfo.load(from: folder) else { return false }
        let fm = FileManager.default
        var longest: Double = 0
        var recovered = false

        let tracks = [(MeetingFiles.microphoneBackup, MeetingFiles.microphone),
                      (MeetingFiles.systemBackup, MeetingFiles.system)]
        for (backupName, finalName) in tracks {
            let backup = folder.appending(path: backupName)
            guard fm.fileExists(atPath: backup.path) else { continue }
            let duration = try convertToM4A(backup, to: folder.appending(path: finalName))
            if duration > 0 {
                recovered = true
                longest = max(longest, duration)
            }
            try? fm.removeItem(at: backup)
        }

        info.inProgress = nil
        let offsets = [info.microphoneOffset ?? 0, info.systemOffset ?? 0]
        info.endDate = max(info.endDate, info.startDate.addingTimeInterval(longest + (offsets.max() ?? 0)))
        try info.save(in: folder)
        return recovered
    }

    /// Copia un .caf PCM a .m4a (AAC). Devuelve la duración en segundos.
    @discardableResult
    static func convertToM4A(_ source: URL, to destination: URL) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0 else { return 0 }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 48_000,
        ]
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".recuperando-\(destination.lastPathComponent)")
        try? FileManager.default.removeItem(at: temporary)
        do {
            let output = try AVAudioFile(forWriting: temporary, settings: settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            let chunk: AVAudioFrameCount = 16_000 * 10
            while input.framePosition < input.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                try input.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            output.close()
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        return Double(input.length) / format.sampleRate
    }
}
