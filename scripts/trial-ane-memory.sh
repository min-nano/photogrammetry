#!/usr/bin/env bash
#
# trial-ane-memory.sh
#
# **「ANE モデルのコンパイル失敗はメモリ不足で起きているのか」を実機で確かめる**
# ための試行スクリプト。Object Capture が動く Mac の手元で回す。
#
#   E5RT encountered an STL exception. msg = MILCompilerForANE error:
#   failed to compile ANE model using ANEF. Error=_ANECompiler : ANECCompile() FAILED.
#
# アプリ本体はこれを「キャッシュを消して作り直す」で回避している（ModelCache）。
# それは対処であって原因ではない。原因の候補は「Xcode が古い」「OS / デバイスと
# 合っていない」「メモリ不足」の 3 つで、前 2 つは CI とビルド設定を見れば分かる
# （docs/investigate-ane-compile-failure.md）。**手元で振れる変数を持つのは
# メモリだけ**なので、それをこのスクリプトで測る。
#
# ---------------------------------------------------------------------------
# 測り方（なぜこの形なのか）
# ---------------------------------------------------------------------------
#
# 1. **試行ごとに ANE キャッシュを消す。** ここが一番大事で、消さないと
#    測定そのものが成立しない。ANE 用モデルのコンパイルは**キャッシュが空の
#    ときにしか走らない**（一度成功すると以降の実行は読むだけ）。素朴に枚数を
#    変えて回すと、コンパイルは 1 回目にしか走らず、2 回目以降の「成功」は
#    「コンパイルが成功した」ではなく「コンパイルしなかった」を意味する。
#    それを枚数の効果と読むと、**必ず「枚数を減らせば直る」という嘘の結論**に
#    なる（最初の 1 回が多い枚数なら、その逆の嘘になる）。
#
# 2. **枚数を往復させる**（多い → 少ない → 多い …）。同じ枚数を続けて回すと、
#    温度・他のアプリ・キャッシュの育ち方といった時間とともに動くものが枚数と
#    見分けられなくなる。巡ごとに全部の枚数を 1 回ずつ回す。
#
# 3. **失敗した瞬間の段階とメモリを記録する。** 「何枚で失敗したか」だけでは
#    メモリ説の裏は取れない。E5RT の行が出た時点の処理段階・そのプロセスの
#    フットプリント・システムの空き・スワップ・メモリ圧レベルまで残す。
#    imageAlignment の山の頂上で毎回出るならメモリ、前処理の最初で出るなら
#    メモリではない、と切り分けられる。
#
# 4. **逆向きの実験も用意する**（`--ballast`）。枚数を減らして失敗しなくなった、
#    は「メモリが原因」の証明にはならない（たまたま出なかっただけかもしれない）。
#    わざと空きを潰して**失敗を呼び出せるか**まで見て初めて確定する。
#    既定では使わない — 実際にマシンを圧迫するので、意図して指定したときだけ。
#
# ---------------------------------------------------------------------------
# 使い方
# ---------------------------------------------------------------------------
#
#   scripts/trial-ane-memory.sh ~/Pictures/現場
#   scripts/trial-ane-memory.sh ~/Pictures/現場 --counts 40,80,160,320 --repeats 3
#   scripts/trial-ane-memory.sh ~/Pictures/現場 --counts 160 --ballast 0,16   # 逆向き
#
# 途中で止めても、そこまでの結果は out ディレクトリに残る（1 試行ごとに追記
# している）。**一晩置く前提**の道具なので、まず `--counts 40 --repeats 1` で
# 一周させて、道具側が壊れていないことを確かめてから本番を回すとよい。
#
# オプション:
#   --out DIR        結果の置き場（既定 ~/ane-trial-<日時>）
#   --counts a,b,c   1 試行に投げる枚数（既定 40,80,160,320）
#   --repeats N      各条件を何巡するか（既定 3）
#   --start N        写真の何枚目から取るか（既定 0）
#   --mode poses|model  既定 poses（model はメッシュまで作るので山が数倍高い）
#   --ballast a,b    わざと確保しておくメモリ（GiB・既定 0）。**注意**の項参照
#   --timeout SEC    1 試行の上限（既定 1800）
#   --keep-cache     試行ごとの ANE キャッシュ削除をやめる（既定は毎回消す）。
#                    **測定としては意味を失う**ので、比較用にだけ使う
#   --stop-on-fail   最初の失敗で止める（原因を手で調べたいとき）
#   --dry-run        何を回すかだけ出して終わる
#
# 注意（--ballast）:
#   重しはシステム全体を圧迫する。他のアプリが落ちる・強制的にスワップする・
#   マシンが数分間張り付く、が実際に起きる。**作業中の Mac では使わない**こと。
#   重しの大きさは搭載メモリの半分までに自動で丸める。
#

