#!/usr/bin/env bash
#
# trial-clustering.sh — 「窓を作る → 最良の窓を Object Capture へ投げる →
# 結果をグラフへ返す → 窓を作り直す」を最後まで回す**試行スクリプト**。
#
# docs/design-loose-clustering.md §3.1（支持成長）・§3.10（姿勢をグラフへ返す
# 反復）を、実データで 1 本のコマンドとして通せるようにしたもの。設計メモ §10 の
# 「次に実データで走らせる手順」を人が 1 巡ずつ手で回す代わりになる。
#
#   ・EXIF は窓を作るのに一切使わない（#8 の撮影順ソートは使わない）
#   ・繋がっているかどうかの正解は Object Capture の姿勢だけを信じる
#   ・窓は共視グラフからの支持成長で作る
#   ・1 巡につき **内部指標で最良の窓を 1 つだけ**投げ、その結果を反映した
#     グラフで窓を作り直してから次の窓を選ぶ
#
# **これは製品ではなく計測の道具**（`photogrammetry-cli` には何も足さない）。
# ここで得た数字で設計を確定してから、`Sources/PhotogrammetryCore/Preprocess/`
# の純ロジックへ移す。
#
# 使い方（Object Capture が動く実機で）:
#
#   scripts/trial-clustering.sh ~/Pictures/現場 --state ~/Desktop/trial
#   scripts/trial-clustering.sh ~/Pictures/現場 --state ~/Desktop/trial --plan-only
#   scripts/trial-clustering.sh --state ~/Desktop/trial --summary
#
# **途中で止めてよい。** 同じ --state でもう一度実行すれば続きから始まる
# （1 回の再構成が数十分かかるので、止められることは要件）。
#
# 出来上がるもの（--state の下）:
#
#   rounds/NNN/windows/       その巡の窓（window-NN.txt・core/・split/・windows.tsv）
#   rounds/NNN/ordering.log   窓を作ったときの出力（辺の確定・除去・窓の突き合わせ）
#   rounds/NNN/poses-*.log    Object Capture の出力
#   attempts/<ラベル>.txt     実際に投げた窓の一覧（そのまま再現できる）
#   poses/<ラベル>.poses.tsv  姿勢（**累積**。次の巡の --feedback の入力）
#   models/<ラベル>.usdz      3D モデル（**目で確かめるため**。--no-models で止まる）
#   ledger.tsv               1 行 1 回の実行（指標と結果を並べてある）
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

photos=""
state="./trial"
capacity=200
neighbours=12
overlap_ratio=0.3
rounds=30
budget_hours=0
sensitivity=high
ordering=sequential
detail=reduced
subject=scene
drop_blurriest=10
# 1 回の上限。**900 秒では足りない。** 実測で 153 枚の窓が位置合わせだけに
# 649 秒かけて通っている（設計 §6.2.1）ので、容量 200 で走らせると、あと少しで
# 終わる再構成を打ち切ってしまう。モデルも一緒に作るぶん（+2.5%）も乗る。
timeout=1800
limit=""
ladder=1
models=1
skip_similar=0.9
plan_only=0
summary_only=0
download=0
ordering_cmd=""
poses_cmd=""

