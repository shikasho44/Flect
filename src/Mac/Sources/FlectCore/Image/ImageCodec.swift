import AppKit
import CoreGraphics
import CWebP
import Foundation
import ImageIO
import UniformTypeIdentifiers
import FlectKit

public enum ImageFormat: String {
    case png, jpeg, webp, heic, gif, ico, svg, tiff, bmp

    public init?(extension ext: String) {
        switch ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
        case "png": self = .png
        case "jpg", "jpeg", "jpe": self = .jpeg
        case "webp": self = .webp
        case "heic", "heif": self = .heic
        case "gif": self = .gif
        case "ico": self = .ico
        case "svg": self = .svg
        case "tif", "tiff": self = .tiff
        case "bmp": self = .bmp
        default: return nil
        }
    }

    init?(typeIdentifier: String) {
        switch typeIdentifier {
        case "public.png": self = .png
        case "public.jpeg": self = .jpeg
        case "org.webmproject.webp", "public.webp": self = .webp
        case "public.heic", "public.heif": self = .heic
        case "com.compuserve.gif": self = .gif
        case "com.microsoft.ico": self = .ico
        case "public.svg-image": self = .svg
        case "public.tiff": self = .tiff
        case "com.microsoft.bmp": self = .bmp
        default: return nil
        }
    }

    var typeIdentifier: String? {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .gif: return "com.compuserve.gif"
        case .ico: return "com.microsoft.ico"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .webp, .svg: return nil
        }
    }

    public var supportsAlpha: Bool { self != .jpeg && self != .bmp }

    public var isLossy: Bool { self == .jpeg || self == .webp || self == .heic }

    var keepsMetadata: Bool { self == .jpeg || self == .heic || self == .tiff }
}

public struct ImageFrame {
    public var image: CGImage
    public var delay: Double
}

public struct LoadedImage {
    public var frames: [ImageFrame]
    public var format: ImageFormat?
    public var properties: [String: Any]
    public var loopCount: Int
    public var orientation: CGImagePropertyOrientation

    public var isAnimatedGif: Bool { format == .gif && frames.count > 1 }

    public var largest: CGImage {
        frames.max { $0.image.width * $0.image.height < $1.image.width * $1.image.height }!.image
    }

    public var upright: CGImage { ImageOps.orient(largest, orientation) }

    var metadata: [String: Any] {
        var kept: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary] as [CFString] {
            if var dictionary = properties[key as String] as? [String: Any] {
                if key == kCGImagePropertyTIFFDictionary {
                    dictionary.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
                }
                if key == kCGImagePropertyExifDictionary {
                    dictionary.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
                    dictionary.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
                }
                kept[key as String] = dictionary
            }
        }
        return kept
    }
}

