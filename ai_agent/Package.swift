// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceAgent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VoiceAgent", targets: ["VoiceAgent"])],
    targets: [.executableTarget(name: "VoiceAgent")]
)
