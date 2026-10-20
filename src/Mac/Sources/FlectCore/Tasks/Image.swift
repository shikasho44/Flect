import CoreGraphics
import Foundation
import FlectKit

class ImageTask: BatchTask {
    var preferences: ImageSettings { Settings.current.image }

    var suffix: String { "" }

    var outputExtension: String? { nil }

    func transform(_ image: CGImage, output format: ImageFormat) -> CGImage { image }

    func quality(for format: ImageFormat, source path: String) -> Double? {
        switch format {
        case .jpeg:
            if ImageFormat(extension: (path as NSString).pathExtension) == .jpeg, let estimate = JpegQuality.estimate(path) {
                return Double(estimate) / 100
            }
            return nil
        case .webp:
            return Double(min(max(preferences.webpQuality, 1), 100)) / 100
        default:
            return nil
        }
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let output = OutputPath.derive(path, suffix: suffix, extension: outputExtension)
        let format = ImageFormat(extension: (output as NSString).pathExtension) ?? .png
        let loaded = try ImageCodec.load(path)
        try Task.checkCancellation()

        try await OutputPath.producing(output) {
            if loaded.isAnimatedGif, format != .svg {
                if format == .gif {
                    let frames = loaded.frames.map { ImageFrame(image: transform($0.image, output: format), delay: $0.delay) }
                    try ImageCodec.writeAnimatedGif(frames, loopCount: loaded.loopCount, to: output)
                    return
                }
                progress.warn(Loc.f("msg.animatedGifFrame", fileName(path)))
            }
            let image = transform(loaded.upright, output: format)
            try ImageCodec.write(image, to: output, quality: quality(for: format, source: path), metadata: loaded.metadata)
        }
    }
}

final class ImageResize: ImageTask {
    private var pixels: PixelTarget?
    private var percent = 50.0

    override var title: String { Loc.t("menu.image.resize") }
    override var suffix: String { "_resized" }

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

    override func transform(_ image: CGImage, output format: ImageFormat) -> CGImage {
        guard let pixels else { return ImageOps.scaled(image, percent: percent) }
        if pixels.width > 0, pixels.height > 0 {
            return ImageOps.fit(image, width: pixels.width, height: pixels.height, exact: !pixels.keepAspect)
        }
        if pixels.width > 0 {
            let height = Int((Double(image.height) * Double(pixels.width) / Double(image.width)).rounded())
            return ImageOps.resize(image, width: pixels.width, height: height)
        }
        let width = Int((Double(image.width) * Double(pixels.height) / Double(image.height)).rounded())
        return ImageOps.resize(image, width: width, height: pixels.height)
    }
}

final class ImageRotate: ImageTask {
    private var degrees = 90.0

    override var title: String { Loc.t("menu.image.rotate") }
    override var suffix: String { "_rotated" }

    override func configure(_ ui: Interaction) async -> Bool {
        if let text = request["deg"], let value = Double(text), value.isFinite { degrees = value }
        return true
    }

    override func transform(_ image: CGImage, output format: ImageFormat) -> CGImage {
        ImageOps.rotate(image, degrees: degrees, background: format.supportsAlpha ? ImageOps.clear : ImageOps.white)
    }
}

final class ImageConvert: ImageTask {
    private static let iconMaxEdge = 256

    private var target = "PNG"

    override var title: String { Loc.t("menu.image.convert") }
    override var outputExtension: String? { "." + target.lowercased() }

    override func configure(_ ui: Interaction) async -> Bool {
        target = (request["to"] ?? "PNG").uppercased()
        return true
    }

    override func transform(_ image: CGImage, output format: ImageFormat) -> CGImage {
        switch format {
        case .ico where image.width > ImageConvert.iconMaxEdge || image.height > ImageConvert.iconMaxEdge:
            return ImageOps.fit(image, width: ImageConvert.iconMaxEdge, height: ImageConvert.iconMaxEdge, exact: false)
        case .jpeg:
            return ImageOps.hasAlpha(image) ? ImageOps.flatten(image, onto: ImageOps.white) : image
        default:
            return image
        }
    }
}

