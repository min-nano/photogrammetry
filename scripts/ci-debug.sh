#!/usr/bin/env bash
#
# ci-debug.sh — `.github/workflows/ci-debug.yml`（CI debug）を起動し、**完了まで待って**
# 結果ペイロードを取り出すクライアント。
#
# なぜこれがあるか
# ----------------
# リモートセッション（claude.ai/code などクラウド上のコンテナ）は Linux で、macOS /
# Xcode / RealityKit が無い。したがって Swift のビルドエラーやテストの失敗、
# 「この API はコンパイルが通るか」という調査は CI（macOS ランナー）上でしか答えが
# 出ない。ところが
#
#   * PR 購読で配信されるのは CI の**失敗**とコメントだけで、**成功は通知されない**。
#   * よってタイマーで見に行くことになるが、実行時間の予測が要るうえ無駄な待機が出る。
#
# 一方このコンテナからは GitHub REST API に直接到達できる（GITHUB_TOKEN が入っている）。
# そこで「完了したら exit するプロセス」をバックグラウンドで走らせれば、待機時間ゼロ・
# タイマー不要で完了を知れる。Claude Code なら:
#
#   Bash(run_in_background: true) で
#     scripts/ci-debug.sh wait --label <label>
#   を投げて別作業を続け、終了通知が来たら出力ファイルを Read するだけ。
#
# ディスパッチ → run の特定 → 完了待ち → ペイロード抽出、までを 1 本でやるので、
# GitHub MCP を 3 往復する必要もない。
#
# 使い方
# ------
#   scripts/ci-debug.sh run --mode <mode> [options]      起動して完了まで待つ
#   scripts/ci-debug.sh wait --label <label>             既存の実行に後から合流する
#   scripts/ci-debug.sh wait --run-id <id>
#   scripts/ci-debug.sh logs --run-id <id>               完了済み実行のペイロードだけ取る
#
#   モード（詳細は scripts/ci-debug-job.sh）:
#     build        swift build（--args に追加フラグ）
#     test         swift test（--args に追加フラグ。例 '--filter UpdateFeedTests'）
#     run-cli      swift run photogrammetry-cli（--args が CLI の引数）
#     shell        --script の bash をそのまま実行（逃げ道）
#
#   オプション:
#     --mode M         必須。上記のいずれか
#     --args A         モードごとの引数
#     --script S       mode=shell のとき実行する bash
#     --ref R          調査対象のブランチ（既定: いま checkout しているブランチ）
#     --label L        実行の識別子（既定: 自動生成。run 名に埋め込まれる）
#     --notify-pr N    完了時に結果を PR へコメントする（待機プロセスを失ったときの保険）
#     --no-wait        ディスパッチだけして待たない
#
# 環境変数:
#   GITHUB_TOKEN / GH_TOKEN   必須（ディスパッチには write 権限が要る）
#   PG_REPO                   owner/repo（既定は下記）
#   CI_DEBUG_POLL             ポーリング間隔・秒（既定 15）
#   CI_DEBUG_TIMEOUT          待機の上限・秒（既定 2700 = 45 分。ジョブ側の
#                             timeout-minutes と同じ）
#
# 終了ステータス: run の conclusion が success なら 0、それ以外は 1。使い方の誤りや
# API エラーは 2。
#
set -uo pipefail

PG_REPO="${PG_REPO:-min-nano/photogrammetry}"
PG_API="https://api.github.com/repos/${PG_REPO}"
WORKFLOW_FILE="ci-debug.yml"
POLL="${CI_DEBUG_POLL:-15}"
TIMEOUT="${CI_DEBUG_TIMEOUT:-2700}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

die() {
	echo "ci-debug: error: $1" >&2
	exit 2
}

command -v jq >/dev/null 2>&1 || die "jq が必要です"

# api <curl args...>: 認証済みの GitHub API 呼び出し。
api() {
	curl -sS \
		-H "Authorization: Bearer $TOKEN" \
		-H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"$@"
}

# ---------------------------------------------------------------------------
# 引数解析
# ---------------------------------------------------------------------------

CMD="${1:-}"
[ -n "$CMD" ] || die "サブコマンドを指定してください（run / wait / logs）"
shift

MODE=""
ARGS=""
SCRIPT=""
REF=""
LABEL=""
NOTIFY_PR=""
RUN_ID=""
WAIT=1

