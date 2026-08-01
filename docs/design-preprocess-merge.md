# 設計メモ: 建築物・外構向けのプリ／ポストプロセッシング

**状態: 設計案（未実装）。** 撮影フローを固めてから段階的に実装する。

## 1. 背景

現状のアプリは「1 つの対象を全周から撮った写真フォルダ → 1 つの USDZ」という
Object Capture 本来の使い方に沿っている。一部屋程度ならこれで問題なく通る。

しかし建築物・外構が対象になると、前提が 2 つ崩れる。

1. **枚数がハードウェア上限を超える。** 現場を一通り記録すると数百〜数千枚になり、
   `PhotogrammetrySession.limits.maximumNumberOfInputImages` を超える。超えなくても
   Object Capture の実用域（1 対象あたり 20〜200 枚）から大きく外れる。
2. **1 回のセッションで解けない。** 部屋・面・階が切り替わると視点の連続性が途切れ、
   アライメントが失敗する（README「うまくいかないとき」のエラー 6）。

したがって「写真を仕分けて複数回に分けて再構成し、後で 1 つの座標系へ合成する」
パイプラインが要る。本書はその設計案である。

## 2. 検証済みの API 事実

Linux のリモートセッションでは RealityKit が無いため、以下は `ci-debug`
（macOS 15.2 SDK / Xcode 16.2）で `swiftc -typecheck` により実在を確認した。

- run: <https://github.com/min-nano/photogrammetry/actions/runs/30722290339>
- run: <https://github.com/min-nano/photogrammetry/actions/runs/30722347437>

合成を自動化できる根拠がこれ。**カメラ姿勢が元の写真ファイル URL に紐づく。**

```swift
@available(macOS 14.0, *)
public struct Poses {
	public let posesBySample: [Int: Pose]
	public var urlsBySample:  [Int: URL] { get }   // ← 姿勢 → 元ファイル
}
@available(macOS 14.0, *)
public struct Pose {
	public let translation: SIMD3<Float>
	public let rotation:    simd_quatf
	public var transform:   Transform { get }
}
```

| API | 用途 | 可用性 |
| --- | --- | --- |
| `PhotogrammetrySession.Request.poses` / `Result.poses(Poses)` | カメラ姿勢 | macOS 14+ |
| `Request.pointCloud` → `PointCloud.points[{position, color}]` | 点群 | macOS 13+ |
| `MDLAsset(url:)` / `canExportFileExtension("usdz")` / `export(to:)` | USDZ 読み書き | ModelIO |
| `VNGenerateImageFeaturePrintRequest` + `computeDistance` | 写真間の視覚的距離 | Vision |
| `VNHomographicImageRegistrationRequest` | 2 枚が実際に重なるかの検証 | Vision |
| `CGImageSource` の EXIF / GPS 辞書 | 撮影時刻・GPS・方位 | ImageIO |

**すべて OS 同梱フレームワーク**なので、CLAUDE.md の「外部依存（SwiftPM
パッケージ）は増やさない」方針を崩さずに実装できる。Vision / ModelIO の型は、
いま RealityKit が `PhotogrammetryEngine` に閉じ込められているのと同じ扱いにする
（ラッパーの外へ漏らさない）。

なお `PhotogrammetrySession(input:configuration:)` の
`AsyncSequence<PhotogrammetrySample>` 版は型チェックが通らなかった（要素型の
制約が厳しい）。**フォルダ入力のままで `urlsBySample` により写真を特定できる**ので、
サンプル列を自前で組む必要は無い。

副産物として、macOS 14+ には `Output.requestProgressInfo`
（`estimatedRemainingTime` / `processingStage`）があることも分かった。現状の
エンジンは使っていない。残り時間表示が欲しくなったらここ。

## 3. 全体像

```
  写真フォルダ（数百〜数千枚）
        │
        │  ① sort — プリプロセス
        ▼
  group-01/ … group-08/ + manifest.json      ← 隣接グループ間に写真を重複させる
        │
        │  ② 各グループを個別に再構成（--subject scene, --emit-poses）
        ▼
  group-01.usdz + group-01.poses.json  …
        │
        │  ③ merge — ポストプロセス
        ▼
  1 つの座標系に配置された USD シーン
```

②は既存のエンジンをそのまま使う（`--emit-poses` の追加だけ）。新規に設計するのは
①と③。

## 4. プリプロセス（`sort`）

### 4.1 混在する撮影スタイルへの対応方針

現場によって撮り方が違う（連続撮影・記録用のバラバラ・iPhone で GPS 付き）ので、
**特定の手がかりに依存しない**。手がかりを「証拠」として並列に扱い、**あるものだけ
使う**設計にする。

