import Foundation
import FlectCore
import FlectKit

enum VideoEvals {
    static func stream(_ path: String, _ selector: String, _ entries: String) async throws -> [String: String] {
        let result = try await ProcessRunner.runOrThrow(try Tools.ffprobe(), [
            "-v", "error", "-select_streams", selector, "-show_entries", entries, "-of", "default=noprint_wrappers=1", path,
        ])
        var values: [String: String] = [:]
        for line in result.standardOutput.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }

    static func register(_ suite: Suite) {
        suite.test("Video resize halves the frame") {
            Harness.useSettings()
            let folder = try Paths.folder("video-resize")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            try await Harness.run("video.resize?scale=50", [input])
            let info = try await Media.read(Paths.join(folder, "clip_resized.mp4"))
            try expect(info.width == 320 && info.height == 180, "\(info.width)x\(info.height)")
        }

        suite.test("Video resize to custom pixels") {
            Harness.useSettings()
            let folder = try Paths.folder("video-resize-custom")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            let ui = ScriptedInteraction()
            ui.pixels = PixelTarget(width: 0, height: 240, keepAspect: true)
            try await Harness.run("video.resize?scale=custom", [input], ui: ui)
            let info = try await Media.read(Paths.join(folder, "clip_resized.mp4"))
            try expect(info.width == 426 && info.height == 240, "\(info.width)x\(info.height)")
        }

        suite.test("Video rotate 90 turns the frame") {
            Harness.useSettings()
            let folder = try Paths.folder("video-rotate")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            try await Harness.run("video.rotate?deg=90", [input])
            let info = try await Media.read(Paths.join(folder, "clip_rotated.mp4"))
            try expect(info.width == 360 && info.height == 640, "\(info.width)x\(info.height)")
        }

        suite.test("Video rotate by a fractional angle widens the frame") {
            Harness.useSettings()
            let folder = try Paths.folder("video-rotate-angle")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            try await Harness.run("video.rotate?deg=12.5", [input])
            let info = try await Media.read(Paths.join(folder, "clip_rotated.mp4"))
            try expect(info.width > 640 && info.height > 360 && info.width % 2 == 0 && info.height % 2 == 0,
                       "\(info.width)x\(info.height)")
        }

        for (target, codec) in [("MKV", "h264"), ("MOV", "h264"), ("FLV", "h264"), ("WEBM", "vp9")] {
            suite.test("Video convert to \(target) changes the container") {
                Harness.useSettings()
                let folder = try Paths.folder("video-convert-\(target)")
                let input = try await Fixtures.copy("clip.mp4", to: folder)
                try await Harness.run("video.convert?to=\(target)", [input])
                let info = try await Media.read(Paths.join(folder, "clip.\(target.lowercased())"))
                try expect(info.videoCodec == codec, "codec \(info.videoCodec ?? "-")")
                try expect(info.hasAudio, "audio missing")
            }
        }

        suite.test("Video convert to AVI writes a playable file") {
            Harness.useSettings()
            let folder = try Paths.folder("video-convert-avi")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            try await Harness.run("video.convert?to=AVI", [input])
            let info = try await Media.read(Paths.join(folder, "clip.avi"))
            try expect(info.duration > 3.5 && info.duration < 4.5 && info.hasVideo, "duration \(info.duration)")
        }

        suite.test("Video convert to MOV falls back to H.264 for VP9 settings") {
            Harness.useSettings { $0.video.codec = .vp9 }
            let folder = try Paths.folder("video-convert-mov-vp9")
            let input = try await Fixtures.copy("clip.mp4", to: folder, as: "clip.mkv")
            let source = Paths.join(folder, "source.webm")
            try await ProcessRunner.runOrThrow(try Tools.ffmpeg(), ["-y", "-loglevel", "error", "-i", input, "-t", "1",
                                                                   "-c:v", "libvpx-vp9", "-deadline", "realtime", "-c:a", "libopus", source])
            try await Harness.run("video.convert?to=MOV", [source])
            let info = try await Media.read(Paths.join(folder, "source.mov"))
            try expect(info.videoCodec == "h264", "codec \(info.videoCodec ?? "-")")
        }

        suite.test("Video encoded as H.265 is tagged for QuickTime") {
            Harness.useSettings { $0.video.codec = .h265 }
            let folder = try Paths.folder("video-hevc")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            try await Harness.run("video.resize?scale=50", [input])
            let values = try await stream(Paths.join(folder, "clip_resized.mp4"), "v:0", "stream=codec_name,codec_tag_string")
            try expect(values["codec_name"] == "hevc" && values["codec_tag_string"] == "hvc1", "\(values)")
        }

        suite.test("Video convert with VideoToolbox encodes on the hardware") {
            Harness.useSettings { $0.video.hardware = .videoToolbox }
            let folder = try Paths.folder("video-videotoolbox")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            try await Harness.run("video.resize?scale=50", [input])
            let values = try await stream(Paths.join(folder, "clip_resized.mp4"), "v:0", "stream=codec_name,width")
            try expect(values["codec_name"] == "h264" && values["width"] == "320", "\(values)")
        }

        suite.test("Video convert to M4A keeps only the sound") {
            Harness.useSettings()
            let folder = try Paths.folder("video-convert-m4a")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            try await Harness.run("video.convert?to=M4A", [input])
            let info = try await Media.read(Paths.join(folder, "clip.m4a"))
            try expect(!info.hasVideo && info.audioCodec == "aac", "video \(info.hasVideo) audio \(info.audioCodec ?? "-")")
        }

        suite.test("Video convert to GIF animates") {
            Harness.useSettings()
            let folder = try Paths.folder("video-gif")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            try await Harness.run("video.convert?to=GIF", [input])
            let output = Paths.join(folder, "clip.gif")
            try expect(Inspect.frames(output) > 10, "frames \(Inspect.frames(output))")
            try expect(Paths.listing(folder).allSatisfy { !$0.hasPrefix(".Flect-") }, "palette left behind")
        }

        for accuracy in [TrimAccuracy.keyframe, .exact] {
            suite.test("Video trim keeps the chosen range (\(accuracy.rawValue))") {
                Harness.useSettings { $0.video.trim.accuracy = accuracy }
                let folder = try Paths.folder("video-trim-\(accuracy.rawValue)")
                let input = try await Fixtures.copy("clip.mp4", to: folder)
                let ui = ScriptedInteraction()
                ui.trim = TrimRange(start: 1, end: 3)
                try await Harness.run("video.trim", [input], ui: ui)
                let info = try await Media.read(Paths.join(folder, "clip_trimmed.mp4"))
                try expect(abs(info.duration - 2) < 0.6, "duration \(info.duration)")
            }
        }

        for (format, maxWidth, name, width) in [(ThumbnailFormat.png, 0, "clip_thumbnail.png", 640),
                                                (.jpg, 320, "clip_thumbnail.jpg", 320)] {
            suite.test("Video thumbnail exports one frame (\(format.rawValue))") {
                Harness.useSettings { settings in
                    settings.video.thumbnail.format = format
                    settings.video.thumbnail.maxWidth = maxWidth
                }
                let folder = try Paths.folder("video-thumbnail-\(format.rawValue)")
                let input = try await Fixtures.copy("clip.mp4", to: folder)
                let ui = ScriptedInteraction()
                ui.thumbnail = 1.5
                try await Harness.run("video.thumbnail", [input], ui: ui)
                let (actual, _) = try Inspect.size(Paths.join(folder, name))
                try expect(actual == width, "width \(actual)")
            }
        }

        suite.test("Video compress keeps a phone video upright with square pixels") {
            Harness.useSettings()
            let folder = try Paths.folder("video-compress-portrait")
            let input = try await Fixtures.copy("portrait.mp4", to: folder)
            let (progress, _) = try await Harness.run("video.compress?bytes=153600", [input])
            let output = Paths.join(folder, "portrait_compressed.mp4")
            let values = try await stream(output, "v:0", "stream=width,height,sample_aspect_ratio")
            let width = Int(values["width"] ?? "") ?? 0
            let height = Int(values["height"] ?? "") ?? 0
            try expect(width < height, "\(values)")
            try expect(values["sample_aspect_ratio"] == "1:1", "\(values)")
            try expect(Paths.size(output) <= 153_600 || !progress.warnings.isEmpty, "size \(Paths.size(output))")
        }

        suite.test("Video compress with the Discord preset uses the saved limit") {
            Harness.useSettings { $0.video.presets.compressDiscord = 200 * 1024 }
            let folder = try Paths.folder("video-compress-discord")
            let input = try await Fixtures.copy("wide.mp4", to: folder)
            let (progress, _) = try await Harness.run("video.compress?preset=discord", [input])
            let output = Paths.join(folder, "wide_compressed.mp4")
            try expect(Paths.size(output) <= 200 * 1024 || !progress.warnings.isEmpty, "size \(Paths.size(output))")
            try expect(Paths.listing(folder).allSatisfy { !$0.hasPrefix(".Flect-") }, "scratch left behind")
        }

        suite.test("Video compress into WebM swaps the codecs") {
            Harness.useSettings { settings in
                settings.video.container = .webM
                settings.video.codec = .h264
            }
            let folder = try Paths.folder("video-compress-webm")
            let input = try await Fixtures.copy("wide.mp4", to: folder)
            try await Harness.run("video.compress?bytes=\(400 * 1024)", [input])
            let info = try await Media.read(Paths.join(folder, "wide_compressed.webm"))
            try expect(info.videoCodec == "vp9" && info.audioCodec == "opus", "\(info.videoCodec ?? "-") \(info.audioCodec ?? "-")")
        }

        suite.test("Video compress leaves small files alone") {
            Harness.useSettings()
            let folder = try Paths.folder("video-compress-small")
            let input = try await Fixtures.copy("clip.mp4", to: folder)
            let (progress, _) = try await Harness.run("video.compress?bytes=\(100 * 1024 * 1024)", [input])
            try expect(Paths.listing(folder) == ["clip.mp4"], "\(Paths.listing(folder))")
            try expect(!progress.infos.isEmpty, "no info message")
        }

        for (target, codec) in [("MP3", "mp3"), ("M4A", "aac"), ("WAV", "pcm_s16le"), ("AIF", "pcm_s16be"),
                                ("AIFF", "pcm_s16be"), ("AAC", "aac"), ("OGG", "vorbis"), ("WMA", "wmav2")] {
            suite.test("Video extract audio writes \(target)") {
                Harness.useSettings()
                let folder = try Paths.folder("video-extract-\(target)")
                let input = try await Fixtures.copy("clip.mp4", to: folder)
                try await Harness.run("video.extractAudio?to=\(target)", [input])
                let info = try await Media.read(Paths.join(folder, "clip.\(target.lowercased())"))
                try expect(info.audioCodec == codec && !info.hasVideo, "codec \(info.audioCodec ?? "-")")
            }
        }

        for (target, codec) in [("M4A", "aac"), ("WAV", "pcm_s16le"), ("OGG", "vorbis"), ("WMA", "wmav2")] {
            suite.test("Audio convert from MP3 to \(target)") {
                Harness.useSettings()
                let folder = try Paths.folder("audio-convert-\(target)")
                let input = try await Fixtures.copy("tone.mp3", to: folder)
                try await Harness.run("audio.convert?to=\(target)", [input])
                let info = try await Media.read(Paths.join(folder, "tone.\(target.lowercased())"))
                try expect(info.audioCodec == codec, "codec \(info.audioCodec ?? "-")")
            }
        }

        suite.test("Audio convert from WAV to MP3") {
            Harness.useSettings()
            let folder = try Paths.folder("audio-convert-mp3")
            let input = try await Fixtures.copy("tone.wav", to: folder)
            try await Harness.run("audio.convert?to=MP3", [input])
            let info = try await Media.read(Paths.join(folder, "tone.mp3"))
            try expect(info.audioCodec == "mp3", "codec \(info.audioCodec ?? "-")")
        }

        suite.test("Cancelling an encode leaves nothing behind") {
            Harness.useSettings { $0.video.priority = .quality }
            let folder = try Paths.folder("video-cancel")
            let input = try await Fixtures.copy("wide.mp4", to: folder)
            let request = Request(verb: "video.rotate?deg=33", paths: [input])!
            let task = Factory.create(request)!
            _ = await task.configure(ScriptedInteraction())
            let progress = RecordingProgress()
            let running = Task { try await task.run(progress) }
            try await Task.sleep(nanoseconds: 700_000_000)
            running.cancel()
            _ = try? await running.value
            try await Task.sleep(nanoseconds: 500_000_000)
            try expect(Paths.listing(folder) == ["wide.mp4"], "\(Paths.listing(folder))")
        }

        suite.test("Subtitles transcribe speech with Apple Speech", category: "speech") {
            Harness.useSettings { settings in
                settings.video.subtitles.language = "en"
                settings.video.subtitles.output = .srt
            }
            let folder = try Paths.folder("subtitles")
            let input = try await Fixtures.copy("speech.wav", to: folder)
            let (progress, _) = try await Harness.run("audio.subtitles", [input], expectClean: false)
            if !progress.errors.isEmpty { throw EvalFailure(description: progress.errors.joined(separator: " | ")) }
            let text = try String(contentsOfFile: Paths.join(folder, "speech.srt"), encoding: .utf8)
            try expect(text.contains("-->") && text.lowercased().contains("subtitle"), text)
        }
    }
}
