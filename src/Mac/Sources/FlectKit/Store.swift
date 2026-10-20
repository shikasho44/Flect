import Foundation

public enum Store {
    private static let attempts = 5
    private static let backoff: useconds_t = 50_000
    private static let brokenSuffix = ".broken"
    private static let staleAfter: TimeInterval = 3600

    public static var directory: URL { Locations.support }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // Dictionary keys such as "video.resize" pass through these too; they are data, not property names, and the
    // Windows version matches them exactly, so anything with a dot is left as written.
    private static func pascal(_ name: String) -> String {
        name.contains(".") ? name : name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func camel(_ name: String) -> String {
        name.contains(".") ? name : name.prefix(1).lowercased() + name.dropFirst()
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .custom { path in Key(stringValue: pascal(path.last!.stringValue)) }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in Key(stringValue: camel(path.last!.stringValue)) }
        return decoder
    }

    public static func read<T: Codable>(_ type: T.Type, from fileName: String, defaults: T) -> T? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        for attempt in 1...2 {
            guard let data = readData(url) else { return nil }
            do {
                return try decodeLeniently(type, from: data, defaults: defaults)
            } catch {
                if attempt == 1 {
                    usleep(backoff)
                    continue
                }
                setAside(url)
            }
        }
        return nil
    }

    public static func decodeLeniently<T: Codable>(_ type: T.Type, from data: Data, defaults: T) throws -> T {
        let overlay = try JSONSerialization.jsonObject(with: data)
        let base = try JSONSerialization.jsonObject(with: makeEncoder().encode(defaults))
        let merged = merge(base, overlay)
        let combined = try JSONSerialization.data(withJSONObject: merged)
        return try makeDecoder().decode(type, from: combined)
    }

    private static func merge(_ base: Any, _ overlay: Any) -> Any {
        guard let baseObject = base as? [String: Any], let overlayObject = overlay as? [String: Any] else {
            return overlay is NSNull ? base : overlay
        }
        // An empty default is a map such as Output.Folders, not a settings group: keep its string entries, which a
        // group's unknown-key filtering below would otherwise drop.
        if baseObject.isEmpty { return overlayObject.filter { $0.value is String } }
        var result = baseObject
        for (key, value) in overlayObject {
            if let existing = baseObject[key] {
                result[key] = merge(existing, value)
            }
        }
        return result
    }

    public static func write<T: Encodable>(_ value: T, to fileName: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(fileName).resolvingSymlinksInPath()
            let folder = target.deletingLastPathComponent()
            let name = target.lastPathComponent
            sweepStale(in: folder, name: name)

            let data = try makeEncoder().encode(value)
            let temp = folder.appendingPathComponent(".\(name).\(UUID().uuidString.lowercased()).tmp")
            defer { try? FileManager.default.removeItem(at: temp) }
            try data.write(to: temp, options: [.withoutOverwriting])
            replace(temp, with: target)
        } catch {
        }
    }

    public static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    private static func readData(_ url: URL) -> Data? {
        for attempt in 1...attempts {
            if let data = try? Data(contentsOf: url) { return data }
            if attempt < attempts { usleep(backoff * useconds_t(attempt)) }
        }
        return nil
    }

    private static func replace(_ temp: URL, with target: URL) {
        for attempt in 1...attempts {
            if rename(temp.path, target.path) == 0 { return }
            if attempt < attempts { usleep(backoff * useconds_t(attempt)) }
        }
    }

    private static func setAside(_ url: URL) {
        let broken = URL(fileURLWithPath: url.path + brokenSuffix)
        try? FileManager.default.removeItem(at: broken)
        try? FileManager.default.moveItem(at: url, to: broken)
    }

    private static func sweepStale(in folder: URL, name: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-staleAfter)
        for entry in entries where entry.lastPathComponent.hasPrefix(".\(name).") && entry.pathExtension == "tmp" {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }
}
