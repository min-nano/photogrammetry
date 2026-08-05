#!/usr/bin/env bash
#
# truth-selftest.sh — measure-truth.swift の**流れと算数**を GPU 無しで確かめる。
#
# 実写真で 1 時間かけて作った正解を、道具の側の誤りで台無しにしたくない。
# `trial-clustering.sh` は実データを通す過程で「黙って嘘をつく」誤りを 4 つ
# 踏んでおり（docs/design-loose-clustering.md §10）、**測定の道具が間違っている
# ことがいちばん高くつく**というのがそこでの学びだった。だからこの道具は、
# 人が写真を触り始める前に、合成写真で一通り通しておく。
#
# 確かめるのは次の 3 つ。
#
#   1. 流れ    下書き → 手で動かす → 読み戻す → 採点、が最後まで通ること
#   2. 同一性  正解フォルダで名前を変えても、元の写真へ正しく戻ること
#   3. 算数    **正しい正解と、でたらめな正解で、成績が実際に変わること**
#
# 3 が要点で、AUC・被覆率・分断の判定が「常に同じ数字を返すだけの飾り」に
# なっていないことを、期待する向きに変わるかどうかで押さえる。
#
#   ./scripts/truth-selftest.sh [作業フォルダ]
#
# macOS が要る（Vision / ImageIO）。CI では ci-debug の mode=shell から呼ぶ。
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="${1:-$(mktemp -d)}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"

failures=0
check()
{
	local label="$1"
	shift
	if "$@"
	then
		printf 'ok    %s\n' "$label"
	else
		printf 'FAIL  %s\n' "$label"
		failures=$(( failures + 1 ))
	fi
}

# metrics.tsv から指標 1 つの AUC を取り出す。
auc_of()
{
	awk -F'\t' -v name="$2" '$1 == name { print $4; exit }' "$1"
}

# 「A が B 以上か」を小数で比べる（bash に小数の比較が無いので awk に出す）。
at_least()
{
	awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && a + 0 >= b + 0) }'
}

at_most()
{
	awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && a + 0 <= b + 0) }'
}

echo "作業フォルダ: $work"

# --- 合成写真（EXIF つき・2 部屋 48 枚。前半 24 枚が部屋 A・後半 24 枚が部屋 B）---
#
# **この 2 部屋が「正解」として分かっている**ことが、この自己診断の土台になる。
if [ ! -d "$work/photos" ]
then
	swift "$SCRIPT_DIR/make-sort-samples.swift" "$work/photos" > "$work/samples.log" 2>&1
fi
photos=$(ls -1 "$work/photos" | wc -l | tr -d ' ')
echo "写真 $photos 枚"

if [ ! -x "$work/bin/measure-truth" ]
then
	mkdir -p "$work/bin"
	swiftc -O "$SCRIPT_DIR/measure-truth.swift" -o "$work/bin/measure-truth"
fi
BIN="$work/bin/measure-truth"

truth="$work/truth"
out="$work/truth-analysis"

# --- 1. 下書き ---
"$BIN" "$work/photos" --truth "$truth" --draft 24 --out "$out" > "$work/draft.log" 2>&1
check "下書きが 2 フォルダできる" test "$(ls -1d "$truth"/0* | wc -l | tr -d ' ')" -eq 2
check "写真が全部置かれる" test "$(find "$truth" -iname '*.jpg' -not -path '*_sheets*' | wc -l | tr -d ' ')" -eq "$photos"
# ハードリンクなので、原本と inode が一致する（＝ディスクも増えない）。
first_link="$(find "$truth/001" -iname '*.jpg' | sort | head -1)"
original="$work/photos/$(basename "$first_link" | sed 's/^[0-9]*_//')"
check "ハードリンクになっている" test "$(stat -f %i "$first_link")" = "$(stat -f %i "$original")"
check "接触シートができる" test -f "$truth/_sheets/index.html"
check "撮影順のシートができる" test -f "$truth/_sheets/sequence.html"

# --- 2. 人の作業の代わり（フォルダに名前を付ける・1 枚を除外する・1 枚を両方へ） ---
mv "$truth/001" "$truth/001-部屋A"
mv "$truth/002" "$truth/002-部屋B"
mkdir -p "$truth/_除外"
excluded="$(find "$truth/001-部屋A" -iname '*.jpg' | sort | tail -1)"
mv "$excluded" "$truth/_除外/"
# 戸口の写真のつもりで、部屋 A の 1 枚を部屋 B にも置く（**被覆なので正しい状態**）。
shared="$(find "$truth/001-部屋A" -iname '*.jpg' | sort | tail -1)"
ln "$shared" "$truth/002-部屋B/$(basename "$shared")"
# 名前を変えても inode で戻れること（人はフォルダの中で名前を整えることがある）。
renamed="$(find "$truth/002-部屋B" -iname '*.jpg' | sort | head -1)"
mv "$renamed" "$(dirname "$renamed")/かべ-01.jpg"

"$BIN" "$work/photos" --truth "$truth" --out "$out" --read > "$work/read.log" 2>&1
check "truth.tsv ができる" test -f "$out/truth.tsv"
check "元の写真へ辿れないファイルが無い" bash -c "! grep -q '辿れなかった' '$work/read.log'"
check "除外が 1 枚" bash -c "awk -F'\t' '\$3 == \"_除外\"' '$out/truth.tsv' | wc -l | tr -d ' ' | grep -qx 1"
check "両方のラベルに入る写真がある" bash -c "grep -q '部屋A|部屋B' '$out/truth.tsv'"
check "未仕分けが無い" bash -c "! grep -q '_未仕分け' '$out/truth.tsv'"
check "Object Capture へ投げる一覧ができる" test "$(ls -1 "$out/truth-windows" | wc -l | tr -d ' ')" -eq 2

