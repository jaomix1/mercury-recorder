import AppKit
import Foundation

/// Exporta una reunión a PDF, tamaño carta. Son dos documentos separados:
/// la transcripción (con las capturas dentro) y el resumen.
@MainActor
enum PDFExporter {
    enum Kind {
        case transcript
        case summary
    }

    static let pageSize = NSSize(width: 612, height: 792) // carta, en puntos
    static let margin: CGFloat = 54

    static func export(_ meeting: Meeting, kind: Kind = .transcript, to url: URL) throws {
        let text = buildDocument(meeting, kind: kind)
        let width = pageSize.width - margin * 2

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.textStorage?.setAttributedString(text)
        textView.sizeToFit()
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
            let used = textView.layoutManager?.usedRect(for: container).height ?? 100
            textView.frame.size.height = max(used, 100)
        }

        let printInfo = NSPrintInfo()
        printInfo.paperSize = pageSize
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.isHorizontallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else {
            throw NSError(domain: "mercury-recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No se pudo crear el PDF."])
        }
    }

    // MARK: Documento

    private static func buildDocument(_ meeting: Meeting, kind: Kind) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        let info = MeetingInfo.load(from: meeting.folder)

        let title = kind == .summary ? "Resumen: \(meeting.title)" : meeting.title
        doc.append(paragraph(title, font: .boldSystemFont(ofSize: 20), spacingAfter: 4))
        var details = [meeting.startDate.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()
            .locale(Locale(identifier: "es_CO")))]
        if let duration = meeting.durationText { details.append("Duración: \(duration)") }
        if let shots = info?.screenshots, !shots.isEmpty { details.append("\(shots.count) capturas") }
        doc.append(paragraph(details.joined(separator: " · "), font: .systemFont(ofSize: 10),
                             color: .secondaryLabelColor, spacingAfter: 16))

        if kind == .summary {
            let summary = (try? String(contentsOf: meeting.summaryURL, encoding: .utf8)) ?? ""
            appendMarkdownBlock(summary, to: doc, skipTitle: true)
            if summary.isEmpty {
                doc.append(paragraph("Esta reunión no tiene resumen.", font: .systemFont(ofSize: 11)))
            }
            return doc
        }

        doc.append(paragraph("Transcripción", font: .boldSystemFont(ofSize: 14), spacingAfter: 8))
        let transcript = (try? String(contentsOf: meeting.transcriptURL, encoding: .utf8)) ?? ""
        appendTranscript(transcript, folder: meeting.folder, to: doc)
        if transcript.isEmpty {
            doc.append(paragraph("Esta reunión no tiene transcripción.", font: .systemFont(ofSize: 11)))
        }
        return doc
    }

    private static func appendTranscript(_ markdown: String, folder: URL, to doc: NSMutableAttributedString) {
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("# "), trimmed != "---" else { continue }

            if trimmed.contains("📷"), let file = linkTarget(in: trimmed) {
                doc.append(styledLine(removeLink(trimmed), size: 11))
                let name = file.removingPercentEncoding ?? file
                if let image = compressedImage(at: folder.appending(path: name)) {
                    doc.append(imageParagraph(image))
                }
                continue
            }
            doc.append(styledLine(trimmed, size: 11))
        }
    }

    /// Resumen: "## Título" → subtítulo, "- " → viñeta, "**x**" → negrita.
    private static func appendMarkdownBlock(_ markdown: String, to doc: NSMutableAttributedString, skipTitle: Bool) {
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" { continue }
            if trimmed.hasPrefix("# ") { if !skipTitle { doc.append(paragraph(String(trimmed.dropFirst(2)), font: .boldSystemFont(ofSize: 16))) }; continue }
            if trimmed.hasPrefix("## ") {
                doc.append(paragraph(String(trimmed.dropFirst(3)), font: .boldSystemFont(ofSize: 14), spacingAfter: 4))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                doc.append(styledLine("•  " + trimmed.dropFirst(2), size: 11, indent: 12))
            } else if trimmed.hasPrefix("_"), trimmed.hasSuffix("_") {
                doc.append(paragraph(String(trimmed.dropFirst().dropLast()), font: .systemFont(ofSize: 9),
                                     color: .secondaryLabelColor))
            } else {
                doc.append(styledLine(trimmed, size: 11))
            }
        }
    }

    // MARK: Piezas

    private static func paragraphStyle(spacingAfter: CGFloat, indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = 2
        style.headIndent = indent
        return style
    }

    private static func paragraph(_ text: String, font: NSFont, color: NSColor = .black,
                                  spacingAfter: CGFloat = 6) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [
            .font: font,
            .foregroundColor: color == .secondaryLabelColor ? NSColor.darkGray : color,
            .paragraphStyle: paragraphStyle(spacingAfter: spacingAfter),
        ])
    }

    /// Una línea con partes en negrita marcadas con **…**.
    private static func styledLine(_ text: String, size: CGFloat, indent: CGFloat = 0) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let parts = text.components(separatedBy: "**")
        for (index, part) in parts.enumerated() where !part.isEmpty {
            result.append(NSAttributedString(string: part, attributes: [
                .font: index % 2 == 1 ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.black,
            ]))
        }
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(.paragraphStyle, value: paragraphStyle(spacingAfter: 6, indent: indent),
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Reduce la captura a 1.600 px de ancho y la comprime en JPEG, para que el PDF
    /// pese poco (una captura de pantalla completa en PNG puede pesar varios MB).
    private static func compressedImage(at url: URL, maxPixelWidth: CGFloat = 1_600) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelWidth,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]),
              let image = NSImage(data: jpeg)
        else { return nil }
        image.size = NSSize(width: CGFloat(thumbnail.width) / 2, height: CGFloat(thumbnail.height) / 2)
        return image
    }

    private static func imageParagraph(_ image: NSImage) -> NSAttributedString {
        let maxWidth = pageSize.width - margin * 2
        let maxHeight = (pageSize.height - margin * 2) * 0.6
        let scale = min(1, maxWidth / max(image.size.width, 1), maxHeight / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: size)
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(.paragraphStyle, value: paragraphStyle(spacingAfter: 12),
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func linkTarget(in line: String) -> String? {
        guard let open = line.range(of: "]("), let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
        else { return nil }
        return String(line[open.upperBound..<close.lowerBound])
    }

    /// "[Captura 10:00:05](archivo.png)" → "Captura 10:00:05".
    private static func removeLink(_ line: String) -> String {
        // El "[" del link es el último antes de "](" (antes está el de la marca de tiempo).
        guard let mid = line.range(of: "]("),
              let start = line.range(of: "[", options: .backwards, range: line.startIndex..<mid.lowerBound),
              let end = line.range(of: ")", range: mid.upperBound..<line.endIndex)
        else { return line }
        return line.replacingCharacters(in: start.lowerBound..<end.upperBound,
                                        with: String(line[start.upperBound..<mid.lowerBound]))
    }
}
