import Foundation

public struct MenuNode: Hashable {
    public var id: String
    public var label: String
    public var verb: String?
    public var children: [MenuNode]

    static func leaf(_ id: String, _ label: String, _ verb: String) -> MenuNode {
        MenuNode(id: id, label: label, verb: verb, children: [])
    }

    static func popup(_ id: String, _ label: String, _ children: [MenuNode]) -> MenuNode {
        MenuNode(id: id, label: label, verb: nil, children: children)
    }
}

public enum MenuBuilder {
    private static let toPrefix = "to "

    public static func build(_ selection: SelectionInfo, settings: Settings) -> [MenuNode] {
        if selection.isEmpty { return [] }

        let nodes: [MenuNode]
        switch selection.category {
        case .folder: nodes = folder()
        case .pdf: nodes = pdf(selection)
        case .image: nodes = image(selection, settings.image.presets)
        case .video: nodes = video(selection, settings.video.presets)
        case .audio: nodes = audio(selection)
        case .text: nodes = text(selection)
        case .jar: nodes = [.leaf("jar.decompile", Loc.t("menu.jar.decompile"), "jar.decompile")]
        case .archive: nodes = [.leaf("archive.extract", Loc.t("menu.archive.extract"), "archive.extract")]
        case .none: return []
        }
        return prune(nodes, hidden: Set(settings.general.hiddenMenuItems))
    }

    private static func folder() -> [MenuNode] {
        ["removeDuplicate", "removeEmpty", "tree", "rename", "analyze", "compress"].map {
            .leaf("folder.\($0)", Loc.t("menu.folder.\($0)"), "folder.\($0)")
        }
    }

    private static func pdf(_ selection: SelectionInfo) -> [MenuNode] {
        var items: [MenuNode] = []
        if selection.paths.count == 1 { items.append(.leaf("pdf.preview", Loc.t("menu.pdf.preview"), "pdf.preview")) }
        if selection.paths.count > 1 { items.append(.leaf("pdf.merge", Loc.t("menu.pdf.merge"), "pdf.merge")) }
        for format in ["PNG", "JPG", "TXT"] {
            items.append(.leaf("pdf.convert.\(format)", toPrefix + format, "pdf.convert?to=\(format)"))
        }
        return items
    }

    private static func resize(_ domain: String, _ a: Double, _ b: Double) -> MenuNode {
        let id = "\(domain).resize"
        let verb = id + "?scale="
        let first = Formatting.number(a > 0 ? a : 50)
        let second = Formatting.number(b > 0 ? b : 25)
        return .popup(id, Loc.t("menu.\(domain).resize"), [
            .leaf(id + ".p1", first + "%", verb + first),
            .leaf(id + ".p2", second + "%", verb + second),
            .leaf(id + ".custom", Loc.t("menu.custom"), verb + "custom"),
        ])
    }

    private static func rotate(_ domain: String, _ values: [Double]) -> MenuNode {
        let id = "\(domain).rotate"
        let verb = id + "?deg="
        let children = values.enumerated().map { index, value -> MenuNode in
            let text = Formatting.number(value)
            return .leaf(id + ".p\(index + 1)", text + "°", verb + text)
        }
        return .popup(id, Loc.t("menu.\(domain).rotate"), children)
    }

    private static func compressItem(_ bytes: Int64, fallback: Int64, id: String, verb: String,
                                     maxSize: UInt64) -> MenuNode? {
        let value = bytes > 0 ? bytes : fallback
        if maxSize <= UInt64(value) { return nil }
        return .leaf(id, Formatting.shortBytes(value), verb + String(value))
    }

    private static func conversions(_ all: [String], present: Set<String>, domain: String) -> [MenuNode] {
        all.filter { !present.contains($0) }.map {
            .leaf("\(domain).convert.\($0)", toPrefix + $0, "\(domain).convert?to=\($0)")
        }
    }

    private static func image(_ selection: SelectionInfo, _ presets: ImagePresets) -> [MenuNode] {
        let mib: Int64 = 1024 * 1024
        let verb = "image.compress?bytes="
        var compress = [
            compressItem(presets.compressA, fallback: 10 * mib, id: "image.compress.p1", verb: verb, maxSize: selection.maxSize),
            compressItem(presets.compressB, fallback: 5 * mib, id: "image.compress.p2", verb: verb, maxSize: selection.maxSize),
            compressItem(presets.compressC, fallback: 3 * mib, id: "image.compress.p3", verb: verb, maxSize: selection.maxSize),
            compressItem(presets.compressD, fallback: 1 * mib, id: "image.compress.p4", verb: verb, maxSize: selection.maxSize),
        ].compactMap { $0 }
        compress.append(.leaf("image.compress.custom", Loc.t("menu.custom"), verb + "custom"))

        var items = [
            resize("image", presets.resizeA, presets.resizeB),
            .popup("image.compress", Loc.t("menu.image.compress"), compress),
            rotate("image", [presets.rotateA, presets.rotateB, presets.rotateC]),
        ]
        if !selection.hasAnimatedGif {
            let convert = conversions(Selection.imageFormats, present: selection.formats, domain: "image")
            if !convert.isEmpty { items.append(.popup("image.convert", Loc.t("menu.image.convert"), convert)) }
        }
        items.append(.leaf("image.ocr", Loc.t("menu.image.ocr"), "image.ocr"))
        items.append(.leaf("image.strip", Loc.t("menu.image.strip"), "image.strip"))
        items.append(.leaf("image.chromakey", Loc.t("menu.image.chromakey"), "image.chromakey"))
        return items
    }

