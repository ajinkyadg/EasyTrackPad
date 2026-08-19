// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InputCustomizerLite",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .systemLibrary(
            name: "CMultitouchSupport",
            path: "Sources/CMultitouchSupport"
        ),
        // Pure gesture-recognition layer: the multitouch wrapper, the
        // finger-count/direction/tap state machine, and the vocabulary of
        // recognizable gestures (`GestureKind`) they produce. No SwiftUI/
        // AppKit UI imports — the compiler enforces that a Views change can
        // never accidentally reach into recognition internals, and this
        // target's own test coverage can never accidentally depend on UI
        // state.
        .target(
            name: "GestureEngine",
            dependencies: ["CMultitouchSupport"],
            path: "Sources/GestureEngine"
        ),
        // Rule/profile/action data model — what a user-configured
        // customization *is* (Codable, no side effects). Depends on
        // GestureEngine for the gesture vocabulary a trigger can reference,
        // nothing else; deliberately can't reach into how an action is
        // actually performed or how the UI is built.
        .target(
            name: "InputModels",
            dependencies: ["GestureEngine"],
            path: "Sources/InputModels"
        ),
        // The only place that actually performs a rule's action (posts
        // CGEvents, launches apps, runs shell commands). Isolated so a
        // change to *how* an action executes can never accidentally touch
        // recognition or model code, and vice versa.
        .target(
            name: "ActionExecution",
            dependencies: ["InputModels"],
            path: "Sources/ActionExecution"
        ),
        // Everything AppKit/SwiftUI-specific: live event taps and NSEvent
        // monitors (Managers), persistence (Storage), and all Views/App.swift.
        // This is the only target allowed to import SwiftUI/AppKit UI or own
        // a running event tap — GestureEngine/InputModels/ActionExecution
        // are all UI-free by construction.
        .executableTarget(
            name: "InputCustomizer",
            dependencies: ["GestureEngine", "InputModels", "ActionExecution"],
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
            dependencies: ["InputCustomizer", "GestureEngine", "InputModels", "ActionExecution"],
            path: "Tests/InputCustomizerTests"
        )
    ]
)
