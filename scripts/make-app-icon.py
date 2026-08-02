#!/usr/bin/env python3
"""make-app-icon.py — アプリアイコン（packaging/AppIcon.svg / AppIcon.icns）を生成する。

このリポジトリのアイコンは「手で描いた画像」ではなく **このスクリプトが唯一の
原典** になっている。理由は 2 つ:

  - macOS のアイコンは 16px から 1024px までの全サイズが要る。ベクタから焼けば
    どのサイズでも輪郭が揃い、寸法（余白・モチーフの大きさ）を数値で管理できる。
  - `.icns` はバイナリなので diff が読めない。デザインの変更履歴を追える形に
    残すには、寸法と色をコードに置くのが一番確実。

デザインの意図（このリポジトリのアプリが何をするかを 1 枚で示す）:

  - 背景は macOS の標準アイコンに合わせたスーパー楕円（squircle）+ 青のグラデ。
    Big Sur 以降のグリッドに従い、1024px キャンバスの中央 824px を内容領域とする。
  - モチーフは「**同じものの 2 通りの表現**」。奥に写真（2D）、手前に立体（3D）を
    置き、写真の中の平面六角形と、立体（等角投影の立方体）のシルエットを
    **同じ六角形・同じ大きさ**にしてある。「多数の写真 → 1 つの 3D モデル」という
    Object Capture の処理そのものを、形の対応で表す。
  - 立体は具体物にしない（抽象化する）。立方体なら被写体の種類を限定しないし、
    16px でも 3 面の陰影だけで「立体」と読める。

生成物:

  packaging/AppIcon.svg    デザインのプレビュー用（人が見て確認するため）
  packaging/AppIcon.icns   .app に同梱する実体（package-app.sh がコピーする）

使い方（macOS は不要。Linux のコンテナでも走る）:

  pip install cairosvg
  scripts/make-app-icon.py

`.icns` の書き出しは `iconutil`（macOS 専用）に頼らず自前で行う。CI もリモート
セッションも Linux で動くことがあるため、macOS がないと再生成できない構成は
避けている。
"""

from __future__ import annotations

import math
import os
import struct
import sys

CANVAS = 1024.0			# アイコンのキャンバス（最大サイズ）
CENTER = CANVAS / 2
CONTENT = 824.0			# Big Sur 以降のグリッドにおける内容領域（squircle の一辺）

# .icns に入れるサイズと OSType の対。iconutil が iconset から作るものと同じ構成。
# （16/32 は 1x と 2x の両方を要求されるので同じ画素数が複数の型に入る）
ICNS_ENTRIES = [
	("icp4", 16),		# 16pt @1x
	("icp5", 32),		# 32pt @1x
	("ic11", 32),		# 16pt @2x
	("ic12", 64),		# 32pt @2x
	("ic07", 128),		# 128pt @1x
	("ic13", 256),		# 128pt @2x
	("ic08", 256),		# 256pt @1x
	("ic14", 512),		# 256pt @2x
	("ic09", 512),		# 512pt @1x
	("ic10", 1024),		# 512pt @2x
]


def squircle_path(cx: float, cy: float, half: float, n: float = 5.0, steps: int = 288) -> str:
	"""スーパー楕円 |x|^n + |y|^n = 1 のパスを返す（macOS のアイコン形状の近似）。

	角丸長方形ではなく指数 5 のスーパー楕円にしているのは、Dock や Finder に
	並んだときに標準アイコンと輪郭が揃うのがこの形だから。折れ線で近似している
	が 288 分割あれば 1024px でも直線に見えない。
	"""
	pts = []
	for i in range(steps):
		t = 2 * math.pi * i / steps
		ct, st = math.cos(t), math.sin(t)
		x = math.copysign(abs(ct) ** (2.0 / n), ct)
		y = math.copysign(abs(st) ** (2.0 / n), st)
		pts.append((cx + half * x, cy + half * y))
	head = "M %.2f %.2f " % pts[0]
	return head + " ".join("L %.2f %.2f" % p for p in pts[1:]) + " Z"


def hexagon(cx: float, cy: float, r: float) -> list[tuple[float, float]]:
	"""頂点が上にある正六角形。等角投影した立方体のシルエットと同じ形。"""
	return [
		(cx + r * math.cos(math.radians(90 - 60 * k)), cy - r * math.sin(math.radians(90 - 60 * k)))
		for k in range(6)
	]


def points(pts: list[tuple[float, float]]) -> str:
	return " ".join("%.2f,%.2f" % p for p in pts)


def build_svg() -> str:
	"""アイコン 1 枚分の SVG を組み立てる。寸法はすべてここに集約する。"""
	sq = squircle_path(CENTER, CENTER, CONTENT / 2)

	# 写真（2D）: 少し傾けたカード。奥にもう 1 枚薄く重ねて「多数の写真」を示す。
	card_cx, card_cy = 433.0, 414.0
	card_w, card_h = 420.0, 340.0
	card_rot, back_rot = -8.0, -17.0

	# 写真の中身は平面の六角形。立体のシルエットと同寸にして「同じもの」と読ませる。
	flat = hexagon(card_cx, card_cy, 122.0)

	# オブジェクト（3D）: 等角投影の立方体。3 面の明度差だけで立体に見せる。
	cube_cx, cube_cy, cube_r = 663.0, 632.0, 168.0
	v = hexagon(cube_cx, cube_cy, cube_r)
	c = (cube_cx, cube_cy)
	top, right, left = [v[0], v[1], c, v[5]], [v[1], v[2], v[3], c], [v[5], c, v[3], v[4]]

	return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<!-- 自動生成: scripts/make-app-icon.py（直接編集しないこと） -->
