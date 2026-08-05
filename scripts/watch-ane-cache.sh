#!/usr/bin/env bash
#
# watch-ane-cache.sh
#
# **ANE モデルキャッシュが壊れる瞬間を押さえる**ための見張り。生成や測定の
# 裏で流しっぱなしにしておく（`trial-ane-memory.sh` と同時に回してよい。
# こちらは読むだけで、何も消さない・何も起動しない）。
#
# なぜ要るか:
#   `ModelCache` が名指ししている故障は「コンパイル済みバンドルが**manifest.plist
#   の無い不完全な状態**で残る」ことである。つまり**壊れた瞬間が必ず存在する**。
#   E5RT の行はその後の実行で出るので、ログを後から読んでも「いつ壊れたか」
#   「そのとき何が動いていたか」は分からない。ここを取れないと、原因の候補
#   （メモリ・中断・同時実行・他プロセスの ANE 占有・ディスク）を切り分けようが
#   ない。1 秒ごとに見ているだけの安い道具だが、これが唯一の目撃者になる。
#
# 使い方:
#   scripts/watch-ane-cache.sh                       # 既定のキャッシュを全部見る
#   scripts/watch-ane-cache.sh --interval 2 --out ~/ane-watch.tsv
#   scripts/watch-ane-cache.sh --cache ~/Library/Caches/foo/com.apple.e5rt.e5bundlecache
#
# 画面には**状態が変わったときだけ**出る（不完全なバンドルの出現・消滅、
# コンパイラの起動・終了、ディスクやメモリの谷）。全標本は --out の TSV に残る。
#
# オプション:
#   --interval SEC  標本の間隔（既定 3 秒）
#   --out FILE      TSV の書き出し先（既定 ~/ane-watch-<日時>.tsv）
#   --cache DIR     見るキャッシュ（複数指定可。既定は下記 2 つ + 見つけたもの）
#   --once          1 回だけ見て終わる（いまの状態を確かめたいとき）
#
# 既定で見る場所:
#   ~/Library/Caches/com.minnano.photogrammetry/com.apple.e5rt.e5bundlecache  ← アプリ
#   ~/Library/Caches/measure-ane/com.apple.e5rt.e5bundlecache                 ← 測定
#   ~/Library/Caches/*/com.apple.e5rt.e5bundlecache                           ← その他
#

# **`set -e` を付けない。** これは何時間も流しっぱなしにする見張りで、
# 途中の `ps` や `df` が 1 回失敗したくらいで死んではいけない
# （黙って死ぬと、肝心の瞬間に誰も見ていないことになる）。
set -u

INTERVAL=3
OUT=""
ONCE=0
CACHES=""

while [ $# -gt 0 ]; do
	case "$1" in
		--interval) INTERVAL="${2:-3}"; shift 2 ;;
		--out) OUT="${2:-}"; shift 2 ;;
		--cache) CACHES="$CACHES ${2:-}"; shift 2 ;;
		--once) ONCE=1; shift ;;
		-h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "不明な引数: $1" >&2; exit 2 ;;
	esac
done

