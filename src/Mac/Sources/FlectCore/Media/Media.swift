import Foundation
import FlectKit

public struct MediaInfo {
    public var duration: Double = 0
    public var width = 0
    public var height = 0
    public var frameRate: Double = 0
    public var videoCodec: String?
    public var audioCodec: String?
    public var videoBitrate: Int64 = 0
    public var audioBitrate: Int64 = 0
    public var audioChannels = 0
    public var audioTrackCount = 0
    public var subtitleTrackCount = 0
    public var container = ""

    public var hasVideo: Bool { videoCodec != nil }
    public var hasAudio: Bool { audioTrackCount > 0 }
    public var shortSide: Int { min(width, height) }

    public var isMp4Family: Bool {
        let name = container.lowercased()
        return name.contains("mp4") || name.contains("mov") || name.contains("m4a")
    }
}

public enum Media {
    public static func read(_ path: String) async throws -> MediaInfo {
        let result = try await ProcessRunner.runOrThrow(try Tools.ffprobe(), [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            path,
        ])
        return try parse(Data(result.standardOutput.utf8))
    }

    static func parse(_ data: Data) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlectError(Loc.t("msg.noDuration"))
        }

        var info = MediaInfo()
        var formatBitrate: Int64 = 0
        var rotation = 0

        if let format = root["format"] as? [String: Any] {
            info.duration = double(format["duration"])
            formatBitrate = long(format["bit_rate"])
            info.container = format["format_name"] as? String ?? ""
        }

        for stream in root["streams"] as? [[String: Any]] ?? [] {
            let kind = stream["codec_type"] as? String
            let codec = stream["codec_name"] as? String

            switch kind {
            case "video":
                if let codec, ["mjpeg", "png", "bmp", "gif"].contains(codec) { continue }
                if info.videoCodec != nil { continue }
                info.videoCodec = codec
                info.width = int(stream["width"])
                info.height = int(stream["height"])
                rotation = rotationOf(stream)
                info.frameRate = rational(stream["avg_frame_rate"] as? String)
                if info.frameRate <= 0 { info.frameRate = rational(stream["r_frame_rate"] as? String) }
                info.videoBitrate = long(stream["bit_rate"])
            case "audio":
                info.audioTrackCount += 1
                if info.audioCodec != nil { continue }
                info.audioCodec = codec
                info.audioBitrate = long(stream["bit_rate"])
                info.audioChannels = int(stream["channels"])
            case "subtitle":
                info.subtitleTrackCount += 1
            default:
                break
            }
        }

        if info.videoBitrate <= 0, formatBitrate > 0 {
            info.videoBitrate = max(0, formatBitrate - info.audioBitrate)
        }
        if abs(rotation) % 180 == 90 { swap(&info.width, &info.height) }
        return info
    }

    private static func rotationOf(_ stream: [String: Any]) -> Int {
        if let sideData = stream["side_data_list"] as? [[String: Any]] {
            for item in sideData {
                if let value = item["rotation"] as? NSNumber { return Int(value.doubleValue.rounded()) }
            }
        }
        if let tags = stream["tags"] as? [String: Any], let text = tags["rotate"] as? String, let value = Int(text) {
            return value
        }
        return 0
    }

    private static func double(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let parsed = Double(text) { return parsed }
        return 0
    }

    private static func long(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String, let parsed = Int64(text) { return parsed }
        return 0
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func rational(_ text: String?) -> Double {
        guard let text, !text.isEmpty else { return 0 }
        let parts = text.split(separator: "/")
        guard parts.count == 2 else { return Double(text) ?? 0 }
        let numerator = Double(parts[0]) ?? 0
        let denominator = Double(parts[1]) ?? 0
        return denominator > 0 ? numerator / denominator : 0
    }
}

public enum Ffmpeg {
    public static let preamble = ["-hide_banner", "-loglevel", "error", "-nostdin", "-progress", "pipe:1", "-y"]
    public static let evenDimensions = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    public static func run(_ arguments: [String], _ progress: TaskProgress, label: String, duration: Double) async throws {
        try await ProcessRunner.runOrThrow(try Tools.ffmpeg(), arguments, background: true) { line in
            report(line, progress, label: label, duration: duration)
        }
    }

    public static func runEncode(_ encoder: EncoderChoice,
                                 _ progress: TaskProgress, label: String, duration: Double, shortSide: Int,
                                 build: (EncoderChoice, Int) -> [String]) async throws {
        guard let fallback = Encoders.cpuFallback(encoder) else {
            try await runLadder(encoder, progress, label: label, duration: duration, shortSide: shortSide, build: build)
            return
        }

        do {
            try await run(build(encoder, EncodePolicy.ladder(shortSide: shortSide)[0]), progress, label: label, duration: duration)
            return
        } catch is ProcessFailure {
            Encoders.disableHardware()
            progress.warn(Loc.f("msg.hardwareFallback", encoder.name))
        }

        try await runLadder(fallback, progress, label: label, duration: duration, shortSide: shortSide, build: build)
    }

    private static func runLadder(_ encoder: EncoderChoice, _ progress: TaskProgress, label: String, duration: Double,
                                  shortSide: Int, build: (EncoderChoice, Int) -> [String]) async throws {
        let rungs = EncodePolicy.ladder(shortSide: shortSide)
        for (attempt, threads) in rungs.enumerated() {
            do {
                try await run(build(encoder, threads), progress, label: label, duration: duration)
                EncodePolicy.recordSuccess(threads: threads)
                return
            } catch let failure as ProcessFailure where failure.crashed && attempt < rungs.count - 1 {
                progress.status("\(label) - Retrying on \(rungs[attempt + 1]) threads")
            }
        }
    }

    private static func report(_ line: String, _ progress: TaskProgress, label: String, duration: Double) {
        let key = "out_time_us="
        guard duration > 0, line.hasPrefix(key), let microseconds = Int64(line.dropFirst(key.count)),
              microseconds >= 0 else { return }
        let done = min(max(Double(microseconds) / 1_000_000 / duration, 0), 1)
        progress.status("\(label) - \(Formatting.wholePercent(done))")
    }
}