<defs>
	<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">
		<stop offset="0" stop-color="#6FB0FF"/>
		<stop offset="0.55" stop-color="#3E6BEA"/>
		<stop offset="1" stop-color="#2438C0"/>
	</linearGradient>
	<radialGradient id="glow" cx="0.5" cy="0.08" r="0.85">
		<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.35"/>
		<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
	</radialGradient>
	<linearGradient id="paper" x1="0" y1="0" x2="0.3" y2="1">
		<stop offset="0" stop-color="#FFFFFF"/>
		<stop offset="1" stop-color="#EDF1F8"/>
	</linearGradient>
	<filter id="motif" x="-30%" y="-30%" width="160%" height="160%">
		<feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#0B1B47" flood-opacity="0.30"/>
	</filter>
	<filter id="body" x="-30%" y="-30%" width="160%" height="160%">
		<feDropShadow dx="0" dy="24" stdDeviation="26" flood-color="#050B22" flood-opacity="0.35"/>
	</filter>
	<clipPath id="content"><path d="{sq}"/></clipPath>
</defs>

<!-- 本体（squircle）。Dock に並べたときの影も含めてキャンバスに収める。 -->
<g filter="url(#body)"><path d="{sq}" fill="url(#bg)"/></g>
<g clip-path="url(#content)"><rect x="0" y="0" width="1024" height="1024" fill="url(#glow)"/></g>
<path d="{sq}" fill="none" stroke="#FFFFFF" stroke-opacity="0.22" stroke-width="3"/>

<!-- 写真（2D）: 奥のカード + 手前のカード。中身は平面の六角形。 -->
<g filter="url(#motif)">
	<g transform="rotate({back_rot} {card_cx} {card_cy})" opacity="0.55">
		<rect x="{card_cx - card_w / 2}" y="{card_cy - card_h / 2}" width="{card_w}" height="{card_h}" rx="30" fill="#FFFFFF"/>
	</g>
	<g transform="rotate({card_rot} {card_cx} {card_cy})">
		<rect x="{card_cx - card_w / 2}" y="{card_cy - card_h / 2}" width="{card_w}" height="{card_h}" rx="30" fill="url(#paper)"/>
		<polygon points="{points(flat)}" fill="#9FBCE6"/>
	</g>
</g>

<!-- オブジェクト（3D）: 写真の六角形と同じシルエットを立体として起こしたもの。 -->
<g filter="url(#motif)">
	<polygon points="{points(top)}" fill="#FFFFFF"/>
	<polygon points="{points(left)}" fill="#C3D7F4"/>
	<polygon points="{points(right)}" fill="#8FAFE2"/>
</g>
</svg>
"""


def build_icns(png_by_size: dict[int, bytes]) -> bytes:
	"""PNG 群を .icns（PNG 埋め込み形式）にまとめる。

	`iconutil` は macOS にしか無いので自前で組む。構造は単純で、'icns' + 全体長の
	ヘッダに続けて「4 バイトの型 + 8 を含む長さ + データ」を並べるだけ。先頭の
	'TOC ' はエントリ一覧（型と長さの繰り返し）で、Finder が全部読まずに必要な
	サイズだけ取り出せるようにするためのもの。
	"""
	entries = [(kind, png_by_size[size]) for kind, size in ICNS_ENTRIES]
	toc = b"".join(kind.encode("ascii") + struct.pack(">I", len(data) + 8) for kind, data in entries)
	blocks = [b"TOC " + struct.pack(">I", len(toc) + 8) + toc]
	blocks += [kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data for kind, data in entries]
	body = b"".join(blocks)
	return b"icns" + struct.pack(">I", len(body) + 8) + body


def main() -> int:
	try:
		import cairosvg
	except ImportError:
		print("error: cairosvg が要ります: pip install cairosvg", file=sys.stderr)
		return 1

	root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
	out_dir = os.path.join(root, "packaging")
	svg = build_svg()

	svg_path = os.path.join(out_dir, "AppIcon.svg")
	with open(svg_path, "w") as f:
		f.write(svg)

	png_by_size: dict[int, bytes] = {}
	for size in sorted({size for _, size in ICNS_ENTRIES}):
		png_by_size[size] = cairosvg.svg2png(
			bytestring=svg.encode("utf-8"), output_width=size, output_height=size
		)

	icns_path = os.path.join(out_dir, "AppIcon.icns")
	with open(icns_path, "wb") as f:
		f.write(build_icns(png_by_size))

	print(f"wrote: {svg_path}")
	print(f"wrote: {icns_path} ({os.path.getsize(icns_path)} bytes, {len(ICNS_ENTRIES)} entries)")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