    private static func video(_ selection: SelectionInfo, _ presets: VideoPresets) -> [MenuNode] {
        let mib: Int64 = 1024 * 1024
        let verb = "video.compress?bytes="
        var compress: [MenuNode] = []

        let discord = presets.compressDiscord > 0 ? presets.compressDiscord : 20 * mib
        if selection.maxSize > UInt64(discord) {
            compress.append(.leaf("video.compress.discord",
                                  "\(Loc.t("menu.video.compress.discord")) (\(Formatting.shortBytes(discord)))",
                                  "video.compress?preset=discord"))
        }
        compress += [
            compressItem(presets.compressA, fallback: 50 * mib, id: "video.compress.p1", verb: verb, maxSize: selection.maxSize),
            compressItem(presets.compressB, fallback: 25 * mib, id: "video.compress.p2", verb: verb, maxSize: selection.maxSize),
            compressItem(presets.compressC, fallback: 5 * mib, id: "video.compress.p3", verb: verb, maxSize: selection.maxSize),
        ].compactMap { $0 }
        compress.append(.leaf("video.compress.custom", Loc.t("menu.custom"), verb + "custom"))

        var items = [resize("video", presets.resizeA, presets.resizeB)]
        if selection.paths.count == 1 {
            items.append(.leaf("video.trim", Loc.t("menu.video.trim"), "video.trim"))
            items.append(.leaf("video.thumbnail", Loc.t("menu.video.thumbnail"), "video.thumbnail"))
        }
        items.append(.leaf("video.subtitles", Loc.t("menu.video.subtitles"), "video.subtitles"))
        items.append(.popup("video.compress", Loc.t("menu.video.compress"), compress))
        items.append(rotate("video", [presets.rotateA, presets.rotateB, presets.rotateC]))

        var convert = conversions(Selection.videoFormats, present: selection.formats, domain: "video")
        convert.append(.leaf("video.convert.GIF", toPrefix + "GIF", "video.convert?to=GIF"))
        items.append(.popup("video.convert", Loc.t("menu.video.convert"), convert))

        let extract = Selection.audioFormats.map {
            MenuNode.leaf("video.extractAudio.\($0)", toPrefix + $0, "video.extractAudio?to=\($0)")
        }
        items.append(.popup("video.extractAudio", Loc.t("menu.video.extractAudio"), extract))
        return items
    }

    private static func audio(_ selection: SelectionInfo) -> [MenuNode] {
        var items: [MenuNode] = []
        let convert = conversions(Selection.audioFormats, present: selection.formats, domain: "audio")
        if !convert.isEmpty { items.append(.popup("audio.convert", Loc.t("menu.audio.convert"), convert)) }
        items.append(.leaf("audio.subtitles", Loc.t("menu.audio.subtitles"), "audio.subtitles"))
        return items
    }

    static func textTargets(from source: String) -> [String] {
        var targets = source == "TXT" ? [] : ["TXT"]
        switch source {
        case "CSV": targets += ["JSON", "XML", "HTML", "MD"]
        case "JSON": targets += ["CSV", "XML"]
        case "XML": targets += ["JSON"]
        case "INI", "CFG": targets += ["JSON", "XML"]
        default: break
        }
        return targets
    }

    private static func text(_ selection: SelectionInfo) -> [MenuNode] {
        var items: [MenuNode] = []
        if selection.formats.count == 1, let source = selection.formats.first {
            let convert = textTargets(from: source).map {
                MenuNode.leaf("text.convert.\($0)", toPrefix + $0, "text.convert?to=\($0)")
            }
            if !convert.isEmpty { items.append(.popup("text.convert", Loc.t("menu.text.convert"), convert)) }
        }

        items.append(.popup("text.encode", Loc.t("menu.text.encode"), [
            .leaf("text.encode.UTF8", "to UTF-8", "text.encode?to=UTF8"),
            .leaf("text.encode.UTF8BOM", "to UTF-8 (BOM)", "text.encode?to=UTF8BOM"),
            .leaf("text.encode.UTF16", "to UTF-16", "text.encode?to=UTF16"),
            .leaf("text.encode.SJIS", "to Shift_JIS", "text.encode?to=SJIS"),
        ]))
        items.append(.popup("text.lineEndings", Loc.t("menu.text.lineEndings"), [
            .leaf("text.lineEndings.CRLF", "to CRLF (Windows)", "text.lineEndings?to=CRLF"),
            .leaf("text.lineEndings.LF", "to LF (Unix)", "text.lineEndings?to=LF"),
        ]))
        if selection.allJson {
            items.append(.leaf("json.pretty", Loc.t("menu.json.pretty"), "json.pretty"))
            items.append(.leaf("json.sort", Loc.t("menu.json.sort"), "json.sort"))
        }
        return items
    }

    private static func prune(_ nodes: [MenuNode], hidden: Set<String>) -> [MenuNode] {
        nodes.compactMap { node in
            if hidden.contains(node.id) { return nil }
            if node.children.isEmpty { return node }
            var copy = node
            copy.children = prune(node.children, hidden: hidden)
            return copy.children.isEmpty ? nil : copy
        }
    }
}
