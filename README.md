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

GUI から実行したときの 3D 生成は、**同梱の `photogrammetry-cli` を子プロセスとして
起動**して行います。macOS の Object Capture 本体（`CorePhotogrammetry`）は内部
エラーで `abort()` することがあり、同一プロセスで動かしているとアプリごと落ちて
しまうためです（この中断は Swift の `try` / `catch` では捕まえられません）。子
プロセスなら落ちるのは子だけで、アプリは原因と対処方法をログとエラーに残します。

## 動作要件

- macOS 14 以降
- Object Capture 対応 Mac（Apple Silicon、または 4GB 以上の GPU を積んだ Intel Mac。
  非対応機ではアプリが起動時に警告を出し、生成は実行できません）
- 写真は 20〜200 枚程度、対象物を全方向から重なりを持たせて撮影したもの
  （建物 1 棟・現場全体のようにこの枚数を大きく超える場合は、
  `photogrammetry-cli sort` で仕分けてからグループごとに生成します。
  仕分け自体は Object Capture 非対応の Mac でも実行できます）

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
3. 品質（**対象の種類**・詳細度・写真の並び・特徴点検出）を選んで「3D モデルを生成」

**対象の種類**は重要な設定です。単一の物体（家具・小物など）を撮った写真なら
「物体」、建物・部屋・現場全体のようなシーンを撮った写真なら「シーン・建物」を
選んでください（下記「うまくいかないとき」参照）。

写真が多すぎて 1 回で扱えない場合は、画面上部で**「写真を仕分ける」**に切り替え
ます。

1. 「入力」で現場の写真フォルダを選択
2. 「仕分け先」で空のフォルダを選択
3. 共有枚数・グループの上下限・区切りの撮影間隔などを確認して「写真を仕分ける」

**「確認のみ」を入れて実行すると、ファイルを作らずに診断だけ**を出します
（数分で終わります）。共有写真の不足・視点の偏り・繋がらないグループがログに
出るので、**現場を離れる前に撮り直しの要否を判断できます**。仕分けが終わったら
「Finder で表示」で group-01 … を開き、グループごとに「3D モデルを生成」へ
戻ってください。仕分けは Object Capture 非対応の Mac でも実行できます
（詳細は下記「大量の写真を仕分ける」）。

### CLI

```bash
photogrammetry-cli <入力フォルダ> <出力ファイル.usdz> \
    [--detail preview|reduced|medium|full|raw] \
    [--sample-ordering unordered|sequential] \
    [--feature-sensitivity normal|high] \
    [--subject object|scene]
```

stdout に機械可読な `key=value` 行を逐次出力します（`progress=0.42` /
`stage=imageAlignment` / `eta=1830` / `note=…` / `output=/path/model.usdz` /
最後に `ok`）。エラーは stderr に `error: …`、終了コードは成功 0 / 失敗 1 /
使い方誤り 2 です。

`stage=` は処理段階（`preProcessing` / `imageAlignment` / `pointCloudGeneration`
/ `meshGeneration` / `textureMapping` / `optimization`）、`eta=` は残り時間の
見積もり（秒）です。どちらも OS が返したときだけ出ます（macOS が値を返さない
区間では出力されません）ので、受け側は欠けても動くようにしてください。

### 大量の写真を仕分ける（`sort`）

建物 1 棟・現場全体を記録すると写真は数百〜数千枚になり、**1 回のセッションでは
解けません**（ハードウェア上限を超えるうえ、部屋・階が変わると視点の連続性が
途切れて位置合わせに失敗します）。`sort` は写真をグループへ仕分け、あとで
1 つの座標系へ合成できる形で書き出します。

GUI（画面上部で「写真を仕分ける」に切り替え）・CLI・URL スキームのどれからでも
実行できます。仕分けは RealityKit を使わない（ImageIO / CoreGraphics / Vision の
み）ので、**Object Capture 非対応の Mac でも動きます**。

```bash
photogrammetry-cli sort <入力フォルダ> <仕分け先フォルダ> \
    [--overlap 15] [--max-per-group 150] [--min-per-group 20] \
    [--time-gap 300] [--group-threshold 0.4] [--min-sharpness 12] \
    [--duplicate-distance 4] [--visual-threshold 0.4] [--no-visual] \
    [--link hardlink|copy|symlink] [--no-recursive] [--dry-run]
```

```
仕分け先/
  group-01/       写真（ハードリンク。同一ボリューム外ならコピーへ自動で切り替え）
  group-02/
  _excluded/      品質フィルタで落とした写真（理由別のサブフォルダ）
  _unassigned/    どのグループにも入らなかった写真
  manifest.json   グループ・隣接・除外・診断の記録
```

仕分けの要点は 4 つです。

