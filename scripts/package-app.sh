#!/usr/bin/env bash
#
# package-app.sh — SwiftPM のビルド成果物から Photogrammetry.app を組み立てる。
#
# SwiftPM は .app バンドルを作れない（作るのは素の実行ファイルだけ）ので、
# バンドルの組み立てはこのスクリプトが担う。CI（build.yml）とローカルの両方から
# 同じ手順で使えるよう、入力は引数と環境変数だけにしてある。
#
# 使い方:
#   scripts/package-app.sh <ビルド済み実行ファイル> <出力ディレクトリ> [<ヘルパー実行ファイル>]
#
# ヘルパー（photogrammetry-cli）は省略時、アプリ実行ファイルと同じディレクトリ
# から拾う（swift build の成果物は同じ bin ディレクトリに並ぶ）。
#
# 環境変数（省略可。CI がリリースのスタンプとして渡す）:
#   PG_COMMIT        ビルド元コミット（7 桁短縮）      → Info.plist :GitCommit
#   PG_BRANCH        ビルド元ブランチ                  → Info.plist :GitBranch
#   PG_CHANNEL       stable | dev                      → Info.plist :BuildChannel
#   PG_BUILD_NUMBER  CI の連番                         → Info.plist :CFBundleVersion
#
# 例:
#   swift build -c release
#   scripts/package-app.sh .build/release/PhotogrammetryApp dist-app
#
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="${1:?ビルド済みの PhotogrammetryApp 実行ファイルを指定してください}"
OUT="${2:?出力ディレクトリを指定してください}"

[ -f "$BIN" ] || { echo "error: 実行ファイルがありません: $BIN" >&2; exit 1; }

APP="$OUT/Photogrammetry.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Info.plist: テンプレートをコピーしてビルドスタンプを書き込む。
cp packaging/Info.plist "$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "$1" "$APP/Contents/Info.plist"; }
plist "Set :GitCommit ${PG_COMMIT:-unknown}"
plist "Set :GitBranch ${PG_BRANCH:-unknown}"
plist "Set :BuildChannel ${PG_CHANNEL:-unknown}"
plist "Set :BuiltAt $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -n "${PG_BUILD_NUMBER:-}" ]; then
	plist "Set :CFBundleVersion $PG_BUILD_NUMBER"
fi

# 実行ファイル。CFBundleExecutable（Photogrammetry）に合わせてリネームして置く。
cp "$BIN" "$APP/Contents/MacOS/Photogrammetry"
chmod +x "$APP/Contents/MacOS/Photogrammetry"

# 生成用ヘルパー（photogrammetry-cli）を同梱する。GUI は 3D 生成をこの子
# プロセスで走らせる（CorePhotogrammetry は内部エラーで abort() することがあり、
# 同一プロセスだとアプリごと落ちるため）。アプリ本体と同じディレクトリに置く
# 決まりで、探すのは HelperProcessEngine.bundledHelperURL。
CLI="${3:-$(dirname "$BIN")/photogrammetry-cli}"
[ -f "$CLI" ] || {
	echo "error: ヘルパー実行ファイルがありません: $CLI" >&2
	echo "       swift build で photogrammetry-cli もビルドしてください。" >&2
	exit 1
}
cp "$CLI" "$APP/Contents/MacOS/photogrammetry-cli"
chmod +x "$APP/Contents/MacOS/photogrammetry-cli"

# アプリアイコン。Info.plist の CFBundleIconFile（AppIcon）と対で、
# Contents/Resources/AppIcon.icns という名前でなければ Finder / Dock は拾わない。
# 実体は scripts/make-app-icon.py が生成してリポジトリに入っている（.icns は
# バイナリなので、デザインを変えるときはスクリプト側を直して再生成する）。
ICON="packaging/AppIcon.icns"
[ -f "$ICON" ] || {
	echo "error: アイコンがありません: $ICON" >&2
	echo "       scripts/make-app-icon.py で生成してください。" >&2
	exit 1
}
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# 自動アップデートの差し替えスクリプトを同梱する（UpdaterService が
# Contents/Resources/install-update.sh を探す）。
cp scripts/install-update.sh "$APP/Contents/Resources/install-update.sh"
chmod +x "$APP/Contents/Resources/install-update.sh"

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "packaged: $APP"
