import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import FlectCore
import FlectKit

struct EvalFailure: Error, CustomStringConvertible {
    let description: String
}

struct Skip: Error {
    let reason: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String,
            line: Int = #line) throws {
    if try !condition() { throw EvalFailure(description: "line \(line): \(message())") }
}

final class RecordingProgress: TaskProgress {
    private let lock = NSLock()
    private(set) var infos: [String] = []
    private(set) var warnings: [String] = []
    private(set) var errors: [String] = []
    private(set) var statuses: [String] = []

    func status(_ text: String) { lock.withLock { statuses.append(text) } }
    func step(_ done: Int, _ total: Int) {}
    func indeterminate() {}
    func info(_ message: String) { lock.withLock { infos.append(message) } }
    func warn(_ message: String) { lock.withLock { warnings.append(message) } }
    func error(_ message: String) { lock.withLock { errors.append(message) } }
}

final class ScriptedInteraction: Interaction {
    var pixels: PixelTarget?
    var targetBytes: Int64?
    var trim: TrimRange?
    var thumbnail: Double?
    var rename: RenamePlan?
    var duplicates: DuplicateMode?
    var pdfOrder: (([String]) -> [String])?
    var confirmation = true
    var shownText: String?
    var analyzed: AnalyzeReport?
    var clipboard: String?
    var reported: [String] = []

    func askPixels() async -> PixelTarget? { pixels }
    func askTargetBytes(largest: Int64) async -> Int64? { targetBytes }
    func askTrim(path: String, duration: Double) async -> TrimRange? { trim }
    func askThumbnail(path: String, duration: Double) async -> Double? { thumbnail }
    func askRename(sampleExtension: String) async -> RenamePlan? { rename }
    func askDuplicates(_ groups: [[ScannedFile]]) async -> DuplicateMode? { duplicates }
    func askPdfOrder(_ paths: [String]) async -> [String]? { pdfOrder.map { $0(paths) } ?? paths }
    func confirm(_ message: String) async -> Bool { confirmation }
    func reportError(_ message: String) async { reported.append(message) }
    func showText(title: String, text: String) async { shownText = text }
    func showAnalyze(_ report: AnalyzeReport) async { analyzed = report }
    func showPdfPreview(path: String) async {}
    func copyToClipboard(_ text: String) async -> Bool {
        clipboard = text
        return true
    }
}

enum Harness {
    @discardableResult
    static func run(_ verb: String, _ paths: [String], ui: ScriptedInteraction = ScriptedInteraction(),
                    expectClean: Bool = true) async throws -> (RecordingProgress, FlectTask) {
        guard let request = Request(verb: verb, paths: paths) else { throw EvalFailure(description: "bad request \(verb)") }
        guard let task = Factory.create(request) else { throw EvalFailure(description: "unknown task \(verb)") }
        let progress = RecordingProgress()
        guard await task.scoped({ await task.configure(ui) }) else {
            throw EvalFailure(description: "configure declined for \(verb)")
        }
        try await task.scoped { try await task.run(progress) }
        await task.scoped { await task.present(ui) }
        if expectClean, !progress.errors.isEmpty {
            throw EvalFailure(description: "\(verb) reported: \(progress.errors.joined(separator: " | "))")
        }
        return (progress, task)
    }

    static func useSettings(_ change: (inout Settings) -> Void = { _ in }) {
        Settings.reset()
        var settings = Settings()
        change(&settings)
        settings.save()
    }
}

enum Paths {
    static var root = ""

    static func folder(_ name: String) throws -> String {
        let path = (root as NSString).appendingPathComponent(name)
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func join(_ folder: String, _ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    static func size(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    static func listing(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }
}

enum Inspect {
    static func type(_ path: String) -> String? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    static func frames(_ path: String) -> Int {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    static func image(_ path: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw EvalFailure(description: "cannot read image \(path)")
        }
        return image
    }

    static func size(_ path: String) throws -> (Int, Int) {
        let image = try image(path)
        return (image.width, image.height)
    }

    static func properties(_ path: String) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }

    static func pixel(_ path: String, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
        let image = try image(path)
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (data[0], data[1], data[2], data[3])
    }
}

enum Fixtures {
    static let ocrText = "FLECT OCR 2026"
    static let speechText = "Hello world. This is a subtitle test for Flect."
    static var masters = ""

    static func copy(_ name: String, to folder: String, as rename: String? = nil) async throws -> String {
        let master = Paths.join(masters, name)
        if !Paths.exists(master) { try await create(name, master) }
        let target = Paths.join(folder, rename ?? name)
        try? FileManager.default.removeItem(atPath: target)
        try FileManager.default.copyItem(atPath: master, toPath: target)
        return target
    }

    private static func ffmpeg(_ arguments: [String]) async throws {
        try await ProcessRunner.runOrThrow(try Tools.ffmpeg(), ["-hide_banner", "-loglevel", "error", "-y"] + arguments)
    }

    private static func create(_ name: String, _ path: String) async throws {
        switch name {
        case "clip.mp4": try await clip(path, 640, 360)
        case "wide.mp4": try await clip(path, 1280, 720)
        case "portrait.mp4":
            let wide = Paths.join(masters, "wide.mp4")
            if !Paths.exists(wide) { try await clip(wide, 1280, 720) }
            try await ffmpeg(["-display_rotation", "90", "-i", wide, "-c", "copy", path])
        case "tone.wav":
            try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=660:sample_rate=44100:duration=3", "-ac", "2", "-c:a", "pcm_s16le", path])
        case "tone.mp3":
            try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=660:sample_rate=44100:duration=3", "-ac", "2",
                              "-c:a", "libmp3lame", "-b:a", "128k", path])
        case "photo.jpg": try photo(path)
        case "rotated.jpg": try rotatedPhoto(path)
        case "noise.jpg": try noise(path, type: "public.jpeg")
        case "noise.png": try noise(path, type: "public.png")
        case "alpha.png": try alpha(path)
        case "green.png": try green(path)
        case "animated.gif": try animated(path)
        case "vector.svg":
            try Data(("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"80\">"
                + "<rect width=\"120\" height=\"80\" fill=\"#1e90ff\"/>"
                + "<circle cx=\"60\" cy=\"40\" r=\"25\" fill=\"#ffd700\"/></svg>").utf8).write(to: URL(fileURLWithPath: path))
        case "alpha.pdf": try pdf(path, "alpha")
        case "bravo.pdf": try pdf(path, "bravo")
        case "ocr.png": try textImage(path)
        case "speech.wav": try await speech(path)
        default: throw EvalFailure(description: "unknown fixture \(name)")
        }
    }

