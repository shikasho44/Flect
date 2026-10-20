import Foundation
import FlectKit

class VideoTask: BatchTask {
    var preferences: VideoSettings { Settings.current.video }

    func videoEncoder(_ encoder: EncoderChoice, extension ext: String) -> [String] {
        Encoders.quality(encoder, preferences.priority) + Encoders.pixelFormat(encoder) + Encoders.tags(encoder, extension: ext)
    }

    static func audioCodec(_ ext: String) -> [String] {
        switch ext {
        case ".webm": return ["-c:a", "libopus"]
        case ".avi": return ["-c:a", "libmp3lame"]
        default: return ["-c:a", "aac"]
        }
    }

    static func audioEncoder(_ ext: String) -> [String] { audioCodec(ext) + ["-b:a", "192k"] }

    func filter(_ input: String, _ output: String, _ filter: String, _ info: MediaInfo,
                _ progress: TaskProgress, label: String) async throws {
        let ext = "." + (output as NSString).pathExtension.lowercased()

        func build(_ audio: [String], _ encoder: EncoderChoice, _ threads: Int) -> [String] {
            Ffmpeg.preamble + ["-i", input, "-vf", filter, "-threads", String(threads)]
                + videoEncoder(encoder, extension: ext) + audio + [output]
        }

        try await OutputPath.producing(output) {
            do {
                try await Ffmpeg.runEncode(Encoders.forContainer(ext, preferences), progress, label: label,
                                           duration: info.duration, shortSide: info.shortSide) { encoder, threads in
                    build(["-c:a", "copy"], encoder, threads)
                }
            } catch is ProcessFailure {
                OutputPath.safeDelete(output)
                try await Ffmpeg.runEncode(Encoders.forContainer(ext, preferences), progress, label: label,
                                           duration: info.duration, shortSide: info.shortSide) { encoder, threads in
                    build(VideoTask.audioEncoder(ext), encoder, threads)
                }
            }
        }
    }

    func requireVideo(_ info: MediaInfo) throws {
        if !info.hasVideo { throw FlectError(Loc.t("msg.noVideoStream")) }
    }

    func readSingle(_ ui: Interaction) async -> (String, MediaInfo)? {
        guard let path = request.paths.first else { return nil }
        guard let info = try? await Media.read(path) else {
            await ui.reportError(Loc.t("msg.noDuration"))
            return nil
        }
        if !info.hasVideo {
            await ui.reportError(Loc.t("msg.noVideoStream"))
            return nil
        }
        if info.duration <= 0 {
            await ui.reportError(Loc.t("msg.noDuration"))
            return nil
        }
        return (path, info)
    }
}

final class VideoResize: VideoTask {
    private var pixels: PixelTarget?
    private var percent = 50.0

    override var title: String { Loc.t("menu.video.resize") }

    override func configure(_ ui: Interaction) async -> Bool {
        let scale = request["scale"]
        if scale?.lowercased() != "custom" {
            if let scale, let value = Double(scale), value > 0 { percent = value }
            return true
        }
        if let width = request["w"].flatMap(Int.init), let height = request["h"].flatMap(Int.init) {
            pixels = PixelTarget(width: width, height: height, keepAspect: request["keep"] != "0")
            return true
        }
        pixels = await ui.askPixels()
        return pixels != nil
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let info = try await Media.read(path)
        try requireVideo(info)
        let output = OutputPath.derive(path, suffix: "_resized")
        try await filter(path, output, scaleFilter(), info, progress, label: Loc.t("label.resizing"))
    }

    private func scaleFilter() -> String {
        guard let pixels else {
            let factor = Formatting.number(percent / 100)
            return "scale=trunc(iw*\(factor)/2)*2:trunc(ih*\(factor)/2)*2"
        }
        let width = pixels.width
        let height = pixels.height
        if width > 0, height > 0 {
            return pixels.keepAspect
                ? "scale=\(width):\(height):force_original_aspect_ratio=decrease," + Ffmpeg.evenDimensions
                : "scale=\(width - width % 2):\(height - height % 2)"
        }
        return width > 0 ? "scale=\(width - width % 2):-2" : "scale=-2:\(height - height % 2)"
    }
}

