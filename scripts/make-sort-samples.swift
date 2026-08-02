//
//  make-sort-samples.swift
//
//  仕分け（`photogrammetry-cli sort`）の動作確認用に、**EXIF 付きの合成写真**を
//  生成する。現場の実写真は公開できない（docs/design-preprocess-merge.md §10-10）
//  ので、読み取り経路（PhotoInspector = ImageIO / CoreGraphics）を確かめるには
//  こういう合成データが要る。
//
//  純ロジック（グルーピング・品質フィルタ・計画・診断）は swift test が合成
//  メタデータで押さえているが、**EXIF のキーを正しく読めているか**だけは実際の
//  画像ファイルを通さないと分からない。このスクリプトはその穴を埋めるためのもの。
//
//  生成するもの:
//    - 部屋 A 24 枚 → 12 分の移動 → 部屋 B 24 枚（時刻・GPS・方位つき）
//    - 部屋 A には数枚、コントラストのほとんど無い「ブレ相当」を混ぜる
//
//  使い方:
//    swift scripts/make-sort-samples.swift /tmp/sort-samples/photos
//    swift run photogrammetry-cli sort /tmp/sort-samples/photos /tmp/sort-samples/sorted
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2
else
{
	print("使い方: swift scripts/make-sort-samples.swift <出力フォルダ>")
	exit(2)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

/// 2026-08-02 10:00:00 +09:00。時刻を固定して生成を再現可能にする。
let epoch = Date(timeIntervalSince1970: 1_785_632_400)

/// 種ごとに違う模様の画像。`flat` を立てると濃淡がほとんど無くなる
/// （ラプラシアン分散が落ちるので「ブレた写真」の代わりになる）。
func makeImage(seed: Int, flat: Bool) -> CGImage
{
	let width = 900
	let height = 675
	let context = CGContext(
		data: nil,
		width: width,
		height: height,
		bitsPerComponent: 8,
		bytesPerRow: 0,
		space: CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	context.setFillColor(CGColor(red: 0.15, green: 0.16, blue: 0.2, alpha: 1))
	context.fill(CGRect(x: 0, y: 0, width: width, height: height))

	// 線形合同法で種から決定的に矩形をばらまく。隣り合う種は似た絵になるので、
	// 知覚ハッシュ上も「連続撮影」らしくなる。
	var value = UInt64(bitPattern: Int64(seed &* 2_654_435_761))
	if flat
	{
		context.setAlpha(0.05)
	}
	for index in 0 ..< 60
	{
		value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
		context.setFillColor(CGColor(
			red: Double(index % 7) / 7,
			green: Double((index + seed) % 5) / 5,
			blue: Double((seed + index) % 3) / 3,
			alpha: 1))
		context.fill(CGRect(
			x: Double((value >> 33) % 860),
			y: Double((value >> 13) % 620),
			width: 70,
			height: 50))
	}
	return context.makeImage()!
}

func stamp(_ seconds: Int, format: String, utc: Bool) -> String
{
	let formatter = DateFormatter()
	formatter.locale = Locale(identifier: "en_US_POSIX")
	formatter.dateFormat = format
	formatter.timeZone = TimeZone(secondsFromGMT: utc ? 0 : 9 * 3600)
	return formatter.string(from: epoch.addingTimeInterval(Double(seconds)))
}

/// iPhone が書くのと同じ形の EXIF / GPS / TIFF を付けて JPEG を書き出す。
func write(index: Int, seconds: Int, latitude: Double, flat: Bool)
{
	let url = root.appendingPathComponent(String(format: "IMG_%04d.JPG", index))
	let exif: [CFString: Any] = [
		kCGImagePropertyExifDateTimeOriginal:
			stamp(seconds, format: "yyyy:MM:dd HH:mm:ss", utc: false),
		kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
		kCGImagePropertyExifSubsecTimeOriginal: "25",
		kCGImagePropertyExifFNumber: 1.78,
		kCGImagePropertyExifExposureTime: 0.008,
		kCGImagePropertyExifISOSpeedRatings: [400],
		kCGImagePropertyExifFocalLenIn35mmFilm: 26,
		kCGImagePropertyExifLensModel: "iPhone 15 Pro back camera 6.765mm f/1.78",
	]
	let gps: [CFString: Any] = [
		kCGImagePropertyGPSLatitude: latitude,
		kCGImagePropertyGPSLatitudeRef: "N",
		kCGImagePropertyGPSLongitude: 139.7671,
		kCGImagePropertyGPSLongitudeRef: "E",
		kCGImagePropertyGPSAltitude: 12.3,
		kCGImagePropertyGPSAltitudeRef: 0,
		kCGImagePropertyGPSImgDirection: Double((index * 7) % 360),
		kCGImagePropertyGPSImgDirectionRef: "T",
		kCGImagePropertyGPSHPositioningError: 4.5,
		kCGImagePropertyGPSDateStamp: stamp(seconds, format: "yyyy:MM:dd", utc: true),
		kCGImagePropertyGPSTimeStamp: stamp(seconds, format: "HH:mm:ss", utc: true),
	]
	let properties: [CFString: Any] = [
		kCGImagePropertyExifDictionary: exif,
		kCGImagePropertyGPSDictionary: gps,
		kCGImagePropertyTIFFDictionary: [
			kCGImagePropertyTIFFMake: "Apple",
			kCGImagePropertyTIFFModel: "iPhone 15 Pro",
		] as [CFString: Any],
	]
	guard let destination = CGImageDestinationCreateWithURL(
		url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
	else
	{
		print("書き出しに失敗: \(url.path)")
		exit(1)
	}
	CGImageDestinationAddImage(
		destination, makeImage(seed: index, flat: flat), properties as CFDictionary)
	CGImageDestinationFinalize(destination)
}

for offset in 0 ..< 24
{
	write(
		index: offset + 1,
		seconds: offset * 4,
		latitude: 35.6812 + Double(offset) * 0.00002,
		flat: offset % 8 == 3)
}
for offset in 0 ..< 24
{
	write(
		index: offset + 101,
		seconds: 720 + offset * 4,
		latitude: 35.6830 + Double(offset) * 0.00002,
		flat: false)
}

let count = (try? FileManager.default.contentsOfDirectory(atPath: root.path).count) ?? 0
print("\(count) 枚を生成しました: \(root.path)")
