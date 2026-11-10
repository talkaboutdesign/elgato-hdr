// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "ElgatoHDR",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "StudioKit", path: "Sources/StudioKit"),
        .executableTarget(name: "ElgatoHDR", dependencies: ["StudioKit"], path: "Sources/ElgatoHDR"),
        .testTarget(name: "StudioKitTests", dependencies: ["StudioKit"], path: "Tests/StudioKitTests", resources: [.copy("Fixtures")]),
    ]
)
