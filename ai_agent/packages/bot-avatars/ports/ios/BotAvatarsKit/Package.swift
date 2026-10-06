// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BotAvatarsKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BotAvatarsKit", targets: ["BotAvatarsKit"])
    ],
    targets: [
        .target(
            name: "BotAvatarsKit",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        ),
    ]
)
