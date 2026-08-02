// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PatchworkServerKit",
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "PatchworkServerKit", targets: ["PatchworkServerKit"])
    ],
    targets: [
        .binaryTarget(
            name: "PatchworkServerFFI",
            path: "Artifacts/PatchworkServerFFI.xcframework"
        ),
        .target(
            name: "PatchworkServerKit",
            dependencies: ["PatchworkServerFFI"],
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
    ]
)
