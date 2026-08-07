// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InputCustomizer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .systemLibrary(
            name: "CMultitouchSupport",
            path: "Sources/CMultitouchSupport"
        ),
        .executableTarget(
            name: "InputCustomizer",
            dependencies: ["CMultitouchSupport"],
            path: "Sources/InputCustomizer",
            exclude: [
                "Resources/Info.plist"
            ],
            linkerSettings: [
                // MultitouchSupport.framework is a private framework with no
                // public SDK entry, so it isn't on the default framework
                // search path — point the linker at it explicitly.
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "MultitouchSupport"
                ])
            ]
        ),
        .testTarget(
            name: "InputCustomizerTests",
            dependencies: ["InputCustomizer"],
            path: "Tests/InputCustomizerTests"
        )
    ]
)
