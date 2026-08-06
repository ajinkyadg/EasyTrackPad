// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InputCustomizer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "InputCustomizer",
            path: "Sources/InputCustomizer",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "InputCustomizerTests",
            dependencies: ["InputCustomizer"],
            path: "Tests/InputCustomizerTests"
        )
    ]
)
