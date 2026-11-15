// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Flect",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Flect", targets: ["FlectApp"]),
        .executable(name: "FlectFinder", targets: ["FlectFinder"]),
        .executable(name: "FlectPreview", targets: ["FlectPreview"]),
        .executable(name: "FlectEvals", targets: ["FlectEvals"]),
    ],
    targets: [
        .target(
            name: "CWebP",
            exclude: ["COPYING", "PATENTS", "AUTHORS", "README.md"],
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags(["-O2", "-w"]),
            ]
        ),
        .target(name: "FlectKit"),
        .target(
            name: "FlectCore",
            dependencies: ["FlectKit", "CWebP"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Vision"),
            ]
        ),
        .executableTarget(
            name: "FlectApp",
            dependencies: ["FlectCore"],
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("FinderSync"),
            ]
        ),
        .executableTarget(
            name: "FlectFinder",
            dependencies: ["FlectKit"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("FinderSync"),
                .unsafeFlags(["-Xlinker", "-application_extension"]),
            ]
        ),
        .target(
            name: "FlectPreviewKit",
            dependencies: ["FlectKit"],
            swiftSettings: [.unsafeFlags(["-application-extension"])]
        ),
        .executableTarget(
            name: "FlectPreview",
            dependencies: ["FlectPreviewKit"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(["-Xlinker", "-application_extension"]),
            ]
        ),
        .executableTarget(
            name: "FlectEvals",
            dependencies: ["FlectCore", "FlectPreviewKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
