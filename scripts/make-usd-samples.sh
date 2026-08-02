#!/usr/bin/env bash
#
# Vectorworks 取り込み検証用の USD サンプルを生成する（ci-debug の mode=shell 用）。
#
# 確かめたいのは 3 点:
#   1. どの形式なら書き出せるのか（ModelIO は usdz を書けないことが判明したので、
#      SceneKit の write(to:) が使えるかを確かめる）
#   2. 外部参照（scene.usda が別ファイルを references で参照する）を Vectorworks が
#      解決できるか  → 設計 §5.5 の主案が成立するか
#   3. usdz へ書き出したときテクスチャが同梱されるか
#
# 生成物は debug-out/usd-samples/ に出るので、ワークフローのアーティファクトとして
# ダウンロードし、実際に Vectorworks へ取り込んで確認する。
#
set -uo pipefail

OUT="debug-out/usd-samples"
mkdir -p "$OUT"
cd "$OUT" || exit 1

cat > gen.swift <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ModelIO
import SceneKit
import UniformTypeIdentifiers
import simd

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

// -------------------------------------------------------------------
// 1. ModelIO が書き出せる拡張子を列挙する
// -------------------------------------------------------------------
print("== MDLAsset.canExportFileExtension ==")
for ext in ["usd", "usda", "usdc", "usdz", "obj", "ply", "stl", "abc"]
{
	print("  \(ext): \(MDLAsset.canExportFileExtension(ext))")
}

// -------------------------------------------------------------------
// 2. SceneKit で 1 辺 1.0 のテクスチャ付き立方体を作る
//    （metersPerUnit=1 なら Vectorworks 上で 1m 角に見えるはず = スケール確認用）
// -------------------------------------------------------------------
func makeBoxNode(name: String, texture: URL) -> SCNNode
{
	let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
	let material = SCNMaterial()
	material.diffuse.contents = NSImage(contentsOf: texture)
	box.materials = [material]
	let node = SCNNode(geometry: box)
	node.name = name
	return node
}

func writeScene(_ scene: SCNScene, _ name: String)
{
	let url = cwd.appendingPathComponent(name)
	let ok = scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
	print("SCNScene.write \(name): \(ok ? "OK" : "FAILED")")
}

let texA = writePNG("tex_a.png", r: 0.9, g: 0.2, b: 0.2)
let texB = writePNG("tex_b.png", r: 0.2, g: 0.4, b: 0.9)

print()
print("== 個別モデル（各グループの再構成結果に相当） ==")
for (name, tex) in [("box_a", texA), ("box_b", texB)]
{
	let scene = SCNScene()
	scene.rootNode.addChildNode(makeBoxNode(name: name, texture: tex))
	writeScene(scene, name + ".usdz")
}

// ModelIO でも usda を出しておく（参照方式のテキスト版サンプル）。
for (name, tex) in [("box_a", texA), ("box_b", texB)]
{
	let allocator = MDLMeshBufferDataAllocator()
	let mesh = MDLMesh(
		boxWithExtent: SIMD3<Float>(1, 1, 1), segments: SIMD3<UInt32>(1, 1, 1),
		inwardNormals: false, geometryType: .triangles, allocator: allocator)
	mesh.name = name
	let material = MDLMaterial(name: name + "_mat", scatteringFunction: MDLScatteringFunction())
	let sampler = MDLTextureSampler()
	sampler.texture = MDLURLTexture(url: tex, name: name + "_tex")
	material.setProperty(MDLMaterialProperty(
		name: "baseColor", semantic: .baseColor, textureSampler: sampler))
	for case let submesh as MDLSubmesh in mesh.submeshes ?? NSMutableArray()
	{
		submesh.material = material
	}
	let asset = MDLAsset()
	asset.add(mesh)
	do { try asset.export(to: cwd.appendingPathComponent(name + ".usda")) }
	catch { print("MDLAsset export \(name).usda FAILED: \(error)") }
}

