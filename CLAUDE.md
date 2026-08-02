# CLAUDE.md

このファイルは Claude Code（claude.ai/code）がこのリポジトリで作業するときの指針です。
**この指示は既定の挙動より優先されます。正確に従ってください。**

## このリポジトリについて

macOS の **Object Capture**（RealityKit の `PhotogrammetrySession`）で、多数の
写真から 3D モデル（USDZ）を生成する macOS アプリです。Apple 公式サンプル
HelloPhotogrammetry の処理フローを土台に、GUI・CLI・Swift ライブラリ・URL
スキームの 4 つの入口を持ちます。使用言語は Swift（SwiftPM、外部依存なし）。

CI・リリース・自動アップデート・CI デバッグの構成は、姉妹リポジトリ
`vectorworks-plugin-import-ifc-homeskz` の仕組みを Swift 向けに移植したものです。
迷ったらそちらの実装と README も参照してください。

## アーキテクチャ: ロジックと GUI の完全分離

**GUI はロジックを持たない薄いシェル**にする。これがこのリポジトリの設計の核で、
他アプリからの連携（ライブラリ / CLI / URL スキーム）が GUI と同じ機能に届くことを
保証する。

```
Sources/
  PhotogrammetryCore/      ロジック本体。SwiftUI / AppKit を import しない
    ReconstructionRequest  生成 1 回分の指示（自前 enum）と validate
    APICommand             URL スキーム / CLI 引数 → Request（外部連携 API の唯一の定義）
    ReconstructionService  実行方式（別プロセス / 同一プロセス）を決める入口
    PhotogrammetryEngine   RealityKit PhotogrammetrySession の唯一のラッパー
    HelperProcessEngine    生成を別プロセス（photogrammetry-cli）で実行する
    HelperProtocol         ヘルパーの stdout 行の書式（CLI ↔ GUI の対）
    InputInspection        入力フォルダの事前チェック（純ロジック）
  PhotogrammetryUpdater/   自動アップデート
    UpdateFeed             Releases JSON → チャンネル一覧・更新判定（純ロジック・I/O なし）
    UpdaterService         ネットワーク・展開・差し替え起動（Foundation のみ）
  photogrammetry-cli/      CLI フロントエンド（Core のみに依存。整形だけ）
  PhotogrammetryApp/       SwiftUI GUI（ViewModel + View。処理は Core/Updater へ委譲）
```

**依存の向きは厳守する:**

- `PhotogrammetryCore` / `PhotogrammetryUpdater` は SwiftUI / AppKit を import しない。
- RealityKit の型は `PhotogrammetryEngine.swift` の外に漏らさない
  （API 表現は `ReconstructionRequest` の自前 enum。変換表はエンジン内に 1 つだけ）。
- 外部連携のパラメータ語彙（`input` / `output` / `detail` / `ordering` /
  `sensitivity` / `subject`）は `APICommand` に **1 か所だけ**定義する。入口
  （URL / CLI）を増やす・変えるときは `APICommand` とそのテストを同時に更新する。
- **GUI からの生成は必ず別プロセス（同梱 `photogrammetry-cli`）で行う。**
  `CorePhotogrammetry` は内部エラーで `abort()` することがあり（実機で
  `com.apple.CorePhotogrammetry.session.recon` キューの SIGABRT を確認）、
  同一プロセスだと GUI ごと落ちる。Swift の `try` / `catch` では捕まえられない
  ので、プロセス境界が唯一の防御線。ヘルパーの同梱（`package-app.sh`）と
  同梱チェック（`build.yml`）、行の書式（`HelperProtocol`）と CLI の出力は
  **対**で、片方を変えるときは必ず両方＋テストを更新する。
- リリースの機械可読形式（アセット名 `Photogrammetry.app.zip`、notes の
  `channel=` / `branch=` / `commit=` / `built=` 行、タグ `stable` / `dev-<slug>`）は
  `UpdateFeed` と `build.yml` の**対**で定義されている。片方を変えるときは必ず
  両方＋テストを更新する。

## テスト方針

- **純ロジック（`APICommand` / `UpdateFeed` / `validate`）を `swift test` でテスト**
  する。GPU もネットワークも不要で、CI（macOS ランナー）で常時回る。
