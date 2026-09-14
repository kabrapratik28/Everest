// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RewriteCore",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "RewriteCore",
            targets: ["RewriteCore"]
        )
    ],
    targets: [
        .target(
            name: "RewriteCore"
        ),
        .testTarget(
            name: "RewriteCoreTests",
            dependencies: ["RewriteCore"]
        ),
    ]
)
