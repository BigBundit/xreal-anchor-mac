// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XrealAnchor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CVirtualDisplay", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "XrealKit", linkerSettings: [.linkedFramework("IOKit"), .linkedLibrary("z")]),
        .executableTarget(name: "imuprobe", dependencies: ["XrealKit"]),
        .executableTarget(
            name: "XrealAnchor",
            dependencies: ["XrealKit", "CVirtualDisplay"]
        ),
    ]
)
