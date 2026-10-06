// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceAgent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VoiceAgent", targets: ["VoiceAgent"])],
    dependencies: [
        .package(path: "packages/bot-avatars/ports/ios/BotAvatarsKit"),
        .package(path: "packages/thinking-orbs/ports/ios/ThinkingOrbsKit")
    ],
    targets: [
        .executableTarget(
            name: "VoiceAgent",
            dependencies: [
                .product(name: "BotAvatarsKit", package: "BotAvatarsKit"),
                .product(name: "ThinkingOrbsKit", package: "ThinkingOrbsKit")
            ]
        )
    ]
)
