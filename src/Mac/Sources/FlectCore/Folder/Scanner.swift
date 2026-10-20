import CryptoKit
import Foundation
import FlectKit

public struct ExclusionFilter {
    public static let none = ExclusionFilter(folders: [], files: [], extensions: [])

    private let folders: [String]
    private let files: [String]
    private let extensions: [String]

    public var isEmpty: Bool { folders.isEmpty && files.isEmpty && extensions.isEmpty }

    public static func from(_ rules: ExclusionRules?) -> ExclusionFilter {
        guard let rules else { return .none }
        let extensions = split(rules.extensions).map { $0.hasPrefix(".") ? $0 : "." + $0 }
        return ExclusionFilter(folders: split(rules.folders), files: split(rules.files), extensions: extensions)
    }

    public func excludesFolder(_ name: String) -> Bool { ExclusionFilter.any(folders, name) }

    public func excludesFile(_ name: String) -> Bool {
        if ExclusionFilter.any(files, name) { return true }
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && ExclusionFilter.any(extensions, "." + ext)
    }

    public static func split(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: CharacterSet(charactersIn: "\n\r;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func any(_ patterns: [String], _ value: String) -> Bool {
        patterns.contains { matches($0, value) }
    }

    static func matches(_ pattern: String, _ value: String) -> Bool {
        if !pattern.contains("*"), !pattern.contains("?") {
            return pattern.caseInsensitiveCompare(value) == .orderedSame
        }
        return wildcard(Array(pattern.uppercased()), Array(value.uppercased()))
    }

    private static func wildcard(_ pattern: [Character], _ value: [Character]) -> Bool {
        var p = 0
        var v = 0
        var star = -1
        var mark = 0
        while v < value.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == value[v] {
                p += 1
                v += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                p += 1
                mark = v
            } else if star >= 0 {
                p = star + 1
                mark += 1
                v = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}

public struct ScannedFile: Hashable {
    public let path: String
    public let size: Int64
    public let lastWrite: Date
    public let fileExtension: String

    public init(path: String, size: Int64, lastWrite: Date, fileExtension: String) {
        self.path = path
        self.size = size
        self.lastWrite = lastWrite
        self.fileExtension = fileExtension
    }
}

public final class TreeScan {
    public init() {}

    public var files: [ScannedFile] = []
    public var emptyDirectories: [String] = []
    public var directoryCount = 0

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct ScanOptions {
    let exclusions: ExclusionFilter
    let empty: EmptyFolderSettings

    public static func from(_ folder: FolderSettings, extra: ExclusionRules? = nil) -> ScanOptions {
        guard let extra else { return ScanOptions(exclusions: .from(folder.scanExclusions), empty: folder.empty) }
        var merged = ExclusionRules()
        merged.folders = (ExclusionFilter.split(folder.scanExclusions.folders) + ExclusionFilter.split(extra.folders)).joined(separator: "\n")
        merged.files = (ExclusionFilter.split(folder.scanExclusions.files) + ExclusionFilter.split(extra.files)).joined(separator: "\n")
        merged.extensions = (ExclusionFilter.split(folder.scanExclusions.extensions) + ExclusionFilter.split(extra.extensions)).joined(separator: "\n")
        return ScanOptions(exclusions: .from(merged), empty: folder.empty)
    }
}

enum FinderFiles {
    static func isSystem(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".localized" || name == "Icon\r" || name.hasPrefix("._")
    }
}

public enum FileScanner {
    private static let headHashBytes = 64 * 1024
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
                                                 .contentModificationDateKey, .isRegularFileKey]

    public static func scan(_ roots: [String], progress: TaskProgress, options: ScanOptions) throws -> TreeScan {
        let scan = TreeScan()
        for root in roots {
            try Task.checkCancellation()
            guard FileSystem.isDirectory(root) else { continue }
            _ = try walk(URL(fileURLWithPath: root, isDirectory: true), scan, progress, options, isRoot: true)
        }
        return scan
    }

    private static func walk(_ directory: URL, _ scan: TreeScan, _ progress: TaskProgress, _ options: ScanOptions,
                             isRoot: Bool) throws -> Bool {
        try Task.checkCancellation()

        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                         options: []) else { return true }
        var hasFiles = false
        var folders: [URL] = []

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let name = entry.lastPathComponent
            if values?.isSymbolicLink == true {
                hasFiles = true
                continue
            }

            if values?.isDirectory == true, values?.isPackage != true {
                if options.exclusions.excludesFolder(name) {
                    hasFiles = true
                } else {
                    folders.append(entry)
                }
                continue
            }
            if values?.isDirectory == true {
                hasFiles = true
                continue
            }
            if FinderFiles.isSystem(name) { continue }

            let size = Int64(values?.fileSize ?? 0)
            if !ignorable(name, size: size, options.empty) { hasFiles = true }
            if options.exclusions.excludesFile(name) { continue }

            scan.files.append(ScannedFile(path: entry.path, size: size,
                                          lastWrite: values?.contentModificationDate ?? .distantPast,
                                          fileExtension: fileExtension(name)))
            if scan.files.count % 4096 == 0 {
                progress.status(Loc.f("msg.scanningCount", Loc.n("count.file", scan.files.count)))
            }
        }

        for folder in folders {
            scan.directoryCount += 1
            if try walk(folder, scan, progress, options, isRoot: false) { hasFiles = true }
        }

        if !hasFiles, !isRoot { scan.emptyDirectories.append(directory.path) }
        return hasFiles
    }

    private static func ignorable(_ name: String, size: Int64, _ empty: EmptyFolderSettings) -> Bool {
        if empty.ignoreZeroByteFiles, size == 0 { return true }
        if empty.ignoreDesktopIni, name.caseInsensitiveCompare("desktop.ini") == .orderedSame { return true }
        return empty.ignoreThumbsDb && name.caseInsensitiveCompare("Thumbs.db") == .orderedSame
    }

    static func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    public static func outermost(_ directories: [String]) -> [String] {
        let all = Set(directories.map { $0.lowercased() })
        return directories
            .filter { !all.contains(($0 as NSString).deletingLastPathComponent.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func findDuplicates(_ files: [ScannedFile], progress: TaskProgress,
                                      settings: DuplicateSettings) throws -> [[ScannedFile]] {
        let eligible = files.filter { !(settings.ignoreEmptyFiles && $0.size == 0) && $0.size >= settings.minimumBytes }
        let candidates = Dictionary(grouping: eligible) { identity($0, settings) }
            .values.filter { $0.count > 1 }.flatMap { $0 }
        if candidates.isEmpty { return [] }

        if settings.strictness == .sizeOnly {
            return Dictionary(grouping: candidates) { identity($0, settings) }.values.map(Array.init).sorted(by: firstPath)
        }

        progress.status(Loc.f("msg.comparing", Loc.n("count.file", candidates.count)))
        let byHead = try hashGroups(candidates, limit: headHashBytes, settings, progress)
        if settings.strictness == .headHash { return byHead }

        var confirmed = byHead.filter { $0[0].size <= headHashBytes }
        let unverified = byHead.filter { $0[0].size > headHashBytes }.flatMap { $0 }
        if unverified.isEmpty { return confirmed }

        progress.status(Loc.f("msg.verifying", Loc.n("count.candidate", unverified.count)))
        confirmed += try hashGroups(unverified, limit: Int.max, settings, progress)
        return confirmed
    }

    private static func firstPath(_ left: [ScannedFile], _ right: [ScannedFile]) -> Bool {
        (left.first?.path ?? "") < (right.first?.path ?? "")
    }

    private static func identity(_ file: ScannedFile, _ settings: DuplicateSettings) -> String {
        var key = String(file.size)
        if settings.matchName { key += "|" + (file.path as NSString).lastPathComponent.lowercased() }
        if settings.matchTimestamp { key += "|" + String(Int64(file.lastWrite.timeIntervalSince1970)) }
        return key
    }

    private static func hashGroups(_ files: [ScannedFile], limit: Int, _ settings: DuplicateSettings,
                                   _ progress: TaskProgress) throws -> [[ScannedFile]] {
        var hashes = [String?](repeating: nil, count: files.count)
        let lock = NSLock()
        var done = 0
        var cancelled = false

        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            lock.lock()
            let stop = cancelled
            lock.unlock()
            if stop { return }
            if Task.isCancelled {
                lock.lock()
                cancelled = true
                lock.unlock()
                return
            }
            let digest = try? hash(files[index].path, limit: limit)
            lock.lock()
            hashes[index] = digest
            done += 1
            let completed = done
            lock.unlock()
            if completed % 128 == 0 { progress.step(completed, files.count) }
        }
        if cancelled || Task.isCancelled { throw CancellationError() }

        var groups: [String: [ScannedFile]] = [:]
        var order: [String] = []
        for (index, file) in files.enumerated() {
            guard let digest = hashes[index] else { continue }
            let key = identity(file, settings) + "#" + digest
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }

    private static func hash(_ path: String, limit: Int) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FlectError("Cannot read \(path)") }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit
        while remaining > 0 {
            let chunk = try handle.read(upToCount: min(1024 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DuplicateMode {
    case keepOldest, keepNewest, deleteAll
}

public enum DuplicatePlan {
    public static func toDelete(_ groups: [[ScannedFile]], mode: DuplicateMode) -> [ScannedFile] {
        var doomed: [ScannedFile] = []
        for group in groups {
            switch mode {
            case .deleteAll:
                doomed += group
            case .keepOldest:
                guard let keep = group.min(by: { $0.lastWrite < $1.lastWrite }) else { continue }
                doomed += group.filter { $0 != keep }
            case .keepNewest:
                guard let keep = group.max(by: { $0.lastWrite < $1.lastWrite }) else { continue }
                doomed += group.filter { $0 != keep }
            }
        }
        return doomed
    }
}
