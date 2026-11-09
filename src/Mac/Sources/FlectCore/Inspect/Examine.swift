import CryptoKit
import Foundation
import FlectKit

public enum Examine {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "heif", "ico", "gif", "svg", "avif", "bmp", "tif", "tiff",
    ]
    private static let mediaExtensions: Set<String> = [
        "mp4", "mov", "mkv", "m4a", "avi", "webm", "flv", "wmv",
        "mp3", "wav", "aif", "aiff", "aac", "ogg", "wma", "flac",
    ]
    private static let archiveExtensions: Set<String> = ["zip", "7z", "tar", "rar", "gz", "tgz", "jar", "tar.gz"]

    public static func inspect(_ path: String) async throws -> FileReport {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw FlectError(Loc.t("dialog.fileAnalyze.single"))
        }
        let fileName = (path as NSString).lastPathComponent
        let name = FileName.read(fileName)
        let ext = name.extension.lowercased()
        let magic = Signature.of(try header(path), fileName: fileName)
        var detected = magic.kind
        var executable = magic.family == "pe"
        var sections: [FileSection] = []

        if magic.family == "image" || (imageExtensions.contains(ext) && ["binary", "text", ""].contains(magic.family)) {
            if let image = attempt({ try ImageDetail.read(path, magic.kind == "SVG" ? "SVG" : detected) }) {
                if let kind = image.kind, !kind.isEmpty, ["image", "binary", "text", ""].contains(magic.family) { detected = kind }
                sections += image.sections
            }
        }

        if magic.family == "pdf" || (ext == "pdf" && sections.isEmpty) {
            if let pdf = attempt({ try PdfDetail.read(path) }) {
                detected = pdf.kind ?? detected
                sections += pdf.sections
            }
        }

        if magic.family == "archive" || archiveExtensions.contains(ext) {
            if let archive = await attempt({ try await ArchiveDetail.read(path, detected) }) {
                if let kind = archive.kind, !kind.isEmpty { detected = kind }
                sections += archive.sections
            }
        }

        if ["video", "audio"].contains(magic.family)
            || (mediaExtensions.contains(ext) && !["image", "pdf", "archive", "pe"].contains(magic.family)) {
            if let media = await attempt({ try await MediaDetail.read(path) }) {
                if let kind = media.kind, !kind.isEmpty, kind != "VIDEO", kind != "AUDIO",
                   ["video", "audio", "binary", "text", ""].contains(magic.family) {
                    detected = preferMedia(detected, kind, magic.family)
                }
                sections += media.sections
            }
        }

        if magic.family == "pe" || ext == "exe" || ext == "dll" {
            if let pe = attempt({ try BinaryDetail.pe(path) }) {
                detected = "PE"
                executable = true
                sections += pe.sections
            }
        }

        if magic.family == "lnk" || ext == "lnk" {
            if let link = attempt({ try BinaryDetail.link(path) }) {
                detected = "LNK"
                sections += link.sections
            }
        }

        if magic.family == "text" || Kinds.isTextExtension(name.extension),
           !["image", "pdf", "archive", "pe", "video", "audio"].contains(magic.family) {
            if let text = attempt({ try TextDetail.read(path, name.extension) }) {
                if let kind = text.kind, !kind.isEmpty, kind != "TEXT" { detected = kind }
                else if detected.isEmpty { detected = "TEXT" }
                sections += text.sections
            }
        }

        var alerts: [String] = []
        let claimed = name.claimedKind
        if !Kinds.same(claimed, detected) {
            alerts.append(Loc.f("dialog.fileAnalyze.mismatch", claimed,
                                detected.isEmpty ? Loc.t("dialog.fileAnalyze.unknown") : detected))
        }
        var disguise = name.disguiseAs
        if disguise == nil, executable, !Kinds.isExecutable(name.extension) {
            disguise = claimed.isEmpty ? Loc.t("dialog.fileAnalyze.unknown") : claimed
        }
        if let disguise { alerts.append(Loc.f("dialog.fileAnalyze.disguise", disguise)) }
        alerts += name.alerts

        let overview = FactBag()
        FileSystemDetail.add(overview, path)
        overview.add("dialog.fileAnalyze.actualName", name.markedName)
        overview.add("dialog.fileAnalyze.shown", name.shownName)
        overview.add("dialog.fileAnalyze.extension", claimed.isEmpty ? Loc.t("dialog.fileAnalyze.none") : claimed)
        overview.add("dialog.fileAnalyze.contents", detected.isEmpty ? Loc.t("dialog.fileAnalyze.unknown") : detected)

        return FileReport(path: URL(fileURLWithPath: path).standardizedFileURL.path, alerts: alerts,
                          overview: overview.rows, sections: sections)
    }

    private static func preferMedia(_ detected: String, _ media: String, _ family: String) -> String {
        if ["video", "audio"].contains(family), !detected.isEmpty, detected != "TEXT" {
            if detected == "MP4", media == "M4A" { return media }
            if detected == "WMA", media == "WMV" { return media }
            if detected == "MKV", media == "WEBM" { return media }
            return detected
        }
        return media
    }

    private static func header(_ path: String) throws -> [UInt8] {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FlectError(Loc.t("dialog.fileAnalyze.single")) }
        defer { try? handle.close() }
        return [UInt8](try handle.read(upToCount: 8192) ?? Data())
    }

    private static func attempt(_ read: () throws -> ProbeResult?) -> ProbeResult? {
        do { return try read() } catch { return failure(error) }
    }

    private static func attempt(_ read: () async throws -> ProbeResult?) async -> ProbeResult? {
        do { return try await read() } catch is CancellationError { return nil } catch { return failure(error) }
    }

    private static func failure(_ error: Error) -> ProbeResult {
        let bag = FactBag()
        var message = describe(error).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.count > 300 { message = String(message.prefix(300)) }
        bag.add("dialog.fileAnalyze.unreadable", message)
        return bag.result("dialog.fileAnalyze.unreadableTitle")
    }
}

