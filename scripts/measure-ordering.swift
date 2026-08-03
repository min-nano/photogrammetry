//
//  measure-ordering.swift
//
//  **実装前に測るためのスクリプト**（docs/design-loose-clustering.md §5.1）。
//
//  新しい仕分けの設計は「撮影順に隣り合う写真は重なっている」という**たった 1 つの
//  仮定**に乗っている。この仮定が現場の写真で成り立たなければ設計ごと作り直しに
//  なるので、コードを書く前にここを確かめる。あわせて、提示されたクラスタリング
//  手順の Step 1（feature print の上位 k 件で候補ペアを出す）が成立するかも
//  同じ計算から出る（順位の再現率）。
//
//  **出力は写真そのものを含まない数値だけ**なので、そのまま共有して設計の判断に
//  使える（設計メモ §10-10「写真を共有せずに調整する」）。ファイル名も出さない。
//
//  なぜ本体（photogrammetry-cli）ではなくスクリプトなのか:
//    これは 1 度きりの計測で、製品の入口（APICommand）に語彙を足す話ではない。
//    測った結果で設計が変わるなら、そのときに正式な入口を考える。
//
//  使い方（Object Capture が動く実機で）:
//
//    swiftc -O scripts/measure-ordering.swift -o /tmp/measure-ordering
//    /tmp/measure-ordering ~/Pictures/現場 | tee /tmp/ordering.txt
//
//  **必ず -O を付けて事前コンパイルすること。** `swift scripts/…` の
//  インタプリタ実行は最適化が効かず、全ペアの距離計算が桁で遅くなる。
//
//  オプション:
//    --no-recursive     サブフォルダを走査しない
//    --limit N          撮影順の先頭 N 枚だけで測る（下見用）
//    --max-pairs N      無関係な組の基準を取るための標本数（既定 200000）
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

// ---------------------------------------------------------------------
// 引数
// ---------------------------------------------------------------------

var inputPath: String?
var recursive = true
var limit: Int?
var maxPairs = 200_000
/// 撮影順を N 枚ずつの区間に切って、区間ごとの中身を出す（`--segments N`）。
/// **measure-poses.swift の `--starts` と同じ添字**なので、どの区間が error 6 に
/// なったかと突き合わせられる。
var segments: Int?

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty
{
	let argument = arguments.removeFirst()
	switch argument
	{
		case "--no-recursive":
			recursive = false
		case "--limit":
			limit = arguments.isEmpty ? nil : Int(arguments.removeFirst())
		case "--max-pairs":
			maxPairs = (arguments.isEmpty ? nil : Int(arguments.removeFirst())) ?? maxPairs
		case "--segments":
			segments = arguments.isEmpty ? nil : Int(arguments.removeFirst())
		case "-h", "--help":
			print("使い方: measure-ordering <写真フォルダ> [--no-recursive] [--limit N] [--max-pairs N]")
			exit(0)
		default:
			if argument.hasPrefix("-") || inputPath != nil
			{
				FileHandle.standardError.write(Data("不明な引数: \(argument)\n".utf8))
				exit(2)
			}
			inputPath = argument
	}
}

guard let inputPath
else
{
	FileHandle.standardError.write(Data("使い方: measure-ordering <写真フォルダ> [オプション]\n".utf8))
	exit(2)
}

let root = URL(fileURLWithPath: inputPath, isDirectory: true).standardizedFileURL

@Sendable func log(_ message: String)
{
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}

// ---------------------------------------------------------------------
// 走査（PhotoInspector.imageFiles と同じ規則）
// ---------------------------------------------------------------------

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

/// 仕分け結果として作られるフォルダ。仕分け先を誤って入力に指定したときに
/// 二重取り込みを起こさないよう、本体と同じく除く。
func isReservedFolderName(_ name: String) -> Bool
{
	name == "_excluded" || name == "_unassigned" || name.hasPrefix("group-")
}

func imageFiles(in folder: URL, recursive: Bool) -> [(url: URL, relativePath: String)]
{
	var result: [(url: URL, relativePath: String)] = []
	let manager = FileManager.default

	func scan(_ directory: URL, prefix: String)
	{
		let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
		for name in names.sorted()
		{
			if name.hasPrefix(".")
			{
				continue
			}
			let child = directory.appendingPathComponent(name)
			var isDirectory: ObjCBool = false
			guard manager.fileExists(atPath: child.path, isDirectory: &isDirectory)
			else
			{
				continue
			}
			let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
			if isDirectory.boolValue
			{
				if recursive, !isReservedFolderName(name)
				{
					scan(child, prefix: relative)
				}
			}
			else if imageExtensions.contains((name as NSString).pathExtension.lowercased())
			{
				result.append((child, relative))
			}
		}
	}

	scan(folder.standardizedFileURL, prefix: "")
	return result
}

