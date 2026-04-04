// swift-tools-version: 6.1
// This is a Skip (https://skip.dev) package.
import PackageDescription

let package = Package(
    name: "faire-games",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FaireGames", type: .dynamic, targets: ["FaireGames"]),
        .library(name: "FaireGamesModel", type: .dynamic, targets: ["FaireGamesModel"]),
        .library(name: "BlockBlast", type: .dynamic, targets: ["BlockBlast"]),
        .library(name: "Tetris", type: .dynamic, targets: ["Tetris"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-model.git", from: "1.0.0"),
        .package(url: "https://source.skip.tools/skip-kit.git", from: "1.0.0"),
        .package(url: "https://github.com/appfair/appfair-app.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "FaireGames", dependencies: [
            "FaireGamesModel",
            "BlockBlast",
            "Tetris",
            .product(name: "AppFairUI", package: "appfair-app")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "FaireGamesTests", dependencies: [
            "FaireGames",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "BlockBlast", dependencies: [
            "FaireGamesModel",
            .product(name: "SkipKit", package: "skip-kit"),
            .product(name: "AppFairUI", package: "appfair-app"),
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "BlockBlastTests", dependencies: [
            "BlockBlast",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "Tetris", dependencies: [
            "FaireGamesModel",
            .product(name: "SkipKit", package: "skip-kit"),
            .product(name: "AppFairUI", package: "appfair-app")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "TetrisTests", dependencies: [
            "Tetris",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "FaireGamesModel", dependencies: [
            .product(name: "SkipModel", package: "skip-model"),
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)
