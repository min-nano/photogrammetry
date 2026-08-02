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
| `Output.requestProgressInfo` → `ProgressInfo` / `ProcessingStage` | 残り時間・処理段階（§11） | macOS 14+ |

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
エンジンは使っていない。**これは本パイプラインと独立に先行実装する**（§11）。

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

### 4.0 設計原則: 撮影者のスキルに依存しない

**撮影を属人的な感覚に頼らせない。** 「うまく重ねて撮る」ような指示は、撮影を
他者へ任せた瞬間に破綻する。撮影推奨（§12）は提示するが、**それを守れたかどうかを
プログラム側が判定し、守れていない箇所を具体的に指摘する**ことで品質を担保する。

したがって本設計は次を守る。

1. **黙って悪い結果を出さない。** 共有写真が足りない、対応点が退化している、
   グループが繋がらない — いずれも検出して**どこがどう不足しているかを名指しで
   報告する**。処理は続行するが、結果を鵜呑みにできないことは必ず伝える。
2. **推奨は機械的に検証できるものだけにする。** 「70% 重ねて」ではなく
   「部屋を移動したら 5 秒止まる」のように、守れたかを後から判定できる形にする。
3. **撮影が推奨から外れていても最善を尽くす。** 明示的に重ねて撮っていなくても、
   隣接判定から共有可能な写真を見つけ出す（§4.4）。推奨は品質を上げるためのもので、
   前提条件ではない。

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

### 4.6 診断モード: 撮り直しをその場で判断する

再構成は時間がかかる（建築規模なら数時間）。**撮影が不十分だったと分かるのが帰社後
では遅い。** `sort` は再構成を伴わないので数分で終わる。そこで、仕分けと同時に
「この写真群は合成まで到達できるか」を判定して報告する診断モードを持たせる。

`sort --diagnose`（あるいは `sort` の既定出力）が報告すること:

- **グループ数と各グループの枚数**（上限超え・少なすぎの警告）
- **隣接グループごとの共有写真数**
  例: `group-03 ↔ group-04: 共有 4 枚（推奨 10 枚以上）— 合成が不安定になります`
- **共有写真の視点の散らばり**（共線退化の予兆。§5.3）
  例: `group-05 ↔ group-06: 共有写真の視点がほぼ一直線です — 角度を変えた写真を数枚追加してください`
- **どのグループとも繋がらない孤立グループ**
  例: `group-07 はどのグループとも共有写真がありません — この範囲は単独のモデルになります`
- **品質フィルタで落とした枚数と理由の内訳**

**これが §4.0 の原則を実際に機能させる仕組み。** 撮影者のスキルではなく、現場で回る
フィードバックループで品質を担保する。撮影者が不慣れでも、「group-03 と 04 の間を
数枚撮り足してください」という指示は誰でも実行できる。

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

書き出し方法は ci-debug（macOS 15.2）で実測した。
run: <https://github.com/min-nano/photogrammetry/actions/runs/30724126241>

| 方法 | usdz 書き出し | テクスチャ |
| --- | --- | --- |
| ModelIO `MDLAsset.export(to:)` | **不可** | — |
| SceneKit `SCNScene.write(to:)` | **可** | zip 内に同梱される |
| 自前で `.usda` を書く（参照方式） | （usdz ではない） | 元ファイルのまま無加工 |

**ModelIO は usdz を書けない。** `canExportFileExtension` は
`usd` / `usda` / `usdc` / `obj` / `ply` / `stl` / `abc` に true を返すが、
**`usdz` だけ false**。書き出したヘッダにも `Model IO export preview` と入る。

以上を踏まえた 3 案。

**(a) SceneKit で単一 usdz に埋め込む** — `SCNScene(url: group-NN.usdz)` で読み、
`node.simdTransform` に相似変換を入れ、1 つの `SCNScene` へ集約して `write(to:)`。
**既存 usdz を読み直して変換を掛け再書き出しする経路まで実測で通っている**
（＝実際の merge と同じ経路）。単一ファイルで完結し、取り込み側の対応を問わない。

- 懸念 1: 書き出し時に `usdUtils/assetLocalization.cpp` のテクスチャ解決警告が出る。
  zip 内にテクスチャは入っているが、**マテリアルの結び付きが正しいかは実際に
  取り込んで見るまで分からない**。
- 懸念 2: SceneKit を経由するとジオメトリ・マテリアルが一度 SceneKit の表現へ落ちる。
  Object Capture の高密度メッシュと PBR テクスチャが劣化しないかは実データで要確認。

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