public enum Checksum {
    public static func sha256(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FlectError(Loc.t("dialog.fileAnalyze.single")) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ReportFile {
    public static func write(_ report: FileReport, sha256: String?, to path: String, format: ReportFormat) throws {
        let text: String
        switch format {
        case .json: text = json(report, sha256)
        case .html: text = html(report, sha256)
        case .txt: text = plain(report, sha256)
        case .csv: text = csv(report, sha256)
        }
        var data = Data(text.utf8)
        if format == .csv { data = Data([0xEF, 0xBB, 0xBF]) + data }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func csv(_ report: FileReport, _ sha256: String?) -> String {
        var lines = ["section,label,value"]
        func row(_ section: String, _ label: String, _ value: String) {
            lines.append([section, label, value].map(quote).joined(separator: ","))
        }
        row("file", "path", report.path)
        if let sha256, !sha256.isEmpty { row("file", "sha256", sha256) }
        for alert in report.alerts { row("alert", "alert", alert) }
        for fact in report.overview { row("overview", fact.label, fact.value) }
        for section in report.sections { for fact in section.rows { row(section.title, fact.label, fact.value) } }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quote(_ value: String) -> String {
        value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }

    private static func json(_ report: FileReport, _ sha256: String?) -> String {
        func facts(_ rows: [FileFact]) -> [[String: String]] { rows.map { ["label": $0.label, "value": $0.value] } }
        let root: [String: Any] = [
            "path": report.path,
            "sha256": sha256 ?? NSNull(),
            "alerts": report.alerts,
            "overview": facts(report.overview),
            "sections": report.sections.map { ["title": $0.title, "rows": facts($0.rows)] as [String: Any] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys,
                                                                               .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func plain(_ report: FileReport, _ sha256: String?) -> String {
        var lines = [report.path]
        if let sha256, !sha256.isEmpty { lines.append("SHA-256  " + sha256) }
        lines += report.alerts
        lines.append("")
        func line(_ fact: FileFact) -> String {
            "\(fact.label): " + fact.value.replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: fact.label.count + 2))
        }
        lines += report.overview.map(line)
        for section in report.sections {
            lines.append("")
            lines.append(section.title)
            lines += section.rows.map(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func html(_ report: FileReport, _ sha256: String?) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        func table(_ rows: [FileFact]) -> String {
            "<table>\n" + rows.map {
                "<tr><td>\(escape($0.label))</td><td>\(escape($0.value).replacingOccurrences(of: "\n", with: "<br>"))</td></tr>\n"
            }.joined() + "</table>\n"
        }
        var html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\">\n<title>Analyze</title>\n"
        html += "<style>body{font:14px sans-serif;margin:24px}h2{font-size:15px;margin:24px 0 8px}\n"
        html += "table{border-collapse:collapse;width:100%}td{padding:4px 10px 4px 0;vertical-align:top}\n"
        html += ".alert{color:#b91c1c}</style></head><body>\n"
        html += "<h1>\(escape((report.path as NSString).lastPathComponent))</h1>\n"
        if let sha256, !sha256.isEmpty { html += "<p>SHA-256 \(escape(sha256))</p>\n" }
        for alert in report.alerts { html += "<p class=\"alert\">\(escape(alert))</p>\n" }
        html += table(report.overview)
        for section in report.sections { html += "<h2>\(escape(section.title))</h2>\n" + table(section.rows) }
        return html + "</body></html>\n"
    }
}
