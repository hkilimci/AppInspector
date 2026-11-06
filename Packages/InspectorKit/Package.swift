// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InspectorKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "InspectorModel", targets: ["InspectorModel"]),
        .library(name: "InspectorParsers", targets: ["InspectorParsers"]),
        .library(name: "InspectorPlatform", targets: ["InspectorPlatform"]),
        .library(name: "InspectorAssociation", targets: ["InspectorAssociation"]),
        .library(name: "InspectorSources", targets: ["InspectorSources"]),
    ],
    targets: [
        .target(name: "InspectorModel"),
        .target(name: "InspectorParsers", dependencies: ["InspectorModel"]),
        .target(name: "InspectorPlatform", dependencies: ["InspectorModel", "InspectorParsers"]),
        .target(name: "InspectorAssociation", dependencies: ["InspectorModel"]),
        .target(name: "InspectorSources", dependencies: ["InspectorModel", "InspectorParsers", "InspectorPlatform", "InspectorAssociation"]),
        .testTarget(name: "InspectorModelTests", dependencies: ["InspectorModel"]),
        .testTarget(name: "InspectorParsersTests", dependencies: ["InspectorParsers", "InspectorModel"]),
        .testTarget(name: "InspectorPlatformTests", dependencies: ["InspectorPlatform", "InspectorModel"]),
        .testTarget(name: "InspectorAssociationTests", dependencies: ["InspectorAssociation", "InspectorModel"]),
        .testTarget(name: "InspectorSourcesTests", dependencies: ["InspectorSources", "InspectorPlatform", "InspectorParsers", "InspectorModel"]),
    ]
)