生成するのは単純なテキストで、**頂点もテクスチャも元ファイルを一切触らないので
劣化が原理的に起きない**。出力は「フォルダ + `scene.usda`」になる。取り込み側が
外部参照を解決できることが条件。

**(c) 変換行列だけ出して取り込み側で配置する** — `merge` の出力を
「個別の `group-NN.usdz` + 変換行列の JSON」とし、配置は取り込み側で行う。
USD の合成機能に一切依存しないので**最も確実**。姉妹リポジトリ
`vectorworks-plugin-import-ifc-homeskz` があるので、Vectorworks プラグイン側で
受ける道がある。ただし取り込み側の実装が要る。

### 5.5.1 検証結果: 案(a) を採用する

`scripts/make-usd-samples.sh` で生成した `scene_reloaded.usdz`（= 既存 usdz を
読み直し、変換を掛けて再結合したもの。**実際の `merge` と同じ経路**）を
Vectorworks で開いて確認した。

| 確認項目 | 期待 | 結果 |
| --- | --- | --- |
| テクスチャ | 赤／青のチェッカーが乗る | **OK**（両方とも表示） |
| 単位系 | 1 USD 単位 = 1 m | **OK**（赤い立方体が 1 辺 1m） |
| 相似変換のスケール | box_b に 0.5 倍 | **OK**（青い立方体が 1 辺 500mm） |
| 相似変換の回転・並進 | Y 軸 45 度・X 方向 3.0 | **OK**（離れた位置に回転して配置） |
| 上方向の変換 | USD は Y-up、Vectorworks は Z-up | **OK**（自動変換される） |

**したがって出力形態は案(a)（SceneKit による単一 usdz）を主案として確定する。**
単一ファイルで完結し、取り込み側に追加実装が要らない。

### 5.5.2 案(b) 外部参照の検証結果: テクスチャが落ちる

同じサンプルの `scene_referenced_usdz.usda` も Vectorworks で開いた。

| 確認項目 | 結果 |
| --- | --- |
| 外部参照の解決 | **OK**（両方の立方体が現れる） |
| 相似変換 | **OK**（片方が 0.5 倍・回転して配置される） |
| prim 名の保持 | **OK**（`def Xform "Site"` がグループ名 `Site` になる） |
| テクスチャ | **NG**（無地になる） |

**参照そのものは解決されている。落ちるのはテクスチャだけ。** 原因は生成時に出ていた
警告と一致する。

```
Failed to resolve reference @0/texgen_0.png@ with computed asset path @0/texgen_0.png@
```

SceneKit が書く usdz は、テクスチャをパッケージ内パス（`0/texgen_0.png`）で参照する。
**その usdz を単体で開くときは解決できるが、外側のレイヤから参照されると解決できない。**

ここで**過大に一般化しないこと**。今回参照した usdz は SceneKit が書いたもので、
テクスチャの資産パスもそれが決めている。**Object Capture が書いた usdz を参照した
場合に同じことが起きるかは別問題**で、未検証。RealityKit が正しく解決できるパスを
書いていれば (b) は成立しうる。

実務上の結論は変わらない。**案(a) が優位で、(b) は現時点で不確実。**
§10-2（SceneKit 経由の劣化）が起きた場合の退避先としては、
(b) より **(c) 変換行列を出して取り込み側で配置**のほうが確実になった。

### 5.5.3 prim 名は Vectorworks のグループ名になる

`def Xform "Site"` がそのままグループ名 `Site` として現れた。したがって
**`group-01` 等の名前は取り込み側まで届く**。「配置のみ・メッシュを結合しない」と
いう選択の利点（部屋ごとに分かれたまま扱える）は実際に活かせる。

案(a) では SceneKit のノード名がこれに相当する。子ノードの名前まで保持されるかは
未確認（§10-3）。

### 5.6 手動の対応点と実寸スケール

`poses` が使えない場合（既に再構成済みのモデルしか無い、共有写真を入れ忘れた）の
逃げ道として、**2 つのモデル上で対応する点を 3 点以上指定する**経路を残す。角や
開口部の端点を選ぶ。**5.3 の Umeyama がそのまま使える**ので、追加コストは点を選ぶ
UI だけ。

同じ仕組みで**実寸化**もできる。モデル上の 2 点と実測値（例「この壁は 3.6 m」）を
与えれば全体スケールが決まる。

ただし**実寸化そのものは必須機能ではない**。取り込み先の Vectorworks で実測値に
合わせてスケールできるため。したがってフェーズ 4 に置く。