    private static func clip(_ path: String, _ width: Int, _ height: Int) async throws {
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=\(width)x\(height):rate=30:duration=4",
                          "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=4",
                          "-c:v", "libx264", "-preset", "veryfast", "-g", "30", "-keyint_min", "30", "-pix_fmt", "yuv420p",
                          "-c:a", "aac", "-b:a", "128k", "-shortest", "-movflags", "+faststart", path])
    }

    static func canvas(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    static func save(_ image: CGImage, _ path: String, type: String, properties: [String: Any] = [:]) throws {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type as CFString, 1, nil) else {
            throw EvalFailure(description: "cannot create \(path)")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EvalFailure(description: "cannot write \(path)") }
    }

    private static func photoImage() -> CGImage {
        canvas(400, 300) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            context.setFillColor(CGColor(srgbRed: 1, green: 0.65, blue: 0, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: 320, height: 220))
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 280, width: 20, height: 20))
        }
    }

    private static func exif(orientation: Int) -> [String: Any] {
        [
            kCGImagePropertyOrientation as String: orientation,
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "FlectCam",
                kCGImagePropertyTIFFSoftware as String: "Flect Evals",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifUserComment as String: "evals comment",
                kCGImagePropertyExifDateTimeOriginal as String: "2026:10:20 12:00:00",
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 35.6833,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 139.7667,
                kCGImagePropertyGPSLongitudeRef as String: "E",
            ],
        ]
    }

    private static func photo(_ path: String) throws {
        try save(photoImage(), path, type: "public.jpeg", properties: exif(orientation: 1))
    }

    private static func rotatedPhoto(_ path: String) throws {
        try save(photoImage(), path, type: "public.jpeg", properties: exif(orientation: 6))
    }

    private static func noise(_ path: String, type: String) throws {
        var generator = SystemRandomNumberGenerator()
        let width = 1600
        let height = 1200
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = UInt8.random(in: 0...255, using: &generator)
            pixels[index + 1] = UInt8.random(in: 0...255, using: &generator)
            pixels[index + 2] = UInt8.random(in: 0...255, using: &generator)
        }
        let image = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        }
        try save(image, path, type: type, properties: type == "public.jpeg" ? [kCGImageDestinationLossyCompressionQuality as String: 0.95] : [:])
    }

    private static func alpha(_ path: String) throws {
        let image = canvas(300, 200) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 50, y: 50, width: 200, height: 100))
        }
        try save(image, path, type: "public.png")
    }

    private static func green(_ path: String) throws {
        let image = canvas(200, 200) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fillEllipse(in: CGRect(x: 60, y: 60, width: 80, height: 80))
        }
        try save(image, path, type: "public.png")
    }

    private static func animated(_ path: String) throws {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                "com.compuserve.gif" as CFString, 3, nil) else {
            throw EvalFailure(description: "cannot create gif")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary as String:
                                                          [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        for color in [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)] {
            let frame = canvas(120, 80) { context in
                context.setFillColor(color)
                context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            }
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary as String:
                                                                [kCGImagePropertyGIFDelayTime as String: 0.2]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw EvalFailure(description: "cannot write gif") }
    }

    private static func draw(_ text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func pdf(_ path: String, _ label: String) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else {
            throw EvalFailure(description: "cannot create pdf")
        }
        for number in 1...2 {
            context.beginPDFPage(nil)
            draw("\(label) page \(number)", size: 18, at: CGPoint(x: 72, y: 720), in: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func textImage(_ path: String) throws {
        let image = canvas(900, 200) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 200))
            draw(ocrText, size: 72, at: CGPoint(x: 40, y: 70), in: context)
        }
        try save(image, path, type: "public.png")
    }

    private static func speech(_ path: String) async throws {
        let aiff = path + ".aiff"
        defer { try? FileManager.default.removeItem(atPath: aiff) }
        let result = try await ProcessRunner.run("/usr/bin/say", ["-v", "Samantha", "-o", aiff, speechText])
        if !result.succeeded {
            try await ProcessRunner.runOrThrow("/usr/bin/say", ["-o", aiff, speechText])
        }
        try await ffmpeg(["-i", aiff, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", path])
    }
}
