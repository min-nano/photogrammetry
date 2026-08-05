//
//  measure-truth.swift
//
//  **手で作った「理想の仕分け」を基準に、指標と窓を採点するスクリプト**
//  （docs/design-manual-truth.md）。
//
//  #11〜#14 の行き詰まりは、指標を増やしても**どれが当たっているかを判定する
//  基準が無い**ことだった。基準になりうるものは 2 つしかない。
//
//    ・**人が見て分かる「同じ場所」**（全数取れる・安い・幾何の保証は無い）
//    ・**Object Capture の姿勢**（幾何の真実・高い・部分的にしか取れない）
//
//  このスクリプトは 1 つ目を作る手伝いをして、2 つ目へ渡せる形にし、
//  **その基準で既存の指標と窓を採点する**。正解そのものを作るのは人で、
//  ここには自動でラベルを決める仕組みは無い（あったら基準にならない）。
//
//  **正解として作るのは「窓（被覆）」ではなく「場所ラベル」**である。窓は容量と
//  重なり率から機械的に決まるので人が作る意味が無いが、「どの写真とどの写真が
//  同じ場所か」は人にしか言えない。窓の良し悪しはラベルさえあれば計算できる。
//
//  使い方（macOS の実機で。Vision / ImageIO が要る）:
//
//    swiftc -O scripts/measure-truth.swift -o /tmp/measure-truth
//
//    # 1. 下書きを作る（撮影順に N 枚ずつ・写真はハードリンクなので原本は動かない）
//    /tmp/measure-truth ~/Pictures/現場 --truth ~/Desktop/truth --draft 50
//
//    # 2. Finder でフォルダを移動して理想の状態にする（人の作業）
//    #    …終わったら接触シートを作り直して見直す
//    /tmp/measure-truth ~/Pictures/現場 --truth ~/Desktop/truth --sheets
//
//    # 3. 読み戻して採点する
//    /tmp/measure-truth ~/Pictures/現場 --truth ~/Desktop/truth --analyze \
//        --cache ~/Desktop/trial/cache.bin
//
//    # 4. 自動の窓を正解で採点する
//    /tmp/measure-truth ~/Pictures/現場 --truth ~/Desktop/truth \
//        --score ~/Desktop/trial/rounds/003/windows
//
//  **必ず -O を付けて事前コンパイルすること。** 全ペアの距離計算があるので、
//  `swift scripts/…` のインタプリタ実行は桁で遅くなる。
//
//  オプション:
//    --truth DIR        正解のフォルダ（人が触る唯一の場所）。必須
//    --out DIR          道具が書き出す先（既定 <truth> の隣の truth-analysis）
//    --draft N          下書きを作る（撮影順に N 枚ずつ・既定 50）
//    --force            下書きの作り直し（**既存の仕分けを消す**）
//    --sheets           接触シート HTML を作り直す（写真を動かしたあとに）
//    --read             正解を読み戻して truth.tsv / truth-windows/ を書く
//    --analyze          指標の分離能・近傍の質・空似の地図（--read を含む）
//    --score DIR        窓の一覧（window-*.txt）を正解で採点する
//    --hints            見直しの候補を出す（**補助であって正解ではない**）
//    --cache FILE       measure-ordering.swift と**同じ**視覚特徴のキャッシュ
//    --neighbours 12    共視グラフの相互近傍の数（measure-ordering と揃える）
//    --with-dhash       知覚ハッシュも指標として測る（全枚数の再デコードが要る）
//    --anonymous        報告のラベル名を L01… に伏せる（そのまま共有する用）
//    --capacity N       truth-windows/ を N 枚ごとに割る（既定 0 = 割らない）
//    --max-pairs N      分離能を測る組の上限（既定 4000000）
//    --no-recursive     写真フォルダのサブフォルダを走査しない
//    --limit N          撮影順の先頭 N 枚だけで測る（下見用）
//    --download         iCloud Drive の未ダウンロードをまとめて落としてから進む
//
//  **出力の扱い**: `metrics.tsv` / `confusion.tsv` / `score-*.tsv` と画面の表は
//  数値とラベル名だけで、写真もファイル名も含まない（`--anonymous` を付ければ
//  ラベル名も伏せる）ので、そのまま共有して設計の判断に使える。
//  `truth.tsv` / `hints.tsv` / `_sheets/` はファイル名と写真を含む**手元専用**。
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// ---------------------------------------------------------------------
// 引数
// ---------------------------------------------------------------------

