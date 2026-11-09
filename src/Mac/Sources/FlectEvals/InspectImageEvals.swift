import CoreGraphics
import Foundation
import ImageIO
import FlectCore
import FlectKit

enum InspectImageEvals {
    static func register(_ suite: Suite) {
        suite.test("Analyze reports a PNG renamed to WEBP as PNG", category: "core") {
            let folder = try Paths.folder("file-png")
            let png = Paths.join(folder, "real.png")
            try Fixtures.save(solid(12, 7, red: 1, blue: 0), png, type: "public.png")
            let spoof = Paths.join(folder, "spoof.webp")
            try FileManager.default.copyItem(atPath: png, toPath: spoof)
            let size = Paths.size(spoof)
            let stamp = try modified(spoof)

            let report = try await Examine.inspect(spoof)

            try expect(Paths.size(spoof) == size && (try modified(spoof)) == stamp, "the file was changed")
            try expect(report.alerts.contains { $0.contains("WEBP") && $0.contains("PNG") }, "alerts \(report.alerts)")
            try expect(value(report, "Contents") == "PNG", "contents \(value(report, "Contents"))")
            try expect(value(report, "Dimensions") == "12 x 7", "dimensions \(value(report, "Dimensions"))")
        }

        suite.test("Analyze lists the camera make of a JPEG", category: "core") {
            let folder = try Paths.folder("file-exif")
            let path = Paths.join(folder, "camera.jpg")
            try Fixtures.save(solid(8, 6, red: 0, blue: 1), path, type: "public.jpeg", properties: [
                kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "FlectCam"],
            ])

            let report = try await Examine.inspect(path)

            try expect(value(report, "Contents") == "JPEG", "contents \(value(report, "Contents"))")
            try expect(value(report, "Dimensions") == "8 x 6", "dimensions \(value(report, "Dimensions"))")
            try expect(value(report, "Make") == "FlectCam", "make \(value(report, "Make"))")
            try expect(report.alerts.isEmpty, "alerts \(report.alerts)")
        }

        suite.test("Analyze reports SVG structure", category: "core") {
            let folder = try Paths.folder("file-svg")
            let path = Paths.join(folder, "icon.svg")
            try Data("""
                <svg xmlns="http://www.w3.org/2000/svg" width="10" height="20" viewBox="0 0 10 20">
                  <image href="https://example.test/a.png"/>
                  <script></script>
                </svg>
                """.utf8).write(to: URL(fileURLWithPath: path))

            let report = try await Examine.inspect(path)

            try expect(value(report, "Contents") == "SVG", "contents \(value(report, "Contents"))")
            try expect(value(report, "viewBox") == "0 0 10 20", "viewBox \(value(report, "viewBox"))")
            try expect(value(report, "Scripts") == "1", "scripts \(value(report, "Scripts"))")
            try expect(value(report, "External references") == "1", "external \(value(report, "External references"))")
            try expect(report.alerts.isEmpty, "alerts \(report.alerts)")
        }

        suite.test("Analyze reports PDF page size and bookmark count", category: "core") {
            let folder = try Paths.folder("file-pdf")
            let path = Paths.join(folder, "doc.pdf")
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else {
                throw EvalFailure(description: "cannot create pdf")
            }
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()

            let report = try await Examine.inspect(path)

            try expect(value(report, "Contents") == "PDF", "contents \(value(report, "Contents"))")
            try expect(value(report, "Pages") == "1", "pages \(value(report, "Pages"))")
            try expect(value(report, "Page size").contains("A4"), "page size \(value(report, "Page size"))")
            try expect(value(report, "Bookmarks") == "0", "bookmarks \(value(report, "Bookmarks"))")
            try expect(value(report, "Encrypted") == "No", "encrypted \(value(report, "Encrypted"))")
            try expect(value(report, "Printing") == "Yes", "printing \(value(report, "Printing"))")
        }
    }

    private static func solid(_ width: Int, _ height: Int, red: CGFloat, blue: CGFloat) -> CGImage {
        Fixtures.canvas(width, height) { context in
            context.setFillColor(CGColor(srgbRed: red, green: 0, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func modified(_ path: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private static func value(_ report: FileReport, _ label: String) -> String {
        (report.overview + report.sections.flatMap(\.rows)).first { $0.label == label }?.value ?? ""
    }
}
