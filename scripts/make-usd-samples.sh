#!/usr/bin/env bash
#
# Vectorworks 取り込み検証用の USD サンプルを生成する（ci-debug の mode=shell 用）。
#
# 確かめたいのは 2 点:
#   1. 外部参照（scene.usda が別ファイルの usdz を references で参照する）を
#      Vectorworks が解決できるか  → 設計 §5.5 (b) 主案が成立するか
#   2. ModelIO の usdz 往復でテクスチャが保持されるか → §5.5 (a) 代替案の可否
#
set -uo pipefail

OUT="debug-out/usd-samples"
mkdir -p "$OUT"
cd "$OUT" || exit 1

cat > gen.swift <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import ModelIO
import UniformTypeIdentifiers

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// 目視でスケール・向き・テクスチャの有無が分かるようにチェッカー模様にする。
func writePNG(_ name: String, r: CGFloat, g: CGFloat, b: CGFloat) -> URL
{
	let url = cwd.appendingPathComponent(name)
	let side = 256
	let ctx = CGContext(
		data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
		space: CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	for y in 0 ..< 8
	{
		for x in 0 ..< 8
		{
			let on = (x + y) % 2 == 0
			ctx.setFillColor(red: on ? r : 1, green: on ? g : 1, blue: on ? b : 1, alpha: 1)
			ctx.fill(CGRect(x: x * 32, y: y * 32, width: 32, height: 32))
		}
	}
	let dest = CGImageDestinationCreateWithURL(
		url as CFURL, UTType.png.identifier as CFString, 1, nil)!
	CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
	CGImageDestinationFinalize(dest)
	return url
}

// 1 辺 1.0 の立方体。metersPerUnit=1 なら Vectorworks 上で 1m 角に見えるはず
// （スケール解釈の確認用）。
func makeBox(name: String, texture: URL) -> MDLMesh
{
	let allocator = MDLMeshBufferDataAllocator()
	let mesh = MDLMesh(
		boxWithExtent: SIMD3<Float>(1, 1, 1), segments: SIMD3<UInt32>(1, 1, 1),
		inwardNormals: false, geometryType: .triangles, allocator: allocator)
	mesh.name = name

	let material = MDLMaterial(name: name + "_mat", scatteringFunction: MDLScatteringFunction())
	let sampler = MDLTextureSampler()
	sampler.texture = MDLURLTexture(url: texture, name: name + "_tex")
	material.setProperty(MDLMaterialProperty(
		name: "baseColor", semantic: .baseColor, textureSampler: sampler))
	for case let submesh as MDLSubmesh in mesh.submeshes ?? NSMutableArray()
	{
		submesh.material = material
	}
	return mesh
}

func export(_ asset: MDLAsset, _ name: String)
{
	let url = cwd.appendingPathComponent(name)
	let ext = url.pathExtension
	guard MDLAsset.canExportFileExtension(ext)
	else
	{
		print("EXPORT-UNSUPPORTED \(name)")
		return
	}
	do
	{
		try asset.export(to: url)
		print("EXPORT-OK \(name)")
	}
	catch
	{
		print("EXPORT-FAIL \(name): \(error)")
	}
}

let texA = writePNG("tex_a.png", r: 0.9, g: 0.2, b: 0.2)
let texB = writePNG("tex_b.png", r: 0.2, g: 0.4, b: 0.9)

// --- 個別のモデル（= 各グループの再構成結果に相当）---
for (name, tex) in [("box_a", texA), ("box_b", texB)]
{
	let asset = MDLAsset()
	asset.add(makeBox(name: name, texture: tex))
	export(asset, name + ".usdz")
	export(asset, name + ".usda")   // 参照時の prim 名を知るためのテキスト版
}

// --- 案(a): ModelIO で 1 つに埋め込む（変換を適用）---
// box_b にスケール 0.5・Y 軸 45 度・X 方向 3.0 の相似変換を掛ける。
let merged = MDLAsset()
merged.add(makeBox(name: "box_a", texture: texA))
let moved = makeBox(name: "box_b", texture: texB)
let c = Float(0.5 * cos(Double.pi / 4)), s = Float(0.5 * sin(Double.pi / 4))
moved.transform = MDLTransform(matrix: simd_float4x4(
	SIMD4<Float>(c, 0, -s, 0),
	SIMD4<Float>(0, 0.5, 0, 0),
	SIMD4<Float>(s, 0, c, 0),
	SIMD4<Float>(3, 0, 0, 1)))
merged.add(moved)
export(merged, "scene_flattened.usdz")
SWIFT

echo "== build =="
swiftc -O gen.swift -o gen 2>&1 | head -30 || true
[ -x ./gen ] || { echo "COMPILE FAILED"; exit 1; }
./gen

echo
echo "== box_a.usda の先頭（参照に使う prim 名の確認） =="
head -25 box_a.usda 2>/dev/null

# 参照先の prim 名を実ファイルから取る（決め打ちしない）。
PRIM_A="$(grep -m1 -oE 'def [A-Za-z]+ "[^"]+"' box_a.usda 2>/dev/null | sed 's/.*"\(.*\)"/\1/')"
PRIM_B="$(grep -m1 -oE 'def [A-Za-z]+ "[^"]+"' box_b.usda 2>/dev/null | sed 's/.*"\(.*\)"/\1/')"
echo "PRIM_A=$PRIM_A PRIM_B=$PRIM_B"

# --- 案(b): 外部参照方式。合成結果はこの 1 枚のテキストになる ---
{
	echo '#usda 1.0'
	echo '('
	echo '    defaultPrim = "Site"'
	echo '    metersPerUnit = 1'
	echo '    upAxis = "Y"'
	echo ')'
	echo
	echo 'def Xform "Site"'
	echo '{'
	echo '    def Xform "group_a" ('
	echo "        prepend references = @./box_a.usdz@</$PRIM_A>"
	echo '    )'
	echo '    {'
	echo '        matrix4d xformOp:transform = ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) )'
	echo '        uniform token[] xformOpOrder = ["xformOp:transform"]'
	echo '    }'
	echo
	echo '    def Xform "group_b" ('
	echo "        prepend references = @./box_b.usdz@</$PRIM_B>"
	echo '    )'
	echo '    {'
	echo '        matrix4d xformOp:transform = ( (0.35355, 0, -0.35355, 0), (0, 0.5, 0, 0), (0.35355, 0, 0.35355, 0), (3, 0, 0, 1) )'
	echo '        uniform token[] xformOpOrder = ["xformOp:transform"]'
	echo '    }'
	echo '}'
} > scene_referenced.usda

echo
echo "== usdz の中身（テクスチャが同梱されているか） =="
for z in box_a.usdz scene_flattened.usdz; do
	echo "--- $z"
	unzip -l "$z" 2>/dev/null | tail -n +4 | head -10
done

echo
echo "== 生成物 =="
ls -la
