import Foundation
import FlectKit

public enum TreeRenderer {
    private static let maxEntries = 200_000

    public static func render(_ roots: [String], settings: TreeSettings, progress: TaskProgress) throws -> String {
        let exclusions = ExclusionFilter.from(settings.exclusions)
        var text = ""
        var budget = maxEntries

        for root in roots {
            try Task.checkCancellation()
            guard FileSystem.isDirectory(root) else { continue }
            progress.status(root)
            if !text.isEmpty { text += "\n\n" }
            text += URL(fileURLWithPath: root).standardizedFileURL.path + "\n"
            try branch(URL(fileURLWithPath: root, isDirectory: true), prefix: "", &text, settings, exclusions, &budget)
        }
        return text
    }

    private static func branch(_ directory: URL, prefix: String, _ text: inout String, _ settings: TreeSettings,
                               _ exclusions: ExclusionFilter, _ budget: inout Int) throws {
        try Task.checkCancellation()
        let (folders, files) = children(directory, exclusions)
        let listed = settings.foldersOnly ? [] : files

        for (index, folder) in folders.enumerated() {
            budget -= 1
            if budget < 0 { return }
            let last = index == folders.count - 1 && listed.isEmpty
            text += prefix + (last ? "└───" : "├───") + folder.lastPathComponent + "\n"
            try branch(folder, prefix: prefix + (last ? "    " : "│   "), &text, settings, exclusions, &budget)
        }
        for (index, file) in listed.enumerated() {
            budget -= 1
            if budget < 0 { return }
            text += prefix + (index == listed.count - 1 ? "└───" : "├───") + file + "\n"
        }
    }

    private static func children(_ directory: URL, _ exclusions: ExclusionFilter) -> ([URL], [String]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                         options: []) else { return ([], []) }
        var folders: [URL] = []
        var files: [String] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let name = entry.lastPathComponent
            if values?.isDirectory == true, values?.isSymbolicLink != true, values?.isPackage != true {
                if !exclusions.excludesFolder(name) { folders.append(entry) }
            } else if !FinderFiles.isSystem(name), !exclusions.excludesFile(name) {
                files.append(name)
            }
        }
        folders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        files.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return (folders, files)
    }
}

public struct TypeShare {
    public let fileExtension: String
    public let count: Int
    public let bytes: Int64
}

public struct AnalyzeReport {
    public static let topCount = 15

    public let roots: [String]
    public let totalBytes: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let largest: [ScannedFile]
    public let byType: [TypeShare]
    public let duplicateGroups: Int
    public let duplicateFiles: Int
    public let reclaimableBytes: Int64
    public let emptyDirectories: [String]
    public let elapsed: TimeInterval

    public static func build(_ roots: [String], _ scan: TreeScan, _ duplicates: [[ScannedFile]], elapsed: TimeInterval) -> AnalyzeReport {
        let byType = Dictionary(grouping: scan.files) { $0.fileExtension.isEmpty ? "(no extension)" : $0.fileExtension }
            .map { TypeShare(fileExtension: $0.key, count: $0.value.count, bytes: $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.fileExtension < $1.fileExtension }

        let reclaimable = duplicates.reduce(Int64(0)) { total, group in
            total + group.reduce(0) { $0 + $1.size } - group[0].size
        }

        return AnalyzeReport(roots: roots,
                             totalBytes: scan.totalBytes,
                             fileCount: scan.files.count,
                             directoryCount: scan.directoryCount,
                             largest: Array(scan.files.sorted { $0.size > $1.size }.prefix(topCount)),
                             byType: byType,
                             duplicateGroups: duplicates.count,
                             duplicateFiles: duplicates.reduce(0) { $0 + $1.count },
                             reclaimableBytes: reclaimable,
                             emptyDirectories: scan.emptyDirectories,
                             elapsed: elapsed)
    }
}

public enum ReportWriter {
    public static func fileExtension(_ format: ReportFormat) -> String {
        switch format {
        case .json: return "json"
        case .html: return "html"
        case .txt: return "txt"
        case .csv: return "csv"
        }
    }

    public static func write(_ report: AnalyzeReport, to path: String, format: ReportFormat) throws {
        let text: String
        switch format {
        case .json: text = json(report)
        case .html: text = html(report)
        case .txt: text = plain(report)
        case .csv: text = csv(report)
        }
        let data = format == .csv ? Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8) : Data(text.utf8)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func quote(_ value: String) -> String {
        value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : value
    }

    private static func csv(_ report: AnalyzeReport) -> String {
        var text = "section,name,bytes,count,share\n"
        func row(_ section: String, _ name: String, _ bytes: Int64?, _ count: Int?, _ share: Double?) {
            text += quote(section) + "," + quote(name) + "," + (bytes.map(String.init) ?? "") + ","
                + (count.map(String.init) ?? "") + "," + (share.map { String(format: "%.5f", $0) } ?? "") + "\n"
        }
        for root in report.roots { row("root", root, nil, nil, nil) }
        row("summary", "total", report.totalBytes, report.fileCount, nil)
        row("summary", "folders", nil, report.directoryCount, nil)
        row("summary", "duplicateGroups", report.reclaimableBytes, report.duplicateGroups, nil)
        row("summary", "duplicateFiles", nil, report.duplicateFiles, nil)
        row("summary", "emptyFolders", nil, report.emptyDirectories.count, nil)
        for file in report.largest { row("largest", file.path, file.size, nil, nil) }
        let total = Double(max(1, report.totalBytes))
        for share in report.byType { row("type", share.fileExtension, share.bytes, share.count, Double(share.bytes) / total) }
        for folder in report.emptyDirectories { row("empty", folder, nil, nil, nil) }
        return text
    }