| 証拠 | 取得元 | 強さ | 使えない条件 |
| --- | --- | --- | --- |
| 撮影時刻の近接 | EXIF `DateTimeOriginal` | 強（連続撮影時） | 時刻が無い／順序がバラバラ |
| GPS の近接 | EXIF GPS 緯度経度 | 中（屋外）／弱（屋内） | GPS 無し |
| 高度 | EXIF GPS 高度 | 中（階の分離に有効） | GPS 無し |
| 方位の一致 | EXIF `GPSImgDirection` | 中（同一「面」の判定） | 方位無し |
| 視覚的類似 | Vision feature print | 常に使える（最後の砦） | なし |
| 実際の重なり | Vision 画像レジストレーション | 強（ただし高コスト） | 候補ペアにのみ適用 |

実装上は、写真ペア (i, j) ごとに証拠を重み付きで合算した**結合スコア**を作り、
利用できない証拠は重みを 0 にして正規化し直す。「時刻が使える現場では時刻が主導し、
使えない現場では視覚が主導する」が自動的に成立する。

### 4.2 段階 1: 品質フィルタ

グルーピングの前に、そもそも再構成に寄与しない写真を落とす。**これだけでも
「枚数上限超え」に直接効く。**

- **ブレ**: ラプラシアン分散（vImage / Accelerate）。閾値以下は除外。
- **露出**: 輝度ヒストグラムの飽和（白飛び・黒つぶれ）。
- **ほぼ同一の重複**: feature print 距離が極端に小さいペアは 1 枚だけ残す。連写や
  立ち止まったままのシャッター連打で大量に発生する。

除外した写真は捨てず `_excluded/` へ理由付きで退避する（判断を後から見直せるように）。

### 4.3 段階 2: グルーピング

1. 4.1 の結合スコアで**重み付き無向グラフ**を作る。
2. 閾値でエッジを切り、**連結成分**を粗グループとする。
3. 粗グループが大きすぎる（`maxPerGroup` 超え）なら、その中で再帰的に分割する。
   分割の切り口は、使える証拠の中で最も強いもの（時刻があれば時刻順の等分割、
   無ければグラフの正規化カット）。
4. 小さすぎるグループ（再構成が成立しない枚数）は、最も結合の強い隣接グループへ
   吸収するか `_unassigned/` へ送る。

**グループサイズの上限は設計上の制約として明示する。** 上限は
`PhotogrammetrySession.limits.maximumNumberOfInputImages` と、実用域（〜200 枚程度）の
小さい方。

**計算量の注意**: 全ペアの feature print 距離は O(n²)。n = 2,000 なら 200 万ペアで
実用範囲だが、n = 10,000 では 5,000 万ペアになる。時刻・GPS が使える場合は先に粗く
ブロック化し、ブロック内とブロック境界だけ全ペアを計算する。手がかりが何も無い場合の
フォールバックとして全ペアを残す。

### 4.4 段階 3: 重複付き分割（合成の前提条件）

**ここが本設計の要。** グループをきれいに切り分けてはいけない。隣接グループには
**同じ写真を両方に入れる**。この共有写真が、③で対応点になる。

- 隣接の定義は「2 でカットしたエッジがある」こと。**切ったエッジこそが隣接の証拠**。
- 隣接ペアごとに、カットエッジの端点から共有写真を `overlap` 枚（既定 15）選び、
  **両方のグループのフォルダへ入れる**。
- 選び方には条件がある。**カメラ位置が一直線に並ぶと③の変換推定が退化する**ので、
  結合スコアが高い順に採るだけでなく、視点が散らばるように選ぶ（例: 既に選んだ
  写真と視覚的に近すぎるものは飛ばす）。廊下を直進しながら撮った区間はここが
  効いてくる。

### 4.5 出力

```
仕分け先/
  group-01/  … 写真（ハードリンク。同一ボリューム外ならコピーへフォールバック）
  group-02/
  _excluded/ … 品質フィルタで落とした写真
  _unassigned/
  manifest.json
```

```jsonc
{
  "version": 1,
  "source": "/Users/me/現場写真",
  "settings": { "overlap": 15, "maxPerGroup": 150, "timeGap": 300, "visualThreshold": 0.35 },
  "groups": [
    { "id": "group-01", "photos": ["IMG_0001.HEIC", "…"], "evidence": ["time", "visual"] }
  ],
  "adjacency": [
    { "a": "group-01", "b": "group-02", "sharedPhotos": ["IMG_0118.HEIC", "…"], "confidence": 0.82 }
  ],
  "excluded": [ { "photo": "IMG_0044.HEIC", "reason": "blur", "score": 0.12 } ]
}
```