final class VideoRotate: VideoTask {
    private var degrees = 90.0

    override var title: String { Loc.t("menu.video.rotate") }

    override func configure(_ ui: Interaction) async -> Bool {
        if let text = request["deg"], let value = Double(text), value.isFinite { degrees = value }
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let info = try await Media.read(path)
        try requireVideo(info)
        let output = OutputPath.derive(path, suffix: "_rotated")
        try await filter(path, output, rotateFilter(), info, progress, label: Loc.t("label.rotating"))
    }

    private func rotateFilter() -> String {
        let turn = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        if turn == 90 { return "transpose=1," + Ffmpeg.evenDimensions }
        if turn == 180 { return "transpose=1,transpose=1," + Ffmpeg.evenDimensions }
        if turn == 270 { return "transpose=2," + Ffmpeg.evenDimensions }

        let angle = Formatting.number(degrees) + "*PI/180"
        return "rotate=\(angle):ow=rotw(\(angle)):oh=roth(\(angle)):fillcolor=\(ColorText.forFfmpeg(preferences.rotateFillColor)),"
            + Ffmpeg.evenDimensions
    }
}

final class VideoConvert: VideoTask {
    private var target = "MP4"

    override var title: String { Loc.t("menu.video.convert") }

    override func configure(_ ui: Interaction) async -> Bool {
        target = (request["to"] ?? "MP4").uppercased()
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let info = try await Media.read(path)

        if target == "GIF" {
            try requireVideo(info)
            try await toGif(path, info, progress)
            return
        }

        let ext = "." + target.lowercased()
        let output = OutputPath.derive(path, extension: ext)
        let copyArguments = target == "M4A" ? ["-vn", "-c:a", "copy"] : ["-c", "copy"]

        func encodeArguments(_ encoder: EncoderChoice) -> [String] {
            target == "M4A"
                ? ["-vn"] + VideoTask.audioEncoder(ext)
                : videoEncoder(encoder, extension: ext) + VideoTask.audioEncoder(ext)
        }

        try await OutputPath.producing(output) {
            do {
                try await Ffmpeg.run(Ffmpeg.preamble + ["-i", path] + copyArguments + [output], progress,
                                     label: Loc.t("label.remuxing"), duration: info.duration)
                return
            } catch is ProcessFailure {
                OutputPath.safeDelete(output)
            }

            try await Ffmpeg.runEncode(Encoders.forContainer(ext, preferences), progress, label: Loc.t("label.converting"),
                                       duration: info.duration, shortSide: info.shortSide) { encoder, threads in
                Ffmpeg.preamble + ["-i", path, "-threads", String(threads)] + encodeArguments(encoder) + [output]
            }
        }
    }

    private var gifChain: String {
        "fps=\(preferences.gifFps),scale='min(\(preferences.gifMaxWidth),iw)':-2:flags=lanczos"
    }

    private var paletteUse: String {
        switch preferences.gifDither {
        case .none: return "paletteuse=dither=none:diff_mode=rectangle"
        case .floydSteinberg: return "paletteuse=dither=floyd_steinberg:diff_mode=rectangle"
        case .bayer: return "paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
        }
    }

    private func toGif(_ path: String, _ info: MediaInfo, _ progress: TaskProgress) async throws {
        let output = OutputPath.derive(path, extension: ".gif")
        let palette = OutputPath.scratch(beside: output, extension: ".png")
        defer { OutputPath.safeDelete(palette) }

        try await OutputPath.producing(output) {
            try await Ffmpeg.run(Ffmpeg.preamble + ["-i", path, "-vf", "\(gifChain),palettegen=stats_mode=diff", palette],
                                 progress, label: Loc.t("label.buildingPalette"), duration: info.duration)
            try await Ffmpeg.run(Ffmpeg.preamble + ["-i", path, "-i", palette, "-lavfi",
                                                    "\(gifChain)[x];[x][1:v]\(paletteUse)", "-loop", "0", output],
                                 progress, label: Loc.t("label.writingGif"), duration: info.duration)
        }
    }
}

