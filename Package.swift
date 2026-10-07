// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacOS_installer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macos-installer", targets: ["macos-installer"]),
        .library(name: "MacOSInstallerKit", targets: ["MacOSInstallerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "macos-installer",
            dependencies: [
                "MacOSInstallerKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "MacOSInstallerKit"),
        .testTarget(
            name: "MacOSInstallerKitTests",
            dependencies: ["MacOSInstallerKit", "macos-installer"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
