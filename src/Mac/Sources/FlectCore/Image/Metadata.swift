import CoreGraphics
import Foundation
import ImageIO
import FlectKit

enum MetadataStripper {
    private static let exifNamespaces: Set<String> = ["exif", "exifEX", "aux", "tiff"]
    private static let commentTags: Set<String> = ["tiff:Software", "tiff:ImageDescription", "exif:UserComment",
                                                   "tiff:Artist", "tiff:Copyright"]

    static func strip(_ path: String, to output: String, settings: MetadataSettings) throws {
        let url = URL(fileURLWithPath: path)
        let format = ImageFormat(extension: url.pathExtension)

        if format != .svg, format != .webp,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) == 1,
           let type = CGImageSourceGetType(source),
           ImageFormat(typeIdentifier: type as String)?.typeIdentifier != nil {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            let bake = settings.applyOrientation && orientation != 1
            if !bake, !settings.removeColorProfile, try copyLosslessly(source, type: type, to: output, settings: settings) {
                return
            }
        }
        try reencode(path, to: output, settings: settings)
    }

    private static func copyLosslessly(_ source: CGImageSource, type: CFString, to output: String,
                                       settings: MetadataSettings) throws -> Bool {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return false }

        let metadata = CGImageMetadataCreateMutable()
        if let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            CGImageMetadataEnumerateTagsUsingBlock(original, nil, nil) { path, tag in
                if keep(path as String, settings: settings) {
                    _ = CGImageMetadataSetTagWithPath(metadata, nil, path, tag)
                }
                return true
            }
        }

        var options: [String: Any] = [
            kCGImageDestinationMetadata as String: metadata,
            kCGImageDestinationMergeMetadata as String: false,
        ]
        if settings.removeComments { options[kCGImageMetadataShouldExcludeXMP as String] = true }
        if settings.removeGps || settings.removeExif { options[kCGImageMetadataShouldExcludeGPS as String] = true }

        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            error?.release()
            return false
        }
        try (data as Data).write(to: URL(fileURLWithPath: output))
        return true
    }

    static func keep(_ path: String, settings: MetadataSettings) -> Bool {
        let namespace = path.split(separator: ":").first.map(String.init) ?? ""
        let name = path.split(separator: ":").dropFirst().joined(separator: ":")
        let isExif = exifNamespaces.contains(namespace)

        if path == "tiff:Orientation" { return !settings.removeExif }
        if isExif {
            if settings.removeExif { return false }
            if settings.removeGps, name.hasPrefix("GPS") { return false }
            if settings.removeComments, commentTags.contains(path) { return false }
            return true
        }
        if namespace == "exifGPS" || namespace == "GPS" { return !(settings.removeExif || settings.removeGps) }
        return !settings.removeComments
    }

    private static func reencode(_ path: String, to output: String, settings: MetadataSettings) throws {
        let loaded = try ImageCodec.load(path)
        let format = ImageFormat(extension: (output as NSString).pathExtension) ?? .png

        var properties: [String: Any] = [:]
        if !settings.removeExif {
            if var exif = loaded.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                if settings.removeComments { exif.removeValue(forKey: kCGImagePropertyExifUserComment as String) }
                properties[kCGImagePropertyExifDictionary as String] = exif
            }
            if var tiff = loaded.metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                if settings.removeComments {
                    for key in [kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFImageDescription,
                                kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright] {
                        tiff.removeValue(forKey: key as String)
                    }
                }
                properties[kCGImagePropertyTIFFDictionary as String] = tiff
            }
            if !settings.removeGps, let gps = loaded.metadata[kCGImagePropertyGPSDictionary as String] {
                properties[kCGImagePropertyGPSDictionary as String] = gps
            }
        }
        if !settings.removeComments, let iptc = loaded.metadata[kCGImagePropertyIPTCDictionary as String] {
            properties[kCGImagePropertyIPTCDictionary as String] = iptc
        }

        func prepare(_ image: CGImage) -> CGImage {
            var result = settings.applyOrientation ? ImageOps.orient(image, loaded.orientation) : image
            if settings.removeColorProfile, let untagged = result.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
                result = untagged
            }
            return result
        }

        if loaded.isAnimatedGif {
            let frames = loaded.frames.map { ImageFrame(image: prepare($0.image), delay: $0.delay) }
            try ImageCodec.writeAnimatedGif(frames, loopCount: loaded.loopCount, to: output)
            return
        }

        let quality = format == .jpeg ? JpegQuality.estimate(path).map { Double($0) / 100 } : nil
        let image = prepare(loaded.largest)
        if !settings.applyOrientation, loaded.orientation != .up {
            properties[kCGImagePropertyOrientation as String] = loaded.orientation.rawValue
        }
        let data = try ImageCodec.encode(image, as: format, quality: quality, metadata: properties)
        try data.write(to: URL(fileURLWithPath: output))
    }
}

enum JpegQuality {
    private static let standardLuminance: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]
    private static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    static func estimate(_ path: String) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: 512 * 1024) else { return nil }
        try? handle.close()
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var index = 2
        while index + 4 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if marker == 0xDB {
                var cursor = index + 4
                let end = index + 2 + length
                while cursor < end, cursor < bytes.count {
                    let precision = bytes[cursor] >> 4
                    let table = bytes[cursor] & 0x0F
                    cursor += 1
                    var values: [Int] = []
                    for _ in 0..<64 where cursor < bytes.count {
                        if precision == 0 {
                            values.append(Int(bytes[cursor]))
                            cursor += 1
                        } else {
                            values.append(Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1]))
                            cursor += 2
                        }
                    }
                    if table == 0, values.count == 64 { return quality(values) }
                }
            }
            if marker == 0xDA { return nil }
            index += 2 + length
        }
        return nil
    }

    private static func quality(_ zigzagValues: [Int]) -> Int {
        var scale = 0.0
        for position in 0..<64 {
            scale += Double(zigzagValues[position]) * 100 / Double(standardLuminance[zigzag[position]])
        }
        scale /= 64
        let quality = scale <= 100 ? (200 - scale) / 2 : 5000 / scale
        return Int(min(max(quality.rounded(), 1), 100))
    }
}
