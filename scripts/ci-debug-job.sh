#!/usr/bin/env bash
#
# ci-debug-job.sh — `.github/workflows/ci-debug.yml`（CI debug）のランナー側本体。
#
# ワークフローは「チェックアウト → Xcode 選択 → このスクリプトを 1 回実行」だけを
# 行い、実際の調査コマンドはすべてここに集約する。こうしている理由は 2 つ:
#
#   1. workflow_dispatch は「デフォルトブランチに存在するワークフロー」しか起動でき
#      ないため、ワークフロー本体を頻繁に触ると毎回 main へマージする必要が出る。
#      モードの追加・修正をこのスクリプト側に閉じ込めれば、作業ブランチに push する
#      だけで（dispatch の ref がそのブランチなので）すぐ試せる。
#   2. インライン YAML の run: と違い、独立したシェルスクリプトなので shellcheck に
#      そのままかけられる。
#
# 入力はすべて環境変数（ワークフローが inputs から詰める）:
#
#   MODE     build | test | run-cli | shell
#   ARGS     モードごとの引数（swift build/test への追加フラグ、CLI の引数）
#   SCRIPT   MODE=shell のときに実行する bash スクリプト本文
#
# 出力は「ペイロードマーカー」で挟んだ 1 ブロックとして stdout に出す:
#
#   ===== BEGIN PAYLOAD (mode=...) =====
#   ...
#   ===== END PAYLOAD (exit=N lines_total=N truncated=yes|no) =====
#
# 呼び出し側（scripts/ci-debug.sh）はこのマーカー間だけを抜き出すので、セット
# アップ手順のノイズを読まずに済む。生の全出力は debug-out/ に残し、ワークフローが
# アーティファクトとしてアップロードする（人間用の保険。AI は GitHub MCP で
# アーティファクトを取得できないため、必要な情報は必ずログ側に出すこと）。
#
# 終了ステータスは調査コマンドのものをそのまま返す（＝run の conclusion になる）。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

MODE="${MODE:-}"
ARGS="${ARGS:-}"
SCRIPT="${SCRIPT:-}"
OUT_DIR="${OUT_DIR:-debug-out}"

# ペイロードに載せる最大行数。これを超えたぶんは切り捨て、END マーカーの
# truncated=yes で「全部は見えていない」ことを呼び出し側に明示する（AI が
# 「該当なし」と誤読しないための最重要ポイント）。全文は debug-out/raw.txt に残る。
MAX_LINES="${PAYLOAD_MAX_LINES:-400}"

mkdir -p "$OUT_DIR"
RAW="$OUT_DIR/raw.txt"
PAYLOAD="$OUT_DIR/payload.txt"

# ---------------------------------------------------------------------------
# 小さなヘルパー
# ---------------------------------------------------------------------------