final class VideoTrim: VideoTask {
    private var range: TrimRange?

    override var title: String { Loc.t("menu.video.trim") }

    override func configure(_ ui: Interaction) async -> Bool {
        if let start = request["start"].flatMap(Formatting.parseTimecode),
           let end = request["end"].flatMap(Formatting.parseTimecode) {
            range = TrimRange(start: start, end: end)
            return true
        }
        guard let (path, info) = await readSingle(ui) else { return false }
        range = await ui.askTrim(path: path, duration: info.duration)
        return range != nil
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        guard let range else { return }
        let info = try await Media.read(path)
        try requireVideo(info)

        let start = min(max(range.start, 0), max(0, info.duration - 0.05))
        let end = min(max(range.end, start), info.duration)
        let length = end - start
        if length <= 0 { throw FlectError(Loc.t("dialog.trim.backwards")) }

        let output = OutputPath.derive(path, suffix: "_trimmed")
        let ext = "." + (output as NSString).pathExtension.lowercased()
        let seek = Ffmpeg.preamble + ["-ss", seconds(start), "-i", path, "-t", seconds(length)]

        try await OutputPath.producing(output) {
            if preferences.trim.accuracy == .keyframe {
                try await Ffmpeg.run(seek + ["-c", "copy", "-avoid_negative_ts", "make_zero", output], progress,
                                     label: Loc.t("label.trimming"), duration: length)
            } else {
                try await Ffmpeg.runEncode(Encoders.forContainer(ext, preferences), progress, label: Loc.t("label.trimming"),
                                           duration: length, shortSide: info.shortSide) { encoder, threads in
                    seek + ["-threads", String(threads)] + self.videoEncoder(encoder, extension: ext)
                        + VideoTask.audioEncoder(ext) + [output]
                }
            }
        }
    }

    private func seconds(_ value: Double) -> String {
        Formatting.number((value * 1000).rounded() / 1000)
    }
}

final class VideoThumbnail: VideoTask {
    private var time = 0.0

    override var title: String { Loc.t("menu.video.thumbnail") }

    override func configure(_ ui: Interaction) async -> Bool {
        if let value = request["time"].flatMap(Formatting.parseTimecode) {
            time = value
            return true
        }
        guard let (path, info) = await readSingle(ui) else { return false }
        guard let chosen = await ui.askThumbnail(path: path, duration: info.duration) else { return false }
        time = min(max(chosen, 0), info.duration)
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let info = try await Media.read(path)
        try requireVideo(info)

        let settings = preferences.thumbnail
        let format = settings.format == .jpg ? "jpg" : "png"
        let output = OutputPath.derive(path, suffix: "_thumbnail", extension: "." + format)

        var arguments = Ffmpeg.preamble + ["-ss", Formatting.number((time * 1000).rounded() / 1000), "-i", path, "-frames:v", "1"]
        if settings.maxWidth > 0 { arguments += ["-vf", "scale='min(\(settings.maxWidth),iw)':-2"] }
        if settings.format == .jpg {
            let quality: Int = min(max(settings.quality, 1), 100)
            let scale: Int = 31 - quality * 29 / 100
            arguments += ["-q:v", String(scale)]
        }
        arguments.append(output)

        try await OutputPath.producing(output) {
            try await Ffmpeg.run(arguments, progress, label: Loc.t("label.exporting"), duration: info.duration)
        }
    }
}

final class VideoCompress: VideoTask {
    private var target: Int64 = 0

    override var title: String { Loc.t("menu.video.compress") }

