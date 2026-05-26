// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoSubtitlePlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VideoSubtitlePlayer",
            path: "Sources/VideoSubtitlePlayer",
            linkerSettings: [
                .linkedFramework("OpenGL"),
                .linkedFramework("Translation"),
            ]
        )
    ]
)