set -euo pipefail

# ---------------------------------------------------------------------------
# 引数
# ---------------------------------------------------------------------------

PHOTOS=""
OUT=""
COUNTS="40,80,160,320"
REPEATS=3
START=0
MODE="poses"
BALLASTS="0"
TIMEOUT=1800
KEEP_CACHE=0
STOP_ON_FAIL=0
DRY_RUN=0

die() { echo "エラー: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT="${2:-}"; shift 2 ;;
		--counts) COUNTS="${2:-}"; shift 2 ;;
		--repeats) REPEATS="${2:-}"; shift 2 ;;
		--start) START="${2:-}"; shift 2 ;;
		--mode) MODE="${2:-}"; shift 2 ;;
		--ballast) BALLASTS="${2:-}"; shift 2 ;;
		--timeout) TIMEOUT="${2:-}"; shift 2 ;;
		--keep-cache) KEEP_CACHE=1; shift ;;
		--stop-on-fail) STOP_ON_FAIL=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) die "不明な引数: $1" ;;
		*)
			[ -z "$PHOTOS" ] || die "写真フォルダは 1 つだけ指定してください"
			PHOTOS="$1"; shift ;;
	esac
done

[ -n "$PHOTOS" ] || die "使い方: $0 <写真フォルダ> [オプション]"
[ -d "$PHOTOS" ] || die "写真フォルダがありません: $PHOTOS"
case "$MODE" in poses|model) ;; *) die "--mode は poses か model です: $MODE" ;; esac
[ "$(uname -s)" = "Darwin" ] || die "macOS でしか動きません（Object Capture が要ります）"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_SOURCE="$REPO_ROOT/scripts/measure-ane.swift"
[ -f "$HARNESS_SOURCE" ] || die "measure-ane.swift が見つかりません: $HARNESS_SOURCE"

[ -n "$OUT" ] || OUT="$HOME/ane-trial-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/logs"
TSV="$OUT/trials.tsv"
ENV_TXT="$OUT/env.txt"

# 実行体の名前は **measure-ane で固定**。ANE キャッシュの置き場がプロセス名で
# 切られるので、名前を変えると下で消す場所とずれる（消したつもりで消せていない
# ＝ 2 回目以降コンパイルが走らない、という最悪の壊れ方をする）。
BIN="$OUT/bin/measure-ane"
CACHE_DIR="$HOME/Library/Caches/measure-ane/com.apple.e5rt.e5bundlecache"

# ANE コンパイル失敗の印。**Sources/PhotogrammetryCore/ModelCache.swift の
# failureMarkers と対**で、片方を変えるときは必ず両方を直すこと。
# `com.apple.e5rt.e5bundlecache` を印に入れていないのは、こちらのログには
# キャッシュの場所そのものを毎回書いているため（自分の出力で誤検出する）。
ANE_MARKERS='ANECCompile|MILCompilerForANE|E5RT|ANEF|MPSGraphExecutable|manifest\.plist'

say() { echo "$@"; }

# ---------------------------------------------------------------------------
# 実行環境（原因の切り分けに要る。結果と一緒に残す）
# ---------------------------------------------------------------------------

PAGE_SIZE="$(sysctl -n hw.pagesize)"
MEM_BYTES="$(sysctl -n hw.memsize)"
MEM_GIB=$(( MEM_BYTES / 1073741824 ))