    private static func json(_ report: AnalyzeReport) -> String {
        let value = JSONValue.object([
            ("roots", .array(report.roots.map { .string($0) })),
            ("totalBytes", .number(String(report.totalBytes))),
            ("files", .number(String(report.fileCount))),
            ("folders", .number(String(report.directoryCount))),
            ("scanSeconds", .number(Formatting.number((report.elapsed * 100).rounded() / 100))),
            ("duplicates", .object([
                ("groups", .number(String(report.duplicateGroups))),
                ("files", .number(String(report.duplicateFiles))),
                ("reclaimableBytes", .number(String(report.reclaimableBytes))),
            ])),
            ("largest", .array(report.largest.map {
                .object([("path", .string($0.path)), ("bytes", .number(String($0.size)))])
            })),
            ("byType", .array(report.byType.map {
                .object([("extension", .string($0.fileExtension)), ("files", .number(String($0.count))),
                         ("bytes", .number(String($0.bytes)))])
            })),
            ("emptyFolders", .array(report.emptyDirectories.map { .string($0) })),
        ])
        return JSONWriter.write(value)
    }

    private static func plain(_ report: AnalyzeReport) -> String {
        var text = report.roots.joined(separator: "   ") + "\n\n"
        text += "\(Formatting.bytes(report.totalBytes)) · \(Loc.n("count.file", report.fileCount)) · \(Loc.n("count.folder", report.directoryCount))\n"
        text += "\(Loc.n("count.group", report.duplicateGroups)) · \(Formatting.bytes(report.reclaimableBytes))\n\n"
        for file in report.largest {
            text += Formatting.bytes(file.size).leftPadded(12) + "  " + file.path + "\n"
        }
        text += "\n"
        let total = Double(max(1, report.totalBytes))
        for share in report.byType {
            text += share.fileExtension.rightPadded(16) + Formatting.bytes(share.bytes).leftPadded(12) + "  "
                + Formatting.percent(Double(share.bytes) / total).leftPadded(8) + "  " + Loc.n("count.file", share.count) + "\n"
        }
        text += "\n"
        for folder in report.emptyDirectories { text += folder + "\n" }
        return text
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func html(_ report: AnalyzeReport) -> String {
        let total = Double(max(1, report.totalBytes))
        var html = "<!doctype html>\n<html><head><meta charset=\"utf-8\">\n"
        html += "<title>\(escape(Branding.name)) - \(escape(Loc.t("dialog.analyze.title")))</title>\n"
        html += "<style>body{font-family:-apple-system,system-ui,sans-serif;margin:32px;color:#1b1b1b}h2{font-size:15px;margin:26px 0 8px}"
            + "table{border-collapse:collapse;width:100%;font-size:13px}td,th{text-align:left;padding:4px 10px;border-bottom:1px solid #e4e4e4}"
            + "td.n{text-align:right;font-variant-numeric:tabular-nums}"
            + "@media(prefers-color-scheme:dark){body{background:#1f1f1f;color:#f2f2f2}td,th{border-bottom-color:#3d3d3d}}</style>\n"
        html += "</head><body>\n"
        html += "<h1>\(escape(Loc.t("dialog.analyze.title")))</h1>\n"
        html += "<p>\(escape(report.roots.joined(separator: "   ")))</p>\n"
        html += "<p>\(escape(Formatting.bytes(report.totalBytes))) · \(escape(Loc.n("count.file", report.fileCount))) · "
            + "\(escape(Loc.n("count.folder", report.directoryCount))) · \(escape(Loc.n("count.group", report.duplicateGroups))) "
            + "(\(escape(Formatting.bytes(report.reclaimableBytes))))</p>\n"
        html += "<h2>\(escape(Loc.t("dialog.analyze.largest")))</h2><table>\n"
        for file in report.largest {
            html += "<tr><td class=\"n\">\(escape(Formatting.bytes(file.size)))</td><td>\(escape(file.path))</td></tr>\n"
        }
        html += "</table>\n<h2>\(escape(Loc.t("dialog.analyze.types")))</h2><table>\n"
        for share in report.byType {
            html += "<tr><td>\(escape(share.fileExtension))</td><td class=\"n\">\(escape(Formatting.bytes(share.bytes)))</td>"
                + "<td class=\"n\">\(escape(Formatting.percent(Double(share.bytes) / total)))</td>"
                + "<td class=\"n\">\(escape(Loc.n("count.file", share.count)))</td></tr>\n"
        }
        html += "</table>\n"
        if !report.emptyDirectories.isEmpty {
            html += "<h2>\(escape(Loc.t("dialog.analyze.empty")))</h2><table>\n"
            for folder in report.emptyDirectories { html += "<tr><td>\(escape(folder))</td></tr>\n" }
            html += "</table>\n"
        }
        html += "</body></html>\n"
        return html
    }
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }

    func rightPadded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
