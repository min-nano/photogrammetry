#!/usr/bin/env bash
#
# wait-pr-checks.sh — PR（またはブランチ / commit）の CI が**完了した瞬間に exit する**
# 待機コマンド。
#
# なぜこれがあるか
# ----------------
# PR を作ったあと「CI が緑になったら次へ進む」をやりたいが、
#
#   * PR 購読で配信されるのは CI の**失敗**とコメントだけで、**成功は通知されない**。
#   * よってタイマーで見に行くことになるが、実行時間の予測が要るうえ無駄な待機が出る。
#
# 一方このコンテナからは GitHub REST API に直接到達できる（GITHUB_TOKEN は読み取り
# 専用でも十分）。そこで「完了したら exit するプロセス」をバックグラウンドで走らせれば、
# 待機時間ゼロ・タイマー不要で完了を知れる。Claude Code なら:
#
#   Bash(run_in_background: true) で
#     scripts/wait-pr-checks.sh --pr 7 >/tmp/pr7.log 2>&1
#   を投げて別作業を続け、終了通知が来たら /tmp/pr7.log を Read するだけ。
#
# ci-debug.sh の wait と考え方は同じだが、あちらは「自分がディスパッチした 1 本の
# run」を待つのに対し、こちらは「その commit に付く CI 全部」を待つ。
#
# ハマりどころ（このスクリプトが存在する直接の理由）
# --------------------------------------------------
# 素朴に `GET /commits/{sha}/status`（combined status）の `.state` を見て
# `pending` の間ループする、という待ち方は**このリポジトリでは永久に終わらない**。
# combined status は「commit status API で登録されたステータス」の集約で、
# GitHub Actions は commit status ではなく **check run** を作るため、
# `total_count: 0` かつ `state: "pending"` を返し続ける。実際 PR #7 では全 5 チェックが
# 2 分で success になったのに、この待ち方をしたコマンドは 27 分たっても exit しなかった。
#
# したがってこのスクリプトは
#
#   1. check runs（`/commits/{sha}/check-runs`）
#   2. workflow runs（`/actions/runs?head_sha=...`）
#   3. commit statuses（`total_count > 0` のときだけ）
#
# の 3 つを見る。2 が要るのは、`build.yml` の `release` のように**後から現れるジョブ**が
# あるため（その時点の check run が全部 completed でも、run 自体はまだ in_progress）。
# 3 は Actions 以外の外部 CI が付いたときのための保険で、0 件なら無視する。
#
# そして**どの経路でも必ず exit する**ように、次の 3 つの出口を用意している。
#
#   * 全部 completed（`--settle` 回連続で一致したら確定。ジョブが増える瞬間の取りこぼし対策）
#   * チェックが 1 つも現れないまま `--start-grace` 秒経過（ワークフロー未設定などを検出）
#   * `--timeout` 秒経過（ハードリミット。無限待機を作らない）
#
# 使い方
# ------
#   scripts/wait-pr-checks.sh --pr 7
#   scripts/wait-pr-checks.sh --ref claude/my-branch
#   scripts/wait-pr-checks.sh --sha 4586d92
#
#   オプション:
#     --pr N            PR 番号。head SHA は毎周回引き直す（push で追随・再スタート）
#     --ref R           ブランチ / タグ。head SHA は毎周回引き直す
#     --sha S           commit を直接指定（追随しない）
#     --poll S          ポーリング間隔・秒（既定 15）
#     --timeout S       待機の上限・秒（既定 2700 = 45 分）
#     --start-grace S   チェックが 1 つも現れないのを許す時間・秒（既定 240）
#     --settle N        「全部 completed」が何周回連続したら確定とするか（既定 2）
#     --quiet           進捗行を出さない（最終サマリだけ）
#
# 環境変数:
#   GITHUB_TOKEN / GH_TOKEN   必須（読み取り権限だけでよい）
#   PG_REPO                   owner/repo（既定は下記）
#
# 出力の最後は必ず 1 行の機械可読サマリ:
#   result=<success|failure|no-checks|timeout|pr-merged|pr-closed> sha=<sha> total=N failed=N pending=N
#
# 終了ステータス:
#   0  全チェック完了・失敗なし（または PR が merge 済み）
#   1  失敗したチェックがある（または PR が merge されずに close された）
#   2  使い方の誤り / トークン無し / API から回復不能
#   3  タイムアウト、またはチェックが 1 つも現れなかった（＝結果は「不明」）
#
set -uo pipefail