while [ "$#" -gt 0 ]; do
	case "$1" in
		--mode) MODE="${2:-}" ; shift 2 ;;
		--args) ARGS="${2:-}" ; shift 2 ;;
		--script) SCRIPT="${2:-}" ; shift 2 ;;
		--ref) REF="${2:-}" ; shift 2 ;;
		--label) LABEL="${2:-}" ; shift 2 ;;
		--notify-pr) NOTIFY_PR="${2:-}" ; shift 2 ;;
		--run-id) RUN_ID="${2:-}" ; shift 2 ;;
		--no-wait) WAIT=0 ; shift ;;
		-h | --help) sed -n '2,60p' "$0" ; exit 0 ;;
		*) die "未知のオプション: $1" ;;
	esac
done

# ---------------------------------------------------------------------------
# run の特定・待機・ログ取得
# ---------------------------------------------------------------------------

# resolve_run <label>: label を run 名に埋め込んであるので、それで自分の run を探す。
# dispatch API は run の id を返さないため、この突き合わせが唯一の手掛かり。GitHub が
# run を作るまで数秒かかるので少し粘る。
resolve_run() {
	local label="$1" tries=0 id
	while [ "$tries" -lt 30 ]; do
		tries=$((tries + 1))
		id="$(api "$PG_API/actions/workflows/$WORKFLOW_FILE/runs?event=workflow_dispatch&per_page=50" |
			jq -r --arg l "[$label]" 'first(.workflow_runs[] | select(.display_title | contains($l)) | .id) // empty')"
		if [ -n "$id" ]; then
			printf '%s\n' "$id"
			return 0
		fi
		sleep 3
	done
	return 1
}

# wait_run <run-id>: completed になるまでポーリングし、conclusion を echo する。
# 一過性の API エラーで待機を殺さないよう、失敗しても次の周回へ進む。
wait_run() {
	local id="$1" started now json status conclusion last=""
	started="$(date +%s)"
	while true; do
		json="$(api "$PG_API/actions/runs/$id")"
		status="$(printf '%s' "$json" | jq -r '.status // empty')"
		conclusion="$(printf '%s' "$json" | jq -r '.conclusion // empty')"
		if [ -n "$status" ] && [ "$status" != "$last" ]; then
			echo "status=$status ($(($(date +%s) - started))s)" >&2
			last="$status"
		fi
		if [ "$status" = "completed" ]; then
			printf '%s\n' "${conclusion:-unknown}"
			return 0
		fi
		now="$(date +%s)"
		if [ "$((now - started))" -ge "$TIMEOUT" ]; then
			echo "ci-debug: timeout: ${TIMEOUT}s 待っても完了しませんでした（run はまだ動いているかもしれません）" >&2
			printf '%s\n' "timed-out-waiting"
			return 1
		fi
		sleep "$POLL"
	done
}

# fetch_payload <run-id>: ペイロードを取り出す。経路は 2 つあり、順に試す。
#
#   1. チェックラン注釈（api.github.com のみ）… ci-debug-job.sh が ::notice:: で
#      ペイロードを注釈としても出しているので、ここから読めればログを触らずに済む。
#      ログのノイズが混ざらず、下記 2 が使えない環境でも動く。
#   2. ジョブログ … 従来の経路。ただしログ API は署名付きの Azure Blob Storage へ
#      302 で飛ぶため、そのホストを egress ポリシーで拒否している環境（Claude Code の
#      リモートセッション等）では取得できない。その場合は理由と代替手段を示す。
fetch_payload() {
	local id="$1" jobs job check url tmp ann
	jobs="$(api "$PG_API/actions/runs/$id/jobs")"
	job="$(printf '%s' "$jobs" | jq -r '.jobs[0].id // empty')"
	[ -n "$job" ] || {
		echo "ci-debug: ジョブが見つかりませんでした（run=$id）" >&2
		return 1
	}
	check="$(printf '%s' "$jobs" | jq -r '.jobs[0].check_run_url // empty')"

	if [ -n "$check" ]; then
		ann="$(api "$check/annotations" |
			jq -r 'map(select(.title == "ci-debug payload")) | .[0].message // empty')"
		if [ -n "$ann" ]; then
			printf '%s\n' "$ann"
			return 0
		fi
	fi

	tmp="$(mktemp)"
	url="$(api -o /dev/null -w '%{redirect_url}' "$PG_API/actions/jobs/$job/logs")"
	if [ -n "$url" ]; then
		if ! curl -sS "$url" >"$tmp" 2>"$tmp.err"; then
			echo "(ペイロード注釈が無く、ジョブログも取得できませんでした)"
			echo "  理由: $(tr -d '\n' <"$tmp.err")"
			echo "  ログ API は署名付きストレージへリダイレクトします。そのホストが"
			echo "  egress ポリシーで拒否されている環境では、GitHub MCP の get_job_logs"
			echo "  （job_id=$job, return_content=true）で取得してください。"
			rm -f "$tmp" "$tmp.err"
			return 1
		fi
	else
		api "$PG_API/actions/jobs/$job/logs" >"$tmp"
	fi
	rm -f "$tmp.err"

	# GitHub のログは各行に ISO タイムスタンプが前置される。読みづらいので落とす。
	sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' "$tmp" >"$tmp.clean"

	if grep -q '^===== BEGIN PAYLOAD' "$tmp.clean"; then
		awk '/^===== BEGIN PAYLOAD/,/^===== END PAYLOAD/' "$tmp.clean"
	else
		# 調査コマンドに到達する前に落ちた場合（チェックアウト失敗など）。
		# 黙って空を返すと「結果なし」と誤読されるので、理由が分かる末尾を出す。
		echo "(ペイロードマーカーがありません — 調査コマンドに到達する前に失敗した可能性があります。ログ末尾:)"
		echo
		tail -n 100 "$tmp.clean"
	fi
	rm -f "$tmp" "$tmp.clean"
}