usage()
{
	cat <<'USAGE'
使い方: trial-clustering.sh <写真フォルダ> [オプション]

  --state DIR          作業場所（既定 ./trial）。同じ場所を指せば続きから
  --capacity N         窓の容量（既定 200）
  --neighbours K       共視グラフの相互近傍数（既定 12）
  --overlap-ratio R    窓のうち重なりに充てる割合（既定 0.3）
  --rounds N           最大の巡数（既定 30）
  --budget-hours H     これを超えたら次の窓を投げずに終わる（既定 0＝無制限）
  --sensitivity S      normal|high（既定 high・設計 §3.5）
  --ordering O         unordered|sequential（既定 sequential）
  --detail D           preview|reduced|medium|full|raw（既定 reduced）
  --subject S          scene|object（既定 scene）
  --drop-blurriest P   ブレの大きい下位 P% を落としてから投げる（既定 10）
  --timeout SEC        1 回の再構成の上限（既定 1800。§6.2.1 の実測より）
  --limit N            写真の先頭 N 枚だけで試す（下見用）
  --no-ladder          落ちた窓を「はぐれ抜きの芯」で試し直さない
  --no-models          3D モデル（usdz）を書き出さない（既定は書き出す）
  --skip-similar J     既に投げた窓と Jaccard がこれ以上なら投げない（既定 0.9）
  --plan-only          窓を作って順位だけ出す（Object Capture は動かさない）
  --summary            既存の --state から集計だけ出す
  --download           iCloud Drive の未ダウンロードを落としてから始める
  --ordering-cmd PATH  measure-ordering の代わりに使う実行体
  --poses-cmd PATH     measure-poses の代わりに使う実行体（自己診断用）
USAGE
}

while [ $# -gt 0 ]
do
	case "$1" in
		--state) state="$2"; shift 2 ;;
		--capacity) capacity="$2"; shift 2 ;;
		--neighbours) neighbours="$2"; shift 2 ;;
		--overlap-ratio) overlap_ratio="$2"; shift 2 ;;
		--rounds) rounds="$2"; shift 2 ;;
		--budget-hours) budget_hours="$2"; shift 2 ;;
		--sensitivity) sensitivity="$2"; shift 2 ;;
		--ordering) ordering="$2"; shift 2 ;;
		--detail) detail="$2"; shift 2 ;;
		--subject) subject="$2"; shift 2 ;;
		--drop-blurriest) drop_blurriest="$2"; shift 2 ;;
		--timeout) timeout="$2"; shift 2 ;;
		--limit) limit="$2"; shift 2 ;;
		--no-ladder) ladder=0; shift ;;
		--no-models) models=0; shift ;;
		--skip-similar) skip_similar="$2"; shift 2 ;;
		--plan-only) plan_only=1; shift ;;
		--summary) summary_only=1; shift ;;
		--download) download=1; shift ;;
		--ordering-cmd) ordering_cmd="$2"; shift 2 ;;
		--poses-cmd) poses_cmd="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		-*)
			echo "不明な引数: $1" >&2
			usage >&2
			exit 2
			;;
		*)
			if [ -n "$photos" ]
			then
				echo "写真フォルダは 1 つだけ指定してください: $1" >&2
				exit 2
			fi
			photos="$1"
			shift
			;;
	esac
done

# **不正な値は黙って既定へ落とさない。** 綴り違いが `normal` として 3.2 時間
# 走った事故があった（設計 §6.2.1）。測定の道具が黙って別の設定へ落ちるのは、
# この設計の「黙って悪い結果を出さない」に真っ向から反する。
validate()
{
	local name="$1" value="$2"
	shift 2
	local allowed
	for allowed in "$@"
	do
		[ "$value" = "$allowed" ] && return 0
	done
	echo "$name の値が不正です: ${value}（使えるのは: $*）" >&2
	exit 2
}
validate --sensitivity "$sensitivity" normal high
validate --ordering "$ordering" unordered sequential
validate --detail "$detail" preview reduced medium full raw
validate --subject "$subject" scene object

mkdir -p "$state"
state="$(cd "$state" && pwd)"
readonly LEDGER="$state/ledger.tsv"
readonly LOG="$state/trial.log"

say()
{
	printf '%s\n' "$*" | tee -a "$LOG"
}

# ---------------------------------------------------------------------
# 集計（--summary。実行の最後にも同じものを出す）
# ---------------------------------------------------------------------