# die <message>: 使い方の誤り。モード実装はサブシェル内で走るので、この exit は
# スクリプト全体ではなくサブシェルだけを終わらせる。メッセージは（stderr ごと）
# RAW に入り、通常どおりペイロードとして出力される — つまり失敗しても呼び出し側は
# 必ずマーカー付きの理由を受け取れる。
die() {
	echo "ci-debug-job: error: $1" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# モード実装。すべて stdout/stderr に出し、呼び出し元が RAW へリダイレクトする。
# ARGS は空白区切りの追加フラグとして意図的に word splitting する。
# ---------------------------------------------------------------------------

# build: swift build。ARGS に追加フラグ（例: '-c release --target PhotogrammetryCore'）。
mode_build() {
	echo "# swift build $ARGS"
	echo
	# shellcheck disable=SC2086
	swift build $ARGS
}

# test: swift test。ARGS に追加フラグ（例: '--filter UpdateFeedTests'）。
mode_test() {
	echo "# swift test $ARGS"
	echo
	# shellcheck disable=SC2086
	swift test $ARGS
}

# run-cli: photogrammetry-cli をビルドして実行する。ARGS が CLI の引数になる。
# 実写真での再構成を CI 上で試したいときは、mode=shell で写真を用意してから
# こちらを使う（ランナーに GPU 要件が無い場合は isSupported で弾かれる — その
# 出力自体が調査結果になる）。
mode_run_cli() {
	echo "# swift run photogrammetry-cli $ARGS"
	echo
	# shellcheck disable=SC2086
	swift run photogrammetry-cli $ARGS
}

# shell: 逃げ道。固定モードで表現できない一発調査を bash でそのまま流す。
# SCRIPT は環境変数で渡ってくる（YAML へ展開しないのでクォート事故が起きない）。
mode_shell() {
	[ -n "$SCRIPT" ] || die "mode=shell には script が必要です"
	local f="$OUT_DIR/script.sh"
	printf '%s\n' "$SCRIPT" >"$f"
	echo "# bash $f"
	echo
	bash "$f"
}

# ---------------------------------------------------------------------------
# ペイロード出力
# ---------------------------------------------------------------------------

# digest_log: ビルド・テストログ向けの抜粋。診断行（error/FAILED …）を先に、
# その後に末尾の数十行を出す。並列ビルドではエラーが末尾に来るとは限らないので、
# 単純な tail ではなく両方を出している。
digest_log() {
	local hits
	hits="$(grep -nE -- '(^|[^A-Za-z])([Ee]rror|ERROR|FAILED|failed|fatal|warning:|XCTAssert)' "$RAW" | head -n 300)"
	if [ -n "$hits" ]; then
		echo "--- diagnostics (max 300 lines, prefixed with the line number in raw.txt) ---"
		printf '%s\n' "$hits"
		echo
	fi
	echo "--- tail of the log (last 80 lines) ---"
	tail -n 80 "$RAW"
}

# emit_payload <exit-status>: マーカーで挟んだ 1 ブロックを stdout と payload.txt へ。
emit_payload() {
	local status="$1" total truncated="no"
	total="$(wc -l <"$RAW" | tr -d ' ')"

	{
		echo "===== BEGIN PAYLOAD (mode=$MODE) ====="
		if [ "$DIGEST" = "log" ]; then
			digest_log
		else
			head -n "$MAX_LINES" "$RAW"
			if [ "$total" -gt "$MAX_LINES" ]; then
				truncated="yes"
			fi
		fi
		echo "===== END PAYLOAD (exit=$status lines_total=$total truncated=$truncated) ====="
	} >"$PAYLOAD"

	cat "$PAYLOAD"
	emit_annotation
}

# emit_annotation: ペイロードを **チェックラン注釈** としても出す。
#
# なぜ二重に出すか: 呼び出し側がペイロードを取る経路は本来ジョブログだが、ログ API は
# 署名付きの Azure Blob Storage へ 302 で飛ぶ。組織の egress ポリシーがそのホストを
# 拒否している環境（Claude Code のリモートセッションなど）では、コンテナからログ本文を
# 取得できない。一方、注釈は
#
#   GET /repos/{owner}/{repo}/check-runs/{check_run_id}/annotations
#
# つまり api.github.com だけで読めるうえ、ログのノイズ（セットアップ手順・アーティ
# ファクトアップロード・ポストジョブ後始末）が混ざらない。ワークフローコマンドの
# 仕様で改行は %0A へエスケープする必要がある（% と CR も同様）。
#
# **GitHub は注釈のメッセージを 4096 文字ちょうどで切る**（実測）。しかも切り方は
# 単語の途中でも構わない乱暴なもので、そのままだと END マーカーごと消えて「これで
# 全部だ」と誤読される。そこで自前でバイト予算に収め、切り詰めた旨の 1 行と END
# マーカー行を**必ず**収まる形で残す。全文はジョブログとアーティファクトに残る。
#
# END 行には lines_total が入っているので、注釈側が切られていても「本当は何行
# あったのか」は読み手に伝わる。
emit_annotation() {
	local budget="${ANNOTATION_MAX_BYTES:-3800}" total kept body tail_line notice
	total="$(wc -l <"$PAYLOAD" | tr -d ' ')"
	tail_line="$(tail -n 1 "$PAYLOAD")"
	notice="... (annotation truncated by GitHub's 4096-char limit — the full payload is in the job log and the run artifact)"

	# 予算から「切り詰め通知＋END 行」ぶんを引いた範囲まで、行単位で詰める。
	# 文字数ではなくバイト数で数えるため LC_ALL=C（日本語のエラーメッセージ対策）。
	body="$(LC_ALL=C awk -v limit="$((budget - ${#notice} - ${#tail_line} - 4))" '
		{
			len += length($0) + 1
			if (len > limit) { exit }
			print
		}' "$PAYLOAD")"

	kept="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
	if [ "$kept" -lt "$total" ]; then
		body="$(printf '%s\n%s\n%s' "$body" "$notice" "$tail_line")"
	fi

	body="$(printf '%s\n' "$body" |
		sed -e 's/%/%25/g' -e 's/\r/%0D/g' |
		awk '{printf "%s%%0A", $0}')"
	echo "::notice title=ci-debug payload::${body}"
}

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

# ビルド・テスト・CLI 実行のログは「診断行＋末尾」のダイジェストにする。
# 短い出力しか出ないモードは head で十分。
case "$MODE" in
	build | test | run-cli) DIGEST="log" ;;
	*) DIGEST="head" ;;
esac

# モード実装はサブシェルで動かす。die の exit がここで止まるので、使い方の誤りでも
# 必ず emit_payload まで到達する（＝呼び出し側は理由をマーカー付きで受け取れる）。
(
	case "$MODE" in
		build) mode_build ;;
		test) mode_test ;;
		run-cli) mode_run_cli ;;
		shell) mode_shell ;;
		*) die "未知の mode: '$MODE'（build / test / run-cli / shell）" ;;
	esac
) >"$RAW" 2>&1
STATUS=$?

emit_payload "$STATUS"
exit "$STATUS"
