import Foundation
import FlectKit

// Ported from src/App/Inspect/Detail/MediaDetail.cs.
enum MediaDetail {
    private typealias Json = [String: Any]

    static func read(_ path: String) async throws -> ProbeResult? {
        let output: String
        do {
            output = try await ProcessRunner.runOrThrow(try Tools.ffprobe(), [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-show_chapters",
                path,
            ]).standardOutput
        } catch is ProcessFailure {
            return nil
        } catch is FlectError {
            return nil
        }

        guard let root = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? Json else { return nil }
        var sections: [FileSection] = []
        let overview = FactBag()
        var container: String?
        if let format = root["format"] as? Json {
            container = text(format, "format_long_name") ?? text(format, "format_name")
            overview.add("dialog.fileAnalyze.container", container)
            overview.add("dialog.fileAnalyze.duration", duration(text(format, "duration")))
            overview.add("dialog.fileAnalyze.bitrate", bitrate(text(format, "bit_rate")))
            if let tags = format["tags"] as? Json { addTags(overview, tags) }
        }

        let chapters = (root["chapters"] as? [Any])?.count ?? 0
        if chapters > 0 { overview.add("dialog.fileAnalyze.chapters", String(chapters)) }

        var cover = 0
        var video = 0
        var audio = 0
        var subtitle = 0
        for stream in root["streams"] as? [Json] ?? [] {
            if attached(stream) {
                cover += 1
                continue
            }
            let section: FileSection?
            switch text(stream, "codec_type") {
            case "video":
                video += 1
                section = videoSection(stream, video)
            case "audio":
                audio += 1
                section = audioSection(stream, audio)
            case "subtitle":
                subtitle += 1
                section = subtitleSection(stream, subtitle)
            default:
                section = nil
            }
            if let section { sections.append(section) }
        }

        if cover > 0 { overview.add("dialog.fileAnalyze.cover", String(cover)) }
        if let head = overview.section("dialog.fileAnalyze.media") { sections.insert(head, at: 0) }
        if sections.isEmpty { return nil }
        return ProbeResult(kind: kind(container, video, audio), sections: sections)
    }

    private static func kind(_ container: String?, _ video: Int, _ audio: Int) -> String? {
        guard let container, !container.isEmpty else { return video > 0 ? "MP4" : audio > 0 ? "AUDIO" : nil }
        let lower = container.lowercased()
        // ffprobe names both "Matroska / WebM"; the EBML doctype in Signature tells them apart.
        if lower.contains("matroska") { return "MKV" }
        if lower.contains("webm") { return "WEBM" }
        if lower.contains("avi") { return "AVI" }
        if lower.contains("flv") { return "FLV" }
        if lower.contains("asf") || lower.contains("wmv") || lower.contains("wma") { return video > 0 ? "WMV" : "WMA" }
        if lower.contains("mp3") { return "MP3" }
        if lower.contains("wav") { return "WAV" }
        if lower.contains("aiff") { return "AIFF" }
        if lower.contains("ogg") { return "OGG" }
        if lower.contains("flac") { return "FLAC" }
        if lower.contains("mov"), !lower.contains("mp4") { return video > 0 ? "MOV" : "M4A" }
        if lower.contains("mp4") || lower.contains("mov") || lower.contains("m4a") { return video > 0 ? "MP4" : "M4A" }
        return video > 0 ? "VIDEO" : audio > 0 ? "AUDIO" : nil
    }

    private static func addTags(_ bag: FactBag, _ tags: Json) {
        bag.add("dialog.fileAnalyze.metaTitle", text(tags, "title"))
        bag.add("dialog.fileAnalyze.artist", text(tags, "artist") ?? text(tags, "album_artist"))
        bag.add("dialog.fileAnalyze.album", text(tags, "album"))
        bag.add("dialog.fileAnalyze.track", text(tags, "track"))
        bag.add("dialog.fileAnalyze.year", text(tags, "date") ?? text(tags, "year"))
        bag.add("dialog.fileAnalyze.genre", text(tags, "genre"))
        bag.add("dialog.fileAnalyze.encoder", text(tags, "encoder") ?? text(tags, "encoded_by"))
    }

    private static func videoSection(_ stream: Json, _ index: Int) -> FileSection? {
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.codec", codec(stream))
        bag.add("dialog.fileAnalyze.profileName", text(stream, "profile"))
        let width = int(stream, "width")
        let height = int(stream, "height")
        if width > 0, height > 0 {
            bag.add("dialog.fileAnalyze.resolution", "\(width) x \(height)")
            let rotation = rotation(stream)
            let shown = display(width, height, text(stream, "sample_aspect_ratio"), rotation)
            if shown.width != width || shown.height != height {
                bag.add("dialog.fileAnalyze.displaySize", "\(shown.width) x \(shown.height)")
            }
            if rotation != 0 { bag.add("dialog.fileAnalyze.rotation", "\(rotation) degrees") }
        }
        bag.add("dialog.fileAnalyze.fps", fps(stream))
        bag.add("dialog.fileAnalyze.pixelFormat", text(stream, "pix_fmt"))
        bag.add("dialog.fileAnalyze.bitDepth", positive(text(stream, "bits_per_raw_sample")))
        bag.add("dialog.fileAnalyze.bitrate", bitrate(text(stream, "bit_rate")))
        bag.add("dialog.fileAnalyze.colorSpace", text(stream, "color_space"))
        bag.add("dialog.fileAnalyze.transfer", text(stream, "color_transfer"))
        bag.add("dialog.fileAnalyze.range", text(stream, "color_range"))
        bag.add("dialog.fileAnalyze.language", language(stream))
        return named(bag, "dialog.fileAnalyze.video", index)
    }