summarize()
{
	local total posed_photos coverage
	echo ""
	echo "■ 投げた窓と結果（ledger.tsv）"
	if [ ! -s "$LEDGER" ]
	then
		echo "  まだ 1 つも投げていません"
		return 0
	fi
	printf '  %-18s %-6s %6s %6s %8s %6s %8s %6s %-22s %s\n' \
		ラベル 種別 枚数 連結 芯の成分 支持数 コンダク 姿勢 モデル 結果
	awk -F'\t' 'NR>1 {
		printf "  %-18s %-6s %6s %6s %8s %6s %8s %6s %-22s %s\n",
			$2, $3, $5, $6, $7, $8, $9, $12, ($15 == "" ? "-" : $15), $11
	}' "$LEDGER"

	# **内部指標は本当に成否を予言したのか。** これが分からないと「最良の窓から
	# 投げる」という手順自体に根拠が無いままになる。連結（窓が 1 つに繋がって
	# いるか）で二分して成功率を並べる。
	echo ""
	echo "■ 内部指標は成否を予言したか（連結 = 窓そのものの最大連結成分）"
	awk -F'\t' 'NR>1 {
		key = ($6 >= 0.999) ? "連結 1.00" : "連結 1.00 未満"
		if (!(key in total)) { kinds++ }
		total[key]++
		if ($11 == "ok") { ok[key]++ }
		posed[key] += $12
	}
	END {
		for (key in total)
		{
			printf "  %-16s 投げた %2d 回 / 通った %2d 回 / 姿勢 %d 枚\n",
				key, total[key], ok[key] + 0, posed[key] + 0
		}
		if (kinds < 2)
		{
			print "  → 片側しか投げていないので、まだ予言できたとは言えない"
		}
	}' "$LEDGER"

	echo ""
	echo "■ 巡ごとのグラフの直り方（見比べられた辺・確定・除去）"
	printf '  %-6s %10s %10s %10s %10s\n' 巡 見比べ 確定 除去 そのまま残った窓
	local dir judged confirmed removed identical
	for dir in "$state"/rounds/*/
	do
		[ -f "$dir/ordering.log" ] || continue
		judged=$(sed -n 's/.*見比べられた辺 \([0-9]*\) 本.*/\1/p' "$dir/ordering.log" | tail -1)
		confirmed=$(sed -n 's/.*確定 \([0-9]*\) 本・除去.*/\1/p' "$dir/ordering.log" | tail -1)
		removed=$(sed -n 's/.*・除去 \([0-9]*\) 本.*/\1/p' "$dir/ordering.log" | tail -1)
		identical=$(sed -n 's/.*そのまま残った窓: \(.*\) 個.*/\1/p' "$dir/ordering.log" | tail -1)
		printf '  %-6s %10s %10s %10s %10s\n' \
			"$(basename "$dir")" "${judged:--}" "${confirmed:--}" "${removed:--}" "${identical:--}"
	done
	echo "  → **除去が巡ごとに減っていれば収束**。増えるなら窓の作り方の問題"
	echo "  → 「そのまま残った窓」は、修正がその近傍まで届かなかった窓の数"

	# 被覆（姿勢が付いた写真の割合）。**どの窓でも姿勢が付かない写真**が
	# 「撮り直し」を名指しできる相手になる（設計 §3.7）。
	posed_photos=0
	if compgen -G "$state/poses/*.poses.tsv" >/dev/null
	then
		posed_photos=$(awk -F'\t' '$2 == 1 { print $1 }' "$state"/poses/*.poses.tsv \
			| sort -u | wc -l | tr -d ' ')
	fi
	total=0
	local latest
	latest=$(ls -d "$state"/rounds/*/windows 2>/dev/null | tail -1 || true)
	if [ -n "$latest" ] && compgen -G "$latest/window-*.txt" >/dev/null
	then
		total=$(cat "$latest"/window-*.txt | sort -u | wc -l | tr -d ' ')
	fi
	coverage=$(awk -v a="$posed_photos" -v b="$total" 'BEGIN { printf "%.3f", (b > 0 ? a / b : 0) }')
	echo ""
	# 分母は「窓に入った写真」。視覚特徴の次元が多数派と違う写真は窓に入らない
	# ので、全枚数とは限らない。**分母を書かない報告が誤読を生む**のは §6.2.2 で
	# 一度踏んでいる。
	echo "■ 姿勢の付いた写真: $posed_photos / ${total}（窓に入った写真のうち・${coverage}）"

	# 3D モデル。**姿勢の枚数は「繋がったか」しか言わない**ので、何がどう
	# 繋がったかは開いて見るしかない。場所を必ず出す。
	local model_count=0
	if compgen -G "$state/models/*.usdz" >/dev/null
	then
		model_count=$(ls -1 "$state"/models/*.usdz | wc -l | tr -d ' ')
		echo ""
		echo "■ 3D モデル: $model_count 個（$state/models）"
		du -h "$state"/models/*.usdz 2>/dev/null | sed 's/^/  /' || true
		echo "  → Finder で開けば（クイックルック / プレビュー）そのまま見える。"
		echo "    **窓ごとに 1 つ**なので、隣り合う窓が同じ場所を写しているかも目で確かめられる"
	fi

	local attempts ok_count
	attempts=$(awk -F'\t' 'NR>1' "$LEDGER" | wc -l | tr -d ' ')
	ok_count=$(awk -F'\t' 'NR>1 && $11 == "ok"' "$LEDGER" | wc -l | tr -d ' ')
	echo ""
	echo "result=summary attempts=$attempts ok=$ok_count posed=$posed_photos total=$total coverage=$coverage models=$model_count"
}

if [ "$summary_only" = 1 ]
then
	summarize
	exit 0
fi

if [ -z "$photos" ]
then
	usage >&2
	exit 2
fi
if [ ! -d "$photos" ]
then
	echo "写真フォルダがありません: $photos" >&2
	exit 2
fi
photos="$(cd "$photos" && pwd)"

# ---------------------------------------------------------------------
# 道具を用意する
#
# **必ず -O で事前コンパイルする**（インタプリタ実行だと全ペアの距離計算が桁で
# 遅い）。実行体の名前は変えない — measure-poses の ANE キャッシュの場所が
# プロセス名で決まるので、設計メモ §6.2.4 の削除手順と対になっている。
# ---------------------------------------------------------------------

mkdir -p "$state/bin" "$state/poses" "$state/attempts" "$state/rounds" "$state/cache"

build()
{
	local name="$1" source="$SCRIPT_DIR/$1.swift" out="$state/bin/$1"
	if [ -x "$out" ] && [ "$out" -nt "$source" ]
	then
		return 0
	fi
	say "ビルド中: $name"
	swiftc -O "$source" -o "$out"
}

if [ -z "$ordering_cmd" ]
then
	build measure-ordering
	ordering_cmd="$state/bin/measure-ordering"
fi
if [ -z "$poses_cmd" ] && [ "$plan_only" != 1 ]
then
	build measure-poses
	poses_cmd="$state/bin/measure-poses"
fi

if [ ! -s "$LEDGER" ]
then
	# **新しい列は末尾に足す。** 途中に入れると、前の実行で書いた台帳の列が
	# ずれて集計が黙って別の数字を出す。
	printf 'round\tlabel\tkind\tsource\tphotos\tconnected\tkcorecomp\tmedsupport\tconductance\trank\tresult\tposed\telapsed\tfingerprint\tmodel\n' > "$LEDGER"
fi

say ""
say "=== 試行開始 $(date '+%Y-%m-%d %H:%M:%S') ==="
say "写真: $photos"
say "作業場所: $state"
say "設定: 容量 ${capacity}・近傍 ${neighbours}・重なり ${overlap_ratio}・"\
"$sensitivity/${ordering}・ブレ除去 ${drop_blurriest}%・上限 ${timeout}s"

# ---------------------------------------------------------------------
# 小道具
# ---------------------------------------------------------------------

# 窓の指紋。**中身の集合が同じなら同じ指紋**（並びは無視する）。同じ窓を
# 投げ直しても新しいことは何も分からないので、これで既出を弾く。
fingerprint()
{
	sort "$1" | shasum -a 256 | cut -d' ' -f1
}

# 既に投げた窓との Jaccard の最大値。**1 回が数十分**なので、ほとんど同じ窓を
# 投げ直すのは高い。完全一致でなくても近ければ見送る。
max_jaccard()
{
	local candidate="$1" best=0 previous value
	local sorted="$state/.candidate.sorted"
	sort "$candidate" > "$sorted"
	for previous in "$state"/attempts/*.sorted
	do
		[ -f "$previous" ] || continue
		value=$(awk 'NR==FNR { if (!($0 in a)) { a[$0] = 1; left++ } next }
			{ if (!($0 in b)) { b[$0] = 1; right++ } }
			END {
				inter = 0
				for (key in a) { if (key in b) { inter++ } }
				union = left + right - inter
				printf "%.4f", (union > 0 ? inter / union : 0)
			}' "$sorted" "$previous")
		best=$(awk -v x="$best" -v y="$value" 'BEGIN { print (y > x) ? y : x }')
	done
	rm -f "$sorted"
	printf '%s' "$best"
}

# Object Capture を 1 回走らせる。ラベルがそのまま poses/<ラベル>.poses.tsv に
# なるので、**巡と窓の番号を必ずラベルに入れる**（窓の番号は巡ごとに意味が
# 変わるため、名前が衝突すると累積した姿勢が上書きされて壊れる）。
#
#   run_object_capture <ラベル> <窓の一覧ファイル> <ログ> <キャッシュを消すか>
# 標準出力に "result<TAB>posed<TAB>elapsed" を返す。
run_object_capture()
{
	local label="$1" list="$2" log="$3" purge="$4"
	local extra=()
	[ "$purge" = 1 ] && extra+=(--purge-model-cache)
	[ "$download" = 1 ] && extra+=(--download)
	# **モデルは同じセッションのついでに作る**（設計 §3.7）。位置合わせが所要の
	# 95% なので、姿勢を取る実行に足してもほぼ増えない。姿勢の枚数は「繋がったか」
	# しか言わないが、モデルは**何がどう繋がったか**を目で見せる。
	[ "$models" = 1 ] && extra+=(--models-out "$state/models")
	set +e
	# bash 3.2（macOS 既定）では set -u のもとで空配列の展開が落ちるので、
	# 空なら展開そのものを消す書き方にしてある。
	"$poses_cmd" "$photos" \
		--window-file "$list" \
		--poses-out "$state/poses" \
		--ordering "$ordering" \
		--sensitivity "$sensitivity" \
		--detail "$detail" \
		--subject "$subject" \
		--drop-blurriest "$drop_blurriest" \
		--timeout "$timeout" \
		${extra[@]+"${extra[@]}"} > "$log" 2>&1
	local status=$?
	set -e
	# **呼び出し側で止める。** ここは $( ) の中なので exit しても子シェルしか
	# 終わらない（黙って先へ進んでしまう）。
	if [ "$status" = 3 ]
	then
		printf 'unsupported\t0\t0\t-'
		return 0
	fi
	local line result posed elapsed model
	line=$(grep -m1 '^window ' "$log" || true)
	if [ -z "$line" ]
	then
		printf 'no-output\t0\t0\t-'
		return 0
	fi
	result=$(printf '%s' "$line" | sed -n 's/.* result=\(.*\)$/\1/p')
	posed=$(printf '%s' "$line" | sed -n 's/.* posed=\([0-9]*\) .*/\1/p')
	elapsed=$(printf '%s' "$line" | sed -n 's/.* elapsed=\([0-9.]*\) .*/\1/p')
	model=$(printf '%s' "$line" | sed -n 's/.* model=\([^ ]*\) .*/\1/p')
	printf '%s\t%s\t%s\t%s' "${result:-unknown}" "${posed:-0}" "${elapsed:-0}" "${model:--}"
}