# report <run-id> <conclusion>: 結果の見出しとペイロードを出し、終了コードを決める。
report() {
	local id="$1" conclusion="$2"
	echo
	echo "conclusion=$conclusion"
	echo "run_url=https://github.com/$PG_REPO/actions/runs/$id"
	echo
	fetch_payload "$id"
	[ "$conclusion" = "success" ]
}

# ---------------------------------------------------------------------------
# サブコマンド
# ---------------------------------------------------------------------------

case "$CMD" in
	run)
		[ -n "$TOKEN" ] || die "GITHUB_TOKEN / GH_TOKEN が未設定です（ディスパッチには write 権限が要ります）"
		[ -n "$MODE" ] || die "--mode が必要です"
		if [ -z "$REF" ]; then
			REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
			if [ -z "$REF" ] || [ "$REF" = "HEAD" ]; then
				die "--ref を指定してください（現在のブランチを判定できません）"
			fi
		fi
		if [ -z "$LABEL" ]; then
			LABEL="dbg-$(date +%s)-$$"
		fi

		body="$(jq -n \
			--arg ref "$REF" \
			--arg mode "$MODE" \
			--arg label "$LABEL" \
			--arg args "$ARGS" \
			--arg script "$SCRIPT" \
			--arg notify_pr "$NOTIFY_PR" \
			'{ref: $ref, inputs: {mode: $mode, label: $label, args: $args, script: $script, notify_pr: $notify_pr}}')"

		code="$(api -o /dev/null -w '%{http_code}' -X POST \
			-d "$body" "$PG_API/actions/workflows/$WORKFLOW_FILE/dispatches")"
		[ "$code" = "204" ] ||
			die "ディスパッチに失敗しました（HTTP $code）。ci-debug.yml が main にマージ済みか、ref='$REF' が push 済みかを確認してください"

		# 待機プロセスが失われても後から合流できるよう、label は必ず先に出す。
		echo "label=$LABEL"
		echo "ref=$REF mode=$MODE"

		run_id="$(resolve_run "$LABEL")" || die "起動した run を特定できませんでした（label=$LABEL）"
		echo "run_id=$run_id"
		echo "run_url=https://github.com/$PG_REPO/actions/runs/$run_id"

		if [ "$WAIT" -eq 0 ]; then
			echo "(--no-wait: 完了は 'scripts/ci-debug.sh wait --run-id $run_id' で待てます)"
			exit 0
		fi

		conclusion="$(wait_run "$run_id")"
		if report "$run_id" "$conclusion"; then exit 0; fi
		exit 1
		;;

	wait)
		[ -n "$TOKEN" ] || die "GITHUB_TOKEN / GH_TOKEN が未設定です"
		if [ -z "$RUN_ID" ]; then
			[ -n "$LABEL" ] || die "--run-id か --label が必要です"
			RUN_ID="$(resolve_run "$LABEL")" || die "label=$LABEL の run が見つかりません"
			echo "run_id=$RUN_ID"
		fi
		conclusion="$(wait_run "$RUN_ID")"
		if report "$RUN_ID" "$conclusion"; then exit 0; fi
		exit 1
		;;

	logs)
		[ -n "$TOKEN" ] || die "GITHUB_TOKEN / GH_TOKEN が未設定です"
		if [ -z "$RUN_ID" ]; then
			[ -n "$LABEL" ] || die "--run-id か --label が必要です"
			RUN_ID="$(resolve_run "$LABEL")" || die "label=$LABEL の run が見つかりません"
		fi
		fetch_payload "$RUN_ID"
		;;

	*)
		die "未知のサブコマンド: '$CMD'（run / wait / logs）"
		;;
esac
