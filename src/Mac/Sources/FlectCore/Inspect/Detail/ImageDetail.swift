import Foundation
import ImageIO
import UniformTypeIdentifiers
import FlectKit

// Ported from src/App/Inspect/Detail/ImageDetail.cs. ImageIO stands in for Magick.NET; the facts ImageIO does not
// expose (interlace, density units, comments, embedded profiles, raw XMP) come from the container bytes.
enum ImageDetail {
    private static let tagLimit = 250
    private static let animationDictionaries = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary,
                                                kCGImagePropertyWebPDictionary, kCGImagePropertyHEICSDictionary]
    private static let generatedTags: Set<String> = ["ColorSpace", "PixelXDimension", "PixelYDimension", "Orientation"]
    // Byte and Undefined typed EXIF tags, which the C# skips, under their ImageIO names.
    private static let skippedTags: Set<String> = [
        "ExifVersion", "FlashPixVersion", "ComponentsConfiguration", "UserComment", "FileSource", "SceneType",
        "CFAPattern", "DeviceSettingDescription", "OECF", "SpatialFrequencyResponse", "TileWidth", "TileLength",
        "GPSVersion", "GPSAltitudeRef", "GPSProcessingMethod", "GPSAreaInformation",
    ]

    static func read(_ path: String, _ detected: String) throws -> ProbeResult? {
        if detected == "SVG" || path.lowercased().hasSuffix(".svg"), let svg = svg(path) { return svg }

        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?, CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any], size(first) != nil
        else { return nil }
        let kind = kindOf(type)
        let layout = Layout.scan((try? Data(contentsOf: url, options: .alwaysMapped)) ?? Data(), kind, path)
        return fromFrames(source, first, kind, layout)
    }

    private static func fromFrames(_ source: CGImageSource, _ first: [String: Any], _ kind: String,
                                   _ layout: Layout) -> ProbeResult {
        let count = CGImageSourceGetCount(source)
        let alpha = first[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        let depth = (first[kCGImagePropertyDepth as String] as? NSNumber)?.intValue ?? 0
        let color = colorOf(first, kind, layout, alpha)

        let image = FactBag()
        image.add("dialog.fileAnalyze.format", formatLabel(kind, layout))
        image.add("dialog.fileAnalyze.dimensions", size(first))
        image.add("dialog.fileAnalyze.bitDepth", depth > 0 ? String(depth) : nil)
        image.add("dialog.fileAnalyze.alpha", Kinds.yesNo(alpha))
        image.add("dialog.fileAnalyze.color", color.map { "\($0.type), \($0.space)" })
        image.add("dialog.fileAnalyze.dpi", layout.density ?? (layout.densityFinal ? nil : density(first)))
        image.add("dialog.fileAnalyze.interlace", layout.interlace ?? Loc.t("dialog.fileAnalyze.noInterlace"))
        image.add("dialog.fileAnalyze.profile", profile(first, layout, color?.space))
        image.add("dialog.fileAnalyze.orientation", orientation(first[kCGImagePropertyOrientation as String]))
        image.add("dialog.fileAnalyze.comment", short(layout.comment))

        let frames = count > 1 ? (0..<count).map { index in
            index == 0 ? first : CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        } : [first]
        let delays = frames.map(delay)
        if count > 1 || delays[0] > 0 {
            image.add("dialog.fileAnalyze.frames", String(count))
            image.add("dialog.fileAnalyze.duration", "\(delays.reduce(0, +) * 10) ms")
            image.add("dialog.fileAnalyze.loop", loop(source, kind, count))
            if delays.count > 1 {
                image.add("dialog.fileAnalyze.delay", "\(delays.min()! * 10) - \(delays.max()! * 10) ms")
            }
        }
        if kind == "ICO" {
            var sizes: [String] = []
            for frame in frames { if let text = size(frame), !sizes.contains(text) { sizes.append(text) } }
            image.add("dialog.fileAnalyze.sizes", sizes.joined(separator: ", "))
        }

        var sections: [FileSection] = []
        if let main = image.section("dialog.fileAnalyze.image") { sections.append(main) }
        let exif = hasExif(first, layout)
        if exif, let camera = camera(first) { sections.append(camera) }
        if exif, let location = location(first) { sections.append(location) }
        if let tags = tags(first, exif, layout.xmp) { sections.append(tags) }
        return ProbeResult(kind: kind, sections: sections)
    }

    private static func camera(_ first: [String: Any]) -> FileSection? {
        let exif = kCGImagePropertyExifDictionary, tiff = kCGImagePropertyTIFFDictionary
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.taken", named(first, exif, "DateTimeOriginal")
                    ?? named(first, exif, "DateTimeDigitized") ?? named(first, tiff, "DateTime"))
        bag.add("dialog.fileAnalyze.make", named(first, tiff, "Make"))
        bag.add("dialog.fileAnalyze.model", named(first, tiff, "Model"))
        bag.add("dialog.fileAnalyze.exposure", named(first, exif, "ExposureTime"))
        bag.add("dialog.fileAnalyze.fNumber", named(first, exif, "FNumber"))
        bag.add("dialog.fileAnalyze.iso", named(first, exif, "ISOSpeedRatings"))
        bag.add("dialog.fileAnalyze.focal", named(first, exif, "FocalLength"))
        bag.add("dialog.fileAnalyze.flash", named(first, exif, "Flash"))
        bag.add("dialog.fileAnalyze.software", named(first, tiff, "Software"))
        return bag.section("dialog.fileAnalyze.camera")
    }

    private static func location(_ first: [String: Any]) -> FileSection? {
        let gps = kCGImagePropertyGPSDictionary
        let values = first[gps as String] as? [String: Any] ?? [:]
        let latitude = coordinate(values["Latitude"], named(first, gps, "LatitudeRef"))
        let longitude = coordinate(values["Longitude"], named(first, gps, "LongitudeRef"))
        if latitude == nil, longitude == nil { return nil }
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.latitude", latitude.map { decimal($0, 6) })
        bag.add("dialog.fileAnalyze.longitude", longitude.map { decimal($0, 6) })
        bag.add("dialog.fileAnalyze.altitude", named(first, gps, "Altitude"))
        return bag.section("dialog.fileAnalyze.location")
    }

    private static func tags(_ first: [String: Any], _ exif: Bool, _ xmp: Data?) -> FileSection? {
        let bag = FactBag()
        var shown = 0
        var hidden = 0
        func add(_ label: String, _ value: String?) {
            guard let text = short(value) else { return }
            if shown >= tagLimit {
                hidden += 1
                return
            }
            bag.addRaw(label, text)
            shown += 1
        }

        if exif {
            for (dictionary, prefix) in [(kCGImagePropertyTIFFDictionary, ""), (kCGImagePropertyExifDictionary, ""),
                                         (kCGImagePropertyGPSDictionary, "GPS")] {
                guard let values = first[dictionary as String] as? [String: Any] else { continue }
                for key in values.keys.sorted() {
                    let name = prefix + (key == "FocalLenIn35mmFilm" ? "FocalLengthIn35mmFilm" : key)
                    if skippedTags.contains(name) || name.localizedCaseInsensitiveContains("MakerNote") { continue }
                    add(name, text(values[key]))
                }
            }
        }
        if let iptc = first[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            for key in iptc.keys.sorted() {
                if let list = iptc[key] as? [Any] { for item in list { add(key, text(item)) } } else { add(key, text(iptc[key])) }
            }
        }
        if let xmp { for (name, value) in XmpReader.leaves(xmp) { add(name, value) } }

        if hidden > 0 { bag.add("dialog.fileAnalyze.moreTags", String(hidden)) }
        return bag.section("dialog.fileAnalyze.tags")
    }

    private static func svg(_ path: String) -> ProbeResult? {
        guard let parser = XMLParser(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let reader = SvgReader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.sawSvg else { return nil }
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.format", "SVG")
        bag.add("dialog.fileAnalyze.viewBox", reader.viewBox)
        if reader.width != nil || reader.height != nil {
            bag.add("dialog.fileAnalyze.svgSize", "\(reader.width ?? "?") x \(reader.height ?? "?")")
        }
        bag.add("dialog.fileAnalyze.embeddedImages", String(reader.images))
        bag.add("dialog.fileAnalyze.scripts", String(reader.scripts))
        bag.add("dialog.fileAnalyze.externalRefs", String(reader.external))
        return bag.result("dialog.fileAnalyze.image", kind: "SVG")
    }

    private static func kindOf(_ type: String) -> String {
        switch type {
        case "public.png": return "PNG"
        case "public.jpeg": return "JPEG"
        case "org.webmproject.webp": return "WEBP"
        case "com.compuserve.gif": return "GIF"
        case "public.heic", "public.heif", "public.heics", "public.avci": return "HEIC"
        case "com.microsoft.ico": return "ICO"
        case "public.svg-image": return "SVG"
        case "public.avif", "public.avis": return "AVIF"
        case "public.tiff": return "TIFF"
        case "com.microsoft.bmp": return "BMP"
        default:
            return (UTType(type)?.preferredFilenameExtension ?? type.components(separatedBy: ".").last ?? type).uppercased()
        }
    }

    private static func formatLabel(_ kind: String, _ layout: Layout) -> String {
        guard kind == "WEBP", let lossless = layout.lossless else { return kind == "WEBP" ? "WebP" : kind }
        return lossless ? "WebP lossless" : "WebP lossy"
    }

    private static func size(_ properties: [String: Any]) -> String? {
        guard let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else { return nil }
        return "\(width) x \(height)"
    }

    // Magick.NET's ColorType and ColorSpace names.
    private static func colorOf(_ first: [String: Any], _ kind: String, _ layout: Layout,
                                _ alpha: Bool) -> (type: String, space: String)? {
        let model = first[kCGImagePropertyColorModel as String] as? String
        let indexed = first[kCGImagePropertyIsIndexed as String] as? Bool == true || kind == "GIF" || layout.pngColor == 3
        let suffix = alpha ? "Alpha" : ""
        if model == "CMYK" { return ("ColorSeparation" + suffix, "CMYK") }
        if model == "Gray" || layout.pngColor == 0 || layout.pngColor == 4 { return ("Grayscale" + suffix, "Gray") }
        if indexed { return ("Palette" + suffix, "sRGB") }
        if model == "RGB" { return ("TrueColor" + suffix, "sRGB") }
        if model == "Lab" { return ("TrueColor" + suffix, "Lab") }
        return nil
    }

    private static func density(_ first: [String: Any]) -> String? {
        if let tiff = first[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let x = (tiff["XResolution"] as? NSNumber)?.doubleValue, let y = (tiff["YResolution"] as? NSNumber)?.doubleValue {
            return Layout.densityText(x, y, (tiff["ResolutionUnit"] as? NSNumber)?.intValue == 3 ? "px/cm" : "ppi")
        }
        guard let x = (first[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue,
              let y = (first[kCGImagePropertyDPIHeight as String] as? NSNumber)?.doubleValue else { return nil }
        return Layout.densityText(x, y, "ppi")
    }

    private static func profile(_ first: [String: Any], _ layout: Layout, _ space: String?) -> String? {
        if layout.profile == false { return nil }
        if let name = first[kCGImagePropertyProfileName as String] as? String,
           !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return layout.profile == true ? space : nil
    }

    private static func orientation(_ value: Any?) -> String? {
        switch (value as? NSNumber)?.intValue {
        case 1: return Loc.t("dialog.fileAnalyze.normal")
        case 2: return "TopRight"
        case 3: return "180 degrees"
        case 4: return "BottomLeft"
        case 5: return "LeftTop"
        case 6: return "90 degrees clockwise"
        case 7: return "RightBottom"
        case 8: return "90 degrees counter-clockwise"
        default: return nil
        }
    }

    // Centiseconds, the unit of Magick's AnimationDelay.
    private static func delay(_ properties: [String: Any]) -> Int {
        for dictionary in animationDictionaries {
            guard let values = properties[dictionary as String] as? [String: Any],
                  let seconds = (values["UnclampedDelayTime"] as? NSNumber ?? values["DelayTime"] as? NSNumber)?.doubleValue
            else { continue }
            return max(0, Int((seconds * 100).rounded()))
        }
        return 0
    }

    private static func loop(_ source: CGImageSource, _ kind: String, _ frames: Int) -> String? {
        if frames <= 1 { return nil }
        let container = CGImageSourceCopyProperties(source, nil) as? [String: Any] ?? [:]
        let iterations = animationDictionaries.lazy
            .compactMap { ((container[$0 as String] as? [String: Any])?["LoopCount"] as? NSNumber)?.intValue }
            .first ?? (kind == "GIF" ? 1 : 0)
        return iterations <= 0 ? Loc.t("dialog.fileAnalyze.infinite") : String(iterations)
    }

    // ImageIO fills in a few EXIF tags of its own, so the bytes decide where they can.
    private static func hasExif(_ first: [String: Any], _ layout: Layout) -> Bool {
        if let exif = layout.exif { return exif }
        return [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary].contains {
            guard let values = first[$0 as String] as? [String: Any] else { return false }
            return values.keys.contains { !generatedTags.contains($0) && !skippedTags.contains($0) }
        }
    }

    private static func named(_ first: [String: Any], _ dictionary: CFString, _ key: String) -> String? {
        clean(text((first[dictionary as String] as? [String: Any])?[key]))
    }

    private static func coordinate(_ raw: Any?, _ reference: String?) -> Double? {
        guard let value = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap({ Double($0) }), value.isFinite
        else { return nil }
        return ["S", "s", "W", "w"].contains(reference ?? "") ? -value : value
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return rational(number.doubleValue)
        case let list as [Any]:
            let parts = list.compactMap { text($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default: return nil
        }
    }

    // ImageIO turns EXIF rationals into doubles; exposures read best as 1/N again.
    private static func rational(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let inverse = 1 / abs(value)
        if abs(value) < 1, inverse < 1e9, abs(inverse - inverse.rounded()) < 1e-6 * inverse {
            return (value < 0 ? "-1/" : "1/") + String(Int64(inverse.rounded()))
        }
        return decimal(value, 6)
    }

    static func decimal(_ value: Double, _ places: Int) -> String {
        var text = String(format: "%.\(places)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func short(_ value: String?) -> String? {
        clean(value).map { $0.count <= 500 ? $0 : String($0.prefix(500)) }
    }
}

// What the container bytes say about the facts ImageIO leaves out. nil means the bytes were not consulted.
private struct Layout {
    var interlace: String?
    var density: String?
    var comment = ""
    var profile: Bool?
    var exif: Bool?
    var xmp: Data?
    var lossless: Bool?
    var pngColor: Int?
    var densityFinal = false

    static func scan(_ data: Data, _ kind: String, _ path: String) -> Layout {
        switch kind {
        case "PNG": return png(data)
        case "JPEG": return jpeg(data)
        case "WEBP": return webp(data)
        case "GIF": return gif(path)
        case "BMP": return bmp(data)
        case "TIFF": return tiff(data)
        case "HEIC", "AVIF":
            let head = data.prefix(1024 * 1024)
            return Layout(profile: head.range(of: Data("colrprof".utf8)) != nil || head.range(of: Data("colrrICC".utf8)) != nil)
        case "ICO": return Layout(profile: false)
        default: return Layout()
        }
    }

    static func densityText(_ x: Double, _ y: Double, _ unit: String) -> String? {
        guard x > 0, y > 0 else { return nil }
        return "\(ImageDetail.decimal(x, 2)) x \(ImageDetail.decimal(y, 2)) \(unit)"
    }

    private static func png(_ data: Data) -> Layout {
        var layout = Layout(profile: false, exif: false, densityFinal: true)
        var position = 8
        while let length = data.be(position, 4), position + 12 + length <= data.count {
            let start = position + 8
            switch data.ascii(position + 4, 4) {
            case "IHDR":
                layout.pngColor = data.byte(start + 9)
                if let method = data.byte(start + 12) {
                    layout.interlace = Loc.t(method == 0 ? "dialog.fileAnalyze.noInterlace" : "dialog.fileAnalyze.adam7")
                }
            case "pHYs":
                if let x = data.be(start, 4), let y = data.be(start + 4, 4), let unit = data.byte(start + 8) {
                    layout.density = unit == 1 ? densityText(Double(x) / 100, Double(y) / 100, "px/cm")
                        : densityText(Double(x), Double(y), "ppi")
                }
            case "iCCP": layout.profile = true
            case "eXIf": layout.exif = true
            case let type where ["tEXt", "zTXt", "iTXt"].contains(type):
                if let (keyword, text) = pngText(type, data.bytes(start, length) ?? Data()) {
                    if keyword.lowercased() == "comment" { layout.comment += text }
                    if keyword == "XML:com.adobe.xmp" { layout.xmp = Data(text.utf8) }
                }
            case "IEND": return layout
            default: break
            }
            position = start + length + 4
        }
        return layout
    }

    private static func pngText(_ type: String, _ chunk: Data) -> (String, String)? {
        let bytes = [UInt8](chunk)
        guard let zero = bytes.firstIndex(of: 0) else { return nil }
        let keyword = String(decoding: bytes[..<zero], as: UTF8.self)
        var rest = Array(bytes[(zero + 1)...])
        switch type {
        case "tEXt":
            return (keyword, String(data: Data(rest), encoding: .isoLatin1) ?? "")
        case "zTXt":
            guard !rest.isEmpty, let text = inflate(Array(rest.dropFirst())) else { return nil }
            return (keyword, String(data: text, encoding: .isoLatin1) ?? "")
        default:
            guard rest.count >= 2 else { return nil }
            let compressed = rest[0] == 1
            rest.removeFirst(2)
            for _ in 0..<2 {
                guard let end = rest.firstIndex(of: 0) else { return nil }
                rest.removeFirst(end + 1)
            }
            guard let text = compressed ? inflate(rest) : Data(rest) else { return nil }
            return (keyword, String(decoding: text, as: UTF8.self))
        }
    }

    // zlib stream: two header bytes, raw deflate, four checksum bytes.
    private static func inflate(_ bytes: [UInt8]) -> Data? {
        guard bytes.count > 6 else { return nil }
        return try? (Data(bytes[2..<(bytes.count - 4)]) as NSData).decompressed(using: .zlib) as Data
    }

    private static func jpeg(_ data: Data) -> Layout {
        var layout = Layout(interlace: Loc.t("dialog.fileAnalyze.noInterlace"), profile: false, exif: false)
        var sawFrame = false
        var position = 2
        while data.byte(position) == 0xFF {
            while data.byte(position) == 0xFF { position += 1 }
            guard let marker = data.byte(position) else { break }
            position += 1
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
            if marker == 0xD9 || marker == 0xDA { break }
            guard let length = data.be(position, 2), length >= 2, position + length <= data.count else { break }
            let start = position + 2
            let size = length - 2
            switch marker {
            case 0xC0...0xCF where ![0xC4, 0xC8, 0xCC].contains(marker):
                if !sawFrame, [0xC2, 0xC6, 0xCA, 0xCE].contains(marker) { layout.interlace = Loc.t("dialog.fileAnalyze.progressive") }
                sawFrame = true
            case 0xE0 where data.starts(start, "JFIF\0"):
                if let unit = data.byte(start + 7), let x = data.be(start + 8, 2), let y = data.be(start + 10, 2),
                   x != 1, y != 1, layout.density == nil {
                    layout.density = densityText(Double(x), Double(y), unit == 2 ? "px/cm" : "ppi")
                }
            case 0xE1 where data.starts(start, "Exif\0\0"): layout.exif = true
            case 0xE1 where data.starts(start, "http://ns.adobe.com/xap/1.0/\0"):
                layout.xmp = data.bytes(start + 29, size - 29)
            case 0xE2 where data.starts(start, "ICC_PROFILE\0"): layout.profile = true
            case 0xFE:
                let bytes = data.bytes(start, size) ?? Data()
                layout.comment += String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
            default: break
            }
            position += length
        }
        return layout
    }

    private static func webp(_ data: Data) -> Layout {
        var layout = Layout(interlace: Loc.t("dialog.fileAnalyze.noInterlace"), profile: false, exif: false)
        func walk(_ from: Int, _ end: Int) {
            var position = from
            while position + 8 <= end, let size = data.le(position + 4, 4) {
                let type = data.ascii(position, 4)
                let start = position + 8
                if type == "VP8L", layout.lossless == nil { layout.lossless = true }
                if type == "VP8 ", layout.lossless == nil { layout.lossless = false }
                guard start + size <= end else { return }
                switch type {
                case "ANMF": walk(start + 16, start + size)
                case "ICCP": layout.profile = true
                case "EXIF": layout.exif = true
                case "XMP ": layout.xmp = data.bytes(start, size)
                default: break
                }
                position = start + size + (size & 1)
            }
        }
        if data.starts(0, "RIFF"), data.starts(8, "WEBP") { walk(12, min(data.count, (data.le(4, 4) ?? 0) + 8)) }
        return layout
    }

    private static func gif(_ path: String) -> Layout {
        let frame = GifMotion.firstFrame(GifMotion.head(path) ?? [])
        return Layout(interlace: frame.interlaced == true ? "Gif" : Loc.t("dialog.fileAnalyze.noInterlace"),
                      comment: frame.comment, profile: false, exif: false)
    }

    private static func bmp(_ data: Data) -> Layout {
        var layout = Layout(profile: false, densityFinal: true)
        guard data.starts(0, "BM"), let header = data.le(14, 4), header >= 40 else { return layout }
        if let x = data.le(38, 4), let y = data.le(42, 4), x > 0, x < Int(Int32.max), y > 0, y < Int(Int32.max) {
            layout.density = densityText(Double(x) / 100, Double(y) / 100, "px/cm")
        }
        layout.profile = header >= 124 && data.starts(70, "DEBM")
        return layout
    }

    private static func tiff(_ data: Data) -> Layout {
        let little = data.starts(0, "II")
        guard little || data.starts(0, "MM") else { return Layout() }
        func read(_ offset: Int, _ count: Int) -> Int? { little ? data.le(offset, count) : data.be(offset, count) }
        guard read(2, 2) == 42, let directory = read(4, 4), let entries = read(directory, 2) else { return Layout() }
        let profile = (0..<entries).contains { read(directory + 2 + $0 * 12, 2) == 34675 }
        return Layout(profile: profile)
    }
}

private extension Data {
    func byte(_ offset: Int) -> Int? { offset >= 0 && offset < count ? Int(self[startIndex + offset]) : nil }

    func be(_ offset: Int, _ length: Int) -> Int? {
        guard offset >= 0, offset + length <= count else { return nil }
        return (0..<length).reduce(0) { $0 << 8 | Int(self[startIndex + offset + $1]) }
    }

    func le(_ offset: Int, _ length: Int) -> Int? {
        guard offset >= 0, offset + length <= count else { return nil }
        return (0..<length).reversed().reduce(0) { $0 << 8 | Int(self[startIndex + offset + $1]) }
    }

    func bytes(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        return subdata(in: startIndex + offset..<startIndex + offset + length)
    }

    func ascii(_ offset: Int, _ length: Int) -> String { bytes(offset, length).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    func starts(_ offset: Int, _ text: String) -> Bool { bytes(offset, text.utf8.count) == Data(text.utf8) }
}

private final class SvgReader: NSObject, XMLParserDelegate {
    var sawSvg = false
    var viewBox: String?
    var width: String?
    var height: String?
    var images = 0
    var scripts = 0
    var external = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local.caseInsensitiveCompare("svg") == .orderedSame {
            sawSvg = true
            viewBox = viewBox ?? attributes["viewBox"]
            width = width ?? attributes["width"]
            height = height ?? attributes["height"]
        }
        if local.caseInsensitiveCompare("script") == .orderedSame { scripts += 1 }
        if local.caseInsensitiveCompare("image") == .orderedSame { images += 1 }
        if Self.isExternal(attributes["href"]) || Self.isExternal(attributes["src"]) { external += 1 }
    }

    private static func isExternal(_ reference: String?) -> Bool {
        guard let trimmed = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return false }
        return !trimmed.hasPrefix("#") && !trimmed.lowercased().hasPrefix("data:")
    }
}

// Leaf elements of an XMP packet, as XDocument.Descendants() yields them in the C#.
private final class XmpReader: NSObject, XMLParserDelegate {
    private var stack: [(name: String, nested: Bool, text: String)] = []
    private var found: [(String, String)] = []

    static func leaves(_ packet: Data) -> [(String, String)] {
        var bytes = packet
        while bytes.last == 0 { bytes.removeLast() }
        let parser = XMLParser(data: bytes)
        let reader = XmpReader()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? reader.found : []
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if !stack.isEmpty { stack[stack.count - 1].nested = true }
        stack.append((elementName, false, ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if !stack.isEmpty { stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let element = stack.popLast(), !element.nested else { return }
        found.append((element.name, element.text))
    }
}