# --- 3. 算数（正しい正解での成績） ---
"$BIN" "$work/photos" --truth "$truth" --out "$out" --analyze > "$work/analyze.log" 2>&1
check "指標の表が出る" grep -q "指標の分離能" "$work/analyze.log"
check "近傍の質が出る" grep -q "近傍の質" "$work/analyze.log"
check "共視グラフの辺が出る" grep -q "共視グラフの辺" "$work/analyze.log"
check "撮影順の検証が出る" grep -q "撮影順は場所の証拠か" "$work/analyze.log"
check "metrics.tsv ができる" test -f "$out/metrics.tsv"
check "confusion.tsv ができる" test -f "$out/confusion.tsv"
check "metrics.tsv に写真の名前が入っていない" bash -c "! grep -q 'IMG_' '$out/metrics.tsv'"

# **撮影順の隔たり**は、正解が撮影順に連続した 2 塊である以上、ほぼ完全に
# 分離できるはず（AUC ≒ 1）。ここは画像の中身に依らず、算数だけで決まる。
good="$(auc_of "$out/metrics.tsv" "撮影順の隔たり")"
echo "  正しい正解での AUC（撮影順の隔たり）: $good"
check "正しい正解なら AUC が高い" at_least "$good" 0.9

# --- 4. 算数（でたらめな正解での成績） ---
#
# **同じ道具・同じ写真で、ラベルだけを混ぜる。** 成績が落ちなければ、その指標は
# 何も測っていないことになる（道具が飾りになっていないことの確認）。
shuffled="$work/truth-shuffled"
rm -rf "$shuffled"
mkdir -p "$shuffled/001-混ぜたA" "$shuffled/002-混ぜたB"
index=0
for file in $(find "$work/photos" -iname '*.jpg' | sort)
do
	if [ $(( index % 2 )) -eq 0 ]
	then
		ln "$file" "$shuffled/001-混ぜたA/$(basename "$file")"
	else
		ln "$file" "$shuffled/002-混ぜたB/$(basename "$file")"
	fi
	index=$(( index + 1 ))
done
"$BIN" "$work/photos" --truth "$shuffled" --out "$work/out-shuffled" --analyze \
	> "$work/analyze-shuffled.log" 2>&1
bad="$(auc_of "$work/out-shuffled/metrics.tsv" "撮影順の隔たり")"
echo "  でたらめな正解での AUC（撮影順の隔たり）: $bad"
check "でたらめな正解なら AUC が落ちる" at_most "$bad" 0.7

# --- 5. 窓の採点 ---
#
# 正解とぴったり同じ窓・正解を割った窓の 2 つを作って、**被覆率が期待どおり
# 動くか**を見る。分断（設計 §1.2 でいちばん高い代償）を見逃さないこと。
windows="$work/windows-perfect"
mkdir -p "$windows"
awk -F'\t' '$3 ~ /部屋A/ { print $2 }' "$out/truth.tsv" \
	| sed "s|^|$work/photos/|" > "$windows/window-01.txt"
awk -F'\t' '$3 ~ /部屋B/ { print $2 }' "$out/truth.tsv" \
	| sed "s|^|$work/photos/|" > "$windows/window-02.txt"
"$BIN" "$work/photos" --truth "$truth" --out "$out" --score "$windows" \
	> "$work/score-perfect.log" 2>&1
check "ぴったりの窓なら分断が無い" grep -q "分断されたラベルはありません" "$work/score-perfect.log"

split="$work/windows-split"
mkdir -p "$split"
awk -F'\t' '$3 ~ /部屋A/ { print $2 }' "$out/truth.tsv" | sed "s|^|$work/photos/|" \
	> "$split/all-a.txt"
head -12 "$split/all-a.txt" > "$split/window-01.txt"
tail -n +13 "$split/all-a.txt" > "$split/window-02.txt"
rm "$split/all-a.txt"
awk -F'\t' '$3 ~ /部屋B/ { print $2 }' "$out/truth.tsv" | sed "s|^|$work/photos/|" \
	> "$split/window-03.txt"
"$BIN" "$work/photos" --truth "$truth" --out "$out" --score "$split" \
	> "$work/score-split.log" 2>&1
check "割られた窓なら分断が出る" grep -q "分断されたラベル: " "$work/score-split.log"
check "採点の機械可読が残る" bash -c "ls '$out'/score-*.tsv > /dev/null"

# --- 6. 見直しの候補 ---
"$BIN" "$work/photos" --truth "$truth" --out "$out" --hints > "$work/hints.log" 2>&1
check "見直しの候補が出る" grep -q "見直しの候補" "$work/hints.log"
check "循環への注意が必ず出る" grep -q "循環に注意" "$work/hints.log"
check "hints.tsv ができる" test -f "$out/hints.tsv"

# --- 7. 作り直しの歯止め ---
if "$BIN" "$work/photos" --truth "$truth" --out "$out" --draft 24 > "$work/redraft.log" 2>&1
then
	echo "FAIL  --force 無しで下書きを作り直せてしまう"
	failures=$(( failures + 1 ))
else
	echo "ok    --force 無しでは手の入った正解を壊さない"
fi

echo ""
if [ "$failures" -eq 0 ]
then
	echo "すべて通りました"
else
	echo "$failures 件失敗しました"
	exit 1
fi
