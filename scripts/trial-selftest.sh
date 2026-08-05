#!/usr/bin/env bash
#
# trial-selftest.sh — trial-clustering.sh の**流れだけ**を GPU 無しで確かめる。
#
# 実機の 1 巡は数十分かかるので、制御の流れ（窓を作る → 最良の窓を選ぶ →
# 投げる → 姿勢を反映して作り直す → 同じ窓は二度投げない → 続きから再開できる）
# を合成写真と身代わり（trial-fake-poses.sh）で先に固めておく。
#
# **確かめられるのは流れだけで、仕分けの精度ではない**（設計メモ §4.8 と同じ
# 但し書き。合成画像は平らな矩形の集まりなので、実写真の分布とは違う）。
#
#   ./scripts/trial-selftest.sh [作業フォルダ]
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

contains()
{
	grep -q "$2" "$1"
}

rows()
{
	awk -F'\t' 'NR>1' "$1" | wc -l | tr -d ' '
}

echo "作業フォルダ: $work"

# --- 合成写真（EXIF つき・2 部屋 48 枚）---
if [ ! -d "$work/photos" ]
then
	swift "$SCRIPT_DIR/make-sort-samples.swift" "$work/photos" > "$work/samples.log" 2>&1
fi
echo "写真 $(ls -1 "$work/photos" | wc -l | tr -d ' ') 枚"

# **1 回だけビルドして使い回す。** 作業フォルダを分けて何度も回すので、
# 素直に任せると同じものを 4 回コンパイルすることになる。
if [ ! -x "$work/bin/measure-ordering" ]
then
	mkdir -p "$work/bin"
	swiftc -O "$SCRIPT_DIR/measure-ordering.swift" -o "$work/bin/measure-ordering"
fi

run_trial()
{
	"$SCRIPT_DIR/trial-clustering.sh" "$work/photos" \
		--state "$1" \
		--capacity "${CAPACITY:-12}" \
		--neighbours "${NEIGHBOURS:-16}" \
		--rounds "$2" \
		--drop-blurriest 0 \
		--ordering-cmd "$work/bin/measure-ordering" \
		--poses-cmd "$SCRIPT_DIR/trial-fake-poses.sh"
}

# --- 1. すべて通る場合: 巡が進み、窓が毎巡作り直されること ---
state="$work/all-ok"
run_trial "$state" 2 > "$work/run1.log" 2>&1 || { cat "$work/run1.log"; exit 1; }

check "窓の指標（windows.tsv）が書き出される" \
	test -s "$state/rounds/001/windows/windows.tsv"
check "1 巡目に窓を投げた" test "$(rows "$state/ledger.tsv")" -ge 1
check "投げた窓の一覧を残している" test -s "$state/attempts/r001-window-01.txt"

# **合成写真の共視グラフが 1 つの窓しか作れないことがある。** 合成画像は平らな
# 矩形の集まりで、feature print から見ればどれも似たようなもの（設計 §4.8）。
# そのときに確かめられるのは「収束して止まる」ことのほうなので、確かめる先を
# 分ける。**どちらを確かめたかは必ず出す**（黙って何も確かめない自己診断が
# いちばん質が悪い）。
window_count=$(awk -F'\t' '!/^#/ && NF >= 15' "$state/rounds/001/windows/windows.tsv" | wc -l | tr -d ' ')
echo "1 巡目の窓: $window_count 個"

if [ "$window_count" -ge 2 ]
then
	check "2 巡目まで回った" test "$(rows "$state/ledger.tsv")" -eq 2
	check "2 巡目は姿勢を反映してグラフを直している" \
		contains "$state/rounds/002/ordering.log" "OC の結果を反映"
	check "見比べられた辺の分母を出している" \
		contains "$state/rounds/002/ordering.log" "見比べられた辺"
	check "姿勢が累積している" \
		test "$(ls -1 "$state"/poses/*.poses.tsv | wc -l | tr -d ' ')" -eq 2
	check "視覚特徴のキャッシュが効いている" \
		contains "$state/rounds/002/ordering.log" "視覚特徴のキャッシュ: 再利用"
else
	echo "（窓が 1 個しか作れなかったので、収束して止まることのほうを確かめます）"
	check "同じ窓しか無ければ収束して止まる" contains "$work/run1.log" "ここが収束"
	check "2 巡目も姿勢を反映してグラフを直している" \
		contains "$state/rounds/002/ordering.log" "OC の結果を反映"
	check "視覚特徴のキャッシュが効いている" \
		contains "$state/rounds/002/ordering.log" "視覚特徴のキャッシュ: 再利用"
fi

# 同じ窓を二度投げていないこと（指紋が重複しない）。
duplicates=$(awk -F'\t' 'NR>1 { seen[$14]++ } END { for (key in seen) { if (seen[key] > 1) { n++ } } print n + 0 }' \
	"$state/ledger.tsv")
check "同じ中身の窓を二度投げていない" test "$duplicates" -eq 0

# --- 2. 続きから再開できること ---
before=$(rows "$state/ledger.tsv")
run_trial "$state" 4 > "$work/run2.log" 2>&1 || { cat "$work/run2.log"; exit 1; }
after=$(rows "$state/ledger.tsv")
if [ "$window_count" -ge 2 ]
then
	check "同じ --state で続きから始まる" test "$after" -gt "$before"
else
	# 収束していれば台帳は増えない。**続きから始まったこと自体**は巡の
	# フォルダが増えたかで見る。
	check "同じ --state で続きから始まる" test -d "$state/rounds/003"
fi
check "巡のフォルダが増えている" test -d "$state/rounds/003"

# --- 3. 集計が出ること ---
"$SCRIPT_DIR/trial-clustering.sh" --state "$state" --summary > "$work/summary.log" 2>&1
check "集計に機械可読の 1 行が出る" contains "$work/summary.log" "^result=summary"
check "内部指標と成否を並べている" contains "$work/summary.log" "内部指標は成否を予言したか"

# --- 4. 落ちた巡は窓を作り直さないこと（辺が 1 本も変わらないので同じ窓が出る）---
state="$work/first-fails"
export FAKE_FAIL="r001"
run_trial "$state" 2 > "$work/run3.log" 2>&1 || { cat "$work/run3.log"; exit 1; }
unset FAKE_FAIL
check "落ちた次の巡は窓を作り直さない" test -f "$state/rounds/002/reused-from"
check "落ちた窓も台帳に残る" contains "$state/ledger.tsv" "fake failure"
if [ -f "$state/rounds/001/windows/core/window-01.txt" ]
then
	# 芯（はぐれ抜き）があるなら、落ちた窓はそれで試し直されているはず。
	check "落ちた窓は芯で試し直す" \
		awk -F'\t' 'NR>1 && $3 == "core" { found = 1 } END { exit found ? 0 : 1 }' \
		"$state/ledger.tsv"
fi

# --- 5. --plan-only は Object Capture を動かさないこと ---
state="$work/plan-only"
"$SCRIPT_DIR/trial-clustering.sh" "$work/photos" --state "$state" --capacity 16 \
	--neighbours 6 --plan-only --ordering-cmd "$work/bin/measure-ordering" \
	> "$work/run4.log" 2>&1
check "--plan-only は順位だけ出す" contains "$work/run4.log" "内部指標の順位"
check "--plan-only は窓を投げない" test -z "$(ls -A "$state/poses")"
check "--plan-only の台帳は空" test "$(rows "$state/ledger.tsv")" -eq 0

echo ""
if [ "$failures" = 0 ]
then
	echo "result=ok 失敗 0 件"
else
	echo "result=failure 失敗 $failures 件"
	exit 1
fi