1. **手がかりに依存しない。** 撮影時刻・GPS（水平誤差と測位時刻で足切り）・
   高度・方位・露出・知覚ハッシュ・サブフォルダ分けを**並列の証拠**として扱い、
   その現場で使えるものだけを重み付けして合算します。EXIF が失われた写真でも
   見た目とファイル名の連番だけで仕分きます。屋内（床下・小屋裏）では GPS が
   直前の屋外の測位のまま残るので、**位置が付いていること自体は信用しません**。
2. **見た目から「同じ場所」を見分ける**（`room-01` …）。上の手がかりはどれも
   「撮影の流れ」しか見ておらず、場所そのものの同一性は判定できません。
   Vision の画像特徴を使うと、**時刻が離れていても同じ部屋ならまとめ、時刻が
   近くても別の部屋なら引き離す**ことができます。部屋を行き来しながら撮った
   現場、隣り合う部屋を続けて撮った現場で効きます。`--no-visual` で切れます
   （速くなりますが精度は落ちます）。
3. **隣り合うグループに同じ写真を重複させる**（`--overlap`、既定 15 枚）。この
   共有写真が、各グループを再構成したあとに 1 つの座標系へ合成するときの
   手がかりになります。選ぶときは視点が散らばるようにします（同じ場所から
   向きだけ変えた写真ばかりだと、変換の推定が退化するため）。同じ場所を写して
   いるグループ同士の隣接は最優先で残します（合成でいうループの閉じ込み）。
4. **閾値を固定しない。** ブレ判定もグループ分けも「同じ場所」の判定も、その
   現場の分布から自動決定します（分布の山が 1 つのときは切らないので、ブレた
   写真が無い現場で良品を捨てず、一続きの場所を刻みません）。
   `--min-sharpness` / `--group-threshold` / `--visual-threshold` は逃げ道です。

`--dry-run` はファイルを作らず解析と診断だけを行います。**再構成は建築規模なら
数時間かかりますが、`sort` は数分で終わります。**現場を出る前にこれを回せば、
撮り直しが必要かどうかをその場で判断できます。

```
$ photogrammetry-cli sort ~/Pictures/現場 ~/Desktop/仕分け --dry-run
note=770 枚を 8 グループに仕分けました（除外 42 枚）。
note=視覚的に 6 か所を見分けました（room-01 128 枚・room-02 96 枚・…）。距離の閾値 0.31・自動決定
note=使った手がかり: 撮影時刻・見た目の近さ・視覚特徴の近さ・同じ場所の判定（結合スコアの閾値 0.38・自動決定）
note=警告: group-03 ↔ group-04: 共有 4 枚（推奨 10 枚以上） — 合成が不安定になります。…
note=警告: group-05 ↔ group-06: 共有写真の視点がほぼ一直線です — …
note=警告: group-07 はどのグループとも共有写真がありません — …
note=警告: group-02 は視覚的に別の場所の写真が混ざっています（room-01 55%・room-04 45%）— …
```

仕分けたあとは、グループごとに通常どおり生成します。グループは**撮影順の連続
区間**になるので `--sample-ordering sequential` が効きます。建物・部屋は
`--subject scene`（オブジェクトマスキング無効）が必須です。

```bash
for g in ~/Desktop/仕分け/group-*; do
    photogrammetry-cli "$g" "$HOME/Desktop/$(basename "$g").usdz" \
        --subject scene --sample-ordering sequential
done
```

複数モデルを 1 つの座標系へ合成する `merge` はフェーズ 3 で実装予定です
（`manifest.json` の `adjacency` がそのための契約です）。設計は
[`docs/design-preprocess-merge.md`](docs/design-preprocess-merge.md) を参照。

**撮影のコツ**（守れなくても `sort` が不足を検出して指摘しますが、守ると精度が
上がります）: 部屋を出る前に**出口付近から次に入る先の方向を数枚**撮り、その
数枚は**2〜3 歩ずつ立ち位置を変えて**撮ってください。合成の精度に最も効きます。

### URL スキーム（他アプリからの連携）

GUI アプリは `photogrammetry://` スキームを宣言しています。パスはパーセント
エンコードして渡してください。

```bash
open "photogrammetry://process?input=/Users/me/photos&output=/Users/me/model.usdz&detail=full"
```

```bash
open "photogrammetry://sort?input=/Users/me/現場&output=/Users/me/仕分け&overlap=15"
```

パラメータ:

- `process`: `input`（必須）/ `output`（必須）/ `detail` / `ordering` /
  `sensitivity` / `subject`
- `sort`: `input`（必須）/ `output`（必須）/ `overlap` / `maxPerGroup` /
  `minPerGroup` / `timeGap` / `groupThreshold` / `minSharpness` /
  `duplicateDistance` / `visual` / `visualThreshold` / `link` / `recursive` /
  `dryRun`

