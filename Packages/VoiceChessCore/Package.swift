// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceChessCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "VoiceChessCore", targets: ["VoiceChessCore"]),
    ],
    targets: [
        .target(name: "VoiceChessCore"),
        .testTarget(name: "VoiceChessCoreTests", dependencies: ["VoiceChessCore"]),
    ]
)
