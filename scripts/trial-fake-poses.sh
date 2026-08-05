#!/usr/bin/env bash
#
# trial-fake-poses.sh — **measure-poses の身代わり**（自己診断専用）。
#
# trial-clustering.sh の反復（窓を作る → 投げる → 姿勢を反映 → 作り直す）は
# 実機で 1 巡が数十分かかる。その**制御の流れだけ**を GPU も Object Capture も
# 無しで確かめられるように、measure-poses と同じ引数を受けて同じ書式で答える
# 身代わりを置いてある（scripts/trial-selftest.sh が使う）。
#
# **これは測定の道具ではない。** ここが返す姿勢に意味は無く、確かめられるのは
# 「反復が回るか」「同じ窓を二度投げないか」「落ちた巡に窓を作り直さないか」
# だけ。実データの答えは実機の measure-poses からしか出ない。
#
#   FAKE_FAIL="r001"  … ラベルにこの文字列を含む窓は「落ちた」ことにする
#
set -euo pipefail

window=""
out=""
models=""
while [ $# -gt 0 ]
do
	case "$1" in
		--window-file) window="$2"; shift 2 ;;
		--poses-out) out="$2"; shift 2 ;;
		--models-out) models="$2"; shift 2 ;;
		--purge-model-cache|--download|--list) shift ;;
		--ordering|--sensitivity|--detail|--subject|--drop-blurriest|--timeout|--window-dir)
			shift 2 ;;
		*) shift ;;
	esac
done

if [ -z "$window" ] || [ -z "$out" ]
then
	echo "使い方: trial-fake-poses.sh <写真フォルダ> --window-file F --poses-out D" >&2
	exit 2
fi

label="$(basename "$window")"
label="${label%.txt}"
mkdir -p "$out"

fail=0
if [ -n "${FAKE_FAIL:-}" ]
then
	case "$label" in
		*${FAKE_FAIL}*) fail=1 ;;
	esac
fi

# **投げた写真すべてを台帳にする**（measure-poses と同じ）。姿勢の付かなかった
# 行が無いと、trial-clustering.sh 側の --feedback が反証を学べない。
{
	printf '# path\tposed\tx\ty\tz\n'
	index=0
	while IFS= read -r path
	do
		[ -n "$path" ] || continue
		# 5 枚に 1 枚は「同じ窓に入れたのに繋がらなかった」ことにする
		# （辺の除去＝反証の経路を通すため）。落ちた窓は 1 枚も付けない。
		if [ "$fail" = 0 ] && [ $(( index % 5 )) != 4 ]
		then
			printf '%s\t1\t%d.0\t0.0\t0.0\n' "$path" "$index"
		else
			printf '%s\t0\t\t\t\n' "$path"
		fi
		index=$(( index + 1 ))
	done < "$window"
} > "$out/$label.poses.tsv"

posed=$(awk -F'\t' '$2 == 1' "$out/$label.poses.tsv" | wc -l | tr -d ' ')

# 3D モデルの身代わり。**中身に意味は無い**（本物は Object Capture が書く）。
# 確かめられるのは「trial-clustering.sh が --models-out を渡し、出来たモデルを
# 台帳に記録するか」だけ。
model="-"
if [ -n "$models" ] && [ "$fail" = 0 ]
then
	mkdir -p "$models"
	printf 'fake usdz for %s\n' "$label" > "$models/$label.usdz"
	model="$label.usdz"
fi

if [ "$fail" = 1 ]
then
	printf 'window name=%s.txt mode=poses ordering=sequential sensitivity=high elapsed=1.0 posed=0 skipped=0 invalid=0 dropped=0 peak=0.1GB stages=- model=%s result=error: fake failure\n' "$label" "$model"
else
	printf 'window name=%s.txt mode=poses ordering=sequential sensitivity=high elapsed=1.0 posed=%s skipped=0 invalid=0 dropped=0 peak=0.1GB stages=- model=%s result=ok\n' "$label" "$posed" "$model"
fi
printf 'done\n'
