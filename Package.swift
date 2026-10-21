// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "reawm",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Core"),
        .executableTarget(
            name: "reawm",
            dependencies: ["Core"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ],
    swiftLanguageModes: [.v5]
)
