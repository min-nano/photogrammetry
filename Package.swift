// swift-tools-version:5.9
//
// Photogrammetry — macOS の Object Capture（RealityKit の PhotogrammetrySession）で
// 複数の写真から 3D モデル（USDZ）を生成する GUI アプリ・CLI・ライブラリ。
//
// ターゲット構成（依存の向きを厳守する。CLAUDE.md「アーキテクチャ」参照）:
//
//   PhotogrammetryCore     ロジック本体。SwiftUI / AppKit に依存しない。
//                          外部アプリはこのライブラリを import するだけで
//                          GUI 抜きで 3D モデル生成を組み込める。
//   PhotogrammetryUpdater  自動アップデート。リリース情報の解釈（UpdateFeed）は
//                          純ロジックで、ネットワークにも GUI にも依存しない。
//   photogrammetry-cli     コマンドラインフロントエンド（Core のみに依存）。
//   PhotogrammetryApp      SwiftUI GUI。Core と Updater の薄いシェルに徹する。
//
import PackageDescription

let package = Package(
    name: "Photogrammetry",
    defaultLocalization: "ja",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotogrammetryCore", targets: ["PhotogrammetryCore"]),
        .library(name: "PhotogrammetryUpdater", targets: ["PhotogrammetryUpdater"]),
        .executable(name: "photogrammetry-cli", targets: ["photogrammetry-cli"]),
        .executable(name: "PhotogrammetryApp", targets: ["PhotogrammetryApp"]),
    ],
    targets: [
        .target(name: "PhotogrammetryCore"),
        .target(name: "PhotogrammetryUpdater"),
        .executableTarget(
            name: "photogrammetry-cli",
            dependencies: ["PhotogrammetryCore"]
        ),
        .executableTarget(
            name: "PhotogrammetryApp",
            dependencies: ["PhotogrammetryCore", "PhotogrammetryUpdater"]
        ),
        .testTarget(
            name: "PhotogrammetryCoreTests",
            dependencies: ["PhotogrammetryCore"]
        ),
        .testTarget(
            name: "PhotogrammetryUpdaterTests",
            dependencies: ["PhotogrammetryUpdater"]
        ),
    ]
)