final class ImageStripMetadata: BatchTask {
    override var title: String { Loc.t("menu.image.strip") }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let output = OutputPath.derive(path, suffix: "_clean")
        try await OutputPath.producing(output) {
            try MetadataStripper.strip(path, to: output, settings: Settings.current.image.metadata)
        }
    }
}

final class ImageChromaKey: BatchTask {
    override var title: String { Loc.t("menu.image.chromakey") }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let settings = Settings.current.image
        let output = OutputPath.derive(path, suffix: "_keyed", extension: ".png")
        let image = try ImageCodec.load(path).upright
        try Task.checkCancellation()

        let key = ColorText.parse(settings.backgroundKeyColor, fallback: .lime)
        let result: CGImage
        switch settings.backgroundMode {
        case .chromaKeyOnly:
            result = ChromaKey.apply(image, key: key, tolerance: settings.backgroundTolerance)
        case .aiOnly:
            result = try SubjectLift.cutOut(image)
        case .aiWithFallback:
            do {
                result = try SubjectLift.cutOut(image)
            } catch {
                progress.warn("\(fileName(path)) - \(Loc.t("msg.bgFallingBackSingle"))")
                result = ChromaKey.apply(image, key: key, tolerance: settings.backgroundTolerance)
            }
        }

        try await OutputPath.producing(output) {
            try ImageCodec.write(result, to: output)
        }
    }
}

final class ImageCompress: BatchTask {
    private static let maxDownscaleRounds = 8
    private static let downscaleFactor = 0.8
    private static let minimumEdge = 32

    private var target: Int64 = 0

    override var title: String { Loc.t("menu.image.compress") }

    override func configure(_ ui: Interaction) async -> Bool {
        let bytes = request["bytes"]
        if bytes?.lowercased() == "custom" {
            guard let answer = await ui.askTargetBytes(largest: largestSelected()) else { return false }
            target = answer
            return true
        }
        target = bytes.flatMap { Int64($0) } ?? 0
        return target > 0
    }

    private struct Attempt {
        var data: Data
        var reached: Bool
        var asWebp: Bool
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let original = FileSystem.size(of: path) ?? 0
        if original <= target {
            progress.info(Loc.f("msg.alreadySmall", fileName(path), Formatting.bytes(original)))
            return
        }

        let loaded = try ImageCodec.load(path)
        let format = loaded.format ?? ImageFormat(extension: (path as NSString).pathExtension) ?? .png
        let attempt = try squeeze(loaded.upright, format: format)

        let output = OutputPath.derive(path, suffix: "_compressed", extension: attempt.asWebp ? ".webp" : nil)
        try await OutputPath.producing(output) {
            try attempt.data.write(to: URL(fileURLWithPath: output))
        }

        if attempt.asWebp {
            progress.info(Loc.f("msg.webpFallback", fileName(path), Formatting.bytes(target)))
        }
        if !attempt.reached {
            progress.warn(Loc.f("msg.targetMissed", fileName(path), Formatting.bytes(target), Formatting.bytes(Int64(attempt.data.count))))
        }
    }

    private func squeeze(_ image: CGImage, format: ImageFormat) throws -> Attempt {
        let (native, reached) = try shrink(image, format: format)
        if reached { return Attempt(data: native, reached: true, asWebp: false) }
        if !Settings.current.image.allowWebpFallback || format == .webp {
            return Attempt(data: native, reached: false, asWebp: false)
        }

        let (webp, webpReached) = try shrink(image, format: .webp)
        return webpReached || webp.count < native.count
            ? Attempt(data: webp, reached: webpReached, asWebp: true)
            : Attempt(data: native, reached: false, asWebp: false)
    }