**重要なのは、合成によって全グループのスケールが揃うこと。** 各グループは
別セッションなのでスケールがばらばらだが、§5.3 の相似変換はスケールも含めて解くので、
合成後は全体が 1 つのスケールに統一される。**そうであれば取り込み側での調整は
全体に 1 回で済む。** 合成せずにグループごとに取り込むと、グループの数だけ手作業で
スケールを合わせることになり現実的でない。ここが `merge` の実務上の価値でもある。

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
| **0** | 進捗表示の改善（残り時間・処理段階）。§11 | 本パイプラインと独立。単独で先行実装できる |
| **1** | 品質フィルタ、時刻／GPS による分割、重複付きチャンク、manifest、診断モード、CLI `sort` | Vision 不要。単独で「枚数上限超え」を解決する |
| **2** | Vision feature print による視覚クラスタリングを証拠として統合 | 1 |
| **3** | `--emit-poses`、`SimilarityTransform` / `PointSetAlignment` / `PoseGraph` / `SceneAssembler`、CLI `merge` | 1（重複付き分割が前提） |
| **4** | 手動対応点の GUI、実寸スケール指定、ICP による精密化、ループ最適化 | 3 |
| **5** | メッシュ結合（要検討。本設計では非推奨） | 3 |

フェーズ 1 と 3 は「重複付き分割」で設計上ひと続きなので、通して実装するほうが
噛み合わせの手戻りが出ない。

## 10. 未解決事項・リスク

1. ~~出力形態をどれにするか~~ → **解決済み。案(a) SceneKit 単一 usdz に確定**（§5.5.1）。
   Vectorworks での実測でテクスチャ・単位系・相似変換すべて正しく渡ることを確認した。
2. **SceneKit 経由でメッシュ・テクスチャが劣化しないか。** ← **残る最大の未検証事項。**
   立方体のサンプルでは問題なかったが、**Object Capture の実出力（高密度メッシュ +
   PBR テクスチャ）で同じとは限らない**。`scripts/usdz-roundtrip.swift` で確かめる
   （写真は不要。既に生成済みのモデルが 1 つあれば足りる）。
   劣化した場合の退避先は **(c) 変換行列出力**。(b) 外部参照は §5.5.2 のとおり
   テクスチャが落ちたため、退避先として当てにできない。
3. **SceneKit のノード名が Vectorworks 側で保持されるか。** USD の prim 名が
   グループ名になることは確認済み（§5.5.3）。案(a) の経路で**子ノードまで**
   名前が届くかは未確認。届けば `group-01` 等が部屋ごとの識別子として使える。
4. **Object Capture が書いた usdz なら外部参照でもテクスチャが解決されるか。**
   §5.5.2 のテクスチャ欠落は SceneKit が書いた資産パスに起因する可能性がある。
   (b) を退避先として復活させたい場合のみ確かめればよく、優先度は低い。
5. **feature print の閾値に万能な既定値は無い。** 写真依存。**固定の既定値を持たず、
   距離のヒストグラムから自動決定する**設計にする（分布の谷を探す。大津の二値化に
   相当）。現場ごとの違いに適応でき、かつ**実写真を見なくても実装できる**。手動での
   上書き（`--visual-threshold`）は逃げ道として残す。
6. **n が数千を超えたときの O(n²) 距離計算。** ブロック化の設計は 4.3 に書いたが、
   実データの規模を見てから詰める。
7. **共有写真の共線退化。** 廊下の直進区間など。4.4 の選び方ヒューリスティクスと
   5.3 の退化検出の両方で守る。
8. **あるグループの再構成が失敗すると、そのノードがポーズグラフから欠ける。**
   隣接が切れて全体が非連結になる場合がある。`merge` は非連結を検出して「どの
   グループが繋がらなかったか」を明示する（黙って一部だけ出力しない）。
9. **誤差の連鎖。** 鎖状に長く繋ぐほど端が歪む。フェーズ 4 の全体最適化までは
   「ループ誤差を報告する」に留める。
