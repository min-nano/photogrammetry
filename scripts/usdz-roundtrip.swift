//
//  usdz-roundtrip.swift
//
//  既存の .usdz を SceneKit で読み直して書き出し、その前後で頂点数・面数・
//  マテリアル・テクスチャが失われていないかを比較する検証スクリプト。
//
//  なぜ要るか: 設計メモ §5.5 で合成の出力形態を「SceneKit による単一 usdz」に
//  確定したが、これは SceneKit が作った立方体で確かめた結果でしかない。
//  Object Capture の実出力（高密度メッシュ + PBR テクスチャ）が同じ経路を通っても
//  劣化しないかは未検証で（§10-2）、劣化するなら外部参照方式へ退避する必要がある。
//
//  写真は要らない。既に生成済みのモデルが 1 つあれば確かめられる。
//
//  使い方:
//      swift scripts/usdz-roundtrip.swift <入力.usdz> [出力.usdz]
//
//  出力を Vectorworks なり Preview なりで開いて、見た目も併せて確認すること
//  （数が合っていてもマテリアルの結び付きが壊れることはあるため）。
//

import Foundation
import SceneKit

struct Stats
{
	var nodes = 0
	var geometries = 0
	var vertices = 0
	var primitives = 0
	var materials = 0
	var texturedMaterials = 0

	var description: String
	{
		"""
		  ノード数        : \(nodes)
		  ジオメトリ数    : \(geometries)
		  頂点数          : \(vertices)
		  プリミティブ数  : \(primitives)
		  マテリアル数    : \(materials)
		  うちテクスチャ有: \(texturedMaterials)
		"""
	}
}

/// シーンを走査して規模を数える。往復の前後で比べるためだけのもの。
func collect(_ node: SCNNode, into stats: inout Stats)
{
	stats.nodes += 1
	if let geometry = node.geometry
	{
		stats.geometries += 1
		stats.vertices += geometry.sources(for: .vertex).first?.vectorCount ?? 0
		stats.primitives += geometry.elements.reduce(0) { $0 + $1.primitiveCount }
		for material in geometry.materials
		{
			stats.materials += 1
			// contents は NSImage / CGImage / URL / NSColor などが入る。
			// 色だけのマテリアルと区別したいので、画像系かどうかで判定する。
			switch material.diffuse.contents
			{
				case is NSImage, is CGImage, is URL, is String, is Data:
					stats.texturedMaterials += 1
				default:
					break
			}
		}
	}
	for child in node.childNodes
	{
		collect(child, into: &stats)
	}
}

func stats(of scene: SCNScene) -> Stats
{
	var s = Stats()
	collect(scene.rootNode, into: &s)
	return s
}

// ---------------------------------------------------------------------

let arguments = Array(CommandLine.arguments.dropFirst())
guard let inputPath = arguments.first
else
{
	print("使い方: swift scripts/usdz-roundtrip.swift <入力.usdz> [出力.usdz]")
	exit(2)
}

let inputURL = URL(fileURLWithPath: inputPath)
let outputURL = arguments.count > 1
	? URL(fileURLWithPath: arguments[1])
	: inputURL.deletingPathExtension().appendingPathExtension("roundtrip.usdz")

let before: SCNScene
do
{
	before = try SCNScene(url: inputURL, options: nil)
}
catch
{
	FileHandle.standardError.write(Data("error: 読み込めません: \(error)\n".utf8))
	exit(1)
}

let beforeStats = stats(of: before)
print("== 入力: \(inputURL.lastPathComponent) ==")
print(beforeStats.description)

guard before.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
else
{
	FileHandle.standardError.write(Data("error: 書き出しに失敗しました\n".utf8))
	exit(1)
}

let after: SCNScene
do
{
	after = try SCNScene(url: outputURL, options: nil)
}
catch
{
	FileHandle.standardError.write(Data("error: 書き出したファイルを読み直せません: \(error)\n".utf8))
	exit(1)
}

let afterStats = stats(of: after)
print()
print("== 出力: \(outputURL.lastPathComponent) ==")
print(afterStats.description)

func fileSize(_ url: URL) -> Int
{
	(try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
}

print()
print("== 比較 ==")
print("  ファイルサイズ  : \(fileSize(inputURL)) → \(fileSize(outputURL)) バイト")

var degraded = false
func compare(_ label: String, _ a: Int, _ b: Int)
{
	let mark: String
	if b < a { mark = "← 減っている"; degraded = true }
	else if b > a { mark = "← 増えている" }
	else { mark = "一致" }
	print("  \(label): \(a) → \(b)  \(mark)")
}
compare("頂点数          ", beforeStats.vertices, afterStats.vertices)
compare("プリミティブ数  ", beforeStats.primitives, afterStats.primitives)
compare("マテリアル数    ", beforeStats.materials, afterStats.materials)
compare("テクスチャ有    ", beforeStats.texturedMaterials, afterStats.texturedMaterials)

print()
if degraded
{
	print("結果: 劣化あり。合成の出力は外部参照方式（設計メモ §5.5 案 b）を検討すること。")
}
else
{
	print("結果: 数の上では劣化なし。見た目も Vectorworks 等で確認すること。")
}