`adjacency` は③がそのまま読む。**`sort` と `merge` の契約はこの manifest 1 つ**で、
`UpdateFeed` と `build.yml` が機械可読形式で対になっているのと同じ関係になる。
片方を変えるときは両方＋テストを更新する。

## 5. ポストプロセス（`merge`）

**Object Capture に「2 つのモデルを合成する」API は無い。** 自前で変換を求める。

### 5.1 求めるもの: 相似変換（7 自由度）

回転 R・並進 t・**一様スケール s**。スケールが自由度に入るのは、depth を持たない
通常のカメラの写真では Object Capture の出力が実寸にならず、セッションごとに
スケールが違うため。

```swift
public struct SimilarityTransform: Equatable, Sendable {
	public var scale: Float
	public var rotation: simd_quatf
	public var translation: SIMD3<Float>
	public var matrix: simd_float4x4 { get }
	public func concatenated(with other: SimilarityTransform) -> SimilarityTransform
	public var inverse: SimilarityTransform { get }
	public func apply(to point: SIMD3<Float>) -> SIMD3<Float>
}
```

### 5.2 対応点をどう作るか

グループ A と B の再構成結果から、それぞれ `Poses` が得られる
（`urlsBySample` で写真ファイルに紐づく）。4.4 で共有写真を入れてあるので、

```
S = keys(poses_A) ∩ keys(poses_B)        // 共有写真の URL 集合
対応点ペア = { (poses_A[u].translation, poses_B[u].translation) | u ∈ S }
```

**対応点が無料で手に入る。** 特徴点マッチングも手作業も要らない。

### 5.3 Umeyama 法 + RANSAC

対応点集合から最小二乗の相似変換を**閉形式で**解く。

1. 両側の重心を引く
2. 共分散行列 `H = Σ (b_i - b̄)(a_i - ā)ᵀ`
3. SVD `H = U Σ Vᵀ` → `R = V · diag(1, 1, det(V Uᵀ)) · Uᵀ`（反射を排除）
4. `s = tr(Σ D) / Σ‖b_i - b̄‖²`
5. `t = ā - s R b̄`

**3×3 の SVD は自前実装で足りる**（`HᵀH` の固有分解を Jacobi 法で）。LAPACK も
Accelerate も要らないので、外部依存ゼロを維持できる。

外れ値対策に RANSAC を被せる: 3 点をランダムに選んで変換を推定 → 全対応点の残差から
インライア数を数える → 最良のインライア集合で再推定。

**退化の検出は必須。** 対応点が同一直線上に並ぶと解が一意に定まらない。共分散行列の
特異値比を見て、閾値以下なら「対応点の配置が退化している」とエラーにする（黙って
おかしな変換を返さない）。4.4 の「視点を散らす」設計はこの退化を避けるためにある。

推定した `R` が共有写真のカメラ**向き**（`Pose.rotation`）も一致させるかを別途
検証すると、誤った解を弾ける。位置だけで解いて向きで検算する。

### 5.4 ポーズグラフ: 全体を 1 つの座標系へ

隣接ペアごとの相対変換が揃ったら、全グループを 1 つの座標系に載せる。

1. グループをノード、相対変換をエッジとするグラフを作る。
2. 基準ノード（最大グループ）を単位変換に固定する。
3. **信頼度（RANSAC のインライア数）で重み付けした最大全域木**を張り、根から変換を
   伝播させる。
4. 木に含まれない閉路のエッジで**ループクロージャ誤差**を計算し、報告する。

4 は最適化しなくても価値がある。「どのグループの繋ぎが怪しいか」がユーザーに分かる
（＝撮り直す場所が分かる）。全体最適化は将来のフェーズ。

**誤差は連鎖する。** 8 グループを鎖状に繋ぐと端で歪む。木の深さを浅くする（基準を
中央に置く）だけでもかなり違う。

### 5.5 出力: 配置のみ

**メッシュは結合しない。** 各グループのメッシュをそのまま残し、座標系だけ揃えて
1 つのシーンへ配置する。建築用途ではむしろこの形の方が扱いやすい（部屋ごとに分かれた
ままレイヤ分けできる）。

書き出し方式は 2 案。**(b) を主案とする。**

**(a) ModelIO で埋め込み** — 各 `group-NN.usdz` を `MDLAsset` として読み、変換を
掛けて 1 つのアセットに子として集約し `export(to:)`。単一ファイルで完結する。
ただし **ModelIO の USDZ 往復でマテリアル・テクスチャが保持されるかは未検証**
（実データでの CI 検証が要る）。