    override func configure(_ ui: Interaction) async -> Bool {
        if request["preset"]?.lowercased() == "discord" {
            target = preferences.presets.compressDiscord
            return true
        }
        let bytes = request["bytes"]
        if bytes?.lowercased() == "custom" {
            guard let answer = await ui.askTargetBytes(largest: largestSelected()) else { return false }
            target = answer
            return true
        }
        target = bytes.flatMap { Int64($0) } ?? 0
        return target > 0
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let original = FileSystem.size(of: path) ?? 0
        if original <= Bitrate.safeTarget(target) {
            progress.info(Loc.f("msg.alreadySmall", fileName(path), Formatting.bytes(original)))
            return
        }

        let info = try await Media.read(path)
        if info.duration <= 0 { throw FlectError(Loc.t("msg.noDuration")) }

        let plan = Planner.build(info, targetBytes: target, container: Containers.resolve(preferences))
        let destination = OutputPath.derive(path, suffix: "_compressed", extension: info.hasVideo ? plan.fileExtension : ".m4a")

        let scratch = try ScratchDirectory(beside: destination)
        defer { scratch.dispose() }
        let pipeline = CompressionPipeline(plan: plan, progress: progress)

        let outcome = info.hasVideo
            ? try await pipeline.run(path, scratch)
            : try await pipeline.runAudioOnlySource(path, scratch)

        try FileManager.default.moveItem(atPath: outcome.path, toPath: destination)

        if outcome.bytes > target {
            progress.warn(Loc.f("msg.overTarget", fileName(path), Formatting.bytes(outcome.bytes), Formatting.bytes(target)))
        }
    }
}

enum AudioFormat {
    static let lossyKbps = 192

    static func fileExtension(_ target: String) -> String { "." + target.lowercased() }

    static func encoder(_ target: String) -> [String] {
        switch target {
        case "MP3": return ["-c:a", "libmp3lame", "-b:a", "\(lossyKbps)k"]
        case "M4A", "AAC": return ["-c:a", "aac", "-b:a", "\(lossyKbps)k"]
        // A fixed 192 kbps is more than libvorbis accepts for low sample rates (a 16 kHz voice memo fails to open the
        // encoder), so use its quality scale: about 192 kbps for 44.1 kHz stereo, and valid for every input.
        case "OGG": return ["-c:a", "libvorbis", "-q:a", "6"]
        case "WMA": return ["-c:a", "wmav2", "-b:a", "\(lossyKbps)k"]
        case "WAV": return ["-c:a", "pcm_s16le"]
        case "AIF", "AIFF": return ["-c:a", "pcm_s16be"]
        default: return ["-c:a", "aac", "-b:a", "\(lossyKbps)k"]
        }
    }

    static func copyable(from target: String) -> String? {
        switch target {
        case "MP3": return "mp3"
        case "M4A", "AAC": return "aac"
        case "OGG": return "vorbis"
        default: return nil
        }
    }
}

final class AudioConvert: BatchTask {
    private var target = "MP3"

    override var title: String { Loc.t("menu.audio.convert") }

    override func configure(_ ui: Interaction) async -> Bool {
        target = (request["to"] ?? "MP3").uppercased()
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let info = try await Media.read(path)
        let output = OutputPath.derive(path, extension: AudioFormat.fileExtension(target))
        try await OutputPath.producing(output) {
            try await Ffmpeg.run(Ffmpeg.preamble + ["-i", path, "-vn"] + AudioFormat.encoder(target) + [output], progress,
                                 label: Loc.f("label.convertingTo", target), duration: info.duration)
        }
    }
}

final class VideoExtractAudio: BatchTask {
    private var target = "MP3"

    override var title: String { Loc.t("menu.video.extractAudio") }

    override func configure(_ ui: Interaction) async -> Bool {
        target = (request["to"] ?? "MP3").uppercased()
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let info = try await Media.read(path)
        if !info.hasAudio { throw FlectError(Loc.t("msg.noAudioTrack")) }

        let output = OutputPath.derive(path, extension: AudioFormat.fileExtension(target))
        let label = Loc.f("label.extracting", target)

        try await OutputPath.producing(output) {
            if let copyable = AudioFormat.copyable(from: target), info.audioCodec?.lowercased() == copyable {
                do {
                    try await Ffmpeg.run(Ffmpeg.preamble + ["-i", path, "-vn", "-c:a", "copy", output], progress,
                                         label: label, duration: info.duration)
                    return
                } catch is ProcessFailure {
                    OutputPath.safeDelete(output)
                }
            }
            try await Ffmpeg.run(Ffmpeg.preamble + ["-i", path, "-vn"] + AudioFormat.encoder(target) + [output], progress,
                                 label: label, duration: info.duration)
        }
    }
}