[ "$(uname -s)" = "Darwin" ] || { echo "macOS 専用です" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$HOME/ane-watch-$(date +%Y%m%d-%H%M%S).tsv"

# 見る場所を決める。指定が無ければ、既知の 2 つに加えて**実際に存在するものを
# 全部**拾う（プロセス名でキャッシュが切られるので、CLI・GUI・測定用の実行体が
# それぞれ別の場所を持つ。どれが壊れたかは事前には分からない）。
if [ -z "$CACHES" ]; then
	CACHES="$HOME/Library/Caches/com.minnano.photogrammetry/com.apple.e5rt.e5bundlecache"
	CACHES="$CACHES $HOME/Library/Caches/measure-ane/com.apple.e5rt.e5bundlecache"
	for found in "$HOME"/Library/Caches/*/com.apple.e5rt.e5bundlecache; do
		case " $CACHES " in
			*" $found "*) ;;
			*) [ -d "$found" ] && CACHES="$CACHES $found" ;;
		esac
	done
fi

echo "見張り開始: $(date '+%Y-%m-%d %H:%M:%S')"
echo "間隔: ${INTERVAL}s / 記録: $OUT"
echo "見るキャッシュ:"
for c in $CACHES; do
	echo "  $c$([ -d "$c" ] || echo '  （いまは無い）')"
done
echo ""
echo "状態が変わったときだけ画面に出ます（Ctrl-C で終了）。"
echo ""

if [ ! -f "$OUT" ]; then
	printf 'time\tcache\tbundles\tincomplete\tsize_kb\tcompiler\taned_cpu\tanalysis_cpu\toc_procs\tfree_disk_mb\tfree_mem_mb\tswap_mb\tpressure\n' > "$OUT"
fi

# ---------------------------------------------------------------------------
# 1 つのキャッシュの状態
# ---------------------------------------------------------------------------
#
# 不完全なバンドル = 直下のディレクトリのうち、その下に manifest.plist が
# 見つからないもの。**これが 1 個でも現れた瞬間が「壊れた瞬間」**で、以降その
# 実行体は毎回同じところで落ちる（ModelCache のコメント参照）。

inspect_cache() {
	local dir="$1" bundles=0 incomplete=0 size=0 sub
	if [ ! -d "$dir" ]; then
		echo "0	0	0"
		return
	fi
	for sub in "$dir"/*; do
		[ -d "$sub" ] || continue
		bundles=$(( bundles + 1 ))
		if [ -z "$(find "$sub" -maxdepth 3 -name manifest.plist -print -quit 2>/dev/null)" ]; then
			incomplete=$(( incomplete + 1 ))
		fi
	done
	size="$( { du -sk "$dir" 2>/dev/null || true; } | awk '{print $1}')"
	[ -n "$size" ] || size=0
	echo "$bundles	$incomplete	$size"
}

# ---------------------------------------------------------------------------
# 周りで何が起きているか
# ---------------------------------------------------------------------------
#
# ANECompilerService は**まさに ANE モデルをコンパイルしている XPC サービス**で、
# これが動いている間だけコンパイルは走っている。落ちる瞬間に何が同席していたかを
# 言うには、ここを見ているのがいちばん近い。
#
# mediaanalysisd / photoanalysisd は写真ライブラリの解析で **ANE を長時間占有する**
# 常連。手が空くと勝手に走り出すので、「同じ操作なのに出たり出なかったりする」の
# 説明になりうる。CPU 使用率の合計を 1 列にまとめて持つ。

probe_processes() {
	local snapshot compiler aned analysis oc
	snapshot="$(ps -Ao pcpu,comm 2>/dev/null || true)"
	compiler="$(echo "$snapshot" | grep -c 'ANECompilerService' || true)"
	aned="$(echo "$snapshot" | awk '/aned$/ {sum += $1} END {printf "%.1f", sum + 0}')"
	analysis="$(echo "$snapshot" \
		| awk '/mediaanalysisd|photoanalysisd|photolibraryd/ {sum += $1} END {printf "%.1f", sum + 0}')"
	# **同じキャッシュを使う実行体が 2 つ以上同時に動いていないか。**
	# 同時に走れば同じバンドルへ同時に書きうる（壊れ方として真っ先に疑う筋）。
	oc="$(echo "$snapshot" | grep -cE 'measure-ane|measure-poses|photogrammetry-cli|Photogrammetry$' || true)"
	echo "$compiler	$aned	$analysis	$oc"
}

probe_system() {
	local page free swap level disk
	page="$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)"
	free="$(vm_stat 2>/dev/null | awk -v ps="$page" '
		/Pages free/ { gsub(/\./, "", $3); f = $3 }
		/Pages speculative/ { gsub(/\./, "", $3); s = $3 }
		END { printf "%.0f", (f + s) * ps / 1048576 }')"
	swap="$(sysctl -n vm.swapusage 2>/dev/null | awk '{gsub(/M/, "", $6); printf "%.0f", $6 + 0}')"
	level="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0)"
	disk="$(df -m "$HOME/Library/Caches" 2>/dev/null | awk 'NR==2 {print $4}')"
	echo "${free:-0}	${swap:-0}	${level:-0}	${disk:-0}"
}

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

say_event() { echo "[$(date '+%H:%M:%S')] $*"; }

# 直前の状態（キャッシュごと）。bash 3.2 なので連想配列は使わず、
# 「パス<TAB>状態」の 1 行文字列を持ち回る。
PREVIOUS=""

previous_state_of() {
	echo "$PREVIOUS" | awk -F'\t' -v key="$1" '$1 == key { print $2 }'
}

first_pass=1
compiler_was=0

while :; do
	stamp="$(date '+%Y-%m-%dT%H:%M:%S')"
	processes="$(probe_processes)"
	system="$(probe_system)"
	compiler="$(echo "$processes" | cut -f1)"
	free_mem="$(echo "$system" | cut -f1)"
	swap="$(echo "$system" | cut -f2)"
	pressure="$(echo "$system" | cut -f3)"
	free_disk="$(echo "$system" | cut -f4)"

	current=""
	for cache in $CACHES; do
		state="$(inspect_cache "$cache")"
		bundles="$(echo "$state" | cut -f1)"
		incomplete="$(echo "$state" | cut -f2)"
		size="$(echo "$state" | cut -f3)"

		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$stamp" "$cache" "$bundles" "$incomplete" "$size" \
			"$processes" "$free_disk" "$free_mem" "$swap" "$pressure" >> "$OUT"

		before="$(previous_state_of "$cache")"
		now="$bundles/$incomplete"
		if [ "$first_pass" = 1 ]; then
			say_event "初期状態 $(basename "$(dirname "$cache")"): バンドル $bundles 個・不完全 $incomplete 個"
		elif [ "$before" != "$now" ]; then
			say_event "変化 $(basename "$(dirname "$cache")"): バンドル $bundles 個・不完全 $incomplete 個"
			# **ここが目撃の瞬間。** 周りの状況を一緒に出す（後から TSV を
			# 突き合わせなくても、画面を見ていれば分かるように）。
			if [ "$incomplete" -gt 0 ]; then
				case "$before" in
					*"/0") say_event "  !! 不完全なバンドルが現れました。ここが壊れた瞬間です" ;;
				esac
				say_event "  コンパイラ=$compiler 空きメモリ=${free_mem}MB スワップ=${swap}MB "\
"圧=$pressure 空きディスク=${free_disk}MB"
				say_event "  同時に動いている生成/測定プロセス=$(echo "$processes" | cut -f4) "\
"写真解析の CPU=$(echo "$processes" | cut -f3)%"
				find "$cache" -maxdepth 3 -type d 2>/dev/null \
					| while read -r sub
					do
						[ "$sub" = "$cache" ] && continue
						if [ -z "$(find "$sub" -maxdepth 2 -name manifest.plist -print -quit 2>/dev/null)" ]; then
							say_event "  不完全: ${sub#"$cache"/}"
						fi
					done
			fi
		fi
		current="$current$cache	$now
"
	done
	PREVIOUS="$current"

	# コンパイラの起動・終了も出す（どの操作のときにコンパイルが走るのかが
	# 分かると、「枚数」ではなく「設定の組み合わせ」が引き金かどうかを言える）。
	if [ "$compiler" != "$compiler_was" ]; then
		if [ "$compiler" -gt 0 ]; then
			say_event "ANECompilerService が動き出しました（コンパイル中）"
		else
			say_event "ANECompilerService が終わりました"
		fi
		compiler_was="$compiler"
	fi

	first_pass=0
	[ "$ONCE" = 1 ] && break
	sleep "$INTERVAL"
done

echo ""
echo "記録: $OUT"
