// swift-tools-version: 6.0
import PackageDescription

// Dev harness: `swift run` / Tools/make-app-bundle.sh. The shipping target is the Xcode project (Developer ID, hardened runtime, no sandbox).
let package = Package(
    name: "AppInspector",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Packages/InspectorKit"),
        // Pinned like Panoramac; bump deliberately and re-test the update path.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "AppInspector",
            dependencies: [
                .product(name: "InspectorModel", package: "InspectorKit"),
                .product(name: "InspectorParsers", package: "InspectorKit"),
                .product(name: "InspectorPlatform", package: "InspectorKit"),
                .product(name: "InspectorSources", package: "InspectorKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .testTarget(name: "AppInspectorTests", dependencies: [
            "AppInspector",
            .product(name: "InspectorModel", package: "InspectorKit"),
        ]),
    ]
)