# **ML モデルキャッシュの故障を見分ける**（設計 §6.2.4・ModelCache と同じ印）。
# これが出た後の成否は測定として信用できないので、黙って「error 6 が増えた」と
# 記録するのが最悪。消して 1 度だけやり直す。
is_model_cache_failure()
{
	grep -qE 'ANECCompile|MILCompilerForANE|com\.apple\.e5rt\.e5bundlecache|MPSGraphExecutable|manifest\.plist' "$1"
}

# ---------------------------------------------------------------------
# 反復（設計 §3.10）
# ---------------------------------------------------------------------

started_at=$SECONDS
# 既にある巡の数から続きを決める（**途中で止めてよい**ことが要件なので、
# 状態はファイルの並びだけで決まるようにしてある）。
existing_rounds=$(ls -1d "$state"/rounds/*/ 2>/dev/null | wc -l | tr -d ' ' || true)
round=$(( existing_rounds + 1 ))
previous_windows=""
if [ "$round" -gt 1 ]
then
	previous_windows=$(ls -d "$state"/rounds/*/windows 2>/dev/null | tail -1 || true)
	say "続きから始めます（次は $round 巡目・前の巡の窓: ${previous_windows:-なし}）"
fi
# 前の巡が 1 枚も姿勢を得られなかったとき、グラフは 1 本も変わらない。成長は
# 決定的なので**まったく同じ窓が出る**（設計 §6.2.5）。作り直す意味が無いので、
# その場合は前の巡の窓をそのまま使って次の候補へ進む。
reuse_previous=0
stop_reason="rounds"

