import CoreGraphics
import Foundation
import PDFKit
import FlectKit

final class PdfPreview: FlectTask {
    override var title: String { Loc.t("menu.pdf.preview") }
    override var showsProgress: Bool { false }

    override func present(_ ui: Interaction) async {
        if let path = request.paths.first { await ui.showPdfPreview(path: path) }
    }
}

final class PdfMerge: FlectTask {
    private var sources: [String] = []
    private var output: String?

    override var title: String { Loc.t("menu.pdf.merge") }

    override var summary: String? {
        output.map { Loc.f("msg.mergedInto", Loc.n("count.document", sources.count), ($0 as NSString).lastPathComponent) }
    }

    override func configure(_ ui: Interaction) async -> Bool {
        let sorted = request.paths.sorted {
            ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
        if request["order"] == "name" {
            sources = sorted
            return true
        }
        guard let chosen = await ui.askPdfOrder(sorted) else { return false }
        sources = chosen
        return true
    }

    override func run(_ progress: TaskProgress) async throws {
        progress.indeterminate()
        progress.status(Loc.t("msg.merging"))

        let merged = PDFDocument()
        for source in sources {
            try Task.checkCancellation()
            guard let document = PDFDocument(url: URL(fileURLWithPath: source)) else {
                throw FlectError("\(fileName(source)) - This document could not be read.")
            }
            if document.isLocked { throw FlectError("\(fileName(source)) - This document is password protected.") }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }

        let destination = try OutputPath.derive(sources[0], suffix: "_merged", extension: ".pdf")
        try await OutputPath.producing(destination) {
            guard merged.write(to: URL(fileURLWithPath: destination)) else { throw FlectError("The merged PDF could not be written.") }
        }
        output = destination
    }
}

final class PdfConvert: BatchTask {
    private static let dpi = 150.0

    private var target = "PNG"

    override var title: String { Loc.t("menu.pdf.convert") }

    override func configure(_ ui: Interaction) async -> Bool {
        target = (request["to"] ?? "PNG").uppercased()
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw FlectError("This document could not be read.")
        }
        if document.isLocked { throw FlectError("This document is password protected.") }
        if target == "TXT" {
            try await extractText(document, path)
        } else {
            try await renderPages(document, path, progress)
        }
    }

    private func extractText(_ document: PDFDocument, _ path: String) async throws {
        let output = try OutputPath.derive(path, extension: ".txt")
        var text = ""
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            text += (document.page(at: index)?.string ?? "") + "\n\n"
        }
        try await OutputPath.producing(output) {
            try Data(text.utf8).write(to: URL(fileURLWithPath: output))
        }
    }

    private func renderPages(_ document: PDFDocument, _ path: String, _ progress: TaskProgress) async throws {
        let pages = document.pageCount
        if pages == 0 { throw FlectError(Loc.t("msg.noPages")) }

        let format: ImageFormat = target == "JPG" ? .jpeg : .png
        let width = String(pages).count
        let name = fileName(path)

        for index in 0..<pages {
            try Task.checkCancellation()
            progress.status(Loc.f("msg.pageOf", name, index + 1, pages))
            guard let page = document.page(at: index) else { continue }

            let suffix = pages == 1 ? "" : "_p" + String(index + 1).leftPadded(width, with: "0")
            let output = try OutputPath.derive(path, suffix: suffix, extension: format == .jpeg ? ".jpg" : ".png")
            let image = PdfRenderer.render(page, dpi: PdfConvert.dpi)
            try await OutputPath.producing(output) {
                try ImageCodec.encode(image, as: format, quality: format == .jpeg ? 0.9 : nil)
                    .write(to: URL(fileURLWithPath: output))
            }
        }
    }
}

enum PdfRenderer {
    static func render(_ page: PDFPage, dpi: Double) -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let scale = dpi / 72
        let width = max(1, Int(((turned ? bounds.height : bounds.width) * scale).rounded()))
        let height = max(1, Int(((turned ? bounds.width : bounds.height) * scale).rounded()))

        var bitmap = Bitmap(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        bitmap.pixels.withUnsafeMutableBytes { buffer in
            guard let context = Bitmap.context(buffer.baseAddress, width, height, bitmap.colorSpace) else { return }
            context.setFillColor(ImageOps.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
        }
        return bitmap.makeImage()
    }
}

final class JarDecompile: BatchTask {
    override var title: String { Loc.t("menu.jar.decompile") }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let java = try Tools.java()
        let cfr = try Tools.cfrJar()

        let root = Settings.current.code.decompile.outputPath.trimmingCharacters(in: .whitespaces)
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let destination = try root.isEmpty
            ? OutputPath.deriveDirectory(path)
            : OutputPath.deriveDirectory(((root as NSString).expandingTildeInPath as NSString).appendingPathComponent(stem))
        try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)

        progress.status(Loc.f("msg.decompiling", fileName(path)))
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(atPath: destination) } }

        try await ProcessRunner.runOrThrow(java, ["-jar", cfr, path, "--outputdir", destination])
        if ((try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []).isEmpty {
            throw FlectError(Loc.t("msg.decompileEmpty"))
        }
        finished = true
    }
}