let files = imageFiles(in: root, recursive: recursive)
guard !files.isEmpty
else
{
	log("画像が 1 枚も見つかりませんでした: \(root.path)")
	exit(2)
}
log("画像 \(files.count) 枚を読み取ります（Vision の推論を含むので数分かかります）")

// ---------------------------------------------------------------------
// 読み取り（EXIF + feature print）
// ---------------------------------------------------------------------

/// 写真 1 枚ぶんの事実。**ファイル名は集計に使うだけで出力しない。**
struct Record
{
	/// 並べ替えの同着を解くためだけに持つ（**出力しない**）。
	/// measure-poses.swift と同じ規則で並べないと、区間の添字が食い違って
	/// 「どの区間が error 6 か」との突き合わせができなくなる。
	var relativePath: String
	var folder: String
	var date: Date?
	var sequence: Int?
	var cameraModel: String?
	var focal35: Double?
	var exposure: Double?
	var hasLocation: Bool
	/// 単位ベクトルへ正規化済みの視覚特徴（FeaturePrint と同じ定義）。
	var elements: [Float]?
	/// ラプラシアン分散（ブレの指標。ImageStatistics と同じ式）。
	var sharpness: Double?
}

/// 並行読み取りの受け皿。スレッドを跨ぐのでロックで守る。
final class Collector: @unchecked Sendable
{
	private let lock = NSLock()
	private var records: [Record?]
	private var done = 0

	init(capacity: Int)
	{
		records = Array(repeating: nil, count: capacity)
	}

	func put(_ record: Record?, at index: Int) -> Int
	{
		lock.lock()
		defer { lock.unlock() }
		records[index] = record
		done += 1
		return done
	}

	func finish() -> [Record?]
	{
		lock.lock()
		defer { lock.unlock() }
		return records
	}
}

/// "+09:00" 形式のオフセットを TimeZone にする（PhotoInspector と同じ）。
@Sendable func timeZone(fromOffset text: String) -> TimeZone?
{
	let trimmed = text.trimmingCharacters(in: .whitespaces)
	guard trimmed.count >= 3, let sign = trimmed.first, sign == "+" || sign == "-"
	else
	{
		return nil
	}
	let digits = trimmed.dropFirst().split(separator: ":")
	guard let hours = Int(digits.first ?? "")
	else
	{
		return nil
	}
	let minutes = digits.count > 1 ? Int(digits[1]) ?? 0 : 0
	let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
	return TimeZone(secondsFromGMT: seconds)
}

/// 撮影時刻。サブ秒まで読むのは、連写だと秒が同じになって順序が崩れるため。
@Sendable func captureDate(exif: [CFString: Any], offset: String?) -> Date?
{
	guard let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
	else
	{
		return nil
	}
	let formatter = DateFormatter()
	formatter.locale = Locale(identifier: "en_US_POSIX")
	formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
	formatter.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? TimeZone.current
	guard let date = formatter.date(from: text)
	else
	{
		return nil
	}
	guard let subsecond = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
		let fraction = Double("0.\(subsecond)")
	else
	{
		return date
	}
	return date.addingTimeInterval(fraction)
}

/// 露出値 EV（ISO 100 換算）。APEX の定義そのまま。
@Sendable func exposureValue(exif: [CFString: Any]) -> Double?
{
	let aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
	let time = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
	let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
	if let aperture, aperture > 0, let time, time > 0
	{
		var value = log2(aperture * aperture / time)
		if let iso = speeds?.first?.doubleValue, iso > 0
		{
			value -= log2(iso / 100)
		}
		return value
	}
	return (exif[kCGImagePropertyExifBrightnessValue] as? NSNumber)?.doubleValue
}

/// ファイル名末尾の連番（PhotoMetadata.sequenceNumber と同じ）。
@Sendable func sequenceNumber(fromName name: String) -> Int?
{
	let stem = (name as NSString).deletingPathExtension
	var digits: [Character] = []
	for character in stem.reversed()
	{
		if character.isNumber
		{
			digits.append(character)
		}
		else if digits.isEmpty
		{
			continue
		}
		else
		{
			break
		}
	}
	guard !digits.isEmpty, digits.count <= 8
	else
	{
		return nil
	}
	return Int(String(digits.reversed()))
}

