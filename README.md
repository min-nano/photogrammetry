# Photogrammetry

macOS の **Object Capture**（RealityKit の `PhotogrammetrySession`）を使い、
対象物を多方向から撮影した**多数の写真から 3D モデル（USDZ）を生成する** macOS
アプリです。Apple 公式サンプル
[HelloPhotogrammetry](https://developer.apple.com/documentation/realitykit/creating-a-photogrammetry-command-line-app)
の処理フローを土台に、GUI・CLI・ライブラリの 3 つの入口を持たせています。

- **GUI アプリ**（`Photogrammetry.app`）… フォルダを選んでボタンを押すだけ
- **CLI**（`photogrammetry-cli`）… スクリプト・他プロセスからの実行
- **Swift ライブラリ**（`PhotogrammetryCore`）… 他アプリへの組み込み
- **URL スキーム**（`photogrammetry://`）… 他アプリから GUI アプリを起動して実行

ロジック（解析・生成・アップデート判定）は GUI から完全に分離されており、
GUI はその薄いシェルにすぎません（下記「アーキテクチャ」）。

## 動作要件

- macOS 14 以降
- Object Capture 対応 Mac（Apple Silicon、または 4GB 以上の GPU を積んだ Intel Mac。
  非対応機ではアプリが起動時に警告を出し、生成は実行できません）
- 写真は 20〜200 枚程度、対象物を全方向から重なりを持たせて撮影したもの

## インストール

[Releases](../../releases) から `Photogrammetry.app.zip` をダウンロードして展開し、
アプリケーションフォルダ等へ置いてください。

- **stable**（`Stable (…)`）… main ブランチの最新ビルド
- **dev-\<branch\>**（プレリリース）… 各ブランチ（PR）の最新ビルド

CI の ad-hoc 署名のみ（Apple Developer ID の署名・公証なし）のため、初回起動時は
Gatekeeper に止められます。**右クリック → 開く**、または

```bash
xattr -dr com.apple.quarantine /Applications/Photogrammetry.app
```

で解除してください（自動アップデート経由の更新では不要です）。

## 使い方

### GUI

1. 「入力」で写真フォルダを選択
2. 「出力」で保存先（`.usdz`）を選択
3. 品質（詳細度・写真の並び・特徴点検出）を選んで「3D モデルを生成」

### CLI

```bash
photogrammetry-cli <入力フォルダ> <出力ファイル.usdz> \
    [--detail preview|reduced|medium|full|raw] \
    [--sample-ordering unordered|sequential] \
    [--feature-sensitivity normal|high]
```

stdout に機械可読な `key=value` 行を逐次出力します（`progress=0.42` /
`note=…` / `output=/path/model.usdz` / 最後に `ok`）。エラーは stderr に
`error: …`、終了コードは成功 0 / 失敗 1 / 使い方誤り 2 です。

### URL スキーム（他アプリからの連携）

GUI アプリは `photogrammetry://` スキームを宣言しています。パスはパーセント
エンコードして渡してください。

```bash
open "photogrammetry://process?input=/Users/me/photos&output=/Users/me/model.usdz&detail=full"
```

パラメータ: `input`（必須）/ `output`（必須）/ `detail` / `ordering` /
`sensitivity`。語彙は CLI と共通で、解釈は `PhotogrammetryCore` の
`APICommand` に一元化されています。

### Swift ライブラリ

```swift
// Package.swift
.package(url: "https://github.com/min-nano/photogrammetry", branch: "main")
// ターゲットの依存に "PhotogrammetryCore"

import PhotogrammetryCore

let request = ReconstructionRequest(
    inputFolder: URL(fileURLWithPath: "/path/photos", isDirectory: true),
    outputFile: URL(fileURLWithPath: "/path/model.usdz"),
    detail: .full)
let engine = PhotogrammetryEngine()
try await engine.process(request) { event in
    if case .progress(let fraction) = event { print(fraction) }
}
```

## 自動アップデート

アプリは GitHub Releases を監視して自分自身を更新します。

- **チャンネル = ブランチ**。設定画面（Photogrammetry > 設定…）で使用する
  バージョン（ブランチ）を選ぶと、そのブランチの最新の**リリース**（main →
  `stable`）または**プレリリース**（それ以外 → `dev-<branch>`）へ更新します。
- 起動時の自動確認（設定でオフ可）と、設定画面からの手動確認があります。
- 更新は「zip をダウンロード → 展開 → 同梱スクリプト
  （`install-update.sh`）を切り離して起動 → アプリ終了 → スクリプトが差し替えて
  再起動」という流れです。インストール済みビルドの識別は Info.plist にスタンプ
  された `GitCommit` とリリースの `commit=` の突き合わせで行います。

## アーキテクチャ

```
Sources/
  PhotogrammetryCore/      ロジック本体（SwiftUI / AppKit 非依存）
    ReconstructionRequest  生成 1 回分の指示と検証
    APICommand             URL スキーム / CLI 引数 → Request（外部連携 API の唯一の定義）
    PhotogrammetryEngine   RealityKit PhotogrammetrySession の唯一のラッパー
  PhotogrammetryUpdater/   自動アップデート
    UpdateFeed             Releases JSON → チャンネル一覧・更新判定（純ロジック）
    UpdaterService         ネットワーク・ダウンロード・差し替え起動（Foundation のみ）
  photogrammetry-cli/      CLI フロントエンド（Core のみに依存）
  PhotogrammetryApp/       SwiftUI GUI（Core / Updater の薄いシェル）
packaging/Info.plist       .app の Info.plist テンプレート
scripts/
  package-app.sh           SwiftPM 成果物 → Photogrammetry.app の組み立て
  install-update.sh        自動アップデートの差し替えスクリプト（.app に同梱）
  ci-debug.sh              CI debug ワークフローのクライアント
  ci-debug-job.sh          CI debug ワークフローのランナー側本体
```

依存の向き: `PhotogrammetryCore` / `PhotogrammetryUpdater` は GUI（SwiftUI /
AppKit）を import しない。GUI・CLI はロジックを持たない。外部から使う API
（ライブラリ・CLI・URL スキーム）の語彙は `APICommand` に 1 か所で定義する。

## 開発

ビルドには macOS + Xcode が必要です（RealityKit / SwiftUI のため Linux では
ビルドできません）。

```bash
swift build            # 全ターゲット
swift test             # 純ロジックの単体テスト（GPU 不要）
swift run photogrammetry-cli ~/photos ~/model.usdz

# GUI アプリを .app として組み立てる
swift build -c release
scripts/package-app.sh .build/release/PhotogrammetryApp dist-app
open dist-app/Photogrammetry.app
```

実際の 3D 再構成（品質・進捗挙動）は Object Capture 対応のローカル Mac で
目視確認してください。CI は純ロジックのテストとビルド成立のみを保証します。

## CI / リリース構成

| ワークフロー | トリガ | 役割 |
| --- | --- | --- |
| `build.yml` | main への push / PR | macOS ランナーでテスト → ユニバーサルビルド → `.app` 組み立て → リリース公開 |
| `ci-debug.yml` | workflow_dispatch のみ | CI（macOS）上で 1 コマンド実行するデバッグ用（下記） |
| `cleanup-dev-release.yml` | ブランチ削除 | そのブランチの `dev-*` プレリリースを削除 |

リリースは**ローリング**です。main へのマージごとにタグ `stable` のリリースを
作り直し、PR への push ごとにタグ `dev-<branch>` のプレリリースを作り直します。
アセットは `Photogrammetry.app.zip`（GUI）と `photogrammetry-cli.zip`（CLI）。
リリース本文の `channel=` / `branch=` / `commit=` / `built=` 行は自動アップデート
（`UpdateFeed`）がパースする機械可読データです。

### CI デバッグ（macOS が手元に無いとき）

macOS が必要な調査（ビルドエラーの再現、テストの実行、CLI の挙動確認）は
`ci-debug.yml` を workflow_dispatch で起動して行います。push / PR では決して
走らず、リリースも公開しません。

```bash
# 起動 → 完了待ち → 結果抽出まで 1 コマンド（要 write 権限トークン）
scripts/ci-debug.sh run --mode test --args '--filter UpdateFeedTests'
scripts/ci-debug.sh run --mode build --args '-c release'
scripts/ci-debug.sh run --mode run-cli --args '--help'
scripts/ci-debug.sh run --mode shell --script 'sw_vers; xcrun simctl list devices'
```

トークンが読み取り専用の環境（Claude Code のリモートセッション等）では、起動を
GitHub MCP（`actions_run_trigger`）で行い、`scripts/ci-debug.sh wait --label <label>`
で合流します（詳細は `CLAUDE.md`「CI デバッグ」節）。
