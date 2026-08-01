#!/usr/bin/env bash
#
# install-update.sh — 自動アップデートの差し替えスクリプト。
#
# 実行中の .app は自分自身を置き換えられないため、アプリ（UpdaterService）が
# このスクリプトを切り離したプロセスとして起動してから終了する。スクリプトは
# アプリの終了を待ち、ステージ済みの新しい .app で置き換えて再起動する。
#
# 原本は scripts/install-update.sh で、パッケージング（scripts/package-app.sh）が
# .app の Contents/Resources へ同梱する。手で実行するものではない。
#
# 使い方: install-update.sh <アプリの PID> <ステージ済み .app> <置き換え先 .app>
#
set -u

PID="${1:?app pid}"
SRC="${2:?staged .app}"
DST="${3:?target .app}"
LOG="${TMPDIR:-/tmp}/photogrammetry-update.log"

{
	echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$PID"
	echo "src=$SRC"
	echo "dst=$DST"

	# アプリの終了を待つ（最大 60 秒。それを過ぎたら強行せず諦める —
	# 実行中のバンドルを消すと動作中のアプリを壊すため）。
	waited=0
	while kill -0 "$PID" 2>/dev/null; do
		if [ "$waited" -ge 120 ]; then
			echo "error: アプリが終了しないため中止します。"
			exit 1
		fi
		sleep 0.5
		waited=$((waited + 1))
	done

	# Gatekeeper: ダウンロード隔離属性を外し、ad-hoc 署名を付け直す
	# （Apple Silicon は署名の無い Mach-O をロードしない）。
	xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true
	codesign --force --deep --sign - "$SRC" 2>/dev/null || true

	rm -rf "$DST"
	if ! mv "$SRC" "$DST" 2>/dev/null; then
		# TMPDIR と置き換え先が別ボリュームだと mv できないので ditto で複製する。
		ditto "$SRC" "$DST" && rm -rf "$SRC"
	fi

	open "$DST"
	echo "done"
} >>"$LOG" 2>&1
