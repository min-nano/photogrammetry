# ANE モデルのコンパイル失敗を掘る

#11〜#14 で Object Capture を何度も試行する中で、次の失敗が繰り返し出ている。

```
E5RT encountered an STL exception. msg = MILCompilerForANE error:
failed to compile ANE model using ANEF. Error=_ANECompiler : ANECCompile() FAILED.
```

アプリ本体（main）は `ModelCache`（`Sources/PhotogrammetryCore/ModelCache.swift`）で
これを見分け、`~/Library/Caches/<バンドル ID>/com.apple.e5rt.e5bundlecache` を消して
作り直すことで復旧している。**それは対処であって原因ではない。** この文書は原因の
候補を 1 つずつ潰すための記録で、結論が出たものはここに書き足していく。

候補は 3 つあった。

| 候補 | 状態 | 根拠 |
| --- | --- | --- |
| Xcode が古い | **潰した**（が犯人ではない） | §1 |
| OS / デバイスと合っていない | **潰した**（範囲は確認済み） | §2 |
| メモリ不足 | **未決。実機で測る**（§3 のスクリプト） | §3 |

---

## 1. Xcode が古い

### 分かったこと

CI は 3 本のワークフロー（`build.yml` / `test.yml` / `ci-debug.yml`）すべてで
**Xcode 16.2（macOS 15.2 SDK）に固定**されていた。2026-08 時点の
[actions/runner-images](https://github.com/actions/runner-images) の中身は

| ランナー | macOS | 入っている Xcode |
| --- | --- | --- |
| `macos-15` | 15.7.7 | 26.3 / 26.2 / 26.1.1 / 26.0.1 / **16.4（既定）** / 16.3 / 16.2 / 16.1 / 16.0 |
| `macos-26` | 26.5.2 | **26.6（既定）** / 26.5 / 26.4.1 / 26.3 / 26.2 / 26.1.1 / 26.0.1 |

なので、16.2 は**既定より 3 世代前**を明示的に選び続けていたことになる。
GA の最新（macos-26 + Xcode 26.6）へ揃えた。ユニバーサル（arm64 + x86_64）の
リリースビルドが通ることは ci-debug で確認済み（`swift build -c release
--arch arm64 --arch x86_64` が成功）。

### ただし、これは犯人ではない

**ANE 用の ML モデルも、それをコンパイルする ANECompiler も、アプリではなく
OS の側にある。** `CorePhotogrammetry` が内部で使うモデルはアプリのバンドルに
入っていないし、コンパイルを走らせるのも E5RT（OS のランタイム）である。
したがって、どの Xcode でビルドしても**コンパイルされる中身は変わらない**。

SDK を上げる意味は「古い SDK にリンクした結果、実行時に別の互換経路へ入る」
という筋の可能性を、調査の変数から外せることに尽きる。**変数を 1 つ減らす
ための作業であって、これで直ると期待してはいけない。**

## 2. OS / デバイスのターゲット

### いま宣言しているもの

| どこ | 値 |
| --- | --- |
| `Package.swift` | `platforms: [.macOS(.v14)]` |
| `packaging/Info.plist` | `LSMinimumSystemVersion = 14.0` |
| ビルド | ユニバーサル（arm64 + x86_64） |
| README | 「macOS 14 以降」 |

macOS 14 を下限にしているのは `PhotogrammetrySession.Request.poses` と
`Output.requestProgressInfo`（進捗の段階・残り時間）が macOS 14+ だから
（`docs/design-preprocess-merge.md` §2）。宣言は 4 か所で揃っている。

### Object Capture 側の要件（Apple の言う下限）

- **Apple Silicon（M1 以降）**、または
- **Intel Mac + 16GB RAM + AMD GPU（VRAM 4GB 以上・レイトレーシング対応）**

満たすかどうかは `PhotogrammetrySession.isSupported` が答える
（`PhotogrammetryEngine.isSupported` で公開済み。GUI・CLI とも起動時に見る）。

### ここから言えること

**ANE の失敗が出ているなら、そのマシンは Apple Silicon である。** Intel Mac に
Neural Engine は無く、E5RT / ANECCompile の経路そのものが存在しない。つまり
「デバイスが要件を満たしていない」という筋ではない — 要件を満たしているからこそ
ANE 経路に入っている。

**残る「合っていない」は OS 側の新しさの向きだけ**（アプリが古い SDK に対して
リンクされている、OS のモデルとコンパイラの組み合わせに不具合がある、など）。
前者は §1 で外した。後者はこちらから動かせないので、**再現条件を細かく残すこと**
（§3 のスクリプトが `env.txt` に macOS のビルド番号まで書く）が唯一の手になる。

## 3. メモリ不足 — 実機で測る

3 つの候補のうち、**手元で振れる変数を持つのはこれだけ**である（写真の枚数を
減らせばメモリの山は下がる）。すでに実測されている山の高さは、

| 条件 | ピーク物理フットプリント |
| --- | --- |
| 190 枚・姿勢のみ | **4.7GB** |
| 190 枚・姿勢 + モデル（`reduced`） | **14.4GB** |

（`docs/design-loose-clustering.md` §6.2.7）。搭載メモリによっては、これは
十分に天井へ届く高さである。

### 測る道具

```
scripts/measure-ane.swift      1 回投げて何が起きたかを機械可読に吐くだけの実行体
scripts/trial-ane-memory.sh    枚数を振って繰り返し、表にする driver
```

```bash
# まず 1 周だけ回して、道具が壊れていないことを確かめる
scripts/trial-ane-memory.sh ~/Pictures/現場 --counts 40 --repeats 1

# 本番（一晩置く想定）
scripts/trial-ane-memory.sh ~/Pictures/現場 --counts 40,80,160,320 --repeats 3

# 逆向きの実験（**作業中の Mac ではやらない**）
scripts/trial-ane-memory.sh ~/Pictures/現場 --counts 160 --repeats 3 --ballast 0,16
```

### 設計で外せない点

1. **試行ごとに ANE キャッシュを消す。** ANE 用モデルのコンパイルは
   **キャッシュが空のときにしか走らない**。消さずに枚数を振ると、コンパイルは
   1 回目にしか走らず、2 回目以降の「成功」は「コンパイルが成功した」ではなく
   「コンパイルしなかった」を意味する。それを枚数の効果と読むと、**必ず
   「枚数を減らせば直る」という嘘の結論**になる（1 回目が多い枚数なら逆の嘘）。
   ここが測定の要で、driver の存在理由でもある。

2. **枚数を往復させる**（巡ごとに全部の枚数を 1 回ずつ）。同じ枚数を続けて回すと、
   温度・他のアプリ・キャッシュの育ち方といった時間とともに動くものが、枚数と
   見分けられなくなる。

3. **失敗した瞬間の段階とメモリを残す。** 「何枚で失敗したか」だけでは裏が
   取れない。E5RT の行が出た時点の処理段階・フットプリント・システムの空き・
   スワップ・メモリ圧レベルまで記録する（`trials.tsv` の `ane_at_*` 列）。
   山の頂上（`imageAlignment` など）で毎回出るならメモリ、前処理の入口で出るなら
   メモリではない。

4. **逆向きの実験を用意する**（`--ballast`）。枚数を減らして出なくなった、は
   「メモリが原因」の証明にならない（たまたま出なかっただけかもしれない）。
   わざと空きを潰して**失敗を呼び出せるか**まで見て初めて確定する。既定では
   使わない。

5. **E5RT の行は行頭に来ないことがある。** フレームワークは改行なしで書くので、
   こちらの 1 行の前に繋がって出る（`"E5RT …ANECCompile() FAILED.window
   name=… result=ok"` が実際に記録されている）。判定も抽出も**行頭で錨を
   打たない**こと。

### 出るもの

```
<out>/env.txt      macOS のバージョンとビルド番号・チップ・搭載メモリ・Xcode・空き容量
<out>/trials.tsv   1 試行 1 行（outcome / ane_marker / ピーク / 失敗時の段階 …）
<out>/logs/        1 試行ぶんの生ログとメモリの標本
```

最後に枚数 × 重しごとの表（試行数・ANE 失敗数・abort 数・ピーク・空きの最小）が
出る。**読み方も一緒に出る**ので、表だけ見て早合点しないこと。

### 結論を書く場所

測定が終わったら、その結果をこの節の下に追記する。「枚数の上限で防げる」なら
それは `SortRequest` / `APICommand` の `maxPerGroup` の既定を決める根拠になり、
「防げない」なら `ModelCache` の対処（消して作り直す）が唯一の手だと確定して、
**自動で消してやり直す**ところまで本体へ入れる判断ができる。

## 4. まだ手を付けていない筋

- **同じ写真・同じ枚数で失敗が再現するか**（決定的なのか、確率的なのか）。
  §3 の driver は同じ条件を複数回回すので、この答えも副産物として出る。
- **キャッシュの置き場が一杯・書き込めない**という筋。`env.txt` に
  `~/Library/Caches` の空きを残しているので、失敗時に相関を見られる。
- **他のプロセスが同時に ANE を使っている**（別アプリの Core ML）。今は
  記録していない。§3 で「枚数と無関係に散らばる」結果が出たら、次はここを見る。
