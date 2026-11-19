// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiddleMove",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MiddleMove",
            path: "Sources/MiddleMove",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