- **実際の 3D 再構成は自動テストしない**。CI ランナーの GPU 要件が保証されず、
  実行時間も長い。品質・進捗挙動は Object Capture 対応のローカル Mac で目視確認
  する。CI 上で挙動を見たいときは ci-debug の `run-cli` モードを使う
  （`isSupported` で弾かれるならその出力自体が調査結果）。
- **別プロセス実行（`HelperProcessEngine`）はテストする**。ヘルパーを差し替え
  られる設計（`helperURL` を受け取る）にしてあるので、シェルスクリプトで
  「進捗を出す / SIGABRT で落ちる / エラー終了する / 中断する」を再現でき、
  GPU も本物の CLI も要らない。クラッシュ時にアプリが道連れにならないことを
  保証する唯一のテストなので消さないこと。
- GUI（ViewModel）はロジックを持たないので専用テストは置かない。テストしたい
  判断が ViewModel に生えてきたら、それは Core / Updater へ下ろすサイン。
- **カバレッジ**は `test.yml` の `test` ジョブ（macOS）が `swift test
  --enable-code-coverage` を 1 回だけ実行して測る（プレーンな swift test を
  別に走らせて同じテストを 2 回実行することはしない）。`llvm-cov` で lcov /
  JSON summary / diff カバレッジをアーティファクトにし、`coverage` ジョブ
  （ubuntu-latest、Swift 不要）がそれを読んで PR に表（🟢/🟡/🔴、全体 + この
  PR が変更した行だけの diff カバレッジ）を sticky コメントとして投稿し、
  しきい値未満なら `coverage` ジョブだけを失敗させる（ゲート）。計測とレポート
  を分けているのは「テスト（または llvm-cov/diff-cover）が壊れた」のか
  「しきい値を下回った」のかを一目で区別するため。`PhotogrammetryEngine.swift`
  （RealityKit/GPU 依存）と `UpdaterService.swift`（ネットワーク I/O）は上記の
  「自動テストしない」方針どおり集計から除外している — 含めると分母が常に
  薄まりしきい値が意味を失うため。しきい値・除外規則は `test.yml` の `test`/
  `coverage` ジョブに 1 か所ずつだけ定義されている。

## Swift コード規約

- インデントはタブ。ブレースは Allman（既存ソースに合わせる）。
- コメントは**日本語**で、「なぜ（意図・制約の根拠）」を書く。
- 公開 API（Core / Updater の public）にはドキュメントコメントを付ける。
- 並行処理: ViewModel は `@MainActor`。エンジンのイベントはスレッドを跨ぐので
  受け側で `Task { @MainActor in … }` により持ち上げる。
- 外部依存（SwiftPM パッケージ）は増やさない方針。標準ライブラリ +
  Foundation + RealityKit + SwiftUI で完結させる。

## ビルド・リリース

- ローカル: `swift build` / `swift test`。`.app` の組み立ては
  `scripts/package-app.sh`（SwiftPM は .app を作れないため）。
- CI はテストとビルドで完全に独立した 2 本のワークフローに分かれている。
  同じ push（main）/ pull_request イベントで起動するが、`needs` などでは
  互いに繋がず**並列に走る**（ビルドの結果を待たずにテストの結果が見え、
  テストの結果を待たずにビルドが進む）。テスト・ビルドの合否は branch
  protection の required checks 側で見る。
  - `test.yml`: 2 ジョブ。`test`（macos-15、カバレッジ計測つきで `swift
    test` を 1 回実行しアーティファクト化）→ `coverage`（ubuntu-latest、
    アーティファクトを PR にコメント・しきい値でゲート。テスト方針節を参照）。
  - `build.yml`: `ctx` ジョブで commit/ref/リリースチャンネルを解決し、
    `build-mac`（ユニバーサルビルド → `.app` 組み立て → ad-hoc 署名 → zip）
    → `release` の順に `needs` で直列化する。
  - main への push → タグ `stable` のローリングリリース（削除して作り直し）。
  - PR への push → タグ `dev-<slug>` のプレリリース（同上）。fork PR は公開不可。
  - ブランチ削除 → `cleanup-dev-release.yml` がプレリリースを掃除。
- 自動アップデートは Info.plist のスタンプ（`GitCommit` / `GitBranch` /
  `BuildChannel`）とリリースを突き合わせる。スタンプは `package-app.sh` が書く。

