// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SystemKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SystemKit", targets: ["SystemKit"]),
        .executable(name: "perfcheck", targets: ["perfcheck"]),
        .executable(name: "sistem-probe", targets: ["sistem-probe"]),
    ],
    targets: [
        .target(name: "CPrivate", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "SystemKit", dependencies: ["CPrivate"]),
        .executableTarget(name: "perfcheck", dependencies: ["SystemKit"]),
        .executableTarget(name: "sistem-probe", dependencies: ["SystemKit"]),
        .testTarget(name: "SystemKitTests", dependencies: ["SystemKit"]),
    ]
)