PG_REPO="${PG_REPO:-min-nano/photogrammetry}"
PG_API="https://api.github.com/repos/${PG_REPO}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

POLL=15
TIMEOUT=2700
START_GRACE=240
SETTLE=2
QUIET=0

PR=""
REF=""
SHA=""

die() {
	echo "wait-pr-checks: error: $1" >&2
	exit 2
}

note() {
	[ "$QUIET" -eq 1 ] || echo "$1" >&2
}

command -v jq >/dev/null 2>&1 || die "jq が必要です"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--pr) PR="${2:-}" ; shift 2 ;;
		--ref) REF="${2:-}" ; shift 2 ;;
		--sha) SHA="${2:-}" ; shift 2 ;;
		--poll) POLL="${2:-}" ; shift 2 ;;
		--timeout) TIMEOUT="${2:-}" ; shift 2 ;;
		--start-grace) START_GRACE="${2:-}" ; shift 2 ;;
		--settle) SETTLE="${2:-}" ; shift 2 ;;
		--quiet) QUIET=1 ; shift ;;
		-h | --help) sed -n '2,80p' "$0" ; exit 0 ;;
		*) die "未知のオプション: $1" ;;
	esac
done

[ -n "$TOKEN" ] || die "GITHUB_TOKEN / GH_TOKEN が未設定です"
[ -n "$PR$REF$SHA" ] || die "--pr / --ref / --sha のいずれかが必要です"