    private static func audioSection(_ stream: Json, _ index: Int) -> FileSection? {
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.codec", codec(stream))
        bag.add("dialog.fileAnalyze.profileName", text(stream, "profile"))
        bag.add("dialog.fileAnalyze.sampleRate", sampleRate(text(stream, "sample_rate")))
        let channels = int(stream, "channels")
        if channels > 0 {
            bag.add("dialog.fileAnalyze.channels", text(stream, "channel_layout").map { "\(channels) (\($0))" } ?? String(channels))
        }
        bag.add("dialog.fileAnalyze.bitDepth", positive(text(stream, "bits_per_sample") ?? text(stream, "bits_per_raw_sample")))
        bag.add("dialog.fileAnalyze.bitrate", bitrate(text(stream, "bit_rate")))
        bag.add("dialog.fileAnalyze.language", language(stream))
        return named(bag, "dialog.fileAnalyze.audio", index)
    }

    private static func subtitleSection(_ stream: Json, _ index: Int) -> FileSection? {
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.codec", codec(stream))
        bag.add("dialog.fileAnalyze.language", language(stream))
        return named(bag, "dialog.fileAnalyze.subtitle", index)
    }

    private static func named(_ bag: FactBag, _ titleKey: String, _ index: Int) -> FileSection? {
        bag.rows.isEmpty ? nil : FileSection(title: Loc.f("dialog.fileAnalyze.stream", Loc.t(titleKey), index), rows: bag.rows)
    }

    private static func attached(_ stream: Json) -> Bool {
        guard let disposition = stream["disposition"] as? Json else { return false }
        return int(disposition, "attached_pic") == 1
    }

    private static func codec(_ stream: Json) -> String? {
        let longName = text(stream, "codec_long_name")
        guard let name = text(stream, "codec_name") else { return longName }
        return longName.map { "\(name) (\($0))" } ?? name
    }

    private static func language(_ stream: Json) -> String? {
        (stream["tags"] as? Json).flatMap { text($0, "language") }
    }

    private static func fps(_ stream: Json) -> String? {
        var rate = rational(text(stream, "avg_frame_rate"))
        if rate <= 0 { rate = rational(text(stream, "r_frame_rate")) }
        guard rate > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        formatter.roundingMode = .halfUp
        return (formatter.string(from: NSNumber(value: rate)) ?? String(rate)) + " fps"
    }

    private static func rotation(_ stream: Json) -> Int {
        for item in stream["side_data_list"] as? [Json] ?? [] {
            if let value = item["rotation"] as? NSNumber { return Int(value.doubleValue.rounded(.toNearestOrEven)) }
        }
        return (stream["tags"] as? Json).flatMap { text($0, "rotate") }.flatMap { Int($0) } ?? 0
    }

    private static func display(_ width: Int, _ height: Int, _ sampleAspect: String?, _ rotation: Int) -> (width: Int, height: Int) {
        let ratio = rational(sampleAspect)
        let shownWidth = ratio > 0 ? Int((Double(width) * ratio).rounded(.toNearestOrEven)) : width
        return abs(rotation) % 180 == 90 ? (height, shownWidth) : (shownWidth, height)
    }

    private static func duration(_ text: String?) -> String? {
        guard let text, let seconds = Double(text) else { return nil }
        return Formatting.timecode(seconds)
    }

    private static func bitrate(_ text: String?) -> String? {
        guard let text, let bits = Int64(text), bits > 0 else { return nil }
        let kbps = Double(bits) / 1000
        return String(format: kbps >= 100 ? "%.0f" : "%.1f", locale: Locale(identifier: "en_US_POSIX"), kbps) + " kbps"
    }

    private static func sampleRate(_ text: String?) -> String? {
        guard let text, let rate = Int(text), rate > 0 else { return nil }
        return Formatting.count(rate) + " Hz"
    }

    private static func positive(_ text: String?) -> String? {
        guard let text, let value = Int(text), value > 0 else { return nil }
        return String(value)
    }

    private static func text(_ element: Json, _ name: String) -> String? { element[name] as? String }

    private static func int(_ element: Json, _ name: String) -> Int {
        guard let number = element[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        return number.intValue
    }

    private static func rational(_ text: String?) -> Double {
        guard let text, !text.isEmpty, text != "0/0" else { return 0 }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return Double(text) ?? 0 }
        guard let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else { return 0 }
        return numerator / denominator
    }
}