10. **実写真は公開できない。** 閾値調整と実機検証をどう回すか。方針は次のとおり。
   - **写真を共有しなくて済む設計にする。** 閾値は自動決定（項目 3）。これが基本。
   - **診断モードが統計だけを出す。** 距離のヒストグラム、グループサイズ、共有写真数、
     除外理由の内訳 — いずれも**写真そのものを含まない**。調整はこの統計だけで足りる。
   - **実機検証は self-hosted runner を検討する。** GitHub Actions のランナーを手元の
     Mac に登録すれば、写真は手元から出ないまま ci-debug が使える。副次的に
     **Object Capture の GPU 要件も満たす**ので、いま実機でしか確認できない項目
     （`poses` の実値、SceneKit 経由の劣化）も CI に載せられる。
   - プライベートリポジトリへ写真を置く案は**採らない**。第三者インフラへ上がること、
     ci-debug の `GITHUB_TOKEN` が別リポジトリを読めない（PAT の登録が要る）こと、
     Git LFS 無しに大量の写真を git へ入れるのが非現実的なこと、の 3 点による。

## 11. 進捗表示の改善（フェーズ 0・先行実装）

**本パイプラインと独立に、先に実装する。** 既存の `Event` に case を足すだけで、
仕分け・合成のどちらにも依存しない。

現状の進捗は `requestProgress` の 0.0〜1.0 だけ。建築規模では 1 グループでも数時間、
さらにそれをグループ数だけ繰り返すので、**「全体の何割か」だけでは足りない**。
macOS 14+ に残り時間と処理段階を返す出力がある（§2 で実在を確認済み）。

```swift
case requestProgressInfo(Request, Output.ProgressInfo)

public struct ProgressInfo {
	public let estimatedRemainingTime: TimeInterval?      // 秒
	public let processingStage: Output.ProcessingStage?
}

public enum ProcessingStage {
	case preProcessing
	case imageAlignment
	case pointCloudGeneration
	case meshGeneration
	case textureMapping
	case optimization
}
```

**段階が見えること自体に診断価値がある。** README の「エラー 6」は写真群の
位置合わせ失敗だが、これは `imageAlignment` で起きる。段階が出れば「アライメントまで
到達したのか、その前で落ちたのか」が切り分けられる。いまは全部「エラー 6」に見える。

設計:

- `PhotogrammetryEngine.Event` に
  `.progressInfo(remaining: TimeInterval?, stage: Stage?)` を追加する。
- `Stage` は**自前 enum**にする。RealityKit の型を外へ漏らさない規約に従い、変換表は
  `PhotogrammetryEngine.swift` 内に 1 つだけ置く（`Detail` / `SampleOrdering` と同じ扱い）。
  rawValue は CLI 出力の語彙になるので `imageAlignment` 等をそのまま使う。
- CLI: 既存の `progress=` はそのままに、`stage=imageAlignment` と `eta=1830` を追加する。
  key=value 1 行という既存の約束を崩さない。
- GUI: プログレスバーの下に「画像の位置合わせ中 — 残り約 30 分」。`ViewModel` は
  イベントを表示へ写すだけで、判断は持たない（既存の方針どおり）。
- `estimatedRemainingTime` も `processingStage` も **Optional**。OS が返さないことが
  あるので、欠けたときに表示が崩れないようにする。

将来（フェーズ 3 以降）: 複数グループを順に処理するようになったら
「グループ 3/8・全体の残り時間」まで出す。グループ単位の進捗は `merge` の導入後。

## 12. 撮影ガイド（推奨手順）

§4.0 のとおり、これは**前提条件ではなく品質を上げるための推奨**。守れなくても
`sort` が不足を検出して指摘する（§4.6）。撮影を他者に任せられるよう、**判定可能で
感覚に頼らない手順だけ**を挙げる。

1. **1 つの部屋・1 つの面を撮り終えるまで、途中で別の場所へ寄り道しない。**
   時刻ギャップによる分割が効かなくなる。
2. **場所を移るときは 5 秒立ち止まってから歩き出す。** この間が「区切り」の信号になる。
3. **部屋を出る前に、出口付近から次に入る先の方向を数枚撮る。**
   これが隣接グループの共有写真になる。**合成の精度に最も効くのはこの数枚。**
4. **その数枚は、立ち位置を変えて撮る。** 同じ場所から向きだけ変えた写真ばかりだと
   視点が一直線に並び、変換推定が退化する（§5.3）。2〜3 歩ずつ動いて撮る。
5. **歩きながら連写しない。** ブレた写真は品質フィルタで落ちるだけで枚数を圧迫する。
   立ち止まって撮る。
6. **同じ場所で何十枚も撮らない。** ほぼ同一の写真は 1 枚しか使われない。

**撮影者への指示は 3 と 4 を中心にする。** この 2 つだけ守られれば合成はかなり安定し、
残りは仕分け側で吸収できる。