**(b) USD の参照を自前で書く** — `scene.usda` をテキストとして生成し、各
`group-NN.usdz` を `references` で参照して `xformOp:transform` を与える。

```usda
#usda 1.0
(upAxis = "Y")
def Xform "Site" {
    def Xform "group_01" ( references = @./group-01.usdz@ ) {
        matrix4d xformOp:transform = ( … )
        uniform token[] xformOpOrder = ["xformOp:transform"]
    }
    def Xform "group_02" ( references = @./group-02.usdz@ ) { … }
}
```

生成するのは単純なテキストで、**テクスチャは元の usdz のまま一切触らないので
確実に保持される**。RealityKit・Blender・各種 CAD いずれも読める。出力は
「フォルダ + `scene.usda`」になる。単一ファイルが要るときは後段で zip 化する
（あるいは (a) を選ぶ）。

### 5.6 手動の対応点と実寸スケール

`poses` が使えない場合（既に再構成済みのモデルしか無い、共有写真を入れ忘れた）の
逃げ道として、**2 つのモデル上で対応する点を 3 点以上指定する**経路を残す。角や
開口部の端点を選ぶ。**5.3 の Umeyama がそのまま使える**ので、追加コストは点を選ぶ
UI だけ。

同じ仕組みで**実寸化**もできる。モデル上の 2 点と実測値（例「この壁は 3.6 m」）を
与えれば、全体スケールが決まる。建築用途ではこれが最終的に一番効く機能かもしれない。

### 5.7 ICP（将来）

点群化 → 法線推定 → 最近傍対応 → Umeyama → 反復、で変換を精密化する。ICP 自体は
純ロジックとして実装・テストできるが、**粗合わせ無しの ICP は収束しない**。
「5.3 の結果を初期値にして誤差を詰める」用途に限定する。単独で「全自動でどこに
繋がるか探す」のは研究レベルなので狙わない。

## 6. アーキテクチャ

依存の向き（CLAUDE.md「アーキテクチャ」）は維持する。GUI は薄いシェルのまま。

```
Sources/PhotogrammetryCore/
  ReconstructionRequest.swift        既存
  APICommand.swift                   既存（7 で拡張）
  PhotogrammetryEngine.swift         既存（poses 出力を追加）
  Preprocess/
    PhotoMetadata.swift        1 枚分のメタ + 特徴ベクトル（値型・Sendable）
    PhotoInspector.swift       Vision / ImageIO / vImage を叩く唯一の層  ← ラッパー
    PhotoGrouping.swift        メタ + 距離 → グループ + 隣接             ← 純ロジック
    SortPlan.swift             グループ → フォルダ構成と重複の割り当て   ← 純ロジック
    SortManifest.swift         manifest.json の Codable 定義            ← 純ロジック
    PhotoSorter.swift          計画の実行（FileManager・リンク／コピー）
    SortRequest.swift          仕分け 1 回分の指示 + validate           ← 純ロジック
  Merge/
    SimilarityTransform.swift  相似変換・合成・逆変換（simd）           ← 純ロジック
    PointSetAlignment.swift    Umeyama + RANSAC + 退化検出              ← 純ロジック
    PoseGraph.swift            相対変換 → 全体の絶対変換・ループ誤差    ← 純ロジック
    ICP.swift                  反復最近傍点（フェーズ 4）               ← 純ロジック
    SceneAssembler.swift       usda 生成／ModelIO 書き出し              ← ラッパー
    MergeRequest.swift         合成 1 回分の指示 + validate             ← 純ロジック
```

**「純ロジック」と書いた層は Vision も ModelIO も RealityKit も import しない。**
フレームワークに触るのは `PhotoInspector` と `SceneAssembler` の 2 つだけで、これは
`PhotogrammetryEngine` が RealityKit を閉じ込めているのと同じ構造。この分離が
そのままテスト方針（8）になる。

## 7. API 語彙の拡張

外部連携の語彙は `APICommand` に 1 か所だけ、というルールを守る。単一のリクエストを
返す形から、コマンドの enum を返す形へ広げる。

```swift
public enum APICommand {
	case process(ReconstructionRequest)
	case sort(SortRequest)
	case merge(MergeRequest)

	public static func parse(url: URL) throws -> APICommand
	public static func parse(arguments: [String]) throws -> APICommand
}
```

CLI（サブコマンド名が無ければ従来どおり `process` として扱い、**既存の呼び出しの
後方互換を壊さない**）:

```bash
photogrammetry-cli sort  <入力フォルダ> <出力フォルダ> \
    [--overlap N] [--max-per-group N] [--time-gap 秒] \
    [--visual-threshold f] [--min-quality f] [--link copy|hardlink|symlink]

photogrammetry-cli merge <グループ出力フォルダ> <出力.usda|出力.usdz> \
    [--method poses|points] [--points 対応点.json] [--scale-reference "3.6"]

photogrammetry-cli <入力> <出力.usdz> [既存のオプション] [--emit-poses <path.json>]
```

URL スキーム（語彙は CLI と共通）:

```
photogrammetry://sort?input=…&output=…&overlap=15&maxPerGroup=150
photogrammetry://merge?input=…&output=…&method=poses
```

`APICommand.parse` の返り値型が変わるのは破壊的変更だが、呼び出し元は CLI と
ViewModel だけで影響は閉じる。README のライブラリ利用例は
`ReconstructionRequest` を直接組み立てているので影響しない。

## 8. テスト方針

CLAUDE.md のテスト方針をそのまま適用する。**純ロジックを `swift test` で、実際の
再構成は自動テストしない。**

下記はすべて GPU もネットワークも要らないので CI で常時回る。

| 対象 | テスト内容 |
| --- | --- |
| `PhotoGrouping` | 合成メタデータ（時刻・GPS・距離行列）→ 期待するグループと隣接。証拠が欠けた場合のフォールバック |
| `SortPlan` | グループ + `overlap` → フォルダ計画。**共有写真が両側に入ること**。上限超えの再分割 |
| `SortManifest` | Codable の往復 |
| `SimilarityTransform` | 合成・逆変換・恒等、行列との相互変換 |
| `PointSetAlignment` | 既知の (s, R, t) で変換した点群から元の変換を復元できる。外れ値混入時に RANSAC が正解を選ぶ。**共線配置で退化エラーになる**。反射を含まない |
| `PoseGraph` | 木の伝播、閉路のループ誤差検出、非連結グラフの検出 |
| `APICommand` | 新しい語彙のパース、既存の位置引数の後方互換 |

`PhotoInspector` / `SceneAssembler`（フレームワークを叩く層）は既存の
`PhotogrammetryEngine` と同じくテストしない。挙動確認は実機、または ci-debug の
`run-cli` で行う。

## 9. フェーズ計画

| フェーズ | 内容 | 前提 |
| --- | --- | --- |
| **1** | 品質フィルタ、時刻／GPS による分割、重複付きチャンク、manifest、CLI `sort` | Vision 不要。単独で「枚数上限超え」を解決する |
| **2** | Vision feature print による視覚クラスタリングを証拠として統合 | 1 |
| **3** | `--emit-poses`、`SimilarityTransform` / `PointSetAlignment` / `PoseGraph` / `SceneAssembler`、CLI `merge` | 1（重複付き分割が前提） |
| **4** | 手動対応点の GUI、実寸スケール指定、ICP による精密化、ループ最適化 | 3 |
| **5** | メッシュ結合（要検討。本設計では非推奨） | 3 |

フェーズ 1 と 3 は「重複付き分割」で設計上ひと続きなので、通して実装するほうが
噛み合わせの手戻りが出ない。

## 10. 未解決事項・リスク

1. **ModelIO の USDZ 往復でテクスチャが保持されるか。** 実データでの検証が要る
   （ci-debug で写真を用意して往復させる）。5.5 (b) の usda 参照方式を主案に
   しているのはこのリスクを回避するため。
2. **出力形態を「フォルダ + scene.usda」にするか単一 usdz にするか。** 連携先
   （Vectorworks 等）が参照付き USD を読めるかで決まる。要確認。
3. **feature print の閾値に万能な既定値は無い。** 写真依存なので、手で調整できる形
   （`--visual-threshold`、manifest を見て再実行）を必ず残す。
4. **n が数千を超えたときの O(n²) 距離計算。** ブロック化の設計は 4.3 に書いたが、
   実データの規模を見てから詰める。
5. **共有写真の共線退化。** 廊下の直進区間など。4.4 の選び方ヒューリスティクスと
   5.3 の退化検出の両方で守る。
6. **あるグループの再構成が失敗すると、そのノードがポーズグラフから欠ける。**
   隣接が切れて全体が非連結になる場合がある。`merge` は非連結を検出して「どの
   グループが繋がらなかったか」を明示する（黙って一部だけ出力しない）。
7. **誤差の連鎖。** 鎖状に長く繋ぐほど端が歪む。フェーズ 4 の全体最適化までは
   「ループ誤差を報告する」に留める。