{
	echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
	echo "model: $(sysctl -n hw.model)"
	echo "chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '-')"
	echo "arch: $(uname -m)"
	echo "cores: $(sysctl -n hw.ncpu)"
	echo "memory: ${MEM_GIB}GiB"
	echo "swap: $(sysctl -n vm.swapusage)"
	echo "thermal: $(pmset -g therm 2>/dev/null | tr '\n' ' ' || echo '-')"
	echo "xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ' || echo '-')"
	echo "swift: $(swift --version 2>&1 | head -1)"
	echo "photos: $PHOTOS"
	echo "free-disk(caches): $(df -h "$HOME/Library/Caches" | awk 'NR==2 {print $4}')"
	echo "ane-cache: $CACHE_DIR"
} > "$ENV_TXT"

say "== 実行環境 =="
cat "$ENV_TXT"
say ""

# ---------------------------------------------------------------------------
# 試行の一覧（枚数 × 重し を巡ごとに 1 回ずつ）
# ---------------------------------------------------------------------------

# カンマ区切りを空白区切りへ（`IFS=,` のまま `$*` を作ると区切りがカンマの
# ままになるので、置換で素直にほどく）。
COUNT_LIST="$(echo "$COUNTS" | tr ',' ' ')"
BALLAST_LIST="$(echo "$BALLASTS" | tr ',' ' ')"

# 重しは搭載メモリの半分で頭打ちにする（それ以上は測定ではなく事故）。
MAX_BALLAST=$(( MEM_GIB / 2 ))
CHECKED_BALLASTS=""
for b in $BALLAST_LIST; do
	if [ "$b" -gt "$MAX_BALLAST" ]; then
		say "!! 重し ${b}GiB は搭載 ${MEM_GIB}GiB に対して大きすぎるので ${MAX_BALLAST}GiB に丸めます"
		b="$MAX_BALLAST"
	fi
	CHECKED_BALLASTS="$CHECKED_BALLASTS $b"
done
BALLAST_LIST="$CHECKED_BALLASTS"

TOTAL=0
for _r in $(seq 1 "$REPEATS"); do
	for _c in $COUNT_LIST; do
		for _b in $BALLAST_LIST; do
			TOTAL=$(( TOTAL + 1 ))
		done
	done
done

say "== 予定 =="
say "枚数: $COUNT_LIST / 重し(GiB): $BALLAST_LIST / 巡: $REPEATS → 全 $TOTAL 試行"
say "mode=$MODE start=$START timeout=${TIMEOUT}s キャッシュ削除=$([ "$KEEP_CACHE" = 1 ] && echo しない || echo 毎回)"
say "結果: $OUT"
say ""

if [ "$DRY_RUN" = 1 ]; then
	exit 0
fi

if [ "$KEEP_CACHE" = 1 ]; then
	say "!! --keep-cache が指定されています。ANE のコンパイルは最初の 1 回しか"
	say "!! 走らないので、2 回目以降の成功は「コンパイルが成功した」ではなく"
	say "!! 「コンパイルしなかった」を意味します。比較用途以外では使わないこと。"
	say ""
fi

# ---------------------------------------------------------------------------
# 測定用の実行体をビルド
# ---------------------------------------------------------------------------

mkdir -p "$OUT/bin"
say "measure-ane をビルドしています…"
swiftc -O "$HARNESS_SOURCE" -o "$BIN" || die "measure-ane のビルドに失敗しました"

# Object Capture が使えないマシンなら、ここで止める（測っても意味が無い）。
"$BIN" --selftest > "$OUT/selftest.txt" 2>&1 || true
cat "$OUT/selftest.txt"
if grep -q "isSupported: false" "$OUT/selftest.txt"; then
	die "このマシンでは Object Capture が使えません（PhotogrammetrySession.isSupported == false）"
fi
say ""

# ---------------------------------------------------------------------------
# 後始末（Ctrl-C でも重しと見張りを残さない）
# ---------------------------------------------------------------------------

BALLAST_PID=""
SAMPLER_PID=""

