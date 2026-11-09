import Foundation
import PDFKit
import FlectKit

// Ported from src/App/Inspect/Detail/PdfDetail.cs. PDFKit stands in for PdfPig; the info strings and the embedded
// file names come from the raw Core Graphics dictionaries so they read as PdfPig shows them.
enum PdfDetail {
    // PdfPig's PageSize table, in whole points.
    private static let sizes: [(name: String, width: Int, height: Int)] = [
        ("A0", 2384, 3370), ("A1", 1684, 2384), ("A2", 1191, 1684), ("A3", 842, 1191), ("A4", 595, 842),
        ("A5", 420, 595), ("A6", 298, 420), ("A7", 210, 298), ("A8", 147, 210), ("A9", 105, 147), ("A10", 74, 105),
        ("Letter", 612, 792), ("Legal", 612, 1008), ("Ledger", 1224, 792), ("Tabloid", 792, 1224), ("Executive", 522, 756),
    ]

    static func read(_ path: String) throws -> ProbeResult? {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw FlectError("This document could not be read.")
        }
        let bag = FactBag()
        if document.isLocked {
            bag.add("dialog.fileAnalyze.encrypted", Kinds.yesNo(true))
            bag.add("dialog.fileAnalyze.password", Loc.t("dialog.fileAnalyze.passwordBody"))
            return bag.result("dialog.fileAnalyze.pdf", kind: "PDF")
        }

        bag.add("dialog.fileAnalyze.version", "\(document.majorVersion).\(document.minorVersion)")
        bag.add("dialog.fileAnalyze.pages", String(document.pageCount))
        bag.add("dialog.fileAnalyze.pageSize", pageSizes(document))
        bag.add("dialog.fileAnalyze.encrypted", Kinds.yesNo(document.isEncrypted))
        bag.add("dialog.fileAnalyze.print", Kinds.yesNo(!document.isEncrypted || document.allowsPrinting))
        bag.add("dialog.fileAnalyze.copy", Kinds.yesNo(!document.isEncrypted || document.allowsCopying))

        let info = document.documentRef?.info
        for (key, name) in [("metaTitle", "Title"), ("author", "Author"), ("subject", "Subject"), ("keywords", "Keywords"),
                            ("creator", "Creator"), ("producer", "Producer"), ("pdfCreated", "CreationDate"),
                            ("pdfModified", "ModDate")] {
            bag.add("dialog.fileAnalyze." + key, string(info, name))
        }
        bag.add("dialog.fileAnalyze.bookmarks", String(count(document.outlineRoot)))
        bag.add("dialog.fileAnalyze.embedded", embedded(document.documentRef))
        return bag.result("dialog.fileAnalyze.pdf", kind: "PDF")
    }

    private static func count(_ node: PDFOutline?) -> Int {
        guard let node else { return 0 }
        return (0..<node.numberOfChildren).reduce(0) { $0 + 1 + count(node.child(at: $1)) }
    }

    private static func embedded(_ document: CGPDFDocument?) -> String {
        var total = 0
        var names: [String] = []
        func walk(_ node: CGPDFDictionaryRef, _ depth: Int) {
            guard depth < 32 else { return }
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Names", &array), let array {
                for index in stride(from: 0, to: CGPDFArrayGetCount(array) - 1, by: 2) {
                    total += 1
                    var name: CGPDFStringRef?
                    if CGPDFArrayGetString(array, index, &name), let name, let text = CGPDFStringCopyTextString(name) as String?,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        names.append(text)
                    }
                }
            }
            if CGPDFDictionaryGetArray(node, "Kids", &array), let array {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var kid: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(array, index, &kid), let kid { walk(kid, depth + 1) }
                }
            }
        }
        if let catalog = document?.catalog, let tree = dictionary(dictionary(catalog, "Names"), "EmbeddedFiles") {
            walk(tree, 0)
        }

        if total == 0 { return Loc.t("dialog.fileAnalyze.none") }
        if names.isEmpty { return String(total) }
        if names.count <= 30 { return names.joined(separator: ", ") }
        return names.prefix(30).joined(separator: ", ") + " +" + String(names.count - 30)
    }

    private static func pageSizes(_ document: PDFDocument) -> String? {
        if document.pageCount == 0 { return nil }
        var groups: [(label: String, count: Int)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            let turned = page.rotation % 180 != 0
            let width = Double(turned ? box.height : box.width)
            let height = Double(turned ? box.width : box.height)
            let label = sizeName(width, height).map { "\($0) (\(millimetres(width, height)))" } ?? millimetres(width, height)
            if let group = groups.firstIndex(where: { $0.label == label }) { groups[group].count += 1 } else { groups.append((label, 1)) }
        }
        if groups.count == 1 { return groups[0].label }
        return groups.map { "\($0.label) x \($0.count)" }.joined(separator: ", ")
    }

    private static func sizeName(_ width: Double, _ height: Double) -> String? {
        let wide = Int(width.rounded())
        let high = Int(height.rounded())
        return (sizes.first { $0.width == wide && $0.height == high } ?? sizes.first { $0.width == high && $0.height == wide })?.name
    }

    private static func millimetres(_ width: Double, _ height: Double) -> String {
        "\(ImageDetail.decimal(width / 72 * 25.4, 1)) x \(ImageDetail.decimal(height / 72 * 25.4, 1)) mm"
    }

    private static func dictionary(_ parent: CGPDFDictionaryRef?, _ key: String) -> CGPDFDictionaryRef? {
        guard let parent else { return nil }
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(parent, key, &value) ? value : nil
    }

    private static func string(_ parent: CGPDFDictionaryRef?, _ key: String) -> String? {
        guard let parent else { return nil }
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(parent, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }
}