/// Vision の観測結果を Float の配列へ広げる（FeaturePrinter.elements と同じ）。
@Sendable func elements(of observation: VNFeaturePrintObservation) -> [Float]?
{
	let count = observation.elementCount
	guard count > 0
	else
	{
		return nil
	}
	let data = observation.data
	switch observation.elementType
	{
		case .float:
			let stride = MemoryLayout<Float>.size
			guard data.count >= count * stride
			else
			{
				return nil
			}
			return data.withUnsafeBytes
			{ buffer in
				(0 ..< count).map
				{ index in
					buffer.loadUnaligned(fromByteOffset: index * stride, as: Float.self)
				}
			}
		case .double:
			let stride = MemoryLayout<Double>.size
			guard data.count >= count * stride
			else
			{
				return nil
			}
			return data.withUnsafeBytes
			{ buffer in
				(0 ..< count).map
				{ index in
					Float(buffer.loadUnaligned(fromByteOffset: index * stride, as: Double.self))
				}
			}
		default:
			return nil
	}
}

/// 単位ベクトルへ正規化する。距離を「向きの違い」だけで測るため
/// （FeaturePrint.init と同じ。生の長さは OS のリビジョンで変わりうる）。
@Sendable func normalized(_ values: [Float]) -> [Float]?
{
	guard !values.isEmpty, values.allSatisfy({ $0.isFinite })
	else
	{
		return nil
	}
	var squared = 0.0
	for value in values
	{
		squared += Double(value) * Double(value)
	}
	let length = squared.squareRoot()
	guard length > 0
	else
	{
		return nil
	}
	return values.map { Float(Double($0) / length) }
}