var inputPath: String?
var truthPath = ""
var outPath = ""
var draftSize: Int?
var force = false
var makeSheets = false
var doRead = false
var doAnalyze = false
var doHints = false
var scoreDirectory = ""
var cachePath = ""
var neighbourCount = 12
var withDHash = false
var anonymous = false
var truthCapacity = 0
var maxPairs = 4_000_000
var recursive = true
var limit: Int?
var downloadFirst = false

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty
{
	let argument = arguments.removeFirst()

	func value() -> String
	{
		arguments.isEmpty ? "" : arguments.removeFirst()
	}

	switch argument
	{
		case "--truth":
			truthPath = value()
		case "--out":
			outPath = value()
		case "--draft":
			// 枚数は省略できる（`--draft` だけで既定の 50 枚ごと）。
			if let first = arguments.first, let number = Int(first)
			{
				arguments.removeFirst()
				draftSize = number
			}
			else
			{
				draftSize = 50
			}
		case "--force":
			force = true
		case "--sheets":
			makeSheets = true
		case "--read":
			doRead = true
		case "--analyze":
			doAnalyze = true
		case "--hints":
			doHints = true
		case "--score":
			scoreDirectory = value()
		case "--cache":
			cachePath = value()
		case "--neighbours":
			neighbourCount = Int(value()) ?? neighbourCount
		case "--with-dhash":
			withDHash = true
		case "--anonymous":
			anonymous = true
		case "--capacity":
			truthCapacity = Int(value()) ?? truthCapacity
		case "--max-pairs":
			maxPairs = Int(value()) ?? maxPairs
		case "--no-recursive":
			recursive = false
		case "--limit":
			limit = Int(value())
		case "--download":
			downloadFirst = true
		case "-h", "--help":
			print("使い方: measure-truth <写真フォルダ> --truth DIR "
				+ "[--draft 50] [--force] [--sheets] [--read] [--analyze] "
				+ "[--score DIR] [--hints] [--out DIR] [--cache FILE] "
				+ "[--neighbours 12] [--with-dhash] [--anonymous] [--capacity N] "
				+ "[--max-pairs N] [--no-recursive] [--limit N] [--download]")
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

@Sendable func log(_ message: String)
{
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}

guard let inputPath, !truthPath.isEmpty
else
{
	log("使い方: measure-truth <写真フォルダ> --truth DIR [オプション]")
	exit(2)
}

let root = URL(fileURLWithPath: inputPath, isDirectory: true).standardizedFileURL
let truthRoot = URL(fileURLWithPath: truthPath, isDirectory: true).standardizedFileURL
let outRoot = outPath.isEmpty
	? truthRoot.deletingLastPathComponent().appendingPathComponent("truth-analysis", isDirectory: true)
	: URL(fileURLWithPath: outPath, isDirectory: true).standardizedFileURL

// 何もしないまま終わるのがいちばん分かりにくいので、既定の動作を決めておく。
if draftSize == nil, !makeSheets, !doAnalyze, !doHints, scoreDirectory.isEmpty
{
	doRead = true
}
if doAnalyze || doHints || !scoreDirectory.isEmpty
{
	doRead = true
}

// ---------------------------------------------------------------------
// 走査（measure-ordering.swift / PhotoInspector.imageFiles と同じ規則）
// ---------------------------------------------------------------------

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

/// 仕分け結果として作られるフォルダ。入力に混ぜない。
func isReservedFolderName(_ name: String) -> Bool
{
	name == "_excluded" || name == "_unassigned" || name.hasPrefix("group-")
}

func imageFiles(in folder: URL, recursive: Bool, skipping: Set<String>) -> [(url: URL, relativePath: String)]
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
				// **正解のフォルダを入力として拾わない。** ハードリンクなので
				// 中身は同じ写真であり、写真フォルダの下に置かれると 2 度読む。
				if recursive, !isReservedFolderName(name),
					!skipping.contains(child.standardizedFileURL.path)
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

// ---------------------------------------------------------------------
// iCloud Drive の未ダウンロード対策（measure-ordering.swift と同じ）
// ---------------------------------------------------------------------

func isMaterialized(_ url: URL) -> Bool
{
	guard let values = try? url.resourceValues(
		forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
		values.isUbiquitousItem == true
	else
	{
		return true
	}
	switch values.ubiquitousItemDownloadingStatus
	{
		case .some(.current), .some(.downloaded):
			return true
		default:
			return false
	}
}

func ensureMaterialized(_ urls: [URL], download: Bool)
{
	var pending = urls.filter { !isMaterialized($0) }
	guard !pending.isEmpty
	else
	{
		return
	}
	guard download
	else
	{
		log("iCloud Drive にまだ実体の無い写真が \(pending.count)/\(urls.count) 枚あります。")
		log("このまま読むと 1 枚ずつダウンロードが走って**止まったように見えます**。")
		log("  1. --download を付けて実行する（まとめて落として進みます）")
		log("  2. Finder でフォルダを右クリック →「今すぐダウンロード」")
		log("  3. ローカルへコピーしてからそちらを指定する（いちばん速い）")
		exit(4)
	}
	log("iCloud からのダウンロードを開始します（\(pending.count) 枚）")
	for url in pending
	{
		try? FileManager.default.startDownloadingUbiquitousItem(at: url)
	}
	var lastReported = pending.count
	while !pending.isEmpty
	{
		Thread.sleep(forTimeInterval: 2)
		pending = pending.filter { !isMaterialized($0) }
		if pending.count != lastReported
		{
			log("  残り \(pending.count) 枚")
			lastReported = pending.count
		}
	}
	log("ダウンロード完了")
}

// ---------------------------------------------------------------------
// 写真 1 枚ぶんの事実（measure-ordering.swift の Record + 正解に要るもの）
// ---------------------------------------------------------------------

struct Record
{
	var relativePath: String
	var date: Date?
	var sequence: Int?
	var focal35: Double?
	var exposure: Double?
	var latitude: Double?
	var longitude: Double?
	/// 単位ベクトルへ正規化済みの視覚特徴（FeaturePrint と同じ定義）。
	var elements: [Float]?
	var sharpness: Double?
	/// 知覚ハッシュ（`--with-dhash` のときだけ）。
	var hash: UInt64?
}

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

/// 度分秒でも十進でも来るので NSNumber に寄せて読む。南緯・西経は符号にする。
@Sendable func coordinate(_ gps: [CFString: Any], _ key: CFString, _ refKey: CFString,
	negative: String) -> Double?
{
	guard let value = (gps[key] as? NSNumber)?.doubleValue
	else
	{
		return nil
	}
	let reference = gps[refKey] as? String
	return reference == negative ? -value : value
}

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
		else
		{
			break
		}
	}
	guard !digits.isEmpty
	else
	{
		return nil
	}
	return Int(String(digits.reversed()))
}

@Sendable func elements(of observation: VNFeaturePrintObservation) -> [Double]?
{
	let data = observation.data
	switch observation.elementType
	{
		case .float:
			return data.withUnsafeBytes
			{ buffer in
				Array(UnsafeBufferPointer(
					start: buffer.baseAddress?.assumingMemoryBound(to: Float.self),
					count: observation.elementCount)).map(Double.init)
			}
		case .double:
			return data.withUnsafeBytes
			{ buffer in
				Array(UnsafeBufferPointer(
					start: buffer.baseAddress?.assumingMemoryBound(to: Double.self),
					count: observation.elementCount))
			}
		default:
			return nil
	}
}

/// 単位ベクトルへ（FeaturePrint と同じ定義。長さは OS 版で変わりうるので向きだけ見る）。
@Sendable func normalized(_ values: [Double]) -> [Float]?
{
	let length = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
	guard length > 0, length.isFinite
	else
	{
		return nil
	}
	return values.map { Float(Double($0) / length) }
}

/// 解析用の縮小画像。**320 px は本体（PhotoInspector.thumbnailSize）と同じ。**
@Sendable func thumbnail(source: CGImageSource) -> CGImage?
{
	let options: [CFString: Any] = [
		kCGImageSourceCreateThumbnailFromImageAlways: true,
		kCGImageSourceCreateThumbnailWithTransform: true,
		kCGImageSourceThumbnailMaxPixelSize: 320,
	]
	return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

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

/// ラプラシアン分散（ImageStatistics.laplacianVariance と同じ式）。
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

/// difference hash（ImageStatistics.differenceHash と同じ定義。9×8 の横の大小関係）。
@Sendable func differenceHash(gray: [UInt8], width: Int, height: Int) -> UInt64?
{
	guard width >= 9, height >= 8, gray.count >= width * height
	else
	{
		return nil
	}
	// 面積平均で 9×8 へ（ImageStatistics.boxDownsample と同じ考え方）。
	var small = [Double](repeating: 0, count: 9 * 8)
	for y in 0 ..< 8
	{
		let top = y * height / 8
		let bottom = max(top + 1, (y + 1) * height / 8)
		for x in 0 ..< 9
		{
			let left = x * width / 9
			let right = max(left + 1, (x + 1) * width / 9)
			var total = 0.0
			var count = 0
			for row in top ..< bottom
			{
				for column in left ..< right
				{
					total += Double(gray[row * width + column])
					count += 1
				}
			}
			small[y * 9 + x] = count > 0 ? total / Double(count) : 0
		}
	}
	var bits: UInt64 = 0
	for y in 0 ..< 8
	{
		for x in 0 ..< 8
		{
			bits <<= 1
			if small[y * 9 + x] > small[y * 9 + x + 1]
			{
				bits |= 1
			}
		}
	}
	return bits
}

// ---------------------------------------------------------------------
// 視覚特徴の置き場（--cache）
//
// **measure-ordering.swift とまったく同じ形式（MOFPC1）**にしてある。同じ現場を
// 何度も読み直すことになるうえ、片方だけが持っている状態を作ると「どちらの数字を
// 信じるか」が分からなくなるため、1 つのファイルを共用する。
// ---------------------------------------------------------------------

struct CacheEntry
{
	var size: UInt64
	var modified: Double
	var sharpness: Double?
	var elements: [Float]?
}

let cacheMagic = Data("MOFPC1\n".utf8)

@Sendable func fileStamp(_ url: URL) -> (size: UInt64, modified: Double)?
{
	guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
		let size = values.fileSize, let modified = values.contentModificationDate
	else
	{
		return nil
	}
	return (UInt64(size), modified.timeIntervalSince1970)
}

func loadCache(_ path: String, root: URL) -> [String: CacheEntry]
{
	guard !path.isEmpty, let data = FileManager.default.contents(atPath: path),
		data.count > cacheMagic.count, data.prefix(cacheMagic.count) == cacheMagic
	else
	{
		return [:]
	}
	var offset = cacheMagic.count

	func take(_ count: Int) -> Data?
	{
		guard offset + count <= data.count
		else
		{
			return nil
		}
		defer { offset += count }
		return data.subdata(in: (data.startIndex + offset) ..< (data.startIndex + offset + count))
	}

	func takeUInt32() -> UInt32?
	{
		take(4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
	}

	func takeUInt64() -> UInt64?
	{
		take(8).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
	}

	func takeDouble() -> Double?
	{
		take(8).map { $0.withUnsafeBytes { $0.loadUnaligned(as: Double.self) } }
	}

	func takeString() -> String?
	{
		guard let length = takeUInt32(), let bytes = take(Int(length))
		else
		{
			return nil
		}
		return String(data: bytes, encoding: .utf8)
	}

	guard let storedRoot = takeString(), storedRoot == root.path, let count = takeUInt32()
	else
	{
		log("キャッシュは別の写真フォルダのものでした（使わずに読み直します）: \(path)")
		return [:]
	}
	var result: [String: CacheEntry] = [:]
	result.reserveCapacity(Int(count))
	for _ in 0 ..< count
	{
		guard let relativePath = takeString(), let size = takeUInt64(),
			let modified = takeDouble(), let sharpness = takeDouble(),
			let dimension = takeUInt32()
		else
		{
			log("キャッシュが途中で壊れていました（\(result.count) 件まで使います）: \(path)")
			return result
		}
		var elements: [Float]?
		if dimension > 0
		{
			guard let bytes = take(Int(dimension) * 4)
			else
			{
				log("キャッシュが途中で壊れていました（\(result.count) 件まで使います）: \(path)")
				return result
			}
			elements = bytes.withUnsafeBytes
			{ buffer in
				Array(UnsafeBufferPointer(
					start: buffer.baseAddress?.assumingMemoryBound(to: Float.self),
					count: Int(dimension)))
			}
		}
		result[relativePath] = CacheEntry(
			size: size, modified: modified,
			sharpness: sharpness.isNaN ? nil : sharpness, elements: elements)
	}
	return result
}

func saveCache(_ path: String, root: URL, entries: [String: CacheEntry])
{
	guard !path.isEmpty
	else
	{
		return
	}
	var data = cacheMagic

	func append(_ value: UInt32)
	{
		withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
	}

	func append(_ value: UInt64)
	{
		withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
	}

	func append(_ value: Double)
	{
		withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
	}

	func append(_ text: String)
	{
		let bytes = Data(text.utf8)
		append(UInt32(bytes.count))
		data.append(bytes)
	}

	append(root.path)
	append(UInt32(entries.count))
	for (relativePath, entry) in entries.sorted(by: { $0.key < $1.key })
	{
		append(relativePath)
		append(entry.size)
		append(entry.modified)
		append(entry.sharpness ?? Double.nan)
		append(UInt32(entry.elements?.count ?? 0))
		if let elements = entry.elements
		{
			elements.withUnsafeBytes { data.append(contentsOf: $0) }
		}
	}
	let url = URL(fileURLWithPath: path)
	try? FileManager.default.createDirectory(
		at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
	do
	{
		try data.write(to: url, options: .atomic)
	}
	catch
	{
		log("キャッシュを書き出せませんでした（処理は続けます）: \(error.localizedDescription)")
	}
}

// ---------------------------------------------------------------------
// 読み取り
// ---------------------------------------------------------------------

/// **サムネイルが要るか**。接触シートを作るときと、知覚ハッシュを測るときだけ
/// 画素が要る。それ以外はキャッシュがあれば 1 枚もデコードしない。
let needsPixels = makeSheets || (draftSize != nil) || withDHash

// **トップレベルの変数は宣言の順に初期化される**ので、下の関数から参照するものは
// 関数より前に置く（順番を崩すとコンパイルが通らない）。並行して読むので、
// 読み取りの中から触る値は不変（let）にしておく。
let wantsDHash = withDHash
let wantsThumbnails = makeSheets || (draftSize != nil)
let sheetDirectory = truthRoot.appendingPathComponent("_sheets", isDirectory: true)
let thumbnailDirectory = sheetDirectory.appendingPathComponent("thumbs", isDirectory: true)

@Sendable func read(url: URL, relativePath: String, cached: CacheEntry?) -> Record?
{
	guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		CGImageSourceGetCount(source) > 0
	else
	{
		return nil
	}
	let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
	let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
	let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
	let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String

	var record = Record(
		relativePath: relativePath,
		date: captureDate(exif: exif, offset: offset),
		sequence: sequenceNumber(fromName: (relativePath as NSString).lastPathComponent),
		focal35: (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue,
		exposure: exposureValue(exif: exif),
		latitude: coordinate(gps, kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef,
			negative: "S"),
		longitude: coordinate(gps, kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef,
			negative: "W"),
		elements: nil)

	// キャッシュで足りるならデコードしない。**足りるかどうかは要る値で決まる**
	// （知覚ハッシュや接触シートを求められたら、キャッシュがあっても画素が要る）。
	if let cached, !needsPixels
	{
		record.elements = cached.elements
		record.sharpness = cached.sharpness
		return record
	}

	guard let image = thumbnail(source: source)
	else
	{
		record.elements = cached?.elements
		record.sharpness = cached?.sharpness
		return record
	}
	if let cached, cached.elements != nil
	{
		record.elements = cached.elements
		record.sharpness = cached.sharpness
	}
	else
	{
		let request = VNGenerateImageFeaturePrintRequest()
		let handler = VNImageRequestHandler(cgImage: image, options: [:])
		if (try? handler.perform([request])) != nil,
			let observation = request.results?.first,
			let values = elements(of: observation)
		{
			record.elements = normalized(values)
		}
	}
	if let gray = grayscale(image: image)
	{
		if record.sharpness == nil
		{
			record.sharpness = laplacianVariance(
				gray: gray.pixels, width: gray.width, height: gray.height)
		}
		if wantsDHash
		{
			record.hash = differenceHash(
				gray: gray.pixels, width: gray.width, height: gray.height)
		}
	}
	if wantsThumbnails
	{
		writeThumbnail(image: image, relativePath: relativePath)
	}
	return record
}

/// 接触シート用のサムネイル。**縮小画像は読み取りの中で 1 回だけ作る**ので、
/// ここで一緒に書き出してしまう（あとから作り直すと全枚数を読み直すことになる）。
@Sendable func writeThumbnail(image: CGImage, relativePath: String)
{
	let name = thumbnailName(for: relativePath)
	let url = thumbnailDirectory.appendingPathComponent(name)
	guard !FileManager.default.fileExists(atPath: url.path),
		let destination = CGImageDestinationCreateWithURL(
			url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
	else
	{
		return
	}
	CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7]
		as CFDictionary)
	CGImageDestinationFinalize(destination)
}

@Sendable func thumbnailName(for relativePath: String) -> String
{
	// 相対パスをそのままファイル名にする（`/` は使えないので置き換える）。
	// **写真とサムネイルの対応が目で追える**ほうが、見直しのときに効く。
	let flattened = relativePath.replacingOccurrences(of: "/", with: "_")
	return (flattened as NSString).deletingPathExtension + ".jpg"
}

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

let files = imageFiles(in: root, recursive: recursive, skipping: [truthRoot.path])
guard !files.isEmpty
else
{
	log("画像が 1 枚も見つかりませんでした: \(root.path)")
	exit(2)
}
ensureMaterialized(files.map(\.url), download: downloadFirst)

if needsPixels
{
	try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
}
try? FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)

log("画像 \(files.count) 枚を読み取ります"
	+ (needsPixels ? "（デコードを伴うので数分かかります）" : "（キャッシュがあれば数秒）"))

let cacheBefore = loadCache(cachePath, root: root)
let collector = Collector(capacity: files.count)
let readLock = NSLock()
var reusedCount = 0
var freshStamps = [String: (size: UInt64, modified: Double)]()
DispatchQueue.concurrentPerform(iterations: files.count)
{ index in
	let file = files[index]
	let stamp = fileStamp(file.url)
	var hit: CacheEntry?
	if let stamp, let entry = cacheBefore[file.relativePath],
		entry.size == stamp.size, abs(entry.modified - stamp.modified) < 0.001
	{
		hit = entry
	}
	let record = read(url: file.url, relativePath: file.relativePath, cached: hit)
	readLock.lock()
	if hit?.elements != nil
	{
		reusedCount += 1
	}
	if let stamp, record != nil
	{
		freshStamps[file.relativePath] = stamp
	}
	readLock.unlock()
	let done = collector.put(record, at: index)
	if done % 200 == 0 || done == files.count
	{
		log("  読み取り \(done)/\(files.count)")
	}
}
let records = collector.finish()
let photos = records.compactMap { $0 }

if !cachePath.isEmpty
{
	var entries: [String: CacheEntry] = [:]
	for record in photos
	{
		guard let stamp = freshStamps[record.relativePath]
		else
		{
			continue
		}
		entries[record.relativePath] = CacheEntry(
			size: stamp.size, modified: stamp.modified,
			sharpness: record.sharpness, elements: record.elements)
	}
	saveCache(cachePath, root: root, entries: entries)
	log("視覚特徴のキャッシュ: 再利用 \(reusedCount) 枚 / 読み直し "
		+ "\(files.count - reusedCount) 枚（\(cachePath)）")
}

// ---------------------------------------------------------------------
// 撮影順（measure-ordering.swift / measure-poses.swift と同じ規則）
//
// **添字を揃えることが目的**で、揃っていないと「窓 3 の error 6」と
// 「区間 3 の中身」が別のものを指してしまう。
// ---------------------------------------------------------------------

let withDate = photos.filter { $0.date != nil }
var ordered: [Record]
let orderingSource: String
if Double(withDate.count) / Double(max(1, photos.count)) >= 0.3
{
	orderingSource = "EXIF 撮影時刻"
	ordered = withDate.sorted
	{ left, right in
		let leftDate = left.date ?? .distantPast
		let rightDate = right.date ?? .distantPast
		return leftDate == rightDate
			? left.relativePath < right.relativePath : leftDate < rightDate
	}
	// 時刻を持たない写真も**落とさずに**末尾へ付ける。正解は全数に付けたいので、
	// 並べ替えの都合で写真が消えてはいけない。
	ordered += photos.filter { $0.date == nil }
		.sorted { $0.relativePath < $1.relativePath }
}
else
{
	orderingSource = "ファイル名の連番"
	ordered = photos.sorted
	{ left, right in
		let leftKey = left.sequence ?? Int.max
		let rightKey = right.sequence ?? Int.max
		return leftKey == rightKey
			? left.relativePath < right.relativePath : leftKey < rightKey
	}
}
if let limit, ordered.count > limit
{
	ordered = Array(ordered.prefix(limit))
}

/// 撮影順での添字。**この添字がすべての出力の共通語**になる。
var positionOf: [String: Int] = [:]
for (index, record) in ordered.enumerated()
{
	positionOf[record.relativePath] = index
}

log("撮影順: \(orderingSource)（\(ordered.count) 枚）")

// ---------------------------------------------------------------------
// 正解フォルダの規約
//
//   <truth>/001-玄関/        場所ラベル 1 つ。先頭の数字が**現地を歩く順**
//   <truth>/002-廊下/        （隣接の判定に使う。数字が無ければ名前順）
//   <truth>/_除外/           使わない写真（ブレ・的外れ）
//   <truth>/_不明/           人が判断できなかった写真（**黙って混ぜない**）
//   <truth>/_sheets/         接触シート（道具が作る。人は触らない）
//
// **1 枚の写真を 2 つのラベルへ入れてよい**（戸口の写真など）。ハードリンクなので
// 複製してもディスクは増えない。仕分けの正解は分割ではなく被覆なので、
// 「どちらにも属する」は正しい状態である。
//
// 写真の同一性は **inode**（ハードリンクの相手）で見る。名前を変えても、
// フォルダを掘っても、正しく元の写真へ戻る。inode で引けなかったときだけ
// ファイル名で照合し、**その件数を必ず報告する**（黙って取り違えないため）。
// ---------------------------------------------------------------------

struct TruthLabel
{
	var name: String
	/// 現地を歩く順（フォルダ名の先頭の数字）。隣接ラベルの判定に使う。
	var order: Int
	/// `ordered` の添字。
	var members: [Int] = []
}

/// ラベル名から表示名を作る（`--anonymous` なら伏せる）。
func displayName(_ index: Int, _ name: String) -> String
{
	anonymous ? String(format: "L%02d", index + 1) : name
}

func leadingNumber(_ name: String) -> Int?
{
	var digits = ""
	for character in name
	{
		if character.isNumber
		{
			digits.append(character)
		}
		else
		{
			break
		}
	}
	return digits.isEmpty ? nil : Int(digits)
}

/// 下書きが付ける接頭辞（`0123_IMG_4567.JPG`）を外す。
func strippedName(_ name: String) -> String
{
	guard let underscore = name.firstIndex(of: "_"),
		name[name.startIndex ..< underscore].allSatisfy({ $0.isNumber }),
		underscore > name.startIndex
	else
	{
		return name
	}
	return String(name[name.index(after: underscore)...])
}

/// ファイルの識別子（デバイス番号 + inode）。ハードリンクなら原本と一致する。
func identity(ofFile url: URL) -> String?
{
	guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
		let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
		let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
	else
	{
		return nil
	}
	return "\(device):\(inode)"
}

/// 正解フォルダを読んだ結果。
struct Truth
{
	var labels: [TruthLabel] = []
	/// `ordered` の添字 → 属するラベルの添字（複数可）。
	var labelsOfPhoto: [[Int]] = []
	var excluded: Set<Int> = []
	var unknown: Set<Int> = []
	/// 元の写真へ辿れなかった正解フォルダの中身（**必ず報告する**）。
	var strayFiles: [String] = []
	var matchedByIdentity = 0
	var matchedByName = 0
}

func readTruth() -> Truth
{
	var identityToIndex: [String: Int] = [:]
	var nameToIndices: [String: [Int]] = [:]
	for file in files
	{
		guard let position = positionOf[file.relativePath]
		else
		{
			continue
		}
		if let key = identity(ofFile: file.url)
		{
			identityToIndex[key] = position
		}
		let name = (file.relativePath as NSString).lastPathComponent
		nameToIndices[name, default: []].append(position)
	}

	var truth = Truth()
	truth.labelsOfPhoto = Array(repeating: [], count: ordered.count)

	let manager = FileManager.default
	guard let entries = try? manager.contentsOfDirectory(atPath: truthRoot.path)
	else
	{
		log("正解フォルダがありません: \(truthRoot.path)")
		log("  まず --draft で下書きを作ってください。")
		exit(3)
	}

	/// 1 つのフォルダの下にある画像を全部集める（掘ってよい）。
	func collect(_ directory: URL) -> [URL]
	{
		var result: [URL] = []
		let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
		for name in names.sorted() where !name.hasPrefix(".")
		{
			let child = directory.appendingPathComponent(name)
			var isDirectory: ObjCBool = false
			guard manager.fileExists(atPath: child.path, isDirectory: &isDirectory)
			else
			{
				continue
			}
			if isDirectory.boolValue
			{
				result += collect(child)
			}
			else if imageExtensions.contains((name as NSString).pathExtension.lowercased())
			{
				result.append(child)
			}
		}
		return result
	}

	/// 正解フォルダの 1 ファイルを、元の写真の添字へ戻す。
	func resolve(_ url: URL) -> Int?
	{
		if let key = identity(ofFile: url), let index = identityToIndex[key]
		{
			truth.matchedByIdentity += 1
			return index
		}
		let name = strippedName(url.lastPathComponent)
		if let candidates = nameToIndices[name], candidates.count == 1
		{
			truth.matchedByName += 1
			return candidates[0]
		}
		truth.strayFiles.append(url.lastPathComponent)
		return nil
	}

	var labelDirectories: [(name: String, url: URL)] = []
	var looseFiles = 0
	for name in entries.sorted() where !name.hasPrefix(".")
	{
		let child = truthRoot.appendingPathComponent(name)
		var isDirectory: ObjCBool = false
		guard manager.fileExists(atPath: child.path, isDirectory: &isDirectory)
		else
		{
			continue
		}
		guard isDirectory.boolValue
		else
		{
			if imageExtensions.contains((name as NSString).pathExtension.lowercased())
			{
				looseFiles += 1
			}
			continue
		}
		switch name
		{
			case "_sheets":
				continue
			case "_除外", "_excluded":
				for url in collect(child)
				{
					if let index = resolve(url)
					{
						truth.excluded.insert(index)
					}
				}
			case "_不明", "_unknown":
				for url in collect(child)
				{
					if let index = resolve(url)
					{
						truth.unknown.insert(index)
					}
				}
			default:
				if name.hasPrefix("_")
				{
					log("知らない特別フォルダは無視します: \(name)")
					continue
				}
				labelDirectories.append((name, child))
		}
	}

	if looseFiles > 0
	{
		log("**\(looseFiles) 枚が正解フォルダの直下に置かれています**"
			+ "（どのラベルにも入っていない扱いになります）")
	}

	// 先頭の数字を歩く順として読む。数字が無いものは名前順で後ろへ回す。
	var withOrder: [(order: Int, name: String, url: URL)] = []
	for (offset, entry) in labelDirectories.enumerated()
	{
		withOrder.append((leadingNumber(entry.name) ?? (100_000 + offset), entry.name, entry.url))
	}
	withOrder.sort { $0.order == $1.order ? $0.name < $1.name : $0.order < $1.order }

	for entry in withOrder
	{
		var label = TruthLabel(name: entry.name, order: entry.order)
		let labelIndex = truth.labels.count
		for url in collect(entry.url)
		{
			guard let index = resolve(url)
			else
			{
				continue
			}
			label.members.append(index)
			if !truth.labelsOfPhoto[index].contains(labelIndex)
			{
				truth.labelsOfPhoto[index].append(labelIndex)
			}
		}
		label.members = Array(Set(label.members)).sorted()
		truth.labels.append(label)
	}
	return truth
}

// ---------------------------------------------------------------------
// 下書き（--draft N）
//
// **種は撮影順の等分にする。** 自動の窓（measure-ordering の出力）から始めると
// 正解がその手法へ引きずられ、採点の基準にならない。撮影順は「人が実際に歩いた
// 順」なので、いちばん近く、いちばん偏りが少ない出発点になる。
//
// 写真は**ハードリンク**で置く。原本は 1 バイトも動かず、ディスクも増えず、
// Finder で自由に動かせる。
// ---------------------------------------------------------------------

func makeDraft(size: Int)
{
	let manager = FileManager.default
	var existing: [String] = []
	if let entries = try? manager.contentsOfDirectory(atPath: truthRoot.path)
	{
		existing = entries.filter { !$0.hasPrefix(".") && $0 != "_sheets" }
	}
	if !existing.isEmpty, !force
	{
		log("正解フォルダには既に \(existing.count) 個の項目があります: \(truthRoot.path)")
		log("**作り直すと手で動かした結果が消えます。** 本当に作り直すなら --force を付けてください。")
		exit(3)
	}
	if !existing.isEmpty
	{
		log("--force: 既存の \(existing.count) 個を消して作り直します（_sheets は残します）")
		for name in existing
		{
			try? manager.removeItem(at: truthRoot.appendingPathComponent(name))
		}
	}
	try? manager.createDirectory(at: truthRoot, withIntermediateDirectories: true)

	var urlOf: [String: URL] = [:]
	for file in files
	{
		urlOf[file.relativePath] = file.url
	}

	var linked = 0
	var copied = 0
	let folderCount = (ordered.count + size - 1) / size
	for folder in 0 ..< folderCount
	{
		let directory = truthRoot.appendingPathComponent(String(format: "%03d", folder + 1),
			isDirectory: true)
		try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
		for position in (folder * size) ..< min(ordered.count, (folder + 1) * size)
		{
			guard let source = urlOf[ordered[position].relativePath]
			else
			{
				continue
			}
			// **撮影順の番号を頭に付ける。** Finder の名前順がそのまま撮影順に
			// なるので、境界をどこへ動かすかを目で決められる。
			let name = String(format: "%04d_%@", position, source.lastPathComponent)
			let destination = directory.appendingPathComponent(name)
			do
			{
				try manager.linkItem(at: source, to: destination)
				linked += 1
			}
			catch
			{
				// 別のボリュームだとハードリンクは張れない。**黙って諦めない。**
				do
				{
					try manager.copyItem(at: source, to: destination)
					copied += 1
				}
				catch
				{
					log("置けませんでした: \(name) — \(error.localizedDescription)")
				}
			}
		}
	}
	log("下書きを作りました: \(folderCount) フォルダ・"
		+ "ハードリンク \(linked) 枚" + (copied > 0 ? "・複製 \(copied) 枚" : ""))
	if copied > 0
	{
		log("**\(copied) 枚はハードリンクにできず複製しました**（別ボリューム）。"
			+ "読み戻しはファイル名の照合になります。")
	}
}

// ---------------------------------------------------------------------
// 接触シート（--sheets）
//
// 1424 枚を Finder だけで見比べるのは現実的でないので、**1 ページで一望できる
// 形**を作る。3 種類あって、それぞれ違う間違いを見つけるためのもの。
//
//   index.html     ラベルの一覧（枚数・撮影順の塊）… 分けすぎ・混ぜすぎを見る
//   folder-*.html  ラベル 1 つの中身（撮影順）    … 迷い込みを見る
//   sequence.html  全部を撮影順に並べたもの        … **再訪と境界**を見る
// ---------------------------------------------------------------------

func escapeHTML(_ text: String) -> String
{
	text.replacingOccurrences(of: "&", with: "&amp;")
		.replacingOccurrences(of: "<", with: "&lt;")
		.replacingOccurrences(of: ">", with: "&gt;")
		.replacingOccurrences(of: "\"", with: "&quot;")
}

func safeFileName(_ text: String) -> String
{
	String(text.map { $0 == "/" || $0 == ":" ? "_" : $0 })
}

/// 撮影順の「塊」の数（measure-ordering.swift と同じ規則。間が 10 を超えたら切る）。
func runs(of positions: [Int]) -> [Int]
{
	let sorted = positions.sorted()
	var result: [Int] = []
	var current = 0
	for (order, value) in sorted.enumerated()
	{
		if order > 0, value - sorted[order - 1] > 10
		{
			result.append(current)
			current = 0
		}
		current += 1
	}
	if current > 0
	{
		result.append(current)
	}
	return result
}

let sheetStyle = """
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body { font-family: -apple-system, sans-serif; margin: 16px; background: #fff; color: #111; }
h1 { font-size: 18px; } h2 { font-size: 15px; margin-top: 24px; }
.grid { display: flex; flex-wrap: wrap; gap: 6px; }
figure { margin: 0; width: 160px; font-size: 10px; word-break: break-all; }
figure img { width: 160px; height: 120px; object-fit: cover; border: 3px solid #ccc; }
figure.gap img { border-color: #d33; }
figure.multi img { border-color: #38c; }
table { border-collapse: collapse; font-size: 13px; }
td, th { border: 1px solid #ccc; padding: 3px 8px; text-align: right; }
th:first-child, td:first-child { text-align: left; }
.note { color: #666; font-size: 12px; }
</style>
"""

func figure(for index: Int, truth: Truth, gap: Bool) -> String
{
	let record = ordered[index]
	let thumb = "thumbs/" + thumbnailName(for: record.relativePath)
	let labels = truth.labelsOfPhoto[index]
	var classes: [String] = []
	if gap
	{
		classes.append("gap")
	}
	if labels.count > 1
	{
		classes.append("multi")
	}
	var caption = String(format: "#%04d", index)
	caption += "<br>" + escapeHTML((record.relativePath as NSString).lastPathComponent)
	return "<figure class=\"\(classes.joined(separator: " "))\">"
		+ "<img src=\"\(escapeHTML(thumb))\" loading=\"lazy\">"
		+ "<figcaption>\(caption)</figcaption></figure>"
}

func writeSheets(truth: Truth)
{
	let manager = FileManager.default
	try? manager.createDirectory(at: sheetDirectory, withIntermediateDirectories: true)

	// --- ラベルごと ---
	var indexRows: [String] = []
	for (labelIndex, label) in truth.labels.enumerated()
	{
		let name = displayName(labelIndex, label.name)
		let file = "folder-" + safeFileName(label.name) + ".html"
		let members = label.members.sorted()
		var body = "<h1>\(escapeHTML(name))（\(members.count) 枚）</h1>"
		body += "<p class=\"note\">撮影順に並べてあります。"
			+ "**赤枠は撮影順が飛んでいるところ**（別の機会に撮った＝再訪かもしれない）。"
			+ "青枠は 2 つ以上のラベルに入れてある写真。</p>"
		body += "<p><a href=\"index.html\">← 一覧へ</a>　<a href=\"sequence.html\">撮影順で見る</a></p>"
		body += "<div class=\"grid\">"
		for (order, index) in members.enumerated()
		{
			let gap = order > 0 && index - members[order - 1] > 10
			body += figure(for: index, truth: truth, gap: gap)
		}
		body += "</div>"
		try? ("<!doctype html><title>\(escapeHTML(name))</title>" + sheetStyle + body)
			.write(to: sheetDirectory.appendingPathComponent(file), atomically: true, encoding: .utf8)

		let chunks = runs(of: members)
		indexRows.append("<tr><td><a href=\"\(escapeHTML(file))\">\(escapeHTML(name))</a></td>"
			+ "<td>\(members.count)</td><td>\(chunks.count)</td>"
			+ "<td>\(chunks.max() ?? 0)</td></tr>")
	}

	// --- 一覧 ---
	let assigned = truth.labelsOfPhoto.filter { !$0.isEmpty }.count
	let unassigned = ordered.count - assigned - truth.excluded.count - truth.unknown.count
	var index = "<h1>正解の一覧（\(truth.labels.count) ラベル）</h1>"
	index += "<p class=\"note\">写真 \(ordered.count) 枚 ／ ラベル付き \(assigned) 枚 ／ "
		+ "除外 \(truth.excluded.count) 枚 ／ 不明 \(truth.unknown.count) 枚 ／ "
		+ "**未仕分け \(unassigned) 枚**</p>"
	index += "<p><a href=\"sequence.html\">撮影順で全部を見る</a></p>"
	index += "<table><tr><th>ラベル</th><th>枚数</th><th>撮影順の塊</th><th>最大の塊</th></tr>"
		+ indexRows.joined() + "</table>"
	index += "<p class=\"note\">**塊が多いラベルは、別の場所を混ぜている疑い**があります"
		+ "（再訪でも 2〜3 で収まるのが普通）。</p>"
	try? ("<!doctype html><title>正解の一覧</title>" + sheetStyle + index)
		.write(to: sheetDirectory.appendingPathComponent("index.html"),
			atomically: true, encoding: .utf8)

	// --- 撮影順に全部 ---
	var sequence = "<h1>撮影順（\(ordered.count) 枚）</h1>"
	sequence += "<p class=\"note\">**ラベルが変わるところで見出しが入ります。**"
		+ "同じ場所へ戻ってきた撮影は、離れた位置に同じラベルが再び現れる形で見えます。</p>"
	sequence += "<p><a href=\"index.html\">← 一覧へ</a></p>"
	var previousKey = ""
	var open = false
	for position in 0 ..< ordered.count
	{
		let labels = truth.labelsOfPhoto[position]
		let key = labels.isEmpty
			? (truth.excluded.contains(position) ? "_除外"
				: (truth.unknown.contains(position) ? "_不明" : "未仕分け"))
			: labels.map { displayName($0, truth.labels[$0].name) }.joined(separator: "+")
		if key != previousKey
		{
			if open
			{
				sequence += "</div>"
			}
			sequence += "<h2>\(escapeHTML(key))　<span class=\"note\">#\(position) から</span></h2>"
			sequence += "<div class=\"grid\">"
			previousKey = key
			open = true
		}
		sequence += figure(for: position, truth: truth, gap: false)
	}
	if open
	{
		sequence += "</div>"
	}
	try? ("<!doctype html><title>撮影順</title>" + sheetStyle + sequence)
		.write(to: sheetDirectory.appendingPathComponent("sequence.html"),
			atomically: true, encoding: .utf8)

	log("接触シート: \(sheetDirectory.appendingPathComponent("index.html").path)")
}

// ---------------------------------------------------------------------
// 読み戻しの書き出し（--read）
//
//   truth.tsv        写真 1 枚 1 行（**ファイル名を含むので手元専用**）
//   truth-windows/   **正解フォルダをそのまま Object Capture へ投げる一覧**。
//                    measure-poses.swift --window-dir へ渡せる形にしてある。
//
// 2 つ目が要点で、これがあると「人が同じ場所だと思ったものは、本当に 1 回の
// 再構成で繋がるのか」を測れる。**正解そのものが仮説である**以上、そこを
// 確かめないまま基準にはできない（設計メモ §9-11 の未解決にも同時に答える）。
// ---------------------------------------------------------------------

func writeTruthFiles(truth: Truth)
{
	let manager = FileManager.default
	try? manager.createDirectory(at: outRoot, withIntermediateDirectories: true)

	var lines = [
		"# measure-truth --read  photos=\(ordered.count) labels=\(truth.labels.count)"
			+ " excluded=\(truth.excluded.count) unknown=\(truth.unknown.count)",
		"#position\trelpath\tlabels\torders",
	]
	for position in 0 ..< ordered.count
	{
		let labels = truth.labelsOfPhoto[position]
		let names: String
		if !labels.isEmpty
		{
			names = labels.map { truth.labels[$0].name }.joined(separator: "|")
		}
		else if truth.excluded.contains(position)
		{
			names = "_除外"
		}
		else if truth.unknown.contains(position)
		{
			names = "_不明"
		}
		else
		{
			names = "_未仕分け"
		}
		let orders = labels.map { String(truth.labels[$0].order) }.joined(separator: "|")
		lines.append("\(position)\t\(ordered[position].relativePath)\t\(names)\t\(orders)")
	}
	try? lines.joined(separator: "\n").appending("\n")
		.write(to: outRoot.appendingPathComponent("truth.tsv"), atomically: true, encoding: .utf8)

	// --- Object Capture へ投げられる一覧 ---
	let windowDirectory = outRoot.appendingPathComponent("truth-windows", isDirectory: true)
	try? manager.removeItem(at: windowDirectory)
	try? manager.createDirectory(at: windowDirectory, withIntermediateDirectories: true)
	var written = 0
	var oversize: [String] = []
	for (labelIndex, label) in truth.labels.enumerated()
	{
		let members = label.members.sorted()
		guard !members.isEmpty
		else
		{
			continue
		}
		if truthCapacity > 0, members.count > truthCapacity
		{
			oversize.append("\(displayName(labelIndex, label.name))（\(members.count) 枚）")
		}
		let chunkSize = truthCapacity > 0 ? truthCapacity : members.count
		var chunk = 0
		var start = 0
		while start < members.count
		{
			let slice = Array(members[start ..< min(members.count, start + chunkSize)])
			let paths = slice.map { root.appendingPathComponent(ordered[$0].relativePath).path }
			let name = truthCapacity > 0 && members.count > chunkSize
				? String(format: "label-%02d%@.txt", labelIndex + 1,
					String(UnicodeScalar(UInt8(97 + min(chunk, 25)))))
				: String(format: "label-%02d.txt", labelIndex + 1)
			try? paths.joined(separator: "\n").appending("\n")
				.write(to: windowDirectory.appendingPathComponent(name),
					atomically: true, encoding: .utf8)
			written += 1
			chunk += 1
			start += chunkSize
		}
	}
	log("正解を書き出しました: \(outRoot.path)")
	log("  truth.tsv（**ファイル名を含む手元専用**）／ truth-windows/ \(written) 個")
	if !oversize.isEmpty
	{
		log("  容量を超えたラベル: " + oversize.joined(separator: "・"))
	}
	log("  → measure-poses --window-dir \(windowDirectory.path) で"
		+ "「人が同じ場所と思ったものが本当に繋がるか」を確かめられます")
}

// ---------------------------------------------------------------------
// 集計の道具
// ---------------------------------------------------------------------

func format(_ value: Double, _ digits: Int) -> String
{
	value.isFinite ? String(format: "%.\(digits)f", value) : "—"
}

func percentile(_ sorted: [Float], _ fraction: Double) -> Double
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
	return Double(sorted[lower]) * (1 - weight) + Double(sorted[upper]) * weight
}

/// **同ラベルの組のほうが小さい値を取る確率**（順位和。0.5 が当てずっぽう）。
/// 閾値を選ばずに指標そのものの良し悪しを比べられるので、ここが指標の比較の軸。
func areaUnderCurve(same: [Float], different: [Float]) -> Double
{
	guard !same.isEmpty, !different.isEmpty
	else
	{
		return .nan
	}
	let a = same.sorted()
	let b = different.sorted()
	var index = 0
	var total = 0.0
	for value in a
	{
		while index < b.count, b[index] < value
		{
			index += 1
		}
		var upper = index
		while upper < b.count, b[upper] == value
		{
			upper += 1
		}
		total += Double(b.count - upper) + 0.5 * Double(upper - index)
	}
	return total / (Double(a.count) * Double(b.count))
}

/// 閾値以下の割合（sorted は昇順）。
func fraction(_ sorted: [Float], atMost value: Double) -> Double
{
	guard !sorted.isEmpty
	else
	{
		return .nan
	}
	var low = 0
	var high = sorted.count
	while low < high
	{
		let middle = (low + high) / 2
		if Double(sorted[middle]) <= value
		{
			low = middle + 1
		}
		else
		{
			high = middle
		}
	}
	return Double(low) / Double(sorted.count)
}

/// 1 つの指標の成績。
struct Separability
{
	var name: String
	var same: [Float] = []
	var different: [Float] = []
	/// 別ラベルのうち**歩く順で隣り合うラベル**どうしの組（いちばん難しい）。
	var adjacent: [Float] = []
}

extension Separability
{
	var report: String
	{
		let sortedSame = same.sorted()
		let sortedDifferent = different.sorted()
		let auc = areaUnderCurve(same: same, different: different)
		let adjacentAUC = areaUnderCurve(same: same, different: adjacent)
		// **同ラベルの 9 割を拾おうとしたときに、別ラベルを何割つかむか。**
		// 閾値を置く方式が成立するかどうかは、実質この 1 つの数字で決まる。
		let cost = fraction(sortedDifferent, atMost: percentile(sortedSame, 0.9))
		var bestJ = -1.0
		var bestThreshold = Double.nan
		for step in 0 ... 200
		{
			let threshold = percentile(sortedSame, Double(step) / 200)
			let truePositive = fraction(sortedSame, atMost: threshold)
			let falsePositive = fraction(sortedDifferent, atMost: threshold)
			if truePositive - falsePositive > bestJ
			{
				bestJ = truePositive - falsePositive
				bestThreshold = threshold
			}
		}
		return [
			name,
			"\(same.count)",
			"\(different.count)",
			format(auc, 3),
			format(adjacentAUC, 3),
			format(percentile(sortedSame, 0.5), 3),
			format(percentile(sortedSame, 0.9), 3),
			format(percentile(sortedDifferent, 0.5), 3),
			format(cost, 3),
			format(bestJ, 3),
			format(bestThreshold, 3),
		].joined(separator: "\t")
	}
}

/// 単位ベクトル同士の距離（0.0〜1.0）。measure-ordering.swift と同じ定義。
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

/// 地球上の 2 点の距離（メートル）。緯度経度の差を平面近似する（数百 m の話なので十分）。
func metres(_ left: Record, _ right: Record) -> Double?
{
	guard let latitude1 = left.latitude, let longitude1 = left.longitude,
		let latitude2 = right.latitude, let longitude2 = right.longitude
	else
	{
		return nil
	}
	let meanLatitude = (latitude1 + latitude2) / 2 * .pi / 180
	let x = (longitude2 - longitude1) * cos(meanLatitude) * 111_320
	let y = (latitude2 - latitude1) * 110_540
	return (x * x + y * y).squareRoot()
}

// ---------------------------------------------------------------------
// 採点（--analyze）
// ---------------------------------------------------------------------

func analyze(truth: Truth)
{
	// --- 対象を決める ---
	var dimensionCounts: [Int: Int] = [:]
	for record in ordered
	{
		if let elements = record.elements
		{
			dimensionCounts[elements.count, default: 0] += 1
		}
	}
	let dimension = dimensionCounts.max { $0.value < $1.value }?.key ?? 0
	guard dimension > 0
	else
	{
		log("視覚特徴が 1 枚も取れていません（--cache の指定が違うか、Vision が使えません）")
		exit(3)
	}

	/// 視覚特徴を持つ写真（ラベルの有無によらない）。**グラフは本番と同じく
	/// 全部の写真で作る** — 除外した写真もグラフの中では隣人として働くため。
	var nodes: [Int] = []
	for position in 0 ..< ordered.count where ordered[position].elements?.count == dimension
	{
		nodes.append(position)
	}
	var rowOfPosition: [Int: Int] = [:]
	for (row, position) in nodes.enumerated()
	{
		rowOfPosition[position] = row
	}
	/// 代表ラベル（複数に属する写真は歩く順がいちばん早いほうを代表にする）。
	var representative = [Int](repeating: -1, count: ordered.count)
	for position in 0 ..< ordered.count
	{
		representative[position] = truth.labelsOfPhoto[position].min() ?? -1
	}
	let subjects = nodes.filter { representative[$0] >= 0 }

	print("")
	print("■ 正解の中身")
	print("  写真 \(ordered.count) 枚（視覚特徴あり \(nodes.count) 枚）")
	print("  ラベル \(truth.labels.count) 個 ／ ラベル付き \(subjects.count) 枚"
		+ " ／ 除外 \(truth.excluded.count) 枚 ／ 不明 \(truth.unknown.count) 枚")
	let unassigned = ordered.count - truth.labelsOfPhoto.filter { !$0.isEmpty }.count
		- truth.excluded.count - truth.unknown.count
	if unassigned > 0
	{
		print("  **どのフォルダにも入っていない写真が \(unassigned) 枚あります**"
			+ "（採点から外れます。_不明 へ入れると意図が残ります）")
	}
	if truth.matchedByName > 0
	{
		print("  ファイル名で照合した写真 \(truth.matchedByName) 枚"
			+ "（ハードリンクでないもの。名前を変えると失われます）")
	}
	if !truth.strayFiles.isEmpty
	{
		print("  **元の写真へ辿れなかったファイル \(truth.strayFiles.count) 件**"
			+ "（正解フォルダの中だけにあるもの）")
	}
	guard subjects.count >= 20, truth.labels.count >= 2
	else
	{
		print("  採点するには少なすぎます（ラベル付き 20 枚・2 ラベル以上が要ります）")
		return
	}

	var vectors = [Float](repeating: 0, count: nodes.count * dimension)
	for (row, position) in nodes.enumerated()
	{
		vectors.replaceSubrange(row * dimension ..< (row + 1) * dimension,
			with: ordered[position].elements ?? [])
	}

	// --- 1. 指標の分離能 ---
	//
	// **同じ場所の組と、違う場所の組を、その指標だけで見分けられるか。**
	// #11〜#14 で「どの指標を信じるか」を決められなかったのは、この比較の
	// 基準（＝正解）が無かったからで、ここがこの道具のいちばんの目的。
	var visual = Separability(name: "視覚特徴の距離")
	var elapsed = Separability(name: "撮影時刻の差(秒)")
	var order = Separability(name: "撮影順の隔たり")
	var location = Separability(name: "GPS の距離(m)")
	var exposure = Separability(name: "露出の差(EV)")
	var hashes = Separability(name: "知覚ハッシュ(bit)")

	let totalPairs = subjects.count * (subjects.count - 1) / 2
	let step = totalPairs > maxPairs ? (totalPairs + maxPairs - 1) / maxPairs : 1
	if step > 1
	{
		log("組が多いので \(step) 組に 1 つを標本にします（全 \(totalPairs) 組）")
	}
	vectors.withUnsafeBufferPointer
	{ buffer in
		guard let base = buffer.baseAddress
		else
		{
			return
		}
		var pairIndex = 0
		for (offset, left) in subjects.enumerated()
		{
			for right in subjects[(offset + 1)...]
			{
				defer { pairIndex += 1 }
				guard pairIndex % step == 0
				else
				{
					continue
				}
				let leftLabels = truth.labelsOfPhoto[left]
				let rightLabels = truth.labelsOfPhoto[right]
				let same = leftLabels.contains { rightLabels.contains($0) }
				// **歩く順で隣り合うラベルどうしが、いちばん難しい組**。
				// 遠いラベルと混ぜて平均すると、そこでの弱さが見えなくなる。
				let neighbouring = !same
					&& abs(representative[left] - representative[right]) == 1

				func record(_ statistics: inout Separability, _ value: Double?)
				{
					guard let value, value.isFinite
					else
					{
						return
					}
					if same
					{
						statistics.same.append(Float(value))
					}
					else
					{
						statistics.different.append(Float(value))
						if neighbouring
						{
							statistics.adjacent.append(Float(value))
						}
					}
				}

				let leftRow = rowOfPosition[left] ?? 0
				let rightRow = rowOfPosition[right] ?? 0
				record(&visual, distance(base, leftRow, rightRow, dimension))
				record(&order, Double(abs(left - right)))
				if let leftDate = ordered[left].date, let rightDate = ordered[right].date
				{
					record(&elapsed, abs(leftDate.timeIntervalSince(rightDate)))
				}
				record(&location, metres(ordered[left], ordered[right]))
				if let leftValue = ordered[left].exposure, let rightValue = ordered[right].exposure
				{
					record(&exposure, abs(leftValue - rightValue))
				}
				if let leftHash = ordered[left].hash, let rightHash = ordered[right].hash
				{
					record(&hashes, Double((leftHash ^ rightHash).nonzeroBitCount))
				}
			}
		}
	}

	let statistics = [visual, order, elapsed, location, exposure, hashes]
		.filter { !$0.same.isEmpty && !$0.different.isEmpty }
	print("")
	print("■ 指標の分離能（同じ場所の組 vs 違う場所の組）")
	print("  指標                組(同)   組(別)   AUC  隣接AUC  同中央  同90%  別中央  90%時誤り  最良J  その閾値")
	for entry in statistics
	{
		let columns = entry.report.split(separator: "\t", omittingEmptySubsequences: false)
			.map(String.init)
		print(String(format: "  %-18@ %7@ %8@ %5@ %8@ %7@ %6@ %7@ %10@ %6@ %9@",
			columns[0] as NSString, columns[1] as NSString, columns[2] as NSString,
			columns[3] as NSString, columns[4] as NSString, columns[5] as NSString,
			columns[6] as NSString, columns[7] as NSString, columns[8] as NSString,
			columns[9] as NSString, columns[10] as NSString))
	}
	print("  AUC = 同じ場所の組のほうが小さい値になる確率。0.5 は当てずっぽう、1.0 は完全に分離。")
	print("  **隣接AUC は「歩く順で隣り合うラベルどうし」だけを相手にしたもの**で、")
	print("  実際に間違えるのはここ。全体の AUC が高くても隣接が 0.6 なら使えない。")
	print("  「90%時誤り」＝同じ場所の 9 割を拾う閾値を置いたとき、違う場所を拾う割合。")
	print("  **閾値方式が成立するかは実質この数字で決まる**（#11 はここで失敗した）。")

	// --- 2. 近傍の質（順位で使うとどうなるか） ---
	//
	// 設計は「距離の絶対値ではなく順位だけを使う」（§2.1）ので、閾値の成績より
	// **順位の成績のほうが本番に近い**。
	var topNeighbours = [[Int]](repeating: [], count: nodes.count)
	let neighbourLock = NSLock()
	let wanted = max(30, neighbourCount)
	vectors.withUnsafeBufferPointer
	{ buffer in
		guard let base = buffer.baseAddress
		else
		{
			return
		}
		DispatchQueue.concurrentPerform(iterations: nodes.count)
		{ row in
			var best: [(Int, Double)] = []
			for other in 0 ..< nodes.count where other != row
			{
				let value = distance(base, row, other, dimension)
				if best.count < wanted
				{
					best.append((other, value))
					best.sort { $0.1 < $1.1 }
				}
				else if value < best[best.count - 1].1
				{
					best[best.count - 1] = (other, value)
					best.sort { $0.1 < $1.1 }
				}
			}
			neighbourLock.lock()
			topNeighbours[row] = best.map(\.0)
			neighbourLock.unlock()
		}
	}

	print("")
	print("■ 近傍の質（視覚特徴の順位。設計が実際に使うのはこちら）")
	print("  k    同ラベル率  取りこぼさない率  無作為なら")
	var neighbourRows: [String] = []
	for k in [5, 10, 30].filter({ $0 <= wanted })
	{
		var precisionTotal = 0.0
		var recallTotal = 0.0
		var counted = 0
		for position in subjects
		{
			guard let row = rowOfPosition[position]
			else
			{
				continue
			}
			let labels = truth.labelsOfPhoto[position]
			let neighbours = topNeighbours[row].prefix(k)
			// **ラベルの付いていない隣人は分母から外す**（正解が無いものを
			// 「間違い」に数えると、除外した写真の枚数だけ成績が下がる）。
			var labelled = 0
			var matching = 0
			for neighbour in neighbours
			{
				let other = nodes[neighbour]
				let otherLabels = truth.labelsOfPhoto[other]
				guard !otherLabels.isEmpty
				else
				{
					continue
				}
				labelled += 1
				if otherLabels.contains(where: { labels.contains($0) })
				{
					matching += 1
				}
			}
			guard labelled > 0
			else
			{
				continue
			}
			let family = labels.reduce(0) { $0 + truth.labels[$1].members.count } - 1
			precisionTotal += Double(matching) / Double(labelled)
			recallTotal += Double(matching) / Double(max(1, min(k, family)))
			counted += 1
		}
		guard counted > 0
		else
		{
			continue
		}
		// 無作為の水準＝「適当に 1 枚選んだとき同じラベルである確率」。
		var chance = 0.0
		for position in subjects
		{
			let family = truth.labelsOfPhoto[position]
				.reduce(0) { $0 + truth.labels[$1].members.count } - 1
			chance += Double(family) / Double(max(1, subjects.count - 1))
		}
		chance /= Double(subjects.count)
		print(String(format: "  %-4d %10@ %17@ %11@", k,
			format(precisionTotal / Double(counted), 3) as NSString,
			format(recallTotal / Double(counted), 3) as NSString,
			format(chance, 3) as NSString))
		neighbourRows.append("近傍k\(k)\t\(format(precisionTotal / Double(counted), 4))"
			+ "\t\(format(recallTotal / Double(counted), 4))\t\(format(chance, 4))")
	}

	// --- 3. 共視グラフの辺のうち、本当に同じ場所なのは何割か ---
	//
	// **設計 §2.2 の共通近傍フィルタは合成グラフでしか確かめていなかった。**
	// 正解があれば実データで「空似を何本落として、本物を何本失ったか」が出る。
	var mutual = [[Int]](repeating: [], count: nodes.count)
	for row in 0 ..< nodes.count
	{
		for other in topNeighbours[row].prefix(neighbourCount)
			where other > row && topNeighbours[other].prefix(neighbourCount).contains(row)
		{
			mutual[row].append(other)
			mutual[other].append(row)
		}
	}
	let neighbourSets = mutual.map { Set($0) }
	var filtered = [[Int]](repeating: [], count: nodes.count)
	for row in 0 ..< nodes.count
	{
		for other in mutual[row]
			where neighbourSets[row].intersection(neighbourSets[other]).count >= 2
		{
			filtered[row].append(other)
		}
	}

	/// 辺を数える。両端にラベルがあるものだけが採点できる。
	func score(_ graph: [[Int]]) -> (total: Int, judged: Int, same: Int)
	{
		var total = 0
		var judged = 0
		var same = 0
		for row in 0 ..< graph.count
		{
			for other in graph[row] where other > row
			{
				total += 1
				let left = truth.labelsOfPhoto[nodes[row]]
				let right = truth.labelsOfPhoto[nodes[other]]
				guard !left.isEmpty, !right.isEmpty
				else
				{
					continue
				}
				judged += 1
				if left.contains(where: { right.contains($0) })
				{
					same += 1
				}
			}
		}
		return (total, judged, same)
	}

	let before = score(mutual)
	let after = score(filtered)
	print("")
	print("■ 共視グラフの辺（相互 \(neighbourCount) 近傍）")
	print(String(format: "  フィルタ前  辺 %d 本（採点できた %d 本）  同じ場所 %@",
		before.total, before.judged,
		format(Double(before.same) / Double(max(1, before.judged)), 3) as NSString))
	print(String(format: "  共通近傍後  辺 %d 本（採点できた %d 本）  同じ場所 %@",
		after.total, after.judged,
		format(Double(after.same) / Double(max(1, after.judged)), 3) as NSString))
	print(String(format: "  → 空似を %d 本落として、本物を %d 本失った",
		max(0, (before.judged - before.same) - (after.judged - after.same)),
		max(0, before.same - after.same)))
	print("  **落ちた辺のほとんどが空似なら、フィルタは実データでも効いている**")
	print("  （設計 §2.2 は合成グラフでしか確かめていなかった）")

	// --- 4. 空似の地図 ---
	//
	// 設計メモ §9-2「かたまりの空似」を**名指しできる形**にする。どのラベルと
	// どのラベルが取り違えられているかが分かれば、対策を打つ場所が決まる。
	var confusion: [String: Int] = [:]
	var edgesOfLabel = [Int](repeating: 0, count: truth.labels.count)
	var sameOfLabel = [Int](repeating: 0, count: truth.labels.count)
	for row in 0 ..< filtered.count
	{
		for other in filtered[row] where other > row
		{
			let left = representative[nodes[row]]
			let right = representative[nodes[other]]
			guard left >= 0, right >= 0
			else
			{
				continue
			}
			edgesOfLabel[left] += 1
			edgesOfLabel[right] += 1
			let leftLabels = truth.labelsOfPhoto[nodes[row]]
			let rightLabels = truth.labelsOfPhoto[nodes[other]]
			if leftLabels.contains(where: { rightLabels.contains($0) })
			{
				sameOfLabel[left] += 1
				sameOfLabel[right] += 1
				continue
			}
			confusion["\(min(left, right))\t\(max(left, right))", default: 0] += 1
		}
	}
	let worst = confusion.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
	print("")
	print("■ 空似の地図（違う場所どうしが辺で結ばれた回数・上位 15 組）")
	if worst.isEmpty
	{
		print("  ありません（**この現場では空似が起きていない**）")
	}
	var confusionLines = ["#labelA\tlabelB\tedges\tphotosA\tphotosB\tadjacent"]
	for (key, count) in worst.prefix(15)
	{
		let parts = key.split(separator: "\t").compactMap { Int($0) }
		guard parts.count == 2
		else
		{
			continue
		}
		let left = truth.labels[parts[0]]
		let right = truth.labels[parts[1]]
		let neighbouring = abs(parts[0] - parts[1]) == 1
		print(String(format: "  %-16@ ↔ %-16@ %5d 本  (%d 枚 / %d 枚)%@",
			displayName(parts[0], left.name) as NSString,
			displayName(parts[1], right.name) as NSString, count,
			left.members.count, right.members.count,
			(neighbouring ? "  歩く順で隣" : "") as NSString))
	}
	for (key, count) in worst
	{
		let parts = key.split(separator: "\t").compactMap { Int($0) }
		guard parts.count == 2
		else
		{
			continue
		}
		confusionLines.append("\(displayName(parts[0], truth.labels[parts[0]].name))"
			+ "\t\(displayName(parts[1], truth.labels[parts[1]].name))\t\(count)"
			+ "\t\(truth.labels[parts[0]].members.count)\t\(truth.labels[parts[1]].members.count)"
			+ "\t\(abs(parts[0] - parts[1]) == 1 ? 1 : 0)")
	}
	print("  **歩く順で隣**でない組が上位に来たら、それが設計 §9-2 の「かたまりの空似」です")

	print("")
	print("■ ラベルごとの成績（辺のうち同じ場所へ向かった割合）")
	print("  ラベル              枚数   辺   同じ場所  撮影順の塊  最大の塊")
	var labelLines = ["#label\tphotos\tedges\tsamerate\truns\tlargestrun"]
	for (index, label) in truth.labels.enumerated()
	{
		let chunks = runs(of: label.members)
		let rate = Double(sameOfLabel[index]) / Double(max(1, edgesOfLabel[index]))
		let largest = Double(chunks.max() ?? 0) / Double(max(1, label.members.count))
		print(String(format: "  %-18@ %5d %5d %9@ %10d %9@",
			displayName(index, label.name) as NSString, label.members.count,
			edgesOfLabel[index], format(rate, 3) as NSString, chunks.count,
			format(largest, 2) as NSString))
		labelLines.append("\(displayName(index, label.name))\t\(label.members.count)"
			+ "\t\(edgesOfLabel[index])\t\(format(rate, 4))\t\(chunks.count)"
			+ "\t\(format(largest, 3))")
	}

	// --- 5. 撮影順は場所の証拠か（設計メモ §10 の A/B/C の判断材料） ---
	var adjacentSame = 0
	var adjacentJudged = 0
	for position in 1 ..< ordered.count
	{
		let left = truth.labelsOfPhoto[position - 1]
		let right = truth.labelsOfPhoto[position]
		guard !left.isEmpty, !right.isEmpty
		else
		{
			continue
		}
		adjacentJudged += 1
		if left.contains(where: { right.contains($0) })
		{
			adjacentSame += 1
		}
	}
	let sortedOrderGaps = order.same.sorted()
	print("")
	print("■ 撮影順は場所の証拠か（設計メモ §10「方針の判断が要る点」）")
	print(String(format: "  撮影順で隣り合う 2 枚が同じ場所である割合: %@（%d 組）",
		format(Double(adjacentSame) / Double(max(1, adjacentJudged)), 3) as NSString,
		adjacentJudged))
	print(String(format: "  同じ場所の組の撮影順の隔たり: 中央 %@ ・ 90%% 点 %@",
		format(percentile(sortedOrderGaps, 0.5), 0) as NSString,
		format(percentile(sortedOrderGaps, 0.9), 0) as NSString))
	let multipleRuns = truth.labels.filter { runs(of: $0.members).count > 1 }.count
	print("  2 つ以上の塊に分かれるラベル（＝戻ってきた撮影）: "
		+ "\(multipleRuns) / \(truth.labels.count)")
	print("  → 隣り合う割合が高く、隔たりの 90% 点が小さければ **C（窓を作るのに使う）**")
	print("    が成立します。塊に分かれるラベルが多ければ、撮影順だけでは足りません。")

	// --- 書き出し ---
	var metricsLines = [
		"# measure-truth --analyze  labels=\(truth.labels.count) labelled=\(subjects.count)"
			+ " neighbours=\(neighbourCount) pairstep=\(step)",
		"#name\tsame\tdifferent\tauc\tadjacentauc\tsamemedian\tsamep90"
			+ "\tdifferentmedian\tcostat90\tbestj\tbestthreshold",
	]
	for entry in statistics
	{
		metricsLines.append(entry.report)
	}
	metricsLines.append("#name\tprecision\trecall\tchance")
	metricsLines += neighbourRows
	metricsLines.append("#graph\ttotal\tjudged\tsame")
	metricsLines.append("mutual\t\(before.total)\t\(before.judged)\t\(before.same)")
	metricsLines.append("filtered\t\(after.total)\t\(after.judged)\t\(after.same)")
	metricsLines.append("#ordering\tadjacentsame\tadjacentjudged\tgapmedian\tgapp90\tmultirunlabels")
	metricsLines.append("ordering\t\(adjacentSame)\t\(adjacentJudged)"
		+ "\t\(format(percentile(sortedOrderGaps, 0.5), 1))"
		+ "\t\(format(percentile(sortedOrderGaps, 0.9), 1))\t\(multipleRuns)")
	metricsLines += labelLines
	try? metricsLines.joined(separator: "\n").appending("\n")
		.write(to: outRoot.appendingPathComponent("metrics.tsv"),
			atomically: true, encoding: .utf8)
	try? confusionLines.joined(separator: "\n").appending("\n")
		.write(to: outRoot.appendingPathComponent("confusion.tsv"),
			atomically: true, encoding: .utf8)
	print("")
	print("  機械可読: \(outRoot.appendingPathComponent("metrics.tsv").path)")
	print("           \(outRoot.appendingPathComponent("confusion.tsv").path)")
	print("  **どちらも写真もファイル名も含まない**ので、そのまま共有できます"
		+ (anonymous ? "" : "（ラベル名は入ります。--anonymous で伏せられます）"))
}

// ---------------------------------------------------------------------
// 自動の窓を正解で採点する（--score DIR）
//
// **窓は分割ではなく被覆**（設計 §3.3）なので、分割どうしを比べる指標
// （ARI など）は使えない。代わりに、設計が実際に必要としている 2 つを見る。
//
//   ラベル被覆率  そのラベルの写真が、**どれか 1 つの窓へどれだけ入ったか**。
//                 低い＝場所が窓をまたいで割れている＝分断（いちばん高い代償）
//   窓の純度      窓の中で最大のラベルが占める割合。低い＝混入（安い代償）
//
// 設計は「混入は安い・分断は高い」（§1.2）なので、**見るべきはまず被覆率**で、
// 純度はそれを説明する材料として置いてある。
// ---------------------------------------------------------------------

func scoreWindows(directory: String, truth: Truth)
{
	let manager = FileManager.default
	let base = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
	let names = ((try? manager.contentsOfDirectory(atPath: base.path)) ?? [])
		.filter { $0.hasSuffix(".txt") }.sorted()
	guard !names.isEmpty
	else
	{
		log("窓の一覧（*.txt）が見つかりません: \(base.path)")
		return
	}
	var indexOfPath: [String: Int] = [:]
	for position in 0 ..< ordered.count
	{
		indexOfPath[root.appendingPathComponent(ordered[position].relativePath).path] = position
	}

	var windows: [(name: String, members: [Int])] = []
	var unknownPaths = 0
	for name in names
	{
		let text = (try? String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)) ?? ""
		var members: [Int] = []
		for line in text.split(separator: "\n")
		{
			let path = line.trimmingCharacters(in: .whitespaces)
			guard !path.isEmpty
			else
			{
				continue
			}
			if let index = indexOfPath[URL(fileURLWithPath: path).standardizedFileURL.path]
			{
				members.append(index)
			}
			else
			{
				unknownPaths += 1
			}
		}
		if !members.isEmpty
		{
			windows.append((name, members))
		}
	}
	guard !windows.isEmpty
	else
	{
		log("窓の中身が 1 枚も写真フォルダと一致しません（--score の指定を確認してください）")
		return
	}
	if unknownPaths > 0
	{
		log("窓の一覧のうち \(unknownPaths) 行は写真フォルダの外を指していました")
	}

	print("")
	print("■ 窓の採点: \(base.path)")
	print("  窓                    枚数  ラベル  最大ラベル  純度  混入  塊  ラベル無し")
	var lines = ["#window\tphotos\tlabels\ttoplabel\tpurity\tforeign\truns\tunlabelled"]
	var purityTotal = 0.0
	for window in windows
	{
		var counts: [Int: Int] = [:]
		var unlabelled = 0
		for member in window.members
		{
			let labels = truth.labelsOfPhoto[member]
			if labels.isEmpty
			{
				unlabelled += 1
				continue
			}
			for label in labels
			{
				counts[label, default: 0] += 1
			}
		}
		let labelled = window.members.count - unlabelled
		let top = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
		let purity = labelled > 0 ? Double(top?.value ?? 0) / Double(labelled) : Double.nan
		purityTotal += purity.isFinite ? purity : 0
		let chunks = runs(of: window.members)
		let topName = top.map { displayName($0.key, truth.labels[$0.key].name) } ?? "—"
		print(String(format: "  %-20@ %5d %7d %11@ %5@ %5d %4d %10d",
			window.name as NSString, window.members.count, counts.count, topName as NSString,
			format(purity, 2) as NSString, labelled - (top?.value ?? 0), chunks.count, unlabelled))
		lines.append("\(window.name)\t\(window.members.count)\t\(counts.count)\t\(topName)"
			+ "\t\(format(purity, 3))\t\(labelled - (top?.value ?? 0))\t\(chunks.count)"
			+ "\t\(unlabelled)")
	}

	print("")
	print("  ラベル              枚数  最大の窓へ  散った窓  判定")
	lines.append("#label\tname\tphotos\tcoverage\tspread")
	var broken: [String] = []
	var coverageTotal = 0.0
	for (index, label) in truth.labels.enumerated()
	{
		guard !label.members.isEmpty
		else
		{
			continue
		}
		let members = Set(label.members)
		var best = 0
		var spread = 0
		for window in windows
		{
			let shared = Set(window.members).intersection(members).count
			best = max(best, shared)
			if shared > 0
			{
				spread += 1
			}
		}
		let coverage = Double(best) / Double(members.count)
		coverageTotal += coverage
		// **8 割は目安**。1 つの場所の 8 割が 1 つの窓に入っていれば、その場所は
		// 1 回の再構成で形になる（残りは隣の窓が持っている＝重なりとして働く）。
		let verdict = coverage >= 0.8 ? "" : "**分断**"
		if coverage < 0.8
		{
			broken.append(displayName(index, label.name))
		}
		print(String(format: "  %-18@ %5d %11@ %9d  %@",
			displayName(index, label.name) as NSString, members.count,
			format(coverage, 2) as NSString, spread, verdict as NSString))
		lines.append("#label\t\(displayName(index, label.name))\t\(members.count)"
			+ "\t\(format(coverage, 3))\t\(spread)")
	}

	let covered = Set(windows.flatMap(\.members)).count
	print("")
	print(String(format: "  平均の純度 %@ ／ 平均のラベル被覆率 %@ ／ 被覆 %d/%d 枚",
		format(purityTotal / Double(windows.count), 3) as NSString,
		format(coverageTotal / Double(max(1, truth.labels.count)), 3) as NSString,
		covered, ordered.count))
	if broken.isEmpty
	{
		print("  **分断されたラベルはありません**（どの場所も 8 割はどこか 1 つの窓に入っている）")
	}
	else
	{
		print("  **分断されたラベル: " + broken.joined(separator: "・") + "**")
		print("  設計 §1.2 のとおり、分断は混入よりはるかに高い代償です。純度が低いこと")
		print("  自体は問題ではありません（Object Capture が使えない写真を捨てるため）。")
	}
	let file = outRoot.appendingPathComponent("score-" + safeFileName(base.lastPathComponent) + ".tsv")
	try? lines.joined(separator: "\n").appending("\n")
		.write(to: file, atomically: true, encoding: .utf8)
	print("  機械可読: \(file.path)")
	print("  → ledger.tsv の成否（error 6 かどうか）と窓の名前で突き合わせれば、")
	print("    **純度・被覆率が Object Capture の成否を予言するか**が分かります")
	print("    （設計メモ §6.2.9 は内部指標が予言しないことを示した。正解由来の指標なら？）")
}

// ---------------------------------------------------------------------
// 見直しの候補（--hints）
//
// **これは正解ではなく、目で確かめる場所の候補**である。視覚特徴が「浮いている」
// と言っているだけで、判断は写真を見た人がする。
//
// **循環に注意**: 視覚特徴で作った候補をそのまま正解へ反映すると、視覚特徴を
// 視覚特徴で採点することになる。候補は「見るべき場所」を絞るためだけに使い、
// **必ず写真を開いて決める**こと。
// ---------------------------------------------------------------------

func hints(truth: Truth)
{
	var dimensionCounts: [Int: Int] = [:]
	for record in ordered
	{
		if let elements = record.elements
		{
			dimensionCounts[elements.count, default: 0] += 1
		}
	}
	let dimension = dimensionCounts.max { $0.value < $1.value }?.key ?? 0
	guard dimension > 0
	else
	{
		return
	}
	var subjects: [Int] = []
	for position in 0 ..< ordered.count
		where ordered[position].elements?.count == dimension
			&& !truth.labelsOfPhoto[position].isEmpty
	{
		subjects.append(position)
	}
	guard subjects.count >= 20
	else
	{
		return
	}
	var vectors = [Float](repeating: 0, count: subjects.count * dimension)
	for (row, position) in subjects.enumerated()
	{
		vectors.replaceSubrange(row * dimension ..< (row + 1) * dimension,
			with: ordered[position].elements ?? [])
	}

	/// 写真 1 枚から見た「そのラベルの近さ」。**近い 5 枚の平均**にするのは、
	/// ラベルの枚数が違っても比べられるようにするため（平均だと大きいラベルが不利）。
	var affinity = [[Double]](repeating: [Double](repeating: .infinity, count: truth.labels.count),
		count: subjects.count)
	vectors.withUnsafeBufferPointer
	{ buffer in
		guard let pointer = buffer.baseAddress
		else
		{
			return
		}
		for (row, position) in subjects.enumerated()
		{
			var byLabel = [[Double]](repeating: [], count: truth.labels.count)
			for (otherRow, other) in subjects.enumerated() where other != position
			{
				let value = distance(pointer, row, otherRow, dimension)
				for label in truth.labelsOfPhoto[other]
				{
					byLabel[label].append(value)
				}
			}
			for label in 0 ..< truth.labels.count
			{
				let nearest = byLabel[label].sorted().prefix(5)
				if !nearest.isEmpty
				{
					affinity[row][label] = nearest.reduce(0, +) / Double(nearest.count)
				}
			}
		}
	}

	var lines = ["#kind\trelpath\tcurrent\tsuggested\tcurrentvalue\tsuggestedvalue"]
	var moves = 0
	for (row, position) in subjects.enumerated()
	{
		let labels = truth.labelsOfPhoto[position]
		let mine = labels.map { affinity[row][$0] }.min() ?? .infinity
		var bestLabel = -1
		var bestValue = Double.infinity
		for label in 0 ..< truth.labels.count where !labels.contains(label)
		{
			if affinity[row][label] < bestValue
			{
				bestValue = affinity[row][label]
				bestLabel = label
			}
		}
		// **はっきり近いときだけ言う。** わずかな差で候補を出すと、見る場所が
		// 絞れなくなって道具として役に立たない。
		guard bestLabel >= 0, bestValue < mine * 0.8
		else
		{
			continue
		}
		moves += 1
		lines.append("移動候補\t\(ordered[position].relativePath)"
			+ "\t\(truth.labels[labels[0]].name)\t\(truth.labels[bestLabel].name)"
			+ "\t\(format(mine, 3))\t\(format(bestValue, 3))")
	}

	// ラベル対の近さ（**同じ場所を 2 つに割っていないか**）。
	var mergeCandidates: [(Int, Int, Double, Double)] = []
	for left in 0 ..< truth.labels.count
	{
		for right in (left + 1) ..< truth.labels.count
		{
			var cross: [Double] = []
			var inside: [Double] = []
			for (row, position) in subjects.enumerated()
			{
				let labels = truth.labelsOfPhoto[position]
				if labels.contains(left)
				{
					cross.append(affinity[row][right])
					inside.append(affinity[row][left])
				}
				else if labels.contains(right)
				{
					cross.append(affinity[row][left])
					inside.append(affinity[row][right])
				}
			}
			guard cross.count >= 10
			else
			{
				continue
			}
			let crossMean = cross.reduce(0, +) / Double(cross.count)
			let insideMean = inside.reduce(0, +) / Double(inside.count)
			if crossMean < insideMean * 1.05
			{
				mergeCandidates.append((left, right, crossMean, insideMean))
			}
		}
	}
	mergeCandidates.sort { $0.2 < $1.2 }
	for candidate in mergeCandidates.prefix(20)
	{
		lines.append("結合候補\t—\t\(truth.labels[candidate.0].name)"
			+ "\t\(truth.labels[candidate.1].name)\t\(format(candidate.3, 3))"
			+ "\t\(format(candidate.2, 3))")
	}

	var manyRuns: [String] = []
	for (index, label) in truth.labels.enumerated()
	{
		let chunks = runs(of: label.members)
		if chunks.count >= 4
		{
			manyRuns.append("\(displayName(index, label.name))（\(chunks.count) 塊）")
			lines.append("塊が多い\t—\t\(label.name)\t—\t\(chunks.count)\t—")
		}
	}

	print("")
	print("■ 見直しの候補（**正解ではありません。写真を見て決めてください**）")
	print("  別のラベルのほうがはっきり近い写真: \(moves) 枚")
	print("  1 つにまとめる候補のラベル対: \(mergeCandidates.count) 組"
		+ (mergeCandidates.isEmpty ? "" : "（近い順に上位 20 組を書き出しました）"))
	print("  撮影順の塊が 4 つ以上のラベル: "
		+ (manyRuns.isEmpty ? "なし" : manyRuns.joined(separator: "・")))
	let file = outRoot.appendingPathComponent("hints.tsv")
	try? lines.joined(separator: "\n").appending("\n")
		.write(to: file, atomically: true, encoding: .utf8)
	print("  \(file.path)（**ファイル名を含むので手元専用**）")
	print("")
	print("  **循環に注意**: これは視覚特徴が言っていることなので、そのまま正解へ")
	print("  反映すると「視覚特徴を視覚特徴で採点する」ことになります。候補は見る")
	print("  場所を絞るためだけに使い、採否は必ず写真を開いて決めてください。")
}

// ---------------------------------------------------------------------
// 実行
// ---------------------------------------------------------------------

if let draftSize
{
	makeDraft(size: draftSize)
}

let truth = readTruth()
log("正解フォルダ: ラベル \(truth.labels.count) 個 ／ "
	+ "ラベル付き \(truth.labelsOfPhoto.filter { !$0.isEmpty }.count) 枚 ／ "
	+ "除外 \(truth.excluded.count) 枚 ／ 不明 \(truth.unknown.count) 枚")
if !truth.strayFiles.isEmpty
{
	log("**元の写真へ辿れなかったファイルが \(truth.strayFiles.count) 件あります**: "
		+ truth.strayFiles.prefix(5).joined(separator: "・")
		+ (truth.strayFiles.count > 5 ? " …" : ""))
	log("  （正解フォルダへ写真フォルダの外から持ち込むと、採点の対象になりません）")
}

if makeSheets || draftSize != nil
{
	writeSheets(truth: truth)
}
if doRead
{
	writeTruthFiles(truth: truth)
}
if doAnalyze
{
	analyze(truth: truth)
}
if !scoreDirectory.isEmpty
{
	scoreWindows(directory: scoreDirectory, truth: truth)
}
if doHints
{
	hints(truth: truth)
}
