// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "pairprogram",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "pairprogram_coreFFI", path: "Frameworks/pairprogram_core.xcframework"),
        .executableTarget(
            name: "pairprogram",
            dependencies: ["pairprogram_coreFFI"],
            resources: [.copy("Extensions"), .copy("AppIcon.icns")] // built-in extensions (fonts, themes, languages), the app icon
        ),
    ]
)
