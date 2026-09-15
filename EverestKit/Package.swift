// swift-tools-version: 6.2
// `.macOS(.v26)` requires PackageDescription 6.2; tools-version 6.0 rejects it.
import PackageDescription

// Everything testable lives here, and every target has a test target.
//
// This shape is forced by AGENTS.md section 0: the codebase is test-driven, and
// TDD needs a runner you can point at a failing test BEFORE an app exists. The
// previous layout put Selection, Replacement, Engines and Overlay as loose files
// inside the .app target, where `swift test` could not reach them and the only
// possible verification was a manual harness. AppKit and Accessibility code runs
// fine in a SwiftPM macOS library, so there was never a reason for it.
//
// The .app target is a thin shell that links these products. Keep it thin: if
// logic lands in the app target it becomes untestable again.

// Every source directory carries AGENTS.md + CLAUDE.md per the doc convention.
// SwiftPM treats unrecognised files in Sources/ as unhandled resources and warns
// once per file per build. Left alone that is eight warnings on every build,
// which is worse than noise: it teaches everyone to skim past warnings, and the
// next real one gets skimmed past too.
let docs = ["AGENTS.md", "CLAUDE.md"]

let package = Package(
    name: "EverestKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RewriteCore", targets: ["RewriteCore"]),
        .library(name: "TextBridge", targets: ["TextBridge"]),
        .library(name: "Engines", targets: ["Engines"]),
        .library(name: "Overlay", targets: ["Overlay"]),
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.10.1"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
    ],
    targets: [
        // Pure. No AppKit, no Accessibility, no network. Keep it that way:
        // this is the target that runs in two seconds with no permissions.
        .target(name: "RewriteCore", exclude: docs),
        .testTarget(name: "RewriteCoreTests", dependencies: ["RewriteCore"]),

        // Reading the selection out of other apps, and writing it back.
        // AppKit + ApplicationServices. The highest-risk code in the project.
        .target(name: "TextBridge", dependencies: ["RewriteCore"], exclude: docs),
        .testTarget(name: "TextBridgeTests", dependencies: ["TextBridge"]),

        .target(
            name: "Engines",
            dependencies: [
                "RewriteCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            exclude: docs
        ),
        .testTarget(name: "EnginesTests", dependencies: ["Engines"]),

        .target(name: "Overlay", dependencies: ["RewriteCore"], exclude: docs),
        .testTarget(name: "OverlayTests", dependencies: ["Overlay"]),

        // The app shell's decisions, so they are testable. The .app target
        // itself stays a wiring shell: NSApplicationDelegate, NSStatusItem,
        // KeyboardShortcuts, SMAppService, SwiftUI views, engine construction.
        // Any branch that lands in the app target is untestable, which is the
        // mistake that forced this project to be rebuilt once.
        //
        // AppCore deliberately imports neither SwiftUI nor KeyboardShortcuts:
        // view models are plain ObservableObject, and the recorder UI is
        // app-target wiring.
        .target(
            name: "AppCore",
            dependencies: ["RewriteCore", "TextBridge", "Engines", "Overlay"],
            exclude: docs
        ),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
    ]
)