## CI デバッグ（macOS が必要な調査は `ci-debug` を使う）

リモートセッション（クラウド上のコンテナ）は Linux で、**macOS / Xcode /
RealityKit が無い**。したがって Swift のビルドエラーの再現・テスト実行・CLI の
挙動確認は、**CI 上でしか答えが出ない**。そのための専用ワークフローが
`.github/workflows/ci-debug.yml` で、`workflow_dispatch` でしか起動しない
（push / PR では**決して**走らない）。

**`build.yml` に一時的な調査ステップを挿してはならない。** 戻し忘れる・その
commit が dev プレリリースとして公開される、と副作用が大きい。調査は必ず下記の
経路で行う。

### 使い方（リモートセッションの AI はこの 2 手順）

リモートセッションのコンテナに入っている `GITHUB_TOKEN` は**読み取り専用**で
`actions: write` を持たない（REST でのディスパッチは 403 になる）。したがって
**起動は GitHub MCP、待機はスクリプト**という 2 手順になる。

```
1. mcp__github__actions_run_trigger
     method: run_workflow, workflow_id: "ci-debug.yml", ref: <調査したいブランチ>,
     inputs: {mode, label, args, script, notify_pr}
     ※ label は一意な文字列にする（これで run を特定する）

2. Bash(run_in_background: true):
     scripts/ci-debug.sh wait --label <label>
```

**手順 2 は必ず `run_in_background: true` で投げる。** このスクリプトは「run の
特定 → 完了待ち → ペイロード抽出」を行って**完了した瞬間に exit する**ので、
待機時間ゼロ・タイマー不要で結果を受け取れる（バックグラウンドコマンドの終了は
ハーネスが通知する）。投げたら別作業を続け、終了通知が来たら出力ファイルを
`Read` するだけでよい。**`sleep` で待ってはいけない。**

書き込み権限のあるトークン（PAT など）が使える環境では、起動と待機をまとめた

```bash
scripts/ci-debug.sh run --mode test --args '--filter UpdateFeedTests'
```

が使える（`run` は内部で 1 と 2 を続けて行う。403 が返る環境では上の 2 手順に
切り替える）。

| mode | 用途 | `--args` |
| --- | --- | --- |
| `build` | swift build（コンパイル可否の確認が主力） | 追加フラグ（例 `-c release`） |
| `test` | swift test | 追加フラグ（例 `--filter UpdateFeedTests`） |
| `run-cli` | photogrammetry-cli をビルドして実行 | CLI の引数 |
| `shell` | 任意の bash（`--script`）。逃げ道 | — |

### 結果の読み方

出力は必ず次のマーカーで挟まれている。`truncated=yes` のときは**全部は見えて
いない**ので、`--args` を絞るか `mode=shell` で件数を数える。

```
===== BEGIN PAYLOAD (mode=...) =====
...
===== END PAYLOAD (exit=N lines_total=N truncated=yes|no) =====
```

失敗して調査コマンドに到達しなかった場合はマーカーが無く、代わりに理由が出る。
ペイロードの取得経路は 2 つあり、`ci-debug.sh` はこの順に試す。

1. **チェックラン注釈**（`GET /repos/{owner}/{repo}/check-runs/{id}/annotations`）。
   `ci-debug-job.sh` がペイロードを `::notice::` としても出しているので、ここから
   読める。`api.github.com` だけで完結する。**通常はこちらで取れる。**
2. **ジョブログ**。ログ API は署名付きの Azure Blob Storage へ 302 で飛ぶが、
   **そのホストは組織の egress ポリシーで拒否されている**ため、リモートセッションの
   コンテナからは取得できない。これは迂回してはならない制約なので、必要なときは
   GitHub MCP の `get_job_logs`（`job_id` 指定・`return_content: true`）を使う。

### 制約

- `workflow_dispatch` は**デフォルトブランチに存在するワークフロー**しか起動
  できない。`ci-debug.yml` は main に入っているので、作業ブランチを `--ref` に
  指定して使える（実行される定義はその ref 側のもの）。
- **モードの追加・修正は `scripts/ci-debug-job.sh`（ランナー側）で行う。**
  ワークフロー本体は薄く保ってあるので、作業ブランチに push するだけで新しい
  モードを試せる。ワークフロー本体を変えると main へのマージが要る。
