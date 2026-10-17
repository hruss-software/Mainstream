// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MainstreamCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MainstreamCore", targets: ["MainstreamCore"]),
    ],
    targets: [
        .target(
            name: "MainstreamCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
        .executableTarget(name: "MainstreamSim", dependencies: ["MainstreamCore"]),
        .testTarget(name: "MainstreamCoreTests", dependencies: ["MainstreamCore"]),
    ]
)
