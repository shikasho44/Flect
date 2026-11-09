import Darwin
import Foundation
import FlectKit

// Ported from src/App/Inspect/Detail/FileSystemDetail.cs. The Windows facts map to their macOS counterparts:
// file attributes to Finder flags and permissions, alternate data streams to extended attributes, and the
// Zone.Identifier mark of the web to the com.apple.quarantine flag and the kMDItemWhereFroms download URLs.
enum FileSystemDetail {
    private static let quarantine = "com.apple.quarantine"
    private static let whereFroms = "com.apple.metadata:kMDItemWhereFroms"

    static func add(_ bag: FactBag, _ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let target = url.resolvingSymlinksInPath()
        let values = try? target.resourceValues(forKeys: [
            .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .creationDateKey,
            .contentModificationDateKey, .isWritableKey, .isUserImmutableKey,
        ])

        bag.add("dialog.fileAnalyze.path", url.path)
        if let size = values?.fileSize { bag.add("dialog.fileAnalyze.size", self.size(Int64(size))) }
        if let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
            bag.add("dialog.fileAnalyze.sizeOnDisk", self.size(Int64(allocated)))
        }
        let dates = DateFormatter()
        dates.dateStyle = .short
        dates.timeStyle = .medium
        if let created = values?.creationDate { bag.add("dialog.fileAnalyze.created", dates.string(from: created)) }
        if let modified = values?.contentModificationDate { bag.add("dialog.fileAnalyze.modified", dates.string(from: modified)) }
        bag.add("dialog.fileAnalyze.attributes", attributes(url, target, values))
        if let link = linkTarget(url) { bag.add("dialog.fileAnalyze.linkTarget", link) }

        let streams = extendedAttributes(target.path)
        if !streams.isEmpty {
            bag.add("dialog.fileAnalyze.streams",
                    streams.map { "\($0.name)  \(Formatting.bytes(Int64($0.size)))" }.joined(separator: "\n"))
        }

        if let agent = quarantineAgent(target.path) {
            let zone = Loc.t("dialog.fileAnalyze.zone3")
            bag.add("dialog.fileAnalyze.zone", agent.isEmpty ? zone : "\(zone) (\(agent))")
        }
        bag.add("dialog.fileAnalyze.zoneUrl", origin(target.path))
    }

    private static func size(_ bytes: Int64) -> String {
        "\(Formatting.bytes(bytes)) (\(Formatting.count(Int(bytes))) \(Loc.t("common.bytes")))"
    }

    private static func attributes(_ url: URL, _ target: URL, _ values: URLResourceValues?) -> String {
        var names: [String] = []
        var info = stat()
        let found = stat(target.path, &info) == 0
        if values?.isWritable == false { names.append(Loc.t("dialog.fileAnalyze.attr.readOnly")) }
        if (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true { names.append(Loc.t("dialog.fileAnalyze.attr.hidden")) }
        if values?.isUserImmutable == true { names.append(Loc.t("dialog.fileAnalyze.attr.locked")) }
        if found, info.st_flags & UInt32(UF_COMPRESSED) != 0 { names.append(Loc.t("dialog.fileAnalyze.attr.compressed")) }
        if found, info.st_mode & 0o111 != 0 { names.append(Loc.t("dialog.fileAnalyze.attr.executable")) }
        return names.isEmpty ? Loc.t("dialog.fileAnalyze.none") : names.joined(separator: ", ")
    }

    // A symbolic link's stored path, or where a Finder alias points (resolved without mounting or prompting).
    private static func linkTarget(_ url: URL) -> String? {
        let kind = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        if kind?.isSymbolicLink == true { return try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) }
        guard kind?.isAliasFile == true else { return nil }
        return (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]))?.path
    }

    // Extended attributes other than macOS's own bookkeeping; the resource fork is kept because it can carry data.
    private static func extendedAttributes(_ path: String) -> [(name: String, size: Int)] {
        let length = listxattr(path, nil, 0, 0)
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        let read = listxattr(path, &buffer, length, 0)
        guard read > 0 else { return [] }
        return buffer.prefix(read).split(separator: 0).compactMap { raw in
            let name = String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !name.hasPrefix("com.apple.") || name == "com.apple.ResourceFork" else { return nil }
            return (name, max(getxattr(path, name, nil, 0, 0, 0), 0))
        }
    }

    // com.apple.quarantine reads "flags;hex time;agent;event id". Nil when the file is not quarantined.
    private static func quarantineAgent(_ path: String) -> String? {
        guard let data = attribute(path, quarantine) else { return nil }
        let fields = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            .split(separator: ";", omittingEmptySubsequences: false)
        return fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
    }

    // kMDItemWhereFroms lists the download URL first and the referring page after it.
    private static func origin(_ path: String) -> String? {
        guard let data = attribute(path, whereFroms),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        let urls = (list as? [Any])?.compactMap { $0 as? String } ?? [list as? String].compactMap { $0 }
        return urls.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func attribute(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0, size <= 1 << 20 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read > 0 ? data.prefix(read) : nil
    }
}
