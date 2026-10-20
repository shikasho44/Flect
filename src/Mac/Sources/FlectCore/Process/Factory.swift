import Foundation
import FlectKit

public enum Factory {
    public static func create(_ request: Request) -> FlectTask? {
        switch request.id {
        case "folder.removeDuplicate": return FolderRemoveDuplicate(request)
        case "folder.removeEmpty": return FolderRemoveEmpty(request)
        case "folder.tree": return FolderTree(request)
        case "folder.rename": return FolderRename(request)
        case "folder.analyze": return FolderAnalyze(request)
        case "folder.compress": return FolderCompress(request)

        case "archive.extract": return ArchiveExtract(request)

        case "image.resize": return ImageResize(request)
        case "image.compress": return ImageCompress(request)
        case "image.rotate": return ImageRotate(request)
        case "image.convert": return ImageConvert(request)
        case "image.ocr": return ImageOcr(request)
        case "image.strip": return ImageStripMetadata(request)
        case "image.chromakey": return ImageChromaKey(request)

        case "video.resize": return VideoResize(request)
        case "video.trim": return VideoTrim(request)
        case "video.thumbnail": return VideoThumbnail(request)
        case "video.subtitles": return MediaSubtitles(request)
        case "video.compress": return VideoCompress(request)
        case "video.rotate": return VideoRotate(request)
        case "video.convert": return VideoConvert(request)
        case "video.extractAudio": return VideoExtractAudio(request)

        case "audio.convert": return AudioConvert(request)
        case "audio.subtitles": return MediaSubtitles(request)

        case "pdf.preview": return PdfPreview(request)
        case "pdf.convert": return PdfConvert(request)
        case "pdf.merge": return PdfMerge(request)

        case "text.encode": return TextEncode(request)
        case "text.lineEndings": return TextLineEndings(request)
        case "text.convert": return TextConvert(request)
        case "json.pretty": return JsonFormat(request, sortKeys: false)
        case "json.sort": return JsonFormat(request, sortKeys: true)

        case "jar.decompile": return JarDecompile(request)

        default: return nil
        }
    }

    public static func label(for verb: String) -> String {
        let id = verb.split(separator: "?").first.map(String.init) ?? verb
        let parts = id.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return id }
        let key = "menu.\(parts[0]).\(parts[1])"
        let text = Loc.t(key)
        return text == key ? id : text
    }
}

public struct UpdateInfo {
    public let version: String
    public let page: URL
    public let download: URL?
}

public enum Updater {
    private static let fileName = "update.json"
    private static let interval: TimeInterval = 24 * 3600

    private struct Memory: Codable {
        var lastCheck: Double
    }

    public static var isDue: Bool {
        let memory = Store.read(Memory.self, from: fileName, defaults: Memory(lastCheck: 0))
        return Date().timeIntervalSince1970 - (memory?.lastCheck ?? 0) >= interval
    }

    public static func check() async throws -> UpdateInfo? {
        Store.write(Memory(lastCheck: Date().timeIntervalSince1970), to: fileName)

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Branding.updateRepository)/releases?per_page=20")!)
        request.setValue("Flect-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return newest(releases, than: Branding.version)
    }

    public static func newest(_ releases: [[String: Any]], than current: String) -> UpdateInfo? {
        guard let installed = version(current) else { return nil }
        var best: (version: [Int], info: UpdateInfo)?

        for release in releases {
            if release["draft"] as? Bool == true || release["prerelease"] as? Bool == true { continue }
            let assets = release["assets"] as? [[String: Any]] ?? []
            guard let asset = assets.first(where: { isMacAsset($0["name"] as? String ?? "") }),
                  let parsed = version(release["tag_name"] as? String) ?? version(release["name"] as? String),
                  parsed.lexicographicallyPrecedes(installed) == false, parsed != installed,
                  let page = (release["html_url"] as? String).flatMap(URL.init(string:)) else { continue }

            let download = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
            let label = versionText(release["tag_name"] as? String) ?? versionText(release["name"] as? String) ?? ""
            let info = UpdateInfo(version: label, page: page, download: download)
            if best == nil || best!.version.lexicographicallyPrecedes(parsed) { best = (parsed, info) }
        }
        return best?.info
    }

    public static func isMacAsset(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".dmg") || (lower.hasSuffix(".zip") && (lower.contains("mac") || lower.contains("darwin")))
    }

    static func versionText(_ text: String?) -> String? {
        guard let text, let range = text.range(of: #"(\d+)\.(\d+)(\.(\d+))?(\.(\d+))?"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    public static func version(_ text: String?) -> [Int]? {
        guard let matched = versionText(text) else { return nil }
        var parts = matched.split(separator: ".").compactMap { Int($0) }
        while parts.count < 4 { parts.append(0) }
        return parts
    }
}