語彙は CLI と共通で、解釈は `PhotogrammetryCore` の `APICommand` に一元化されて
います。

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

## うまくいかないとき

**「CoreOC.PhotogrammetrySession.Error エラー 6」で失敗する**
写真群の位置合わせ（アライメント）に失敗しています。典型原因は 2 つ:

1. **対象の種類が合っていない。** 既定の「物体」モードは背景から単一の物体を
   切り出して復元します（オブジェクトマスキング）。建物・部屋・現場全体の写真では
   切り出す物体が無いため失敗します。「シーン・建物」（CLI では
   `--subject scene`）に切り替えてください。
2. **写真が Object Capture の想定と異なる。** 想定は「1 つの対象を全周から、隣接
   写真と 70% 程度重なるように 20〜200 枚」。記録用に歩き回って撮った写真の
   寄せ集めでは、視点のつながりが復元できず失敗します。

建物 1 棟・現場全体のように**そもそも 1 回で解けない量**を撮った場合は、
`photogrammetry-cli sort` で仕分けてからグループごとに生成してください
（上記「大量の写真を仕分ける」）。`--dry-run` を付ければ、どこが繋がらないかを
数分で確認できます。

**枚数の上限**
入力枚数がこの Mac のハードウェア上限（`PhotogrammetrySession.limits`）を超えると
ログに警告が出ます。失敗する場合は写真を減らすか、`sort` で分割してください。

**毎回まったく同じ進捗で「生成処理が異常終了しました（シグナル 6: SIGABRT）」と出る**
まずこれを疑ってください。**機械学習モデルのキャッシュ破損**です。Object Capture は
再構成の途中で Apple Neural Engine 用の ML モデルを使いますが、その初回コンパイルが
失敗するとキャッシュが不完全なまま残り、以降は**毎回同じ進捗で** abort します
（写真・枚数・詳細度・フォルダの場所はいずれも無関係で、何を変えても直りません）。
ログに次のような出力があればこれです。

```
ファイル"manifest.plist"は存在しないため、開けませんでした。
Assert: in line 521
E5RT encountered an STL exception. msg = MILCompilerForANE error: … ANECCompile() FAILED.
```

アプリはこの署名を見分けて、エラー表示に **「ML モデルのキャッシュを削除」ボタン**を
出します。押してからもう一度実行すれば OS がキャッシュを作り直します。手動で消す
場合は次のフォルダです（削除して安全なキャッシュです）。

```bash
rm -rf ~/Library/Caches/com.minnano.photogrammetry/com.apple.e5rt.e5bundlecache
```

**その他の理由で処理の途中に異常終了する**
macOS の Object Capture 本体（`CorePhotogrammetry`）が内部エラーで処理を中断
した状態です。アプリ側では捕捉できない中断なので、**生成は別プロセス
（同梱の `photogrammetry-cli`）で実行**しており、アプリとログはそのまま残ります。
発生したときは次を試してください。

1. 詳細度を下げる（プレビュー / 低）
2. 写真の枚数を減らす、解像度の大きすぎる写真を外す
3. 入力フォルダをクラウド（iCloud Drive / Google Drive）ではなく
   ローカル（例: `~/Pictures`）へコピーする
4. 対象の種類（物体 / シーン・建物）を撮影内容に合わせる
5. 他の重いアプリを閉じてメモリを空ける

毎回ほぼ同じ進捗で落ちる場合は、特定の写真や写真の組み合わせが原因である
可能性が高いです（枚数を半分ずつに分けて試すと切り分けられます）。
なお `シグナル 9: SIGKILL` で終わる場合はメモリ不足が疑われます。

**エラーの詳細**
失敗時はログ（GUI のログ欄 / CLI の stderr）にエラーの domain / code / userInfo が
出ます。問い合わせ・調査の際はこの全文を添えてください。処理段階（GUI は
プログレスバー下と「段階: …」のログ、CLI は `stage=`）も一緒に見ると、
位置合わせ（`imageAlignment`）まで到達して落ちたのか、その前で落ちたのかを
切り分けられます。

