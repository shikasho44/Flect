import Foundation
import FlectCore
import FlectKit

enum InspectArchiveEvals {
    static func value(_ report: FileReport, _ label: String) -> String {
        if let fact = (report.overview + report.sections.flatMap(\.rows)).first(where: { $0.label == label }) { return fact.value }
        return ""
    }

    private static func tar(_ arguments: [String]) async throws {
        try await ProcessRunner.runOrThrow(Tools.tar, arguments, environment: ["LC_ALL": "en_US.UTF-8"])
    }

    static func register(_ suite: Suite) {
        suite.test("Analyze lists the largest ZIP entry and reads the JAR manifest") {
            let folder = try Paths.folder("inspect-zip")
            let content = Paths.join(folder, "content")
            try FolderEvals.write(Paths.join(content, "big.txt"), String(repeating: "x", count: 80))
            try FolderEvals.write(Paths.join(content, "small.txt"), "y")
            try FolderEvals.write(Paths.join(content, "META-INF/MANIFEST.MF"),
                                  "Manifest-Version: 1.0\nMain-Class: demo.App\nImplementation-Version: 1.2.3\n")
            try FileManager.default.createDirectory(atPath: Paths.join(content, "demo"), withIntermediateDirectories: true)
            try Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41]).write(to: URL(fileURLWithPath: Paths.join(content, "demo/App.class")))

            let zipPath = Paths.join(folder, "pack.zip")
            try await tar(["-c", "-f", zipPath, "--format", "zip", "--options", "zip:compression=store", "-C", content,
                           "big.txt", "small.txt"])
            let jarPath = Paths.join(folder, "app.jar")
            try await tar(["-c", "-f", jarPath, "--format", "zip", "--options", "zip:compression=deflate", "-C", content,
                           "META-INF/MANIFEST.MF", "demo/App.class"])

            let zip = try await Examine.inspect(zipPath)
            try expect(value(zip, "Contents") == "ZIP", "contents \(value(zip, "Contents"))")
            try expect(value(zip, "Files") == "2", "files \(value(zip, "Files"))")
            try expect(value(zip, "Largest items").hasPrefix("80 B  big.txt"), "largest \(value(zip, "Largest items"))")
            try expect(value(zip, "Encrypted") == "No", "encrypted \(value(zip, "Encrypted"))")
            try expect(zip.alerts.isEmpty, "alerts \(zip.alerts)")

            let jar = try await Examine.inspect(jarPath)
            try expect(value(jar, "Contents") == "JAR", "contents \(value(jar, "Contents"))")
            try expect(value(jar, "Main class") == "demo.App", "main class \(value(jar, "Main class"))")
            try expect(value(jar, "Version") == "1.2.3", "version \(value(jar, "Version"))")
            try expect(value(jar, "Bytecode") == "65 (Java 21)", "bytecode \(value(jar, "Bytecode"))")
            try expect(value(jar, "Signed") == "No", "signed \(value(jar, "Signed"))")
            try expect(value(jar, "Class files") == "1" && value(jar, "Other entries") == "0", "\(jar.sections)")