public enum ImageCodec {
    public static func load(_ path: String) throws -> LoadedImage {
        let url = URL(fileURLWithPath: path)
        if ImageFormat(extension: url.pathExtension) == .svg {
            return try loadVector(url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return try loadVector(url)
        }

        let type = CGImageSourceGetType(source) as String? ?? ""
        let format = ImageFormat(typeIdentifier: type)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let container = CGImageSourceCopyProperties(source, nil) as? [String: Any] ?? [:]

        var frames: [ImageFrame] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            var delay = 0.1
            if format == .gif,
               let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
               let gif = frame[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue ?? 0
                let clamped = (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue ?? 0.1
                delay = unclamped > 0 ? unclamped : clamped
            }
            frames.append(ImageFrame(image: image, delay: delay))
        }
        guard !frames.isEmpty else { throw FlectError("This image could not be read.") }

        let gif = container[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let loopCount = (gif?[kCGImagePropertyGIFLoopCount as String] as? NSNumber)?.intValue ?? 0
        let raw = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up

        return LoadedImage(frames: frames, format: format, properties: properties, loopCount: loopCount,
                           orientation: format == .gif ? .up : orientation)
    }

    private static func loadVector(_ url: URL) throws -> LoadedImage {
        guard let image = NSImage(contentsOf: url) else { throw FlectError("This image could not be read.") }
        var size = image.size
        if size.width < 1 || size.height < 1 { size = NSSize(width: 512, height: 512) }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())

        var bitmap = Bitmap(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        bitmap.pixels.withUnsafeMutableBytes { buffer in
            guard let context = Bitmap.context(buffer.baseAddress, width, height, bitmap.colorSpace) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }
        let format = ImageFormat(extension: url.pathExtension)
        return LoadedImage(frames: [ImageFrame(image: bitmap.makeImage(), delay: 0.1)], format: format,
                           properties: [:], loopCount: 0, orientation: .up)
    }

    public static func encode(_ image: CGImage, as format: ImageFormat, quality: Double? = nil,
                              metadata: [String: Any] = [:]) throws -> Data {
        switch format {
        case .webp:
            return try encodeWebP(image, quality: quality ?? Double(Settings.current.image.webpQuality) / 100)
        case .svg:
            return try encodeSvg(image)
        case .ico:
            return try encodeIcon(image)
        default:
            break
        }

        guard let type = format.typeIdentifier else { throw FlectError("Cannot write \(format.rawValue.uppercased()).") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw FlectError("Cannot write \(format.rawValue.uppercased()).")
        }

        var properties: [String: Any] = format.keepsMetadata ? metadata : [:]
        properties[kCGImagePropertyOrientation as String] = 1
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality as String] = quality ?? defaultQuality(format)
        }
        let output = format.supportsAlpha ? image : (ImageOps.hasAlpha(image) ? ImageOps.flatten(image, onto: ImageOps.white) : image)
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FlectError("Cannot write \(format.rawValue.uppercased()).")
        }
        return data as Data
    }

    static func defaultQuality(_ format: ImageFormat) -> Double {
        switch format {
        case .jpeg: return 0.92
        case .heic: return 0.9
        case .webp: return Double(Settings.current.image.webpQuality) / 100
        default: return 1
        }
    }

    public static func write(_ image: CGImage, to path: String, quality: Double? = nil, metadata: [String: Any] = [:]) throws {
        guard let format = ImageFormat(extension: (path as NSString).pathExtension) else {
            throw FlectError("Cannot write \((path as NSString).pathExtension.uppercased()).")
        }
        try encode(image, as: format, quality: quality, metadata: metadata).write(to: URL(fileURLWithPath: path))
    }

    public static func writeAnimatedGif(_ frames: [ImageFrame], loopCount: Int, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString,
                                                                frames.count, nil) else {
            throw FlectError("Cannot write GIF.")
        }
        let container = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: loopCount]]
        CGImageDestinationSetProperties(destination, container as CFDictionary)
        for frame in frames {
            let properties = [kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frame.delay,
                kCGImagePropertyGIFUnclampedDelayTime as String: frame.delay,
            ]]
            CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw FlectError("Cannot write GIF.") }
    }

    static func encodeWebP(_ image: CGImage, quality: Double) throws -> Data {
        let bitmap = Bitmap(image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var straight = bitmap.unpremultiplied()
        var output: UnsafeMutablePointer<UInt8>?
        let size = straight.withUnsafeMutableBufferPointer { pixels in
            WebPEncodeRGBA(pixels.baseAddress, Int32(bitmap.width), Int32(bitmap.height), Int32(bitmap.bytesPerRow),
                           Float(min(max(quality, 0), 1) * 100), &output)
        }
        guard size > 0, let output else { throw FlectError("Cannot write WEBP.") }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }

    static func encodeIcon(_ image: CGImage) throws -> Data {
        let fitted = image.width > 256 || image.height > 256 ? ImageOps.fit(image, width: 256, height: 256, exact: false) : image
        let png = try encode(fitted, as: .png)
        var data = Data()
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.append(contentsOf: [UInt8(fitted.width >= 256 ? 0 : fitted.width), UInt8(fitted.height >= 256 ? 0 : fitted.height), 0, 0])
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(32))
        data.appendLittleEndian(UInt32(png.count))
        data.appendLittleEndian(UInt32(22))
        data.append(png)
        return data
    }

    static func encodeSvg(_ image: CGImage) throws -> Data {
        let png = try encode(image, as: .png)
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(image.width)\" height=\"\(image.height)\" "
            + "viewBox=\"0 0 \(image.width) \(image.height)\">"
            + "<image href=\"data:image/png;base64,\(png.base64EncodedString())\" width=\"\(image.width)\" height=\"\(image.height)\"/>"
            + "</svg>"
        return Data(svg.utf8)
    }
}
