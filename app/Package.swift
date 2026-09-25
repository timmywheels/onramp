// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "onramp",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "onramp_coreFFI", path: "Frameworks/onramp_core.xcframework"),
        .executableTarget(
            name: "onramp",
            dependencies: ["onramp_coreFFI"],
            resources: [.copy("Extensions"), .copy("Reviewers"), .copy("AppIcon.icns")] // built-in extensions (fonts, themes, languages), the app icon
        ),
    ]
)