    private func shrink(_ image: CGImage, format: ImageFormat) throws -> (Data, Bool) {
        let encode: (CGImage) throws -> Data = format.isLossy
            ? { try self.highestQualityUnder($0, format: format) }
            : { try self.smallestPalette($0, format: format) }

        var best = try encode(image)
        if best.count <= target { return (best, true) }

        var current = image
        for _ in 0..<ImageCompress.maxDownscaleRounds {
            try Task.checkCancellation()
            if current.width <= ImageCompress.minimumEdge || current.height <= ImageCompress.minimumEdge { break }
            current = ImageOps.resize(current, width: Int(Double(current.width) * ImageCompress.downscaleFactor),
                                      height: Int(Double(current.height) * ImageCompress.downscaleFactor))
            let candidate = try encode(current)
            if candidate.count < best.count { best = candidate }
            if best.count <= target { return (best, true) }
        }
        return (best, best.count <= target)
    }

    private func highestQualityUnder(_ image: CGImage, format: ImageFormat) throws -> Data {
        var fitting: Data?
        var smallest: Data?
        var low = 5
        var high = 95

        while low <= high {
            try Task.checkCancellation()
            let middle = (low + high) / 2
            let data = try ImageCodec.encode(image, as: format, quality: Double(middle) / 100)
            if smallest == nil || data.count < smallest!.count { smallest = data }
            if data.count <= target {
                fitting = data
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return fitting ?? smallest!
    }

    private func smallestPalette(_ image: CGImage, format: ImageFormat) throws -> Data {
        let bitmap = Bitmap(image)
        let prepared = Quantizer.prepare(bitmap.unpremultiplied(), width: bitmap.width, height: bitmap.height)
        var best: Data?
        for colors in [256, 128, 64, 32] {
            try Task.checkCancellation()
            let quantized = prepared.palette(colors: colors)
            let data: Data
            switch format {
            case .png:
                data = IndexedPng.encode(quantized)
            case .svg:
                let png = IndexedPng.encode(quantized)
                let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(bitmap.width)\" height=\"\(bitmap.height)\" "
                    + "viewBox=\"0 0 \(bitmap.width) \(bitmap.height)\">"
                    + "<image href=\"data:image/png;base64,\(png.base64EncodedString())\" width=\"\(bitmap.width)\" height=\"\(bitmap.height)\"/>"
                    + "</svg>"
                data = Data(svg.utf8)
            default:
                data = try ImageCodec.encode(Quantizer.image(quantized, colorSpace: bitmap.colorSpace), as: format)
            }
            if best == nil || data.count < best!.count { best = data }
            if data.count <= target { return data }
        }
        return best!
    }
}

final class ImageOcr: BatchTask {
    private var settings = OcrSettings()
    private var collected = ""
    private var outcome: String?

    override var title: String { Loc.t("menu.image.ocr") }
    override var summary: String? { outcome }

    override func configure(_ ui: Interaction) async -> Bool {
        settings = Settings.current.ocr
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let image = try ImageCodec.load(path).upright
        try Task.checkCancellation()
        let text = try TextRecognition.recognize(image, language: settings.language)

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            progress.warn(Loc.f("msg.noTextFound", fileName(path)))
            return
        }

        if settings.output != .textFile {
            if request.paths.count > 1 {
                if !collected.isEmpty { collected += "\n\n" }
                collected += "== \(fileName(path)) ==\n"
            }
            collected += text + "\n"
            return
        }

        let output = OutputPath.derive(path, suffix: "_ocr", extension: ".txt")
        try await OutputPath.producing(output) {
            try TextFile.encode(text, as: settings.encoding).write(to: URL(fileURLWithPath: output))
        }
    }

    override func present(_ ui: Interaction) async {
        guard settings.output != .textFile, !collected.isEmpty else { return }
        if settings.output == .clipboard {
            outcome = await ui.copyToClipboard(collected) ? Loc.t("msg.ocrCopied") : Loc.t("common.copyFailed")
        }
        await ui.showText(title: title, text: collected)
    }
}
