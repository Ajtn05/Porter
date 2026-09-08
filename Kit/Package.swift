// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Porter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PorterKit", targets: ["PorterKit"])
    ],
    targets: [
        .target(
            name: "PorterKit",
            path: "Sources/PorterKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "porterctl",
            dependencies: ["PorterKit"],
            path: "Sources/porterctl",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PorterKitTests",
            dependencies: ["PorterKit"],
            path: "Tests/PorterKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