            let locked = Paths.join(folder, "locked.zip")
            try await tar(["-c", "-f", locked, "--format", "zip", "--options", "zip:encryption=zipcrypt", "--passphrase", "flect",
                           "-C", content, "big.txt"])
            let secret = try await Examine.inspect(locked)
            try expect(value(secret, "Encrypted") == "Yes", "encrypted \(value(secret, "Encrypted"))")
        }

        suite.test("Analyze lists a tar.gz and a bare gzip") {
            let folder = try Paths.folder("inspect-targz")
            let content = Paths.join(folder, "content")
            try FolderEvals.write(Paths.join(content, "docs/large file.txt"), String(repeating: "a", count: 5000))
            try FolderEvals.write(Paths.join(content, "note.txt"), "hello")
            let bundle = Paths.join(folder, "bundle.tar.gz")
            try await tar(["-c", "-z", "-f", bundle, "--format", "pax", "-C", content, "docs", "note.txt"])

            let report = try await Examine.inspect(bundle)
            try expect(value(report, "Contents") == "TAR.GZ", "contents \(value(report, "Contents"))")
            try expect(value(report, "Format") == "TAR.GZ", "format \(value(report, "Format"))")
            try expect(value(report, "Files") == "2" && value(report, "Folders") == "1",
                       "files \(value(report, "Files")) folders \(value(report, "Folders"))")
            try expect(value(report, "Uncompressed") == "4.89 KB", "uncompressed \(value(report, "Uncompressed"))")
            try expect(value(report, "Largest items").hasPrefix("4.88 KB  docs/large file.txt"),
                       "largest \(value(report, "Largest items"))")
            try expect(value(report, "Encrypted") == "No", "encrypted \(value(report, "Encrypted"))")
            try expect(report.alerts.isEmpty, "alerts \(report.alerts)")

            let note = Paths.join(folder, "note.txt")
            try FolderEvals.write(note, String(repeating: "note ", count: 400))
            try await ProcessRunner.runOrThrow("/usr/bin/gzip", ["-k", note])
            let gzip = try await Examine.inspect(note + ".gz")
            try expect(value(gzip, "Contents") == "GZIP", "contents \(value(gzip, "Contents"))")
            try expect(value(gzip, "Uncompressed") == "1.95 KB", "uncompressed \(value(gzip, "Uncompressed"))")
            try expect(value(gzip, "Largest items") == "1.95 KB  note.txt", "largest \(value(gzip, "Largest items"))")
        }

        suite.test("Analyze reads MP4 streams") {
            let folder = try Paths.folder("inspect-media")
            let clip = try await Fixtures.copy("clip.mp4", to: folder)
            let report = try await Examine.inspect(clip)
            try expect(value(report, "Contents") == "MP4", "contents \(value(report, "Contents"))")
            try expect(report.alerts.isEmpty, "alerts \(report.alerts)")
            try expect(value(report, "Duration") == "0:04.0", "duration \(value(report, "Duration"))")
            try expect(report.sections.map(\.title).starts(with: ["Media", "Video 1", "Audio 1"]),
                       "sections \(report.sections.map(\.title))")
            let video = report.sections[1].rows
            let audio = report.sections[2].rows
            func row(_ rows: [FileFact], _ label: String) -> String { rows.first { $0.label == label }?.value ?? "" }
            try expect(row(video, "Codec").hasPrefix("h264 ("), "codec \(row(video, "Codec"))")
            try expect(row(video, "Resolution") == "640 x 360", "resolution \(row(video, "Resolution"))")
            try expect(row(video, "Frame rate") == "30 fps", "fps \(row(video, "Frame rate"))")
            try expect(row(video, "Pixel format") == "yuv420p", "pixel format \(row(video, "Pixel format"))")
            try expect(row(video, "Display size").isEmpty && row(video, "Rotation").isEmpty, "\(video)")
            try expect(row(audio, "Codec").hasPrefix("aac ("), "codec \(row(audio, "Codec"))")
            try expect(row(audio, "Sample rate") == Formatting.count(44_100) + " Hz", "sample rate \(row(audio, "Sample rate"))")
            try expect(row(audio, "Channels").hasPrefix("1"), "channels \(row(audio, "Channels"))")

            let portrait = try await Examine.inspect(try await Fixtures.copy("portrait.mp4", to: folder))
            let turned = portrait.sections.first { $0.title == "Video 1" }?.rows ?? []
            try expect(row(turned, "Resolution") == "1280 x 720" && row(turned, "Display size") == "720 x 1280",
                       "\(turned)")
            try expect(row(turned, "Rotation").hasSuffix(" degrees"), "rotation \(row(turned, "Rotation"))")

            let mkv = Paths.join(folder, "clip.mkv")
            try await ProcessRunner.runOrThrow(try Tools.ffmpeg(), ["-hide_banner", "-loglevel", "error", "-y", "-i", clip, "-c", "copy", mkv])
            let matroska = try await Examine.inspect(mkv)
            try expect(value(matroska, "Contents") == "MKV" && matroska.alerts.isEmpty,
                       "contents \(value(matroska, "Contents")) alerts \(matroska.alerts)")
        }
    }
}
