import Foundation
import FlectKit

public enum FileSystem {
    public static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    public static func size(of path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    public static func modified(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}

public enum OutputPath {
    public static func derive(_ source: String, suffix: String = "", extension ext: String? = nil,
                              avoiding taken: Set<String> = []) -> String {
        let directory = (source as NSString).deletingLastPathComponent
        let stem = ((source as NSString).lastPathComponent as NSString).deletingPathExtension + suffix

        var extensionText = ext ?? {
            let original = (source as NSString).pathExtension
            return original.isEmpty ? "" : "." + original
        }()
        if !extensionText.isEmpty, !extensionText.hasPrefix(".") { extensionText = "." + extensionText }

        var candidate = (directory as NSString).appendingPathComponent(stem + extensionText)
        var number = 2
        while FileSystem.exists(candidate) || taken.contains(candidate) {
            candidate = (directory as NSString).appendingPathComponent("\(stem) (\(number))\(extensionText)")
            number += 1
        }
        return candidate
    }

    public static func deriveDirectory(_ source: String, stem: String? = nil, suffix: String = "") -> String {
        let directory = (source as NSString).deletingLastPathComponent
        let base = (stem ?? ((source as NSString).lastPathComponent as NSString).deletingPathExtension) + suffix

        var candidate = (directory as NSString).appendingPathComponent(base)
        var number = 2
        while FileSystem.exists(candidate) {
            candidate = (directory as NSString).appendingPathComponent("\(base) (\(number))")
            number += 1
        }
        return candidate
    }

    public static func scratch(beside finalPath: String, extension ext: String) -> String {
        let directory = (finalPath as NSString).deletingLastPathComponent
        let suffix = ext.isEmpty || ext.hasPrefix(".") ? ext : "." + ext
        return (directory as NSString).appendingPathComponent(".\(Branding.name)-\(UUID().uuidString.lowercased())\(suffix)")
    }

    public static func temporaryDirectory() -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(Branding.name)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    public static func safeDelete(_ path: String) {
        guard FileSystem.exists(path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    public static func producing<T>(_ path: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            safeDelete(path)
            throw error
        }
    }
}

public final class ScratchDirectory {
    private static let lockName = ".lock"
    private static let abandonedAfter: TimeInterval = 3600

    public let root: String
    private var lockDescriptor: Int32 = -1

    public init(beside path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        ScratchDirectory.sweepAbandoned(in: parent)

        root = (parent as NSString).appendingPathComponent(".\(Branding.name)-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        let lockPath = (root as NSString).appendingPathComponent(ScratchDirectory.lockName)
        lockDescriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_EX | LOCK_NB) }
    }

    deinit { dispose() }

    public func path(for name: String) -> String { (root as NSString).appendingPathComponent(name) }

    public func files() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.filter { $0 != ScratchDirectory.lockName }.sorted().map(path(for:))
    }

    public func dispose() {
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    private static func sweepAbandoned(in parent: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return }
        let cutoff = Date().addingTimeInterval(-abandonedAfter)
        for name in names where name.hasPrefix(".\(Branding.name)-") {
            let directory = (parent as NSString).appendingPathComponent(name)
            guard FileSystem.isDirectory(directory),
                  let created = (try? FileManager.default.attributesOfItem(atPath: directory))?[.creationDate] as? Date,
                  created < cutoff, !inUse(directory) else { continue }
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    private static func inUse(_ directory: String) -> Bool {
        let descriptor = open((directory as NSString).appendingPathComponent(lockName), O_RDWR)
        if descriptor < 0 { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 { return true }
        flock(descriptor, LOCK_UN)
        return false
    }
}

public enum Recycler {
    public static func delete(_ paths: [String], method: DeleteMethod) throws {
        var failures: [String] = []
        for path in paths {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: path)
            do {
                switch method {
                case .permanent:
                    try FileManager.default.removeItem(at: url)
                default:
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            } catch {
                failures.append("\((path as NSString).lastPathComponent) - \(describe(error))")
            }
        }
        if !failures.isEmpty {
            let shown = failures.prefix(5).joined(separator: "\n")
            let more = failures.count > 5 ? "\n" + Loc.f("msg.andMore", Formatting.count(failures.count - 5)) : ""
            throw FlectError(shown + more)
        }
    }
}