/// 解析用の縮小画像。**320 px は本体（PhotoInspector.thumbnailSize）と同じ。**
/// feature print の入力が 299 四方なので、これより小さいと拡大されてから
/// 特徴を取ることになる（＝測っているものが本体とずれる）。
@Sendable func thumbnail(source: CGImageSource) -> CGImage?
{
	let options: [CFString: Any] = [
		kCGImageSourceCreateThumbnailFromImageAlways: true,
		kCGImageSourceCreateThumbnailWithTransform: true,
		kCGImageSourceThumbnailMaxPixelSize: 320,
	]
	return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

@Sendable func read(url: URL, relativePath: String) -> Record?
{
	guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		CGImageSourceGetCount(source) > 0
	else
	{
		return nil
	}
	let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
	let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
	let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
	let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
	let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String

	let components = relativePath.split(separator: "/")
	let folder = components.count > 1 ? components.dropLast().joined(separator: "/") : ""

	var record = Record(
		relativePath: relativePath,
		folder: folder,
		date: captureDate(exif: exif, offset: offset),
		sequence: sequenceNumber(fromName: (relativePath as NSString).lastPathComponent),
		cameraModel: tiff[kCGImagePropertyTIFFModel] as? String,
		focal35: (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue,
		exposure: exposureValue(exif: exif),
		hasLocation: gps[kCGImagePropertyGPSLatitude] != nil,
		elements: nil)

	if let image = thumbnail(source: source)
	{
		let request = VNGenerateImageFeaturePrintRequest()
		let handler = VNImageRequestHandler(cgImage: image, options: [:])
		if (try? handler.perform([request])) != nil,
			let observation = request.results?.first,
			let values = elements(of: observation)
		{
			record.elements = normalized(values)
		}
		if let gray = grayscale(image: image)
		{
			record.sharpness = laplacianVariance(
				gray: gray.pixels, width: gray.width, height: gray.height)
		}
	}
	return record
}

/// 縮小画像からグレースケール画素を取り出す（PhotoInspector と同じ）。
@Sendable func grayscale(image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)?
{
	let width = image.width
	let height = image.height
	guard width > 0, height > 0,
		let context = CGContext(
			data: nil, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
			bitmapInfo: CGImageAlphaInfo.none.rawValue)
	else
	{
		return nil
	}
	context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
	guard let data = context.data
	else
	{
		return nil
	}
	let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
	var pixels = [UInt8]()
	pixels.reserveCapacity(width * height)
	for row in 0 ..< height
	{
		pixels.append(contentsOf: UnsafeBufferPointer(
			start: bytes + row * context.bytesPerRow, count: width))
	}
	return (pixels, width, height)
}

/// ラプラシアン分散。**ImageStatistics.laplacianVariance と同じ式**にしてある
/// （ここで測った値をそのまま `--min-sharpness` の検討に使えるように）。
@Sendable func laplacianVariance(gray: [UInt8], width: Int, height: Int) -> Double
{
	guard width > 2, height > 2, gray.count >= width * height
	else
	{
		return 0
	}
	var sum = 0.0
	var sumOfSquares = 0.0
	var count = 0
	for y in 1 ..< (height - 1)
	{
		let row = y * width
		let above = row - width
		let below = row + width
		for x in 1 ..< (width - 1)
		{
			let value =
				Double(gray[above + x]) + Double(gray[below + x])
				+ Double(gray[row + x - 1]) + Double(gray[row + x + 1])
				- 4 * Double(gray[row + x])
			sum += value
			sumOfSquares += value * value
			count += 1
		}
	}
	guard count > 0
	else
	{
		return 0
	}
	let mean = sum / Double(count)
	return max(0, sumOfSquares / Double(count) - mean * mean)
}

let collector = Collector(capacity: files.count)
let started = Date()
DispatchQueue.concurrentPerform(iterations: files.count)
{ index in
	let file = files[index]
	let done = collector.put(read(url: file.url, relativePath: file.relativePath), at: index)
	if done % 100 == 0 || done == files.count
	{
		log("  読み取り \(done)/\(files.count)")
	}
}
let readSeconds = Date().timeIntervalSince(started)
let records = collector.finish()

let unreadable = records.filter { $0 == nil }.count
let photos = records.compactMap { $0 }

// ---------------------------------------------------------------------
// 撮影順を決める（設計メモ §3.1 の優先順位）
// ---------------------------------------------------------------------

let withDate = photos.filter { $0.date != nil }
let withSequence = photos.filter { $0.date == nil && $0.sequence != nil }
/// 撮影順に乗らない写真＝隔離の対象（§3.4「異物」）。
let foreign = photos.filter { $0.date == nil && $0.sequence == nil }

enum OrderingSource: String
{
	case exif
	case filename
}

let orderingSource: OrderingSource
var ordered: [Record]
if Double(withDate.count) / Double(max(1, photos.count)) >= 0.3
{
	orderingSource = .exif
	// **同着はパスで解く。** measure-poses.swift と同じ規則で並べないと、
	// 区間の添字が食い違って「どの区間が error 6 か」と突き合わせられない
	// （Swift の sort は安定ではないので、同着を放置すると実行ごとに変わる）。
	ordered = withDate.sorted
	{ left, right in
		let leftDate = left.date ?? .distantPast
		let rightDate = right.date ?? .distantPast
		return leftDate == rightDate
			? left.relativePath < right.relativePath : leftDate < rightDate
	}
}
else
{
	// EXIF 時刻がほとんど無い現場。連番で並べたときにどうなるかを測る。
	orderingSource = .filename
	ordered = photos.filter { $0.sequence != nil }.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
}

if let limit, ordered.count > limit
{
	ordered = Array(ordered.prefix(limit))
}

// 視覚特徴が取れたものだけを距離の対象にする。次元が食い違うものは
// 比べられないので、多数派の次元に揃える（FeaturePrint は「最も遠い」として
// 扱うが、ここは測定なので黙って混ぜずに落として枚数を報告する）。
var dimensionCounts: [Int: Int] = [:]
for record in ordered
{
	if let elements = record.elements
	{
		dimensionCounts[elements.count, default: 0] += 1
	}
}
let dominantDimension = dimensionCounts.max { $0.value < $1.value }?.key ?? 0
/// 撮影順に並んだ、視覚特徴を持つ写真。`position` は撮影順での添字。
let series: [(position: Int, elements: [Float])] = ordered.enumerated().compactMap
{ index, record in
	guard let elements = record.elements, elements.count == dominantDimension
	else
	{
		return nil
	}
	return (index, elements)
}

guard series.count >= 10, dominantDimension > 0
else
{
	log("視覚特徴を持つ写真が少なすぎて測れません（\(series.count) 枚）")
	exit(3)
}

// ---------------------------------------------------------------------
// 距離
// ---------------------------------------------------------------------

let count = series.count
let dimension = dominantDimension
/// 距離計算のために連続した領域へ並べ直す。
var matrix = [Float](repeating: 0, count: count * dimension)
for (index, entry) in series.enumerated()
{
	matrix.replaceSubrange(index * dimension ..< (index + 1) * dimension, with: entry.elements)
}

/// 単位ベクトル同士の距離（0.0〜1.0）。FeaturePrint.distance と同じ定義だが、
/// ‖a-b‖² = 2 - 2(a・b) を使って内積 1 本で求める（全ペアを回すので効く）。
@inline(__always)
@Sendable func distance(
	_ buffer: UnsafePointer<Float>, _ leftIndex: Int, _ rightIndex: Int, _ dimension: Int) -> Double
{
	let left = buffer + leftIndex * dimension
	let right = buffer + rightIndex * dimension
	var dot = 0.0
	for index in 0 ..< dimension
	{
		dot += Double(left[index]) * Double(right[index])
	}
	let squared = max(0, 2 - 2 * dot)
	return min(1, squared.squareRoot() / 2)
}

func percentile(_ sorted: [Double], _ fraction: Double) -> Double
{
	guard !sorted.isEmpty
	else
	{
		return .nan
	}
	let position = fraction * Double(sorted.count - 1)
	let lower = Int(position.rounded(.down))
	let upper = min(sorted.count - 1, lower + 1)
	let weight = position - Double(lower)
	return sorted[lower] * (1 - weight) + sorted[upper] * weight
}

func median(_ values: [Double]) -> Double
{
	percentile(values.sorted(), 0.5)
}

/// 撮影順での隔たり（オフセット）ごとの距離。**1 が「隣り合う組」**で、
/// 大きくするほど無関係な組の水準へ近づくはず。近づく速さが「撮影順が場所を
/// どれだけ反映しているか」そのもので、共有区間の長さの目安にもなる。
let offsets = [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610]
	.filter { $0 < count }
var distancesByOffset: [Int: [Double]] = [:]
matrix.withUnsafeBufferPointer
{ buffer in
	guard let base = buffer.baseAddress
	else
	{
		return
	}
	for offset in offsets
	{
		var values: [Double] = []
		values.reserveCapacity(count - offset)
		for index in 0 ..< (count - offset)
		{
			values.append(distance(base, index, index + offset, dimension))
		}
		distancesByOffset[offset] = values
	}
}

/// 無関係な組の水準。全ペアを回さず標本で足りる（中央値しか使わないため）。
var randomDistances: [Double] = []
matrix.withUnsafeBufferPointer
{ buffer in
	guard let base = buffer.baseAddress
	else
	{
		return
	}
	var state: UInt64 = 0x2545_F491_4F6C_DD1D
	func next(_ bound: Int) -> Int
	{
		state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
		return Int((state >> 33) % UInt64(bound))
	}
	let samples = min(maxPairs, count * (count - 1) / 2)
	randomDistances.reserveCapacity(samples)
	var taken = 0
	while taken < samples
	{
		let left = next(count)
		let right = next(count)
		// **撮影順に近い組は「無関係」ではない**ので基準から外す。
		guard abs(left - right) > max(10, count / 20)
		else
		{
			continue
		}
		randomDistances.append(distance(base, left, right, dimension))
		taken += 1
	}
}

/// 撮影が途切れていない組だけに絞った隣接距離。撮影順で隣でも、そこが
/// 昼休みや別の日をまたいでいれば「隣り合う撮影」ではない。
var continuousNeighbourDistances: [Double] = []
matrix.withUnsafeBufferPointer
{ buffer in
	guard let base = buffer.baseAddress, orderingSource == .exif
	else
	{
		return
	}
	for index in 0 ..< (count - 1)
	{
		let leftDate = ordered[series[index].position].date
		let rightDate = ordered[series[index + 1].position].date
		guard let leftDate, let rightDate, rightDate.timeIntervalSince(leftDate) <= 300
		else
		{
			continue
		}
		continuousNeighbourDistances.append(distance(base, index, index + 1, dimension))
	}
}

// ---------------------------------------------------------------------
// 順位の再現率（提示手順 Step 1 が成立するか）
// ---------------------------------------------------------------------

let topKs = [5, 10, 30, 50]
/// `neighbourOffsets[j]` の隣人が、上位 k 件に入った回数。
let neighbourOffsets = [1, 2, 3]
var hits = [[Int]](repeating: [Int](repeating: 0, count: topKs.count), count: neighbourOffsets.count)
var trials = [Int](repeating: 0, count: neighbourOffsets.count)
var rankSum = [Double](repeating: 0, count: neighbourOffsets.count)

let rankLock = NSLock()
matrix.withUnsafeBufferPointer
{ buffer in
	guard let base = buffer.baseAddress
	else
	{
		return
	}
	DispatchQueue.concurrentPerform(iterations: count)
	{ index in
		var row = [Double](repeating: 0, count: count)
		for other in 0 ..< count
		{
			row[other] = other == index ? -1 : distance(base, index, other, dimension)
		}
		var localHits = [[Int]](
			repeating: [Int](repeating: 0, count: topKs.count), count: neighbourOffsets.count)
		var localTrials = [Int](repeating: 0, count: neighbourOffsets.count)
		var localRankSum = [Double](repeating: 0, count: neighbourOffsets.count)

		for (offsetIndex, offset) in neighbourOffsets.enumerated()
		{
			for neighbour in [index - offset, index + offset]
			{
				guard neighbour >= 0, neighbour < count
				else
				{
					continue
				}
				// 自分より近い相手が何人いるか＝その隣人の順位。
				let target = row[neighbour]
				var rank = 0
				for other in 0 ..< count
				{
					if other != index, row[other] < target
					{
						rank += 1
					}
				}
				localTrials[offsetIndex] += 1
				localRankSum[offsetIndex] += Double(rank + 1)
				for (kIndex, k) in topKs.enumerated() where rank < k
				{
					localHits[offsetIndex][kIndex] += 1
				}
			}
		}

		rankLock.lock()
		for offsetIndex in 0 ..< neighbourOffsets.count
		{
			trials[offsetIndex] += localTrials[offsetIndex]
			rankSum[offsetIndex] += localRankSum[offsetIndex]
			for kIndex in 0 ..< topKs.count
			{
				hits[offsetIndex][kIndex] += localHits[offsetIndex][kIndex]
			}
		}
		rankLock.unlock()
	}
}

// ---------------------------------------------------------------------
// 出力
// ---------------------------------------------------------------------

func histogram(_ values: [Double], bins: Int = 20, width: Int = 40) -> [String]
{
	guard !values.isEmpty
	else
	{
		return ["（該当なし）"]
	}
	var counts = [Int](repeating: 0, count: bins)
	for value in values
	{
		let bin = min(bins - 1, max(0, Int(value * Double(bins))))
		counts[bin] += 1
	}
	let peak = counts.max() ?? 1
	return counts.enumerated().compactMap
	{ index, amount in
		guard amount > 0
		else
		{
			return nil
		}
		let low = Double(index) / Double(bins)
		let high = Double(index + 1) / Double(bins)
		let bar = String(repeating: "█", count: max(1, amount * width / max(1, peak)))
		return String(format: "  %.2f-%.2f %6d %@", low, high, amount, bar)
	}
}

func format(_ value: Double, _ digits: Int = 3) -> String
{
	value.isNaN ? "—" : String(format: "%.\(digits)f", value)
}

/// 端末上の表示幅。**全角は 2 桁**として数える。`String.count` で詰めると
/// 見出しだけ半分の幅になって表が崩れる（実際に崩れた）。
func displayWidth(_ text: String) -> Int
{
	text.unicodeScalars.reduce(0)
	{ total, scalar in
		switch scalar.value
		{
			case 0x1100 ... 0x115F, 0x2E80 ... 0xA4CF, 0xAC00 ... 0xD7A3,
				0xF900 ... 0xFAFF, 0xFE30 ... 0xFE4F, 0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6:
				return total + 2
			default:
				return total + 1
		}
	}
}

/// 右詰めで桁を揃える。`String(format:)` の `%N@` は Darwin では幅指定が効かず、
/// 表が崩れる（実際に崩れたので自前で詰める）。
func pad(_ text: String, _ width: Int) -> String
{
	let current = displayWidth(text)
	return current >= width ? text : String(repeating: " ", count: width - current) + text
}

let randomMedian = median(randomDistances)
let neighbourMedian = median(distancesByOffset[1] ?? [])
let continuousMedian = median(continuousNeighbourDistances)
let ratio = randomMedian > 0 ? neighbourMedian / randomMedian : .nan
let continuousRatio = randomMedian > 0 && !continuousNeighbourDistances.isEmpty
	? continuousMedian / randomMedian : .nan

print("=====================================================================")
print(" 撮影順のバックボーンは意味を持つか（docs/design-loose-clustering.md §5.1）")
print("=====================================================================")
print("")
print("■ 入力")
print("  画像ファイル              \(files.count) 枚（読み取れなかった \(unreadable) 枚）")
print("  視覚特徴が取れた          \(photos.filter { $0.elements != nil }.count) 枚")
print("  特徴ベクトルの次元        \(dimension)"
	+ (dimensionCounts.count > 1 ? "（食い違う次元の写真を除外した）" : ""))
print("  読み取り所要              \(String(format: "%.1f", readSeconds)) 秒")
print("")
print("■ 撮影順（§3.1）")
print("  EXIF 撮影時刻あり         \(withDate.count) 枚")
print("  時刻は無いが連番あり      \(withSequence.count) 枚")
print("  **どちらも無い（異物）**  \(foreign.count) 枚  ← §3.4 の隔離対象")
print("  採用した順序              \(orderingSource.rawValue)")
print("  測定に使った枚数          \(count) 枚")

if orderingSource == .exif
{
	var gaps: [Double] = []
	for index in 1 ..< ordered.count
	{
		guard let previous = ordered[index - 1].date, let current = ordered[index].date
		else
		{
			continue
		}
		gaps.append(current.timeIntervalSince(previous))
	}
	let buckets: [(String, ClosedRange<Double>)] = [
		("     〜2 秒", 0 ... 2),
		("   2〜5 秒", 2 ... 5),
		("  5〜15 秒", 5 ... 15),
		(" 15〜60 秒", 15 ... 60),
		("  1〜5 分", 60 ... 300),
		("  5〜60 分", 300 ... 3600),
		("   60 分〜", 3600 ... .infinity),
	]
	print("")
	print("■ 撮影時刻のギャップ（§3.3 の「切れ目らしさ」の材料）")
	for (label, range) in buckets
	{
		let amount = gaps.filter { range.contains($0) }.count
		print("  \(label)  \(amount) 組")
	}
	print("  → 5 分以上のギャップ \(gaps.filter { $0 >= 300 }.count) 箇所が自然な切れ目の候補")
}

var models: [String: Int] = [:]
var focals: [Int: Int] = [:]
for photo in photos
{
	models[photo.cameraModel ?? "（不明）", default: 0] += 1
	if let focal = photo.focal35
	{
		focals[Int(focal.rounded()), default: 0] += 1
	}
	else
	{
		focals[0, default: 0] += 1
	}
}
print("")
print("■ 機材（§3.4 の現場の事実 1・2）")
for (model, amount) in models.sorted(by: { $0.value > $1.value }).prefix(6)
{
	print("  \(model)  \(amount) 枚")
}
print("  35mm 換算焦点距離: "
	+ focals.sorted { $0.key < $1.key }
		.map { $0.key == 0 ? "無し×\($0.value)" : "\($0.key)mm×\($0.value)" }
		.joined(separator: " "))
print("  GPS あり  \(photos.filter(\.hasLocation).count) 枚")

print("")
print("■ 撮影順の隔たりごとの視覚距離（中央値）")
print("  " + pad("隔たり", 8) + pad("中央値", 9) + pad("25%", 8) + pad("75%", 8) + pad("組数", 9))
for offset in offsets
{
	let values = (distancesByOffset[offset] ?? []).sorted()
	print("  " + pad("\(offset)", 8)
		+ pad(format(percentile(values, 0.5)), 8)
		+ pad(format(percentile(values, 0.25)), 8)
		+ pad(format(percentile(values, 0.75)), 8)
		+ pad("\(values.count)", 9))
}
print("  " + pad("無関係", 8) + pad(format(randomMedian), 8) + pad("", 16)
	+ pad("\(randomDistances.count)", 9))

/// 無関係な組の水準の 90% に達する隔たり＝「そこまで離れると重なりが期待できない」
/// 目安。共有区間はこれより短くしない（§3.2 の重なり率の根拠になる）。
let correlationLength = offsets.first
{
	median(distancesByOffset[$0] ?? []) >= randomMedian * 0.9
}
print("")
print("  無関係の 90% に達する隔たり: "
	+ (correlationLength.map { "\($0) 枚" } ?? "\(offsets.last ?? 0) 枚を超える"))

print("")
print("■ 判定 1: 撮影順は場所の近さを反映しているか")
print("  隣り合う組の中央値 A          \(format(neighbourMedian))")
print("  無関係な組の中央値 B          \(format(randomMedian))")
print("  **比 A/B                      \(format(ratio))**")
if !continuousNeighbourDistances.isEmpty
{
	print("  （時刻ギャップ 5 分以内に限る） \(format(continuousRatio))"
		+ "  \(continuousNeighbourDistances.count) 組")
}
print("  → 0.6 未満なら設計を進めてよい。1.0 に近ければ撮影順は場所と無関係")

print("")
print("■ 判定 2: feature print の「上位 k 件」で候補ペアを出せるか（提示手順 Step 1）")
print("  " + pad("隣人", 6) + pad("平均順位", 11)
	+ topKs.map { pad("上位\($0)", 9) }.joined())
for (offsetIndex, offset) in neighbourOffsets.enumerated()
{
	let attempts = max(1, trials[offsetIndex])
	let rates = topKs.indices.map { Double(hits[offsetIndex][$0]) / Double(attempts) }
	print("  " + pad("±\(offset)", 6)
		+ pad(format(rankSum[offsetIndex] / Double(attempts), 1), 11)
		+ rates.map { pad(format($0, 2), 9) }.joined())
}
// **無作為に選んだ相手でもこの割合は出る**（k 件のうち当たる確率）。上の行と
// 比べられないと「上位 30 に 0.7 入った」を signal と読み違える — 実際に
// 合成サンプル（枚数が少なく k が全体に近い）で 0.73 が出た。
let chance = topKs.map { min(1.0, Double($0) / Double(max(1, count - 1))) }
print("  " + pad("無作為", 6) + pad("\(count / 2)", 11)
	+ chance.map { pad(format($0, 2), 9) }.joined())
print("  → ±1 が「無作為」の行を明確に上回らなければ Step 1 は成立しない")
print("    （目安: 上位30 が 0.5 以上、かつ無作為の 3 倍以上）")

print("")
print("■ 距離の分布（隣り合う組）")
histogram(distancesByOffset[1] ?? []).forEach { print($0) }
print("")
print("■ 距離の分布（無関係な組）")
histogram(randomDistances).forEach { print($0) }

// ---------------------------------------------------------------------
// 区間ごとの中身（--segments）
// ---------------------------------------------------------------------

if let segmentSize = segments, segmentSize > 1
{
	/// 2 枚の視覚距離（次元が違えば nil）。
	func distanceBetween(_ left: [Float]?, _ right: [Float]?) -> Double?
	{
		guard let left, let right, left.count == right.count, !left.isEmpty
		else
		{
			return nil
		}
		var dot = 0.0
		for index in 0 ..< left.count
		{
			dot += Double(left[index]) * Double(right[index])
		}
		return min(1, max(0, 2 - 2 * dot).squareRoot() / 2)
	}

	print("")
	print("■ 区間ごとの中身（\(segmentSize) 枚ごと・**measure-poses の --starts と同じ添字**）")
	print("  start   span(s)  鋭さ中央値   鋭さ下位10%  隣接距離  レンズ  最多レンズ")
	var index = 0
	while index < ordered.count
	{
		let slice = Array(ordered[index ..< min(ordered.count, index + segmentSize)])
		let dates = slice.compactMap(\.date)
		let span = dates.count > 1
			? (dates.max()!.timeIntervalSince(dates.min()!)) : 0
		let sharpnessValues = slice.compactMap(\.sharpness).sorted()
		var neighbourDistances: [Double] = []
		for offset in 1 ..< slice.count
		{
			if let value = distanceBetween(slice[offset - 1].elements, slice[offset].elements)
			{
				neighbourDistances.append(value)
			}
		}
		var lenses: [Int: Int] = [:]
		for photo in slice
		{
			lenses[photo.focal35.map { Int($0.rounded()) } ?? 0, default: 0] += 1
		}
		let top = lenses.max { $0.value < $1.value }
		print(String(
			format: "  %5d %9.0f %11@ %12@ %9@ %6d  %@",
			index, span,
			format(percentile(sharpnessValues, 0.5), 1) as NSString,
			format(percentile(sharpnessValues, 0.1), 1) as NSString,
			format(median(neighbourDistances)) as NSString,
			lenses.count,
			(top.map { $0.key == 0 ? "無し×\($0.value)" : "\($0.key)mm×\($0.value)" } ?? "-")
				as NSString))
		index += segmentSize
	}
	print("  → error 6 になった区間と、鋭さ（ブレ）・隣接距離・レンズ数のどれが")
	print("    対応しているかを見る。**鋭さが低い区間で落ちているなら品質フィルタが効く**")
}

let neighbourRecall = Double(hits[0][2]) / Double(max(1, trials[0]))
/// 無作為でも当たる割合に対する倍率。**割合そのものではなくこの倍率で判断する。**
let recallLift = neighbourRecall / max(0.000_001, chance[2])
let verdict = ratio.isNaN ? "unknown" : (ratio < 0.6 ? "go" : (ratio < 0.8 ? "weak" : "no-go"))
let step1 = neighbourRecall >= 0.5 && recallLift >= 3 ? "ok" : "weak"
print("")
print("result=\(verdict) step1=\(step1) ratio=\(format(ratio))"
	+ " ratio_continuous=\(format(continuousRatio))"
	+ " recall1@30=\(format(neighbourRecall, 2)) lift=\(format(recallLift, 1))"
	+ " ordering=\(orderingSource.rawValue) foreign=\(foreign.count) n=\(count)")