# api <path>: 認証済みの GitHub API 呼び出し。ネットワークや 5xx の一過性エラーで
# 待機を殺さないよう、失敗は戻り値で伝えて呼び出し側で「今回は判定しない」に倒す。
api() {
	curl -sS --fail-with-body --max-time 30 \
		-H "Authorization: Bearer $TOKEN" \
		-H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 対象 commit の解決
# ---------------------------------------------------------------------------

PR_STATE=""
PR_MERGED=""
RESOLVED_SHA=""

# resolve_sha: 待つべき commit を RESOLVED_SHA に入れる（PR の場合は PR_STATE /
# PR_MERGED も更新する）。戻り値で成否を返し、コマンド置換を使わないのは意図的で、
# サブシェルにすると PR_STATE の更新が呼び出し元に伝わらないため。
#
# --pr / --ref は毎周回引き直す。待機中に push されたら新しい commit に自動で
# 乗り換えるためで、そうしないと古い commit の緑を見て「終わった」と誤判定する。
resolve_sha() {
	local json
	RESOLVED_SHA=""
	if [ -n "$SHA" ]; then
		RESOLVED_SHA="$SHA"
		return 0
	fi
	if [ -n "$PR" ]; then
		json="$(api "$PG_API/pulls/$PR")" || return 1
		PR_STATE="$(printf '%s' "$json" | jq -r '.state // empty')"
		PR_MERGED="$(printf '%s' "$json" | jq -r '.merged // false')"
		RESOLVED_SHA="$(printf '%s' "$json" | jq -r '.head.sha // empty')"
	else
		json="$(api "$PG_API/commits/$REF")" || return 1
		RESOLVED_SHA="$(printf '%s' "$json" | jq -r '.sha // empty')"
	fi
	[ -n "$RESOLVED_SHA" ]
}

# ---------------------------------------------------------------------------
# スナップショット（1 周回ぶんの集計）
# ---------------------------------------------------------------------------

# 完了扱いしない check run / workflow run の status。GitHub は queued / in_progress の
# ほかに waiting（environment 承認待ち）/ requested / pending を返すことがあるので、
# 「completed 以外はすべて未完了」と裏返しで判定する（新しい状態が増えても壊れない）。
#
# 失敗扱いの conclusion。neutral / skipped / success は失敗にしない（build.yml は
# 条件によってジョブを skip するため、skipped を失敗にすると常に赤になる）。
JQ_SNAPSHOT='
def failed_conclusions: ["failure","cancelled","timed_out","action_required","startup_failure","stale"];

# ci-debug のような手動ディスパッチ実行は「この PR の CI」ではないので数えない。
# 待っている最中に調査用の run を投げたら待機が延びる、という事故を防ぐ。
def ignored_events: ["workflow_dispatch","schedule"];

($runs.workflow_runs // []) as $allruns
| ($allruns | map(select(.event as $e | ignored_events | index($e))) | map(.id | tostring)) as $ignored_ids
| ($allruns | map(select(.event as $e | ignored_events | index($e) | not))) as $wanted_runs
# check run は event を持たないので、html_url に埋まっている run id で紐づけて除外する。
| (($checks.check_runs // []) | map(
      . + {run_id: ((.html_url // "") | [scan("/actions/runs/([0-9]+)")] | (.[0][0] // ""))}
  ) | map(select(.run_id as $r | $r == "" or ($ignored_ids | index($r) | not)))) as $wanted_checks
| ($st.total_count // 0) as $st_total
| ($st.state // "") as $st_state
| {
    items: ($wanted_checks | map({name, status, conclusion})),
    runs: ($wanted_runs | map({name, status, conclusion})),
    total: (($wanted_checks | length) + $st_total),
    pending: (
        ($wanted_checks | map(select(.status != "completed")) | length)
      + ($wanted_runs   | map(select(.status != "completed")) | length)
      + (if $st_total > 0 and $st_state == "pending" then 1 else 0 end)
    ),
    failed: (
        ($wanted_checks | map(select(.conclusion as $c | failed_conclusions | index($c))) | length)
      + (if $st_total > 0 and ($st_state == "failure" or $st_state == "error") then 1 else 0 end)
    ),
    seen: (($wanted_checks | length) + ($wanted_runs | length) + $st_total)
  }
'

# snapshot <sha>: 3 経路をまとめて 1 つの JSON に畳む。API が 1 つでも欠けたら
# 判定せずに次の周回へ回す（「取れなかった」を「終わった」と読み替えない）。
snapshot() {
	local sha="$1" runs checks st
	runs="$(api "$PG_API/actions/runs?head_sha=$sha&per_page=100")" || return 1
	checks="$(api "$PG_API/commits/$sha/check-runs?per_page=100&filter=latest")" || return 1
	st="$(api "$PG_API/commits/$sha/status?per_page=100")" || return 1

	printf '%s' "$runs" | jq -e 'has("workflow_runs")' >/dev/null 2>&1 || return 1
	printf '%s' "$checks" | jq -e 'has("check_runs")' >/dev/null 2>&1 || return 1

	jq -n --argjson runs "$runs" --argjson checks "$checks" --argjson st "$st" "$JQ_SNAPSHOT" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 最終サマリ
# ---------------------------------------------------------------------------

# finish <result> <sha> <snapshot-json> <exit-code>
finish() {
	local result="$1" sha="$2" snap="$3" code="$4"
	echo
	echo "sha=$sha"
	echo "commit_url=https://github.com/$PG_REPO/commit/$sha"
	[ -z "$PR" ] || echo "pr_url=https://github.com/$PG_REPO/pull/$PR"
	if [ -n "$snap" ]; then
		# チェックが 1 件も無いときは workflow run 側を出す（何も出ないと
		# 「取得できなかった」のか「本当に無い」のか区別できないため）。
		printf '%s' "$snap" | jq -r '
			(if (.items | length) > 0 then .items else .runs end)
			| sort_by(.name)[]
			| "  \(.conclusion // .status)\t\(.name)"'
		echo
		printf '%s' "$snap" | jq -r --arg r "$result" --arg s "$sha" \
			'"result=\($r) sha=\($s) total=\(.total) failed=\(.failed) pending=\(.pending)"'
	else
		echo "result=$result sha=$sha total=0 failed=0 pending=0"
	fi
	exit "$code"
}

# ---------------------------------------------------------------------------
# 待機ループ
# ---------------------------------------------------------------------------

started="$(date +%s)"
tracked=""      # いま追っている commit
settled=0       # 「全部 completed」が連続した回数
api_fails=0     # 連続 API 失敗数
last_line=""
snap=""

note "wait-pr-checks: repo=$PG_REPO ${PR:+pr=$PR}${REF:+ref=$REF}${SHA:+sha=$SHA} poll=${POLL}s timeout=${TIMEOUT}s"

while true; do
	elapsed=$(($(date +%s) - started))

	sha=""
	if resolve_sha; then
		sha="$RESOLVED_SHA"
	fi
	if [ -z "$sha" ]; then
		api_fails=$((api_fails + 1))
		# API が続けて落ちるなら待っても無駄。黙って回り続けず 2 で落として気づかせる。
		[ "$api_fails" -lt 10 ] || die "GitHub API に $api_fails 回連続で失敗しました（トークン / ネットワークを確認してください）"
		sleep "$POLL"
		continue
	fi

	if [ "$sha" != "$tracked" ]; then
		if [ -n "$tracked" ]; then
			note "head が更新されました: ${tracked:0:7} → ${sha:0:7}（新しい commit の CI を待ちます）"
			started="$(date +%s)"
			elapsed=0
		fi
		tracked="$sha"
		settled=0
	fi

	# PR が閉じた・merge されたら、その PR の CI を待つ意味はもう無い。
	if [ -n "$PR" ] && [ "$PR_STATE" = "closed" ]; then
		snap="$(snapshot "$sha")"
		if [ "$PR_MERGED" = "true" ]; then
			finish "pr-merged" "$sha" "$snap" 0
		fi
		finish "pr-closed" "$sha" "$snap" 1
	fi

	snap="$(snapshot "$sha")"
	if [ -z "$snap" ]; then
		api_fails=$((api_fails + 1))
		[ "$api_fails" -lt 10 ] || die "GitHub API に $api_fails 回連続で失敗しました（トークン / ネットワークを確認してください）"
		sleep "$POLL"
		continue
	fi
	api_fails=0

	seen="$(printf '%s' "$snap" | jq -r '.seen')"
	pending="$(printf '%s' "$snap" | jq -r '.pending')"
	failed="$(printf '%s' "$snap" | jq -r '.failed')"
	total="$(printf '%s' "$snap" | jq -r '.total')"

	line="checks=$total pending=$pending failed=$failed"
	if [ "$line" != "$last_line" ]; then
		note "${sha:0:7} $line (${elapsed}s)"
		last_line="$line"
	fi

	if [ "$seen" -eq 0 ]; then
		# まだ 1 つも現れていない。GitHub が check suite を作るまで数十秒かかることが
		# あるので少し待つが、いつまでも待たない（ワークフローが無い / トリガ条件から
		# 外れている、という「答え」を返すべき場面なので）。
		if [ "$elapsed" -ge "$START_GRACE" ]; then
			echo "wait-pr-checks: ${START_GRACE}s 待ってもチェックが 1 つも現れませんでした。" >&2
			echo "  ワークフローのトリガ条件から外れている / fork PR で実行が保留されている、などが考えられます。" >&2
			finish "no-checks" "$sha" "$snap" 3
		fi
	elif [ "$pending" -eq 0 ]; then
		# ジョブが増える瞬間（例: build-mac 完了 → release が現れるまでの数秒）に
		# 「全部 completed」に見えることがある。連続で一致するまで確定させない。
		settled=$((settled + 1))
		if [ "$settled" -ge "$SETTLE" ]; then
			if [ "$failed" -eq 0 ]; then
				finish "success" "$sha" "$snap" 0
			fi
			finish "failure" "$sha" "$snap" 1
		fi
	else
		settled=0
	fi

	if [ "$elapsed" -ge "$TIMEOUT" ]; then
		echo "wait-pr-checks: timeout: ${TIMEOUT}s 待っても完了しませんでした（CI はまだ動いているかもしれません）" >&2
		finish "timeout" "$sha" "$snap" 3
	fi

	sleep "$POLL"
done