**クラウド上のフォルダが遅い・見つからない**
iCloud Drive・Google Drive などのストリーミングフォルダは、実体が未ダウンロード
だと読めない・非常に遅いことがあります。処理の途中で実体が読めなくなると異常
終了の原因にもなります。未ダウンロードのファイル（`.icloud`）があるとログに警告が
出るので、Finder で「今すぐダウンロード」するか、写真をローカル（例: `~/Pictures`）
へコピーしてから実行してください。

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
    ReconstructionService  実行方式（別プロセス / 同一プロセス）を決める入口
    PhotogrammetryEngine   RealityKit PhotogrammetrySession の唯一のラッパー
    HelperProcessEngine    生成を別プロセス（photogrammetry-cli）で走らせる
    HelperProtocol         ヘルパーの stdout 行の書式（CLI と GUI の対）
    InputInspection        入力フォルダの事前チェック（枚数・iCloud の未ダウンロード）
    ModelCache             ML モデルのキャッシュ破損の見分けと削除
    Preprocess/            大量の写真の仕分け（sort）
      PhotoMetadata        写真 1 枚分の事実（時刻・位置・露出・指紋・品質）
      PhotoInspector       ImageIO / CoreGraphics の唯一のラッパー
      FeaturePrinter       Vision（画像特徴）の唯一のラッパー
      ImageStatistics      ブレ・露出・知覚ハッシュの計算（純ロジック）
      FeaturePrint         視覚特徴の値型と距離（純ロジック）
      RoomClustering       視覚特徴から同じ場所を見分ける（純ロジック）
      ThresholdEstimator   分布から閾値を決める判別分析（純ロジック）
      QualityFilter        寄与しない写真の除外（純ロジック）
      PhotoGrouping        証拠の合算 → グループと隣接（純ロジック）
      SortPlan             重複付き分割の計画（純ロジック）
      SortDiagnostics      撮り直しの判断材料（純ロジック）
      SortManifest         manifest.json の定義（sort と merge の契約）
      SortRequest          仕分け 1 回分の指示と検証
      PhotoSorter          計画の実行（走査・配置・書き出し）
  PhotogrammetryUpdater/   自動アップデート
    UpdateFeed             Releases JSON → チャンネル一覧・更新判定（純ロジック）
    UpdaterService         ネットワーク・ダウンロード・差し替え起動（Foundation のみ）
  photogrammetry-cli/      CLI フロントエンド（Core のみに依存）
  PhotogrammetryApp/       SwiftUI GUI（Core / Updater の薄いシェル）
packaging/
  Info.plist               .app の Info.plist テンプレート
  AppIcon.svg              アプリアイコン（プレビュー用・生成物）
  AppIcon.icns             アプリアイコン（.app に同梱する実体・生成物）
scripts/
  package-app.sh           SwiftPM 成果物 → Photogrammetry.app の組み立て
  make-app-icon.py         アプリアイコンの生成（デザインの原典）
  install-update.sh        自動アップデートの差し替えスクリプト（.app に同梱）
  ci-debug.sh              CI debug ワークフローのクライアント
  ci-debug-job.sh          CI debug ワークフローのランナー側本体
  wait-pr-checks.sh        PR / ブランチの CI 完了待ち（完了した瞬間に exit する）
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

### アプリアイコン

アイコンは画像ファイルを手で描くのではなく、`scripts/make-app-icon.py` が
ベクタ（SVG）から全サイズを焼いて `packaging/AppIcon.icns` を作ります。寸法と
色はスクリプト内に集約してあるので、`.icns` がバイナリでも変更履歴が読めます。

```bash
pip install cairosvg
scripts/make-app-icon.py      # packaging/AppIcon.svg と AppIcon.icns を更新
```

デザインは「同じものの 2 通りの表現」です。奥の写真（2D）に写った平面の六角形と、
手前の立体（3D・等角投影の立方体）のシルエットが同じ六角形になっていて、
「多数の写真 → 1 つの 3D モデル」という Object Capture の処理そのものを表します。
被写体を特定の物にせず抽象的な立体にしているのは、用途を限定しないためと、
16px でも 3 面の陰影だけで立体と読めるためです。背景は macOS 標準アイコンに
合わせたスーパー楕円（squircle、1024px キャンバスの中央 824px）です。

`.icns` は `iconutil`（macOS 専用）を使わず自前で書き出しているので、macOS が
無い環境（Linux のリモートセッション）でも再生成できます。

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

### CI の完了待ち

PR やブランチの CI が終わるのを待つには `scripts/wait-pr-checks.sh` を使います。
完了した瞬間に exit するので、バックグラウンドに置いて別作業を続けられます
（読み取り権限のトークンだけで動きます）。

```bash
scripts/wait-pr-checks.sh --pr 7
scripts/wait-pr-checks.sh --ref claude/my-branch
```

出力の最後は `result=<success|failure|no-checks|timeout|pr-merged|pr-closed> …` の
1 行で、終了ステータスは 0=成功 / 1=失敗 / 2=使い方・API エラー / 3=不明
（タイムアウト・チェックなし）です。

GitHub Actions は commit status ではなく check run を作るため、`GET
/commits/{sha}/status`（combined status）は `total_count: 0` / `state: "pending"` を
返し続けます。これを見て待つと CI が終わっても永久に待ち続けるので、このスクリプトは
check runs・workflow runs・commit statuses の 3 経路を見たうえで、必ず有限時間で
exit するようにしています（詳しい理由はスクリプト冒頭のコメント）。