while [ "$round" -le "$rounds" ]
do
	round_dir=$(printf '%s/rounds/%03d' "$state" "$round")
	windows="$round_dir/windows"
	mkdir -p "$round_dir"

	if [ "$reuse_previous" = 1 ] && [ -n "$previous_windows" ]
	then
		say ""
		say "── $round 巡目: 前の巡は姿勢を 1 枚も得られなかったので、窓は作り直しません"
		say "   （辺が 1 本も変わっていない以上、成長は決定的なので同じ窓が出る）"
		rm -rf "$windows"
		cp -R "$previous_windows" "$windows"
		printf '%s\n' "$previous_windows" > "$round_dir/reused-from"
	else
		say ""
		posed_files=$(ls -1 "$state"/poses/*.poses.tsv 2>/dev/null | wc -l | tr -d ' ' || true)
		say "── $round 巡目: 窓を作ります（累積した姿勢 $posed_files 件を反映）"
		ordering_args=(
			"$photos"
			--windows "$capacity"
			--window-dir "$windows"
			--neighbours "$neighbours"
			--overlap-ratio "$overlap_ratio"
			--cache "$state/cache/featureprints.cache"
		)
		[ -n "$limit" ] && ordering_args+=(--limit "$limit")
		[ "$download" = 1 ] && ordering_args+=(--download)
		if compgen -G "$state/poses/*.poses.tsv" >/dev/null
		then
			ordering_args+=(--feedback "$state/poses")
		fi
		[ -n "$previous_windows" ] && ordering_args+=(--compare-windows "$previous_windows")
		"$ordering_cmd" "${ordering_args[@]}" > "$round_dir/ordering.log" 2>&1 \
			|| { say "窓を作れませんでした（$round_dir/ordering.log を見てください）"; exit 4; }
		grep -E '^  (OC の結果を反映|見比べられた辺|窓 |次数 0|細い繋ぎ目)' \
			"$round_dir/ordering.log" | tee -a "$LOG" || true
	fi

	if [ ! -s "$windows/windows.tsv" ]
	then
		say "windows.tsv がありません（measure-ordering が窓を作れていない）: $windows"
		stop_reason="no-windows"
		break
	fi

	# --- 内部指標で順位を付ける（設計 §3.1.1・§6.2.3）---
	#
	# **すべてグラフから出た数字だけ**で決める（EXIF も見た目も使わない）。
	# 重みを付けて足し合わせるのではなく**辞書式**にしてあるのは、単位の違う
	# 数字を足した点数で切る場所を選ぶのを #12 で棄却したのと同じ理由。
	#
	#   1. 連結が 1.00（窓そのものが 1 つに繋がっている）を最優先
	#      — 繋がっていない窓は、1 回の再構成で繋がりようがない
	#   2. 芯の成分（3 コアの最大連結成分の割合）が大きい順 — 芯が太い
	#   3. 支持数の中央値が大きい順 — 1 枚ずつが強く結ばれて入った
	#   4. コンダクタンスが小さい順 — 外へ漏れていない（自然な切れ目）
	#   5. 窓の番号（同着を決定的に解く）
	ranked="$round_dir/ranked.txt"
	awk -F'\t' 'BEGIN { OFS = " " }
		/^#/ { next }
		NF >= 15 {
			broken = ($5 >= 0.999) ? 0 : 1
			printf "%d %.4f %d %.4f %s %d %.4f %.4f %d %.4f %d\n",
				broken, 1 - $8, 99 - $9, $10, $1, $2, $5, $8, $9, $10, $14
		}' "$windows/windows.tsv" \
		| sort -k1,1n -k2,2g -k3,3n -k4,4g -k5,5 > "$ranked"

	if [ ! -s "$ranked" ]
	then
		say "窓が 1 つもありません: $windows"
		stop_reason="no-windows"
		break
	fi

	say "  内部指標の順位（上から投げる）:"
	awk '{ printf "    %2d. %-16s 枚数 %4d  連結 %s  芯の成分 %s  支持数 %2d  コンダクタンス %s\n",
		NR, $5, $6, $7, $8, $9, $10 }' "$ranked" | tee -a "$LOG"

	if [ "$plan_only" = 1 ]
	then
		say ""
		say "--plan-only なのでここで止めます（Object Capture は動かしていません）"
		stop_reason="plan-only"
		break
	fi

	# --- まだ投げていない窓のうち、いちばん良いものを 1 つ選ぶ ---
	choice=""
	choice_rank=0
	while read -r _ _ _ _ name photos_count connected kcorecomp medsupport conductance hascore
	do
		choice_rank=$(( choice_rank + 1 ))
		list="$windows/$name"
		[ -f "$list" ] || continue
		print=$(fingerprint "$list")
		if awk -F'\t' -v fp="$print" 'NR>1 && $14 == fp { found = 1 } END { exit found ? 0 : 1 }' "$LEDGER"
		then
			say "    （$name はもう投げた窓と中身が同じなので飛ばします）"
			continue
		fi
		similar=$(max_jaccard "$list")
		if awk -v a="$similar" -v b="$skip_similar" 'BEGIN { exit (a >= b) ? 0 : 1 }'
		then
			say "    （$name は投げた窓と $similar 重なっているので飛ばします）"
			continue
		fi
		choice="$name"
		break
	done < "$ranked"

	if [ -z "$choice" ]
	then
		say ""
		say "投げていない窓がもうありません。**ここが収束**（同じ窓しか出てこない）"
		stop_reason="converged"
		break
	fi

	# 予算は「次の窓を投げる前」に見る。走っている再構成を途中で切らない。
	if [ "$budget_hours" != 0 ]
	then
		spent=$(( SECONDS - started_at ))
		if awk -v s="$spent" -v h="$budget_hours" 'BEGIN { exit (s >= h * 3600) ? 0 : 1 }'
		then
			say ""
			say "時間の予算（${budget_hours} 時間）を使い切りました"
			stop_reason="budget"
			break
		fi
	fi

	label=$(printf 'r%03d-%s' "$round" "${choice%.txt}")
	list="$state/attempts/$label.txt"
	cp "$windows/$choice" "$list"
	sort "$list" > "$state/attempts/$label.sorted"
	print=$(fingerprint "$list")

	say ""
	say "  → $choice を投げます（${label}・$(awk 'END { print NR }' "$list") 枚・順位 ${choice_rank}）"
	outcome=$(run_object_capture "$label" "$list" "$round_dir/poses-$label.log" \
		"$([ "$round" = 1 ] && [ ! -f "$state/.purged" ] && echo 1 || echo 0)")
	touch "$state/.purged"
	result=$(printf '%s' "$outcome" | cut -f1)
	posed=$(printf '%s' "$outcome" | cut -f2)
	elapsed=$(printf '%s' "$outcome" | cut -f3)
	model=$(printf '%s' "$outcome" | cut -f4)
	if [ "$result" = "unsupported" ]
	then
		say "この Mac は Object Capture に対応していません（measure-poses が result=unsupported）"
		exit 3
	fi

	# ML モデルキャッシュの故障なら、消して 1 度だけやり直す。
	if [ "$result" != "ok" ] && is_model_cache_failure "$round_dir/poses-$label.log"
	then
		say "  !! ML モデルキャッシュの故障の印が出ました。消してやり直します（設計 §6.2.4）"
		outcome=$(run_object_capture "$label" "$list" "$round_dir/poses-$label.retry.log" 1)
		result=$(printf '%s' "$outcome" | cut -f1)
		posed=$(printf '%s' "$outcome" | cut -f2)
		elapsed=$(printf '%s' "$outcome" | cut -f3)
		model=$(printf '%s' "$outcome" | cut -f4)
	fi

	say "  結果: ${result}（姿勢 $posed 枚・${elapsed}s・モデル ${model}）"
	printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n' \
		"$round" "$label" "window" "$choice" "$photos_count" "$connected" "$kcorecomp" \
		"$medsupport" "$conductance" "$choice_rank" "$result" "$posed" "$elapsed" "$print" \
		"$model" >> "$LEDGER"

	gained="$posed"

	# --- 落ちた窓は「はぐれ抜きの芯」で試し直す（設計 §3.6 の梯子・§6.2.3）---
	#
	# 芯は「1 回の再構成で繋がるはず」と言い切れる唯一の集合なので、
	# **落ちた原因がはぐれなのか中身そのものなのか**を往復せずに切り分けられる。
	if [ "$result" != "ok" ] && [ "$ladder" = 1 ] && [ -f "$windows/core/$choice" ]
	then
		core_label="$label-core"
		core_list="$state/attempts/$core_label.txt"
		cp "$windows/core/$choice" "$core_list"
		sort "$core_list" > "$state/attempts/$core_label.sorted"
		core_print=$(fingerprint "$core_list")
		say "  → 落ちたので、はぐれを外した芯で試し直します（$(awk 'END { print NR }' "$core_list") 枚）"
		outcome=$(run_object_capture "$core_label" "$core_list" \
			"$round_dir/poses-$core_label.log" 0)
		core_result=$(printf '%s' "$outcome" | cut -f1)
		core_posed=$(printf '%s' "$outcome" | cut -f2)
		core_elapsed=$(printf '%s' "$outcome" | cut -f3)
		core_model=$(printf '%s' "$outcome" | cut -f4)
		say "  芯の結果: ${core_result}（姿勢 $core_posed 枚・${core_elapsed}s・モデル ${core_model}）"
		printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n' \
			"$round" "$core_label" "core" "$choice" "$(awk 'END { print NR }' "$core_list")" \
			"$connected" "$kcorecomp" "$medsupport" "$conductance" "$choice_rank" \
			"$core_result" "$core_posed" "$core_elapsed" "$core_print" "$core_model" >> "$LEDGER"
		gained=$(( gained + core_posed ))
	fi

	if [ "$gained" -gt 0 ]
	then
		reuse_previous=0
	else
		# 何も学べなかった巡。グラフは変わらないので窓も変わらない。
		reuse_previous=1
	fi
	previous_windows="$windows"
	round=$(( round + 1 ))
done

say ""
say "=== 試行終了（${stop_reason}）$(date '+%Y-%m-%d %H:%M:%S') ==="
summarize | tee -a "$LOG"
