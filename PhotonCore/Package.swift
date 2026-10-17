// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotonCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PhotonCore", targets: ["PhotonCore"]),
    ],
    targets: [
        .target(
            name: "PhotonCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
        .executableTarget(name: "PhotonSim", dependencies: ["PhotonCore"]),
        .testTarget(name: "PhotonCoreTests", dependencies: ["PhotonCore"]),
    ]
)
