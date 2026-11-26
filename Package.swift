// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IppleMusic",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "IppleMusicMac", targets: ["IppleMusicMac"]),
        .library(name: "MusicCore", targets: ["MusicCore"]),
    ],
    targets: [
        .target(name: "MusicCore"),
        .executableTarget(
            name: "IppleMusicMac",
            dependencies: ["MusicCore"],
            resources: [.copy("Resources/PlayingWaveform.gif"), .copy("Resources/LoginCovers")]
        ),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"]),
    ]
)
