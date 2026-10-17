// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LinkCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LinkCore", targets: ["LinkCore"]),
    ],
    targets: [
        .target(
            name: "LinkCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
        .executableTarget(name: "LinkSim", dependencies: ["LinkCore"]),
        .testTarget(name: "LinkCoreTests", dependencies: ["LinkCore"]),
    ]
)