cleanup() {
	[ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null || true
	[ -n "$BALLAST_PID" ] && kill "$BALLAST_PID" 2>/dev/null || true
	SAMPLER_PID=""; BALLAST_PID=""
}
trap 'cleanup; say ""; say "中断しました。ここまでの結果: $TSV"; exit 130' INT TERM
trap cleanup EXIT

# ---------------------------------------------------------------------------
# システム側のメモリを見張る（プロセスのフットプリントは実行体が自分で出す）
# ---------------------------------------------------------------------------

sample_system() {
	# 1 行 = epoch 空き(MiB) 圧縮(MiB) スワップ使用(MiB) 圧レベル
	while :; do
		/usr/bin/vm_stat | /usr/bin/awk -v ps="$PAGE_SIZE" -v ts="$(date +%s)" \
			-v swap="$(sysctl -n vm.swapusage | awk '{print $6}' | tr -d 'M')" \
			-v level="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0)" '
			/Pages free/ { gsub(/\./, "", $3); free = $3 }
			/Pages speculative/ { gsub(/\./, "", $3); spec = $3 }
			/Pages occupied by compressor/ { gsub(/\./, "", $5); comp = $5 }
			END {
				printf "%s %.0f %.0f %s %s\n",
					ts, (free + spec) * ps / 1048576, comp * ps / 1048576, swap, level
			}'
		sleep 2
	done
}

# ---------------------------------------------------------------------------
# 1 試行
# ---------------------------------------------------------------------------

if [ ! -f "$TSV" ]; then
	printf 'round\tcount\tballast_gib\toutcome\tane_marker\texit\telapsed_s\tpeak_footprint_mb\tpeak_stage\tposed\tane_at_stage\tane_at_footprint_mb\tane_at_t\tfree_min_mb\tswap_max_mb\tpressure_max\tcache_before\tcache_after_kb\tlog\n' > "$TSV"
fi

DONE=0
FAILURES=0

run_trial() {
	local round count ballast label log samples cache_before waited
	local result_line elapsed peak_bytes peak_stage posed outcome exit_code last_sample
	local ane_marker ane_at_stage ane_at_footprint ane_at_t
	local free_min swap_max pressure_max cache_after_kb
	round="$1"; count="$2"; ballast="$3"
	label="r${round}-c${count}-b${ballast}"
	log="$OUT/logs/$label.log"
	samples="$OUT/logs/$label.samples"

	DONE=$(( DONE + 1 ))
	say "[$DONE/$TOTAL] $label を実行しています…"

	# --- ANE キャッシュを消す（この 1 行がこの測定の要）
	cache_before="absent"
	if [ -d "$CACHE_DIR" ]; then
		cache_before="present"
	fi
	if [ "$KEEP_CACHE" = 0 ]; then
		rm -rf "$CACHE_DIR"
	fi

	# --- 重し
	if [ "$ballast" -gt 0 ]; then
		say "  重し ${ballast}GiB を確保しています（マシンが張り付きます）…"
		"$BIN" --ballast "$ballast" > "$OUT/logs/$label.ballast" 2>&1 &
		BALLAST_PID=$!
		waited=0
		while ! grep -q "BALLAST ready" "$OUT/logs/$label.ballast" 2>/dev/null; do
			sleep 2
			waited=$(( waited + 2 ))
			if [ "$waited" -ge 300 ]; then
				say "  !! 重しが 5 分で用意できませんでした。この試行は飛ばします"
				kill "$BALLAST_PID" 2>/dev/null || true
				BALLAST_PID=""
				return 0
			fi
			if ! kill -0 "$BALLAST_PID" 2>/dev/null; then
				say "  !! 重しのプロセスが落ちました。この試行は飛ばします"
				BALLAST_PID=""
				return 0
			fi
		done
	fi

	# --- 見張り
	sample_system > "$samples" 2>/dev/null &
	SAMPLER_PID=$!

	# --- 本番。**落ちても続ける**（abort はこの測定で見たいものの 1 つ）
	set +e
	"$BIN" "$PHOTOS" --count "$count" --start "$START" --mode "$MODE" \
		--timeout "$TIMEOUT" > "$log" 2>&1
	exit_code=$?
	set -e

	cleanup

	# --- ログから拾う
	#
	# **行頭で錨を打たない。** フレームワークは E5RT の行を改行なしで書くので、
	# **こちらの 1 行の前に他人の文字列が付く**ことが実際にある
	# （"E5RT …ANECCompile() FAILED.window name=… result=ok" が
	# trial-clustering.sh に記録されている）。`^RESULT` で拾うとこの行を丸ごと
	# 取り逃がし、「落ちた」と誤記録することになる。
	result_line="$(sed -n 's/.*\(RESULT count=.*\)/\1/p' "$log" | tail -1 || true)"
	elapsed="$(echo "$result_line" | sed -n 's/.*elapsed=\([0-9.]*\).*/\1/p')"
	peak_bytes="$(echo "$result_line" | sed -n 's/.*peak_bytes=\([0-9]*\).*/\1/p')"
	peak_stage="$(echo "$result_line" | sed -n 's/.*peak_stage=\([^ ]*\).*/\1/p')"
	posed="$(echo "$result_line" | sed -n 's/.*posed=\([0-9]*\).*/\1/p')"
	# outcome は空白を含まない（実行体が `_` に潰して出す）。`.*$` で取ると、
	# 後ろに繋がった E5RT の行まで飲み込んでしまう。
	outcome="$(echo "$result_line" | sed -n 's/.*outcome=\([^ ]*\).*/\1/p')"

	# RESULT が無い＝プロセスが死んだ。**シグナル死をここで見分ける**
	# （CorePhotogrammetry の abort() は try/catch では捕まらない）。
	if [ -z "$result_line" ]; then
		if [ "$exit_code" -gt 128 ]; then
			outcome="signal-$(( exit_code - 128 ))"
		else
			outcome="died(exit=$exit_code)"
		fi
		# 落ちる直前の SAMPLE から、どこまで行ったかを拾う。
		last_sample="$(grep 'SAMPLE t=' "$log" | tail -1 || true)"
		peak_bytes="$(echo "$last_sample" | sed -n 's/.*footprint=\([0-9]*\).*/\1/p')"
		peak_stage="$(echo "$last_sample" | sed -n 's/.*stage=\([^ ]*\).*/\1/p')"
		elapsed="$(echo "$last_sample" | sed -n 's/.*t=\([0-9.]*\).*/\1/p')"
	fi

	# --- ANE の印が出た瞬間の段階とメモリ（メモリ説の裏取りの本体）
	ane_marker="no"
	ane_at_stage="-"; ane_at_footprint=""; ane_at_t="-"
	if grep -qE "$ANE_MARKERS" "$log"; then
		ane_marker="yes"
		# **印が出た瞬間に、直前の SAMPLE が何を言っていたか**を取る。
		# 印の判定を先に置くのは、SAMPLE の行に印が繋がって出た場合に
		# 「その行の SAMPLE」ではなく「1 つ前の SAMPLE」を答えにするため
		# （繋がった行の SAMPLE は印より後の時刻の値になっている）。
		eval "$(awk -v markers="$ANE_MARKERS" '
			{
				if (!seen && match($0, markers)) {
					seen = 1
					printf "ane_at_t=%s; ane_at_footprint=%s; ane_at_stage=%s\n",
						(t == "" ? "-" : t), f, (s == "" ? "-" : s)
				}
				if (match($0, /SAMPLE t=[0-9.]+ footprint=[0-9]+ stage=[A-Za-z]+/)) {
					n = split(substr($0, RSTART, RLENGTH), fields, " ")
					for (i = 2; i <= n; i++) {
						split(fields[i], kv, "=")
						if (kv[1] == "t") t = kv[2]
						if (kv[1] == "footprint") f = kv[2]
						if (kv[1] == "stage") s = kv[2]
					}
				}
			}' "$log")"
	fi

	# --- システム側の谷（空きの最小・スワップの最大・圧レベルの最悪）
	free_min="-"; swap_max="-"; pressure_max="-"
	if [ -s "$samples" ]; then
		eval "$(awk '
			NR == 1 || $2 < fmin { fmin = $2 }
			$4 > smax { smax = $4 }
			$5 > pmax { pmax = $5 }
			END { printf "free_min=%.0f; swap_max=%.0f; pressure_max=%s\n", fmin, smax, pmax }
			' "$samples")"
	fi

	cache_after_kb="$(du -sk "$CACHE_DIR" 2>/dev/null | awk '{print $1}')"
	[ -n "$cache_after_kb" ] || cache_after_kb=0

	mb() { [ -n "$1" ] && [ "$1" != "0" ] && echo $(( $1 / 1048576 )) || echo "-"; }

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$round" "$count" "$ballast" "${outcome:--}" "$ane_marker" "$exit_code" \
		"${elapsed:--}" "$(mb "${peak_bytes:-}")" "${peak_stage:--}" "${posed:--}" \
		"$ane_at_stage" "$(mb "${ane_at_footprint:-}")" "$ane_at_t" \
		"$free_min" "$swap_max" "$pressure_max" \
		"$cache_before" "$cache_after_kb" "logs/$label.log" >> "$TSV"

	say "  → outcome=${outcome:--} ane=$ane_marker peak=$(mb "${peak_bytes:-}")MB stage=${peak_stage:--} 空きの最小=${free_min}MB"

	if [ "$ane_marker" = "yes" ]; then
		say "  !! ANE コンパイル失敗の印が出ました（$ane_at_stage / t=${ane_at_t}s / footprint=$(mb "${ane_at_footprint:-}")MB）"
		FAILURES=$(( FAILURES + 1 ))
		if [ "$STOP_ON_FAIL" = 1 ]; then
			say ""
			say "--stop-on-fail が指定されているのでここで止めます。ログ: $log"
			summarize
			exit 1
		fi
	fi
}

# ---------------------------------------------------------------------------
# 集計
# ---------------------------------------------------------------------------

summarize() {
	say ""
	say "== 集計（枚数 × 重し ごと）=="
	awk -F'\t' '
		NR == 1 { next }
		{
			key = $2 "\t" $3
			n[key]++
			if ($5 == "yes") ane[key]++
			if ($4 ~ /^signal-/) crash[key]++
			if ($8 != "-") { peak[key] += $8; peakn[key]++ ; if ($8 + 0 > peakmax[key]) peakmax[key] = $8 }
			if ($14 != "-") { if (!(key in freemin) || $14 + 0 < freemin[key]) freemin[key] = $14 }
		}
		END {
			# 見出しは TSV の列名と同じ ASCII にする（日本語だと桁が揃わず、
			# 一晩ぶんの表が読めなくなる）。
			printf "%7s %8s %7s %9s %6s %12s %12s %12s\n",
				"count", "ballast", "trials", "ane_fail", "abort",
				"peak_avg_MB", "peak_max_MB", "free_min_MB"
			for (key in n) {
				split(key, k, "\t")
				printf "%7s %8s %7d %9d %6d %12s %12s %12s\n",
					k[1], k[2], n[key], ane[key] + 0, crash[key] + 0,
					(peakn[key] ? sprintf("%.0f", peak[key] / peakn[key]) : "-"),
					(peakmax[key] ? peakmax[key] : "-"),
					(key in freemin ? freemin[key] : "-")
			}
		}' "$TSV" | (read -r header; echo "$header"; sort -n)

	say ""
	say "== 読み方 =="
	say "・ANE失敗が**多い枚数にだけ**出る → メモリ説が生きている。枚数の上限が対策になる"
	say "・ANE失敗が**枚数によらず散らばる** → メモリではない。OS / モデルキャッシュ側を疑う"
	say "・ANE失敗が**1 度も出ない** → この条件では再現しない。--ballast で空きを潰して"
	say "  呼び出せるか試す（呼び出せなければメモリ説は捨ててよい）"
	say "・失敗した行の ane_at_stage / ane_at_footprint_mb を見る。山の頂上（imageAlignment"
	say "  など）で出ているならメモリ、前処理の入口で出ているならメモリではない"
	say ""
	say "生データ: $TSV"
	say "環境: $ENV_TXT"
	say "ログ: $OUT/logs/"
}

# ---------------------------------------------------------------------------
# 本体（巡ごとに全条件を 1 回ずつ）
# ---------------------------------------------------------------------------

for round in $(seq 1 "$REPEATS"); do
	for count in $COUNT_LIST; do
		for ballast in $BALLAST_LIST; do
			run_trial "$round" "$count" "$ballast"
		done
	done
done

summarize

if [ "$FAILURES" -gt 0 ]; then
	say ""
	say "ANE コンパイル失敗を $FAILURES 件観測しました。"
	exit 1
fi
say ""
say "ANE コンパイル失敗は観測されませんでした（全 $DONE 試行）。"
