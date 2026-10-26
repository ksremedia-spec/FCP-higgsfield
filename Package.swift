// swift-tools-version:5.9
import PackageDescription

// HiggsfieldKit is Foundation-only so it builds and tests on Linux as well as macOS.
// HiggsfieldPanel is the SwiftUI panel shared by the container app and the
// Final Cut Pro workflow extension; its sources compile only on macOS.
let package = Package(
    name: "HiggsfieldFCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HiggsfieldKit", targets: ["HiggsfieldKit"]),
        .library(name: "HiggsfieldPanel", targets: ["HiggsfieldPanel"]),
        .executable(name: "hfcp", targets: ["hfcp"]),
    ],
    targets: [
        .target(name: "HiggsfieldKit"),
        .target(
            name: "HiggsfieldPanel",
            dependencies: ["HiggsfieldKit"]
        ),
        .executableTarget(
            name: "hfcp",
            dependencies: ["HiggsfieldKit"]
        ),
        .testTarget(
            name: "HiggsfieldPanelTests",
            dependencies: ["HiggsfieldPanel", "HiggsfieldKit"]
        ),
        .testTarget(
            name: "HiggsfieldKitTests",
            dependencies: ["HiggsfieldKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