// -------------------------------------------------------------------
// 3. 案(a): 1 つのファイルへ埋め込む（SceneKit で変換を適用して結合）
//    box_b にスケール 0.5・Y 軸 45 度・X 方向 3.0 の相似変換を掛ける。
// -------------------------------------------------------------------
let c = Float(0.5 * cos(Double.pi / 4)), s = Float(0.5 * sin(Double.pi / 4))
let transformB = simd_float4x4(
	SIMD4<Float>(c, 0, -s, 0),
	SIMD4<Float>(0, 0.5, 0, 0),
	SIMD4<Float>(s, 0, c, 0),
	SIMD4<Float>(3, 0, 0, 1))

print()
print("== 案(a) 埋め込み方式 ==")
let merged = SCNScene()
merged.rootNode.addChildNode(makeBoxNode(name: "group_a", texture: texA))
let moved = makeBoxNode(name: "group_b", texture: texB)
moved.simdTransform = transformB
merged.rootNode.addChildNode(moved)
writeScene(merged, "scene_flattened.usdz")

// 既存の usdz を読み直して変換を掛けられるか（= 実際の merge と同じ経路）。
print()
print("== 案(a') 既存 usdz を読み直して結合 ==")
let reloaded = SCNScene()
for (name, m) in [("box_a.usdz", matrix_identity_float4x4), ("box_b.usdz", transformB)]
{
	let url = cwd.appendingPathComponent(name)
	guard FileManager.default.fileExists(atPath: url.path)
	else
	{
		print("  \(name) 無し")
		continue
	}
	do
	{
		let node = try SCNScene(url: url, options: nil).rootNode.clone()
		node.simdTransform = m
		reloaded.rootNode.addChildNode(node)
		print("  \(name) 読み込み OK")
	}
	catch
	{
		print("  \(name) 読み込み FAILED: \(error)")
	}
}
writeScene(reloaded, "scene_reloaded.usdz")
SWIFT

echo "== build =="
swiftc -O gen.swift -o gen 2>&1 | head -30
[ -x ./gen ] || { echo "COMPILE FAILED"; exit 1; }
echo
./gen

# 参照先の prim 名は決め打ちせず、実ファイルから取る。
PRIM_A="$(grep -m1 -oE 'def [A-Za-z]+ "[^"]+"' box_a.usda 2>/dev/null | sed 's/.*"\(.*\)"/\1/')"
echo
echo "PRIM_A=$PRIM_A"

# -------------------------------------------------------------------
# 4. 案(b): 外部参照方式。合成結果はこの 1 枚のテキストになる。
#    usdz を参照する版と usda を参照する版の両方を出し、Vectorworks が
#    どちらを解決できるか切り分けられるようにする。
# -------------------------------------------------------------------
write_scene_usda() {
	local out="$1" ext="$2"
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
		echo "        prepend references = @./box_a.$ext@"
		echo '    )'
		echo '    {'
		echo '        matrix4d xformOp:transform = ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) )'
		echo '        uniform token[] xformOpOrder = ["xformOp:transform"]'
		echo '    }'
		echo
		echo '    def Xform "group_b" ('
		echo "        prepend references = @./box_b.$ext@"
		echo '    )'
		echo '    {'
		echo '        matrix4d xformOp:transform = ( (0.35355, 0, -0.35355, 0), (0, 0.5, 0, 0), (0.35355, 0, 0.35355, 0), (3, 0, 0, 1) )'
		echo '        uniform token[] xformOpOrder = ["xformOp:transform"]'
		echo '    }'
		echo '}'
	} > "$out"
	echo "wrote $out"
}

write_scene_usda scene_referenced_usdz.usda usdz
write_scene_usda scene_referenced_usda.usda usda

echo
echo "== usdz の中身（テクスチャが同梱されているか） =="
for z in box_a.usdz scene_flattened.usdz scene_reloaded.usdz; do
	echo "--- $z"
	unzip -l "$z" 2>/dev/null | tail -n +4 | head -12 || echo "  (無し)"
done

echo
echo "== 生成物 =="
ls -la
rm -f gen gen.swift
