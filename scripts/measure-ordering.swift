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
//    --segments N       撮影順を N 枚ずつに切って区間ごとの中身を出す
//    --seriate 12       視覚特徴だけで並べ替える（スペクトル法）。EXIF 無しで
//                       成立するかの検証。k は相互近傍の数
//    --windows 200      **支持成長で窓を作って書き出す**（設計 §3.1）。容量を指定。
//                       書き出した一覧は measure-poses --window-dir で OC へ投げる
//    --window-dir DIR   書き出し先（既定 ./windows）
//    --neighbours 12    共視グラフの相互近傍の数
//    --overlap-ratio 0.3 窓のうち重なりに充てる割合（残りが新規の枠）
//    --feedback DIR     **Object Capture の結果で共視グラフを直す**。
//                       measure-poses --poses-out が書いた *.poses.tsv を読む
//    --compare-windows DIR 前の巡の窓と一致度を比べる
//    --grow-full        **窓の成長で被覆を見ない**（既定は 2 段階）。既定では
//                       段階 1 が「まだどの窓にも入っていない写真」だけで育てる
//                       ので、**先に育った窓がその領域の良い写真を先取りし**、
//                       後から育つ窓は遠くの弱い写真で枠を埋める羽目になる。
//                       これを付けると、どの窓も全写真から最良の N 枚になる
//    --cache FILE       視覚特徴とブレ指標をファイルへ残し、次回は読み直さない。
//                       **反復（trial-clustering.sh）では毎巡ここを通る**ので、
//                       1424 枚の読み取り（数分）が 2 巡目以降ほぼゼロになる
//    --download         iCloud Drive の未ダウンロードをまとめて落としてから進む
//
//  `--windows` を付けると、窓の一覧（window-NN.txt）と一緒に **windows.tsv**
//  （窓ごとの指標を機械可読にしたもの）を書き出す。人が読む表と同じ数字で、
//  trial-clustering.sh はこれを見て「次にどの窓を Object Capture へ投げるか」を
//  決める。**表を目で読んで選ぶ作業を自動化するためだけのもの**で、判断そのものは
//  増えていない。
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
/// iCloud Drive の未ダウンロードをまとめて落としてから進む（`--download`）。
var downloadFirst = false
/// **視覚特徴だけで並べ替える**（`--seriate k`）。EXIF を一切使わずに
/// 「隣り合う写真は重なっている」並びを作れるかを確かめる（設計 §3.9）。
var seriateK: Int?
/// **窓を作って書き出す**（`--windows N`）。N は窓の容量。設計 §3.1 の
/// 支持成長をそのまま実行し、measure-poses へ渡せる一覧を書き出す。
var windowCapacity: Int?
var windowDirectory = "windows"
/// 共視グラフの相互近傍の数（`--neighbours`）。
var neighbourCount = 12
/// 窓のうち「重なり」に充てる割合（`--overlap-ratio`）。残りが**新規**の枠。
var overlapRatio = 0.3
/// **Object Capture の結果で共視グラフを直す**（`--feedback DIR`）。
/// measure-poses --poses-out が書いた `*.poses.tsv` を読む。
var feedbackDirectory = ""
/// **前の巡の窓と突き合わせる**（`--compare-windows DIR`）。窓は毎巡グラフから
/// 作り直すので、**辺が直れば悪い窓は作られなくなる**はず。それが本当に起きて
/// いるかを見るための機能で、成長は決定的（乱数なし）なので、
/// **近傍の辺が 1 本も変わらなければまったく同じ窓が再び出る**。
var previousWindowDirectory = ""
/// **視覚特徴とブレ指標の置き場**（`--cache FILE`）。
///
/// 反復（設計 §3.10）では同じ写真フォルダを何巡も読み直すことになるが、
/// 縮小画像のデコードと Vision の推論は毎回まったく同じ答えを返す。1424 枚で
/// 数分かかるので、**巡の数だけ無駄になる**。EXIF は毎回読み直す（安いうえ、
/// 撮影メタデータを古いまま使う事故を避けたい）ので、残すのは画素から作った
/// 2 つだけにしてある。
var cachePath = ""
/// **窓の成長で被覆を見ない**（`--grow-full`）。
///
/// 既定の 2 段階（未被覆だけで枠まで → 襟を容量まで）は「窓が増えすぎる」のを
/// 防ぐために入れたものだが、その代償として**窓の中身が成長順に依存する**。
/// 先に育った窓が良い写真を先取りし、後の窓は遠くの弱い写真で枠を埋める。
/// 実データで、同じ領域の窓が巡を追って 212 → 164 枚に痩せ、芯の成分が
/// 0.92 → 0.79 まで落ちて error 6 になった。
///
/// 反復では 1 巡に 1 窓しか投げないので、**窓が増えること自体のコストはほぼ無い**
/// （選ばれなかった窓は作られただけで終わる）。
var growFull = false

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
		case "--download":
			downloadFirst = true
		case "--seriate":
			seriateK = arguments.isEmpty ? 12 : (Int(arguments.removeFirst()) ?? 12)
		case "--windows":
			windowCapacity = arguments.isEmpty ? nil : Int(arguments.removeFirst())
		case "--window-dir":
			windowDirectory = arguments.isEmpty ? windowDirectory : arguments.removeFirst()
		case "--neighbours":
			neighbourCount = (arguments.isEmpty ? nil : Int(arguments.removeFirst())) ?? neighbourCount
		case "--overlap-ratio":
			overlapRatio = (arguments.isEmpty ? nil : Double(arguments.removeFirst())) ?? overlapRatio
		case "--feedback":
			feedbackDirectory = arguments.isEmpty ? feedbackDirectory : arguments.removeFirst()
		case "--compare-windows":
			previousWindowDirectory = arguments.isEmpty
				? previousWindowDirectory : arguments.removeFirst()
		case "--cache":
			cachePath = arguments.isEmpty ? cachePath : arguments.removeFirst()
		case "--grow-full":
			growFull = true
		case "-h", "--help":
			print("使い方: measure-ordering <写真フォルダ> [--no-recursive] [--limit N] "
				+ "[--max-pairs N] [--segments N] [--seriate 12] "
				+ "[--windows 200] [--window-dir DIR] [--neighbours 12] "
				+ "[--overlap-ratio 0.3] [--feedback DIR] [--compare-windows DIR] "
				+ "[--cache FILE] [--grow-full] [--download]")
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


// ---------------------------------------------------------------------
// iCloud Drive の未ダウンロード対策
//
// 写真が iCloud Drive にあると、実体がローカルに無い（プレースホルダの）まま
// 見えている。その状態で読むと**1 枚ずつダウンロードが走って止まる**。
// 黙って固まるのが最悪なので、読む前に数えて、必要ならまとめて落とす。
// 本体側（InputInspection）が同じ理由で同じ検査をしている。
// ---------------------------------------------------------------------

/// ローカルに実体があるか。iCloud の項目でなければ常に true。
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

/// 未ダウンロードがあれば、落とすか・案内して止まるかを決める。
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
		log("次のどれかをしてください。")
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

let files = imageFiles(in: root, recursive: recursive)
guard !files.isEmpty
else
{
	log("画像が 1 枚も見つかりませんでした: \(root.path)")
	exit(2)
}
ensureMaterialized(files.map(\.url), download: downloadFirst)
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

// ---------------------------------------------------------------------
// 画素から作った値の置き場（--cache）
//
// **残すのは画素からしか作れない 2 つ（視覚特徴・ブレ指標）だけ。** EXIF は
// 毎回読み直す — 属性の読み取りは安く、しかも「メタデータだけ差し替えた写真」を
// 古いまま使う事故が起きない。写真の同一性は**大きさと更新時刻**で見る。
//
// 形式（すべてリトルエンディアン）:
//   "MOFPC1\n" + UInt32(root のパスの長さ) + root のパス
//   + UInt32(件数) + 件数ぶんの
//     UInt32(相対パスの長さ) + 相対パス + UInt64(バイト数) + Double(更新時刻)
//     + Double(ブレ指標。無ければ NaN) + UInt32(次元) + 次元ぶんの Float32
// ---------------------------------------------------------------------

/// キャッシュに残す 1 枚ぶん。**写真の同一性はここで判定する。**
struct CacheEntry
{
	var size: UInt64
	var modified: Double
	var sharpness: Double?
	var elements: [Float]?
}

let cacheMagic = Data("MOFPC1\n".utf8)

/// ファイルの大きさと更新時刻。取れなければ nil（＝キャッシュを使わない）。
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

	// **別のフォルダのキャッシュを黙って使わない。** 相対パスで引いているので、
	// root が違えば同じ相対パスが別の写真を指しうる。
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

	// **画素から作る 2 つだけはキャッシュを使う。** 同じ写真なら必ず同じ答えに
	// なるので、反復のたびにデコードと推論をやり直す理由が無い。
	if let cached
	{
		record.elements = cached.elements
		record.sharpness = cached.sharpness
		return record
	}

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
let cacheBefore = loadCache(cachePath, root: root)
/// キャッシュから来た枚数。**「使えた」と「読み直した」を必ず report する** —
/// 黙って古い値を使っていたら、測定そのものが信用できなくなる。
let reused = NSLock()
var reusedCount = 0
var freshStamps = [String: (size: UInt64, modified: Double)]()
DispatchQueue.concurrentPerform(iterations: files.count)
{ index in
	let file = files[index]
	let stamp = fileStamp(file.url)
	// 大きさと更新時刻が一致したときだけキャッシュを信じる。
	var hit: CacheEntry?
	if let stamp, let entry = cacheBefore[file.relativePath],
		entry.size == stamp.size, abs(entry.modified - stamp.modified) < 0.001
	{
		hit = entry
	}
	let record = read(url: file.url, relativePath: file.relativePath, cached: hit)
	reused.lock()
	if hit != nil
	{
		reusedCount += 1
	}
	if let stamp, record != nil
	{
		freshStamps[file.relativePath] = stamp
	}
	reused.unlock()
	let done = collector.put(record, at: index)
	if done % 100 == 0 || done == files.count
	{
		log("  読み取り \(done)/\(files.count)")
	}
}
let readSeconds = Date().timeIntervalSince(started)
let records = collector.finish()

if !cachePath.isEmpty
{
	var entries: [String: CacheEntry] = [:]
	for record in records.compactMap({ $0 })
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


// ---------------------------------------------------------------------
// 視覚特徴だけで並べ替える（--seriate・EXIF を使わない）
//
// **理屈**: 歩きながら撮った写真は「撮影順に離れるほど似ていない」。この性質を
// 持つ類似度行列を Robinson 行列と呼び、**その並べ替えはグラフラプラシアンの
// 第 2 固有ベクトル（フィードラーベクトル）で復元できる**ことが知られている
// （Atkins, Boman & Hendrickson 1998）。閾値もクラスタ数も要らない。
//
// この現場の実測（隔たりごとの距離が 0.242 → 0.456 へ単調に増える）は、まさに
// その前提が成り立っていることの確認になっている。**現場固有の数値合わせでは
// なく、撮影という物理過程から来る性質**なので、他の現場へも持ち越せる。
// ---------------------------------------------------------------------

if let neighbourCount = seriateK, neighbourCount > 0, count > 10
{
	// --- 1. 相互 k 近傍グラフ（閾値を持たない） ---
	var neighbours = [[Int]](repeating: [], count: count)
	let neighbourLock = NSLock()
	matrix.withUnsafeBufferPointer
	{ buffer in
		guard let base = buffer.baseAddress
		else
		{
			return
		}
		DispatchQueue.concurrentPerform(iterations: count)
		{ index in
			var best: [(Int, Double)] = []
			for other in 0 ..< count where other != index
			{
				let value = distance(base, index, other, dimension)
				if best.count < neighbourCount
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
			neighbours[index] = best.map(\.0)
			neighbourLock.unlock()
		}
	}

	var weights = [[(node: Int, weight: Double)]](repeating: [], count: count)
	var edgeCount = 0
	matrix.withUnsafeBufferPointer
	{ buffer in
		guard let base = buffer.baseAddress
		else
		{
			return
		}
		for index in 0 ..< count
		{
			for other in neighbours[index] where other > index && neighbours[other].contains(index)
			{
				// 相互に上位へ入った組だけを辺にする（片側だけの近傍は、
				// ハブになった 1 枚が全体を繋いでしまうので採らない）。
				let weight = max(0.001, 1 - distance(base, index, other, dimension))
				weights[index].append((other, weight))
				weights[other].append((index, weight))
				edgeCount += 1
			}
		}
	}

	// --- 2. 連結成分 ---
	var parent = Array(0 ..< count)
	func findRoot(_ node: Int) -> Int
	{
		var root = node
		while parent[root] != root
		{
			parent[root] = parent[parent[root]]
			root = parent[root]
		}
		return root
	}
	for index in 0 ..< count
	{
		for edge in weights[index]
		{
			let left = findRoot(index)
			let right = findRoot(edge.node)
			if left != right
			{
				parent[right] = left
			}
		}
	}
	var components: [Int: [Int]] = [:]
	for index in 0 ..< count
	{
		components[findRoot(index), default: []].append(index)
	}
	let sortedComponents = components.values.sorted { $0.count > $1.count }

	// --- 3. 成分ごとにフィードラーベクトルで並べる ---
	func fiedlerOrder(_ nodes: [Int]) -> [Int]
	{
		guard nodes.count > 2
		else
		{
			return nodes
		}
		var localIndex: [Int: Int] = [:]
		for (position, node) in nodes.enumerated()
		{
			localIndex[node] = position
		}
		let size = nodes.count
		var adjacency = [[(Int, Double)]](repeating: [], count: size)
		var degree = [Double](repeating: 0, count: size)
		for (position, node) in nodes.enumerated()
		{
			for edge in weights[node]
			{
				guard let other = localIndex[edge.node]
				else
				{
					continue
				}
				adjacency[position].append((other, edge.weight))
				degree[position] += edge.weight
			}
		}
		// B = cI - L（L = D - W）の最大固有ベクトルを、定数ベクトルを
		// 除きながら冪乗法で求める。それが L の第 2 固有ベクトル。
		let shift = 2 * (degree.max() ?? 1)
		// 初期ベクトルは決定的に散らす（乱数を使わないので結果が再現する）。
		var vector = [Double](repeating: 0, count: size)
		for position in 0 ..< size
		{
			let sign: Double = position % 2 == 0 ? 1 : -1
			let magnitude = 1 + Double(position) / Double(size)
			vector[position] = sign * magnitude
		}
		for _ in 0 ..< 4000
		{
			var next = [Double](repeating: 0, count: size)
			for position in 0 ..< size
			{
				var sum = (shift - degree[position]) * vector[position]
				for edge in adjacency[position]
				{
					sum += edge.1 * vector[edge.0]
				}
				next[position] = sum
			}
			let mean = next.reduce(0, +) / Double(size)
			for position in 0 ..< size
			{
				next[position] -= mean
			}
			let norm = next.reduce(0) { $0 + $1 * $1 }.squareRoot()
			guard norm > 0
			else
			{
				break
			}
			vector = next.map { $0 / norm }
		}
		return nodes.enumerated()
			.sorted { vector[$0.offset] < vector[$1.offset] }
			.map(\.element)
	}

	var spectralOrder: [Int] = []
	for nodes in sortedComponents
	{
		spectralOrder.append(contentsOf: fiedlerOrder(nodes))
	}

	// --- 4. 報告 ---
	print("")
	print("■ 視覚特徴だけで並べ替える（EXIF 不使用・スペクトル法）")
	print("  相互 \(neighbourCount) 近傍グラフ  辺 \(edgeCount) 本")
	print("  連結成分 \(sortedComponents.count) 個  大きい順: "
		+ sortedComponents.prefix(6).map { String($0.count) }.joined(separator: " / "))

	matrix.withUnsafeBufferPointer
	{ buffer in
		guard let base = buffer.baseAddress
		else
		{
			return
		}
		print("  隔たりごとの距離（**この並べ替えでの**中央値）")
		print("    隔たり   中央値     組数")
		for offset in offsets
		{
			var values: [Double] = []
			for index in 0 ..< (spectralOrder.count - offset)
			{
				values.append(distance(
					base, spectralOrder[index], spectralOrder[index + offset], dimension))
			}
			print(String(
				format: "    %5d %9@ %8d", offset, format(median(values)) as NSString, values.count))
		}
	}

	// 撮影順（EXIF）との一致。**EXIF を答え合わせにだけ使う**。
	var position = [Int](repeating: 0, count: count)
	for (rank, node) in spectralOrder.enumerated()
	{
		position[node] = rank
	}
	var adjacentInBoth = 0
	var comparable = 0
	for index in 0 ..< (count - 1)
	{
		comparable += 1
		if abs(position[index] - position[index + 1]) <= 3
		{
			adjacentInBoth += 1
		}
	}
	print(String(
		format: "  撮影順で隣り合う組のうち、この並べ替えでも 3 以内: %.2f（%d/%d）",
		Double(adjacentInBoth) / Double(max(1, comparable)), adjacentInBoth, comparable))
	print("  → 隔たり 1 の距離が撮影順のときと同等以下なら、**EXIF 無しで同じ品質の")
	print("    並びが作れている**。一致率そのものは高くなくてよい（別の道順でも")
	print("    「隣は重なっている」が成り立てば窓としては等価）")
}


// ---------------------------------------------------------------------
// 窓を作って書き出す（--windows）
//
// **設計 §3.1 の支持成長をそのまま実装したもの。** EXIF を一切使わないので、
// 撮影時刻の無い写真も同じ経路で窓に入る（そこが検証したい点）。
// 書き出したファイル一覧は measure-poses --window-dir で Object Capture へ
// 投げられる。**本格実装の前に、この窓が実際に通るかを確かめるための道具。**
// ---------------------------------------------------------------------

if let capacity = windowCapacity, capacity > 1, dominantDimension > 0
{
	let members = photos.filter { ($0.elements?.count ?? 0) == dominantDimension }
	let total = members.count
	let width = dominantDimension
	log("窓を作ります（対象 \(total) 枚・容量 \(capacity)・近傍 \(neighbourCount)"
		+ "・重なり \(Int(overlapRatio * 100))%）")

	var vectors = [Float](repeating: 0, count: total * width)
	for (index, record) in members.enumerated()
	{
		vectors.replaceSubrange(index * width ..< (index + 1) * width, with: record.elements ?? [])
	}

	// --- 相互 k 近傍グラフ（閾値を持たない） ---
	var topNeighbours = [[Int]](repeating: [], count: total)
	let topLock = NSLock()
	vectors.withUnsafeBufferPointer
	{ buffer in
		guard let base = buffer.baseAddress
		else
		{
			return
		}
		DispatchQueue.concurrentPerform(iterations: total)
		{ index in
			var best: [(Int, Double)] = []
			for other in 0 ..< total where other != index
			{
				let value = distance(base, index, other, width)
				if best.count < neighbourCount
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
			topLock.lock()
			topNeighbours[index] = best.map(\.0)
			topLock.unlock()
		}
	}

	var mutual = [[Int]](repeating: [], count: total)
	for index in 0 ..< total
	{
		for other in topNeighbours[index]
			where other > index && topNeighbours[other].contains(index)
		{
			mutual[index].append(other)
			mutual[other].append(index)
		}
	}
	let edgesBefore = mutual.reduce(0) { $0 + $1.count } / 2

	// --- 共通近傍フィルタ（設計 §2.2） ---
	let neighbourSets = mutual.map { Set($0) }
	var graph = [[Int]](repeating: [], count: total)
	for index in 0 ..< total
	{
		for other in mutual[index]
			where neighbourSets[index].intersection(neighbourSets[other]).count >= 2
		{
			graph[index].append(other)
		}
	}
	var edgesAfter = graph.reduce(0) { $0 + $1.count } / 2

	// --- Object Capture の結果を取り込む（--feedback） ---
	//
	// **自前ではできなかった幾何検証を、Object Capture が副産物としてやってくれる。**
	// かたまりの空似（設計 §9-2）に効く唯一の手。規則は 3 つに分ける。
	//
	//   両方に姿勢   同じ再構成に入った ＝ 幾何的に繋がっている → **確定**（守る）
	//   片方だけ姿勢 OC が両方を手にして繋げなかった          → **取り除く**
	//   両方とも無し どちらも落ちただけ                      → **触らない**
	//
	// 3 行目が要点。OC は一貫した最大の集合を 1 つだけ返すので、窓の中に繋がらない
	// 2 つの領域があると小さいほうは丸ごと落ちる。**落ちた者どうしは互いに正しく
	// 繋がっている可能性がある**ので、ここを消すと本物を失う。
	var confirmedEdges = 0
	var removedEdges = 0
	/// 姿勢を読めた窓の数。**確定でも除去でもない辺の大半は「両端とも姿勢なし」
	/// ではなく「そもそも同じ窓に入っていないので判定していない」**なので、
	/// 分母を出さないと結果を読み違える（実際に一度読み違えた）。
	var judgedWindows = 0
	/// 「両端がひとつの窓の中にあり、実際に見比べられた」辺の数。
	var judgedEdges = 0
	if !feedbackDirectory.isEmpty
	{
		var indexOfPath: [String: Int] = [:]
		for (index, record) in members.enumerated()
		{
			indexOfPath[root.appendingPathComponent(record.relativePath).path] = index
		}
		let names = (try? FileManager.default.contentsOfDirectory(atPath: feedbackDirectory)) ?? []
		var confirmed = Set<Int>()   // a * total + b（a < b）
		var refuted = Set<Int>()
		var judged = Set<Int>()
		var windowsRead = 0
		for name in names.sorted() where name.hasSuffix(".poses.tsv")
		{
			let path = (feedbackDirectory as NSString).appendingPathComponent(name)
			guard let text = try? String(contentsOfFile: path, encoding: .utf8)
			else
			{
				continue
			}
			var posed: [Int] = []
			var unposed: [Int] = []
			for line in text.split(separator: "\n") where !line.hasPrefix("#")
			{
				let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
				guard columns.count >= 2, let index = indexOfPath[String(columns[0])]
				else
				{
					continue
				}
				if columns[1] == "1"
				{
					posed.append(index)
				}
				else
				{
					unposed.append(index)
				}
			}
			guard !posed.isEmpty
			else
			{
				// 窓ごと落ちた（error 6）。**何も学べないので触らない。**
				continue
			}
			windowsRead += 1
			// **見比べられた辺**（両端がこの窓の中にある辺）。姿勢の有無に
			// かかわらず数える。確定でも除去でもない辺の大半は、両端が同じ窓に
			// 入っていないだけで**まだ何も分かっていない**。
			let inWindow = Set(posed).union(unposed)
			for node in inWindow
			{
				for next in graph[node] where next > node && inWindow.contains(next)
				{
					judged.insert(node * total + next)
				}
			}
			let posedSet = Set(posed)
			for node in posed
			{
				for next in graph[node] where next > node && posedSet.contains(next)
				{
					confirmed.insert(node * total + next)
				}
			}
			let unposedSet = Set(unposed)
			for node in posed
			{
				for next in graph[node] where unposedSet.contains(next)
				{
					refuted.insert(min(node, next) * total + max(node, next))
				}
			}
		}
		// 一度でも確定した辺は守る（別の窓では落ちていても、繋がる証拠がある）。
		refuted.subtract(confirmed)
		if windowsRead > 0
		{
			for node in 0 ..< total
			{
				graph[node] = graph[node].filter
				{ next in
					!refuted.contains(min(node, next) * total + max(node, next))
				}
			}
			confirmedEdges = confirmed.count
			removedEdges = refuted.count
			judgedWindows = windowsRead
			judgedEdges = judged.count
			edgesAfter = graph.reduce(0) { $0 + $1.count } / 2
			log("Object Capture の結果を取り込みました（窓 \(judgedWindows) 個・"
				+ "見比べられた辺 \(judgedEdges) 本・"
				+ "確定 \(confirmedEdges) 本・除去 \(removedEdges) 本）")
		}
	}

	// --- 支持成長（設計 §3.1）---
	var covered = [Bool](repeating: false, count: total)
	/// これ未満の窓は解体して最も近い窓へ入れる。成長の下限でもある。
	let minimumWindow = max(10, capacity / 10)

	/// 次の種。**既に覆われた領域からグラフ上で最も遠い写真**を選ぶ（最遠点
	/// サンプリング）。
	///
	/// 種を「未被覆で次数最大」にしていたときは、覆い終わったあとに残った
	/// 孤立気味の写真を種にするたびに既存の写真ばかりの窓ができ、実データで
	/// 窓が 57 個になった。**遠いところから順に取れば、窓は自然に散らばり、
	/// 重なりは窓どうしがぶつかったところにだけできる。**
	///
	/// 最遠点サンプリングは施設配置問題の標準的な貪欲法で、「最も近い種までの
	/// 距離」の最大値を最適の 2 倍以内に抑える保証がある。乱数も要らない。
	/// **同距離なら添字の小さいほう**（設計 §3.1.1-(1)）。
	func nextSeed() -> Int?
	{
		// 覆われた写真すべてを始点にした多重始点の幅優先で、各写真の
		// 「覆われた領域までの距離」を求める。
		var distanceToCovered = [Int](repeating: Int.max, count: total)
		var queue: [Int] = []
		for index in 0 ..< total where covered[index]
		{
			distanceToCovered[index] = 0
			queue.append(index)
		}
		var head = 0
		while head < queue.count
		{
			let node = queue[head]
			head += 1
			for next in graph[node] where distanceToCovered[next] == Int.max
			{
				distanceToCovered[next] = distanceToCovered[node] + 1
				queue.append(next)
			}
		}
		var best = -1
		var bestDistance = -1
		var bestDegree = -1
		for index in 0 ..< total where !covered[index]
		{
			// 到達できない（別の連結成分）写真は最も遠いものとして扱う。
			let value = distanceToCovered[index] == Int.max ? Int.max - 1 : distanceToCovered[index]
			if value > bestDistance || (value == bestDistance && graph[index].count > bestDegree)
			{
				best = index
				bestDistance = value
				bestDegree = graph[index].count
			}
		}
		return best >= 0 ? best : nil
	}

	/// 支持数（いまの集合へ何本つながっているか）が多い順に足す。
	///
	/// **2 段階に分ける。** まず**まだどの窓にも入っていない写真だけ**で育て
	/// （新規の枠まで）、そのあとで**既に覆われた写真を襟として足す**（容量まで）。
	///
	/// 段階を分けないと、覆い終わったあとに残った孤立気味の写真を種にするたびに、
	/// **既存の写真ばかりの窓がもう 1 つできる**。実データでそうなった —
	/// 1424 枚に対して窓 57 個・1 枚あたり平均 8.1 個の窓に入り、そのうち 33 個は
	/// 新規が 5 枚未満だった。**重なりは意図して作るものであって、
	/// 副作用で増えてよいものではない。**
	/// 細い繋ぎ目（支持数 1 の候補しか無い状態）を越えた回数。窓ごとに数える。
	var thinCrossings = 0
	/// 写真を足したときの支持数。**窓の中身がどれだけ強く結ばれているか**の材料。
	var admissionSupports: [Int] = []

	func grow(from seed: Int) -> [Int]
	{
		// **段階 1: まだ覆われていない写真だけで育てる**（容量 ×(1 - 重なり率)）。
		// **段階 2: 襟（既に覆われた写真）を容量まで足す。ただし支持数 1 しか
		// 残っていなければ埋めずに止める。**
		//
		// 両方の失敗を踏まえた形。段階を分けないと、覆い終わったあとに残った
		// 写真を種にするたび既存の写真ばかりの窓ができる（実データで 57 個）。
		// 逆に止め方を「支持数 2 未満」だけにすると窓が砕ける（同 71 個・中央値
		// 51 枚）。**枠は段階 1 にだけ課し、段階 2 は良い材料がある間だけ埋める。**
		//
		// 合成グラフでの見積もり（n=1337・容量 200・重なり 30%）:
		//   窓 9〜10 個・各 200 枚・延べ 1.35〜1.50 倍・隣接の重なり 60〜118 枚
		//   （かたまりの空似を入れても同じ）
		let freshTarget = max(1, Int(Double(capacity) * (1 - overlapRatio)))
		var inside: Set<Int> = [seed]
		var order = [seed]
		var fresh = 1
		var support: [Int: Int] = [:]
		for node in graph[seed]
		{
			support[node, default: 0] += 1
		}

		/// 支持数が最大の候補。**同数なら添字の小さいほう**（決定的にする）。
		func best(freshOnly: Bool) -> (node: Int, support: Int)?
		{
			var bestNode = -1
			var bestSupport = -1
			for (node, value) in support where !freshOnly || !covered[node]
			{
				if value > bestSupport || (value == bestSupport && node < bestNode)
				{
					bestNode = node
					bestSupport = value
				}
			}
			return bestNode >= 0 ? (bestNode, bestSupport) : nil
		}

		func add(_ node: Int, _ value: Int)
		{
			admissionSupports.append(value)
			if value < 2
			{
				thinCrossings += 1
			}
			support.removeValue(forKey: node)
			inside.insert(node)
			order.append(node)
			if !covered[node]
			{
				fresh += 1
			}
			for next in graph[node] where !inside.contains(next)
			{
				support[next, default: 0] += 1
			}
		}

		// **--grow-full: 被覆を見ずに容量まで育てる。** どの窓も、その領域で
		// 最良の N 枚になる（成長順に左右されない）。重なりは増えるが、設計は
		// 「重なりは多いほど良い」側（§1.2・§3.3）。
		if growFull
		{
			while inside.count < capacity, let candidate = best(freshOnly: false)
			{
				add(candidate.node, candidate.support)
			}
			return order
		}

		while fresh < freshTarget, inside.count < capacity, let candidate = best(freshOnly: true)
		{
			add(candidate.node, candidate.support)
		}
		while inside.count < capacity, let candidate = best(freshOnly: false)
		{
			// **襟は良い材料がある間だけ。** 支持数 1 しか残っていないなら、
			// 枠を埋めるために弱い繋がりを引き込まずに止める。切れた先とは
			// あとで繋ぎ目の写真を共有する（「細い繋ぎ目の補修」）。
			if candidate.support < 2
			{
				break
			}
			add(candidate.node, candidate.support)
		}
		return order
	}

	var windows: [[Int]] = []
	var crossingsPerWindow: [Int] = []
	var supportsPerWindow: [[Int]] = []
	// **残りが下限を割ったら打ち切る。** 最後の数枚のために「既存の写真ばかりの
	// 窓」をもう 1 つ作るのが、窓が増えすぎるいちばんの原因だった。残りは
	// はぐれとして最も近い窓へ入れる。
	while (0 ..< total).filter({ !covered[$0] }).count >= minimumWindow, let seed = nextSeed()
	{
		thinCrossings = 0
		admissionSupports = []
		let window = grow(from: seed)
		for node in window
		{
			covered[node] = true
		}
		windows.append(window)
		crossingsPerWindow.append(thinCrossings)
		supportsPerWindow.append(admissionSupports)
	}

	// --- はぐれの吸収 ---
	//
	// **小さい窓は解体しない。** 実機で 40 枚の窓（床下）が単独で通り、35 枚中
	// 15 枚に姿勢が付いた。**単独でモデルになるなら、他へ混ぜて容量を食わせるより
	// そのまま出したほうが有用**（混ぜた先を汚す危険も無い）。
	//
	// 解体するのは `keepFloor` を下回るものだけ。グラフ上で孤立した写真
	// （実データで次数 0 が 155 枚）は 1 枚の窓になってしまうので、そこだけは
	// **最も見た目の近い写真がいる窓へ入れる**。
	/// これを下回る窓だけ解体する。**再構成に足りるかどうかは Object Capture が
	/// 決めることなので、こちらで先回りして捨てない。**
	let keepFloor = max(8, minimumWindow / 2)
	var strays = (0 ..< total).filter { !covered[$0] }
	var kept: [[Int]] = []
	// **解体したぶんは、付随する配列からも同時に落とす。** ここを揃えないと
	// 以降の添字が 1 つずつずれ、**支持数中央とコンダクタンスが別の窓の値**に
	// なる（順位付けが第 4 段でこれを見ているので、選ぶ窓まで変わる）。
	var keptCrossings: [Int] = []
	var keptSupports: [[Int]] = []
	for (index, window) in windows.enumerated()
	{
		if window.count >= keepFloor
		{
			kept.append(window)
			keptCrossings.append(index < crossingsPerWindow.count ? crossingsPerWindow[index] : 0)
			keptSupports.append(index < supportsPerWindow.count ? supportsPerWindow[index] : [])
		}
		else
		{
			strays.append(contentsOf: window)
		}
	}
	let strayCount = strays.count
	/// 窓ごとの「はぐれ（後から見た目だけで入れた写真）」。**支持成長で育てた
	/// 部分はグラフ上で必ず連結**（支持数 1 以上でしか足さないため）なので、
	/// 窓が内部で分断されるとしたら原因はここにしかない。実データで最大成分が
	/// 0.48〜0.62 まで落ちた窓があり、それは「繋がらない 2 つの塊を 1 回の
	/// 再構成へ渡している」ことを意味する（設計 §6.2.2）。
	var strayMembers = [Set<Int>](repeating: [], count: kept.count)
	if !kept.isEmpty, !strays.isEmpty
	{
		// 受け入れ側の写真 → 窓の番号
		var owner: [Int: Int] = [:]
		for (index, window) in kept.enumerated()
		{
			for node in window
			{
				owner[node] = index
			}
		}
		let hosts = Array(owner.keys).sorted()
		vectors.withUnsafeBufferPointer
		{ buffer in
			guard let base = buffer.baseAddress
			else
			{
				return
			}
			for stray in strays
			{
				var bestHost = hosts[0]
				var bestDistance = Double.infinity
				for host in hosts
				{
					let value = distance(base, stray, host, width)
					if value < bestDistance
					{
						bestDistance = value
						bestHost = host
					}
				}
				if let index = owner[bestHost]
				{
					kept[index].append(stray)
					strayMembers[index].insert(stray)
				}
			}
		}
	}
	if kept.isEmpty
	{
		// 十分な大きさの窓が 1 つも作れなかった（グラフがほぼ空）。
		// 全部を 1 つの窓にして、判断は Object Capture へ渡す。
		kept = [Array(0 ..< total)]
		keptCrossings = [0]
		keptSupports = [[]]
	}
	windows = kept
	crossingsPerWindow = keptCrossings
	supportsPerWindow = keptSupports

	// --- 窓の中の並び（設計 §3.4）: 端から端への幅優先 ---
	func localOrder(_ window: [Int]) -> [Int]
	{
		let inside = Set(window)
		func distances(from start: Int) -> [Int: Int]
		{
			var result = [start: 0]
			var queue = [start]
			var head = 0
			while head < queue.count
			{
				let node = queue[head]
				head += 1
				for next in graph[node] where inside.contains(next) && result[next] == nil
				{
					result[next] = (result[node] ?? 0) + 1
					queue.append(next)
				}
			}
			return result
		}
		let fromSeed = distances(from: window[0])
		var far = window[0]
		var farthest = -1
		for (node, value) in fromSeed where value > farthest || (value == farthest && node < far)
		{
			far = node
			farthest = value
		}
		let fromEnd = distances(from: far)
		return window.sorted
		{ left, right in
			let a = fromEnd[left] ?? Int.max
			let b = fromEnd[right] ?? Int.max
			return a == b ? left < right : a < b
		}
	}

	/// **窓の中身がひとかたまりか、寄せ集めか**を、EXIF を使わずに測る。
	///
	/// コンダクタンス（外への漏れ）だけでは判別できなかった — 実データで、
	/// 17 個の断片が寄り集まった窓が 2 番目に低いコンダクタンスを示しながら
	/// 最悪の結果になった。**外との関係ではなく、内部の結び方**を見る必要がある。
	///
	/// - 平均内部次数: 窓の中だけで数えた次数。高いほど密
	/// - 3 コア: 内部次数 3 未満の写真を取り除き続けて残る割合。**寄せ集めだと
	///   細い繋ぎで付いている写真が次々に剥がれて小さくなる**
	/// - 最大成分: 3 コアの中で最大の連結成分が窓に占める割合。**ひとかたまりなら
	///   1 に近く、断片の寄せ集めなら小さい**（「最大の塊」の EXIF 不使用版）
	func interiorStructure(_ window: [Int])
		-> (degree: Double, core: Double, largest: Double, connected: Double)
	{
		let inside = Set(window)
		var alive = inside

		/// 与えられた集合の中での最大連結成分の大きさ。
		func largestComponent(_ nodes: Set<Int>) -> Int
		{
			var unseen = nodes
			var largest = 0
			while let start = unseen.first
			{
				var size = 0
				var queue = [start]
				unseen.remove(start)
				var head = 0
				while head < queue.count
				{
					let node = queue[head]
					head += 1
					size += 1
					for next in graph[node] where unseen.contains(next)
					{
						unseen.remove(next)
						queue.append(next)
					}
				}
				largest = max(largest, size)
			}
			return largest
		}

		// **窓そのものの連結性**（3 コアに削る前）。支持成長で育てた部分は必ず
		// 連結なので、これが 1.00 を下回るぶんは**後から入れたはぐれ**にしか
		// 由来しない。**1 回の再構成で繋がりようがない写真が何割いるか**を表す。
		let connectedShare = Double(largestComponent(inside)) / Double(max(1, window.count))
		var internalEdges = 0
		for node in window
		{
			internalEdges += graph[node].filter { inside.contains($0) }.count
		}
		let averageDegree = Double(internalEdges) / Double(max(1, window.count))

		// 3 コア（内部次数 3 未満を取り除き続ける）
		var changed = true
		while changed
		{
			changed = false
			for node in alive
				where graph[node].filter({ alive.contains($0) }).count < 3
			{
				alive.remove(node)
				changed = true
				break
			}
		}
		let coreShare = Double(alive.count) / Double(max(1, window.count))

		// 3 コアの中の最大連結成分（**芯の太さ**。上の connectedShare とは別物で、
		// こちらは必ず coreShare 以下になる）
		let largest = largestComponent(alive)
		return (averageDegree, coreShare,
			Double(largest) / Double(max(1, window.count)), connectedShare)
	}

	/// 窓から外へ出る辺の割合（設計 §3.1.1-(2)）。**停止条件ではなく指標**。
	func conductance(_ window: [Int]) -> Double
	{
		let inside = Set(window)
		var cut = 0
		var volume = 0
		for node in window
		{
			for next in graph[node]
			{
				volume += 1
				if !inside.contains(next)
				{
					cut += 1
				}
			}
		}
		return volume > 0 ? Double(cut) / Double(volume) : 0
	}

	// --- 細い繋ぎ目の補修 ---
	//
	// **グラフ上では接しているのに写真を 1 枚も共有していない窓の対**を探し、
	// 繋ぎ目の写真を両側へ少しだけ入れる。成長を支持数 1 で止めているので、
	// 本物の細い繋がり（廊下の突き当たりなど）はここで切れている。共有写真が
	// 無いと合成のポーズグラフが繋がらない — §1.2 でいう「分断」のいちばん
	// 高くつく形なので、必ず塞ぐ。
	//
	// 空似だった場合のコストは「数枚の混入」と「merge の RANSAC が落とす偽の
	// 隣接」だけで、どちらに転んでも安い側に倒れる。
	var sets = windows.map { Set($0) }
	var repairedPairs = 0
	let linkCollar = max(4, minimumWindow / 2)
	for left in 0 ..< windows.count
	{
		for right in (left + 1) ..< windows.count
			where sets[left].intersection(sets[right]).isEmpty
		{
			// 2 つの窓をまたぐ辺の端点を、またぐ本数の多い順に採る。
			var fromRight: [Int: Int] = [:]
			var fromLeft: [Int: Int] = [:]
			for node in windows[left]
			{
				for next in graph[node] where sets[right].contains(next)
				{
					fromRight[next, default: 0] += 1
					fromLeft[node, default: 0] += 1
				}
			}
			guard !fromRight.isEmpty
			else
			{
				continue
			}
			func pick(_ counts: [Int: Int]) -> [Int]
			{
				counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
					.prefix(linkCollar).map(\.key)
			}
			for node in pick(fromRight)
			{
				windows[left].append(node)
				sets[left].insert(node)
			}
			for node in pick(fromLeft)
			{
				windows[right].append(node)
				sets[right].insert(node)
			}
			repairedPairs += 1
		}
	}

	// --- 書き出し ---
	let directory = URL(fileURLWithPath: windowDirectory, isDirectory: true)
	try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	var multiplicity = [Int](repeating: 0, count: total)
	/// 撮影順での位置（**検算にだけ使う**。窓を作るのには使っていない）。
	var captureIndex: [String: Int] = [:]
	for (index, record) in ordered.enumerated()
	{
		captureIndex[record.relativePath] = index
	}

	print("")
	print("■ 支持成長で作った窓（EXIF 不使用・設計 §3.1）")
	print("  相互 \(neighbourCount) 近傍 \(edgesBefore) 本 → 共通近傍フィルタ後 \(edgesAfter) 本")
	if !feedbackDirectory.isEmpty
	{
		// **分母を必ず添える。** 「確定でも除去でもない辺」の大半は両端が同じ窓に
		// 入っていないだけで、まだ何も分かっていない。判定できた辺の数を出さないと
		// 「残りは全部おかしい辺」と読み違える。
		let untouched = max(0, judgedEdges - confirmedEdges - removedEdges)
		// 分母は**取り込む前**の辺の数（いまの edgesAfter は除去した後の値）。
		let beforeFeedback = edgesAfter + removedEdges
		let share = beforeFeedback > 0 ? Double(judgedEdges) * 100 / Double(beforeFeedback) : 0
		print("  OC の結果を反映: 窓 \(judgedWindows) 個ぶんの姿勢から"
			+ "確定 \(confirmedEdges) 本・除去 \(removedEdges) 本")
		print("    見比べられた辺 \(judgedEdges) 本（全体の \(format(share, 1))%）"
			+ "・うち両端とも姿勢なし \(untouched) 本")
		print("    → **残りの辺は「正しい」のではなく「まだ見ていない」**。"
			+ "全部の窓の姿勢が揃うまで判定は伸びない")
	}
	var degrees: [Int: Int] = [:]
	for row in graph
	{
		degrees[row.count, default: 0] += 1
	}
	let isolated = degrees[0] ?? 0
	print("  次数 0（どこにも繋がらない写真）: \(isolated) 枚"
		+ "  平均次数 \(String(format: "%.1f", Double(2 * edgesAfter) / Double(max(1, total))))")
	print("  窓 \(windows.count) 個（小さすぎて解体し、最も近い窓へ入れた写真 \(strayCount) 枚）")
	print("  細い繋ぎ目の補修: \(repairedPairs) 対（接しているのに共有ゼロだった窓の対）")
	// 窓どうしの重なり（**枠で強制せず、ぶつかったところに自然にできたもの**）。
	var maximumShared = [Int](repeating: 0, count: windows.count)
	for left in 0 ..< windows.count
	{
		for right in (left + 1) ..< windows.count
		{
			let shared = sets[left].intersection(sets[right]).count
			maximumShared[left] = max(maximumShared[left], shared)
			maximumShared[right] = max(maximumShared[right], shared)
		}
	}

	// **はぐれを外した「芯」も書き出す。** 支持成長で育てた部分はグラフ上で必ず
	// 連結なので、芯は「1 回の再構成で繋がるはず」と言い切れる唯一の集合になる。
	// 窓が落ちたときに、原因がはぐれの混入なのか中身そのものなのかを、往復せずに
	// 切り分けられる（設計 §3.6 の梯子の 3 段目より前に試すべき手）。
	let coreDirectory = directory.appendingPathComponent("core", isDirectory: true)
	try? FileManager.default.createDirectory(at: coreDirectory, withIntermediateDirectories: true)
	var coreCount = 0

	var verification: [(Int, Int, Double, Int, Int)] = []
	/// **windows.tsv の行**（機械可読）。人が読む表とまったく同じ数字で、
	/// trial-clustering.sh が「次にどの窓を投げるか」を決めるのに使う。
	/// 目で読んで選ぶ作業を自動化するためのもので、判断は増えていない。
	var machineRows: [String] = []
	/// 窓ごとの芯の有無（windows.tsv の hascore 列）。
	var hasCore = [Bool](repeating: false, count: windows.count)
	print("  【EXIF 不使用】番号  枚数  はぐれ  重なり  連結  内部次数  3コア  芯の成分  支持数中央  コンダクタンス")
	for (index, window) in windows.enumerated()
	{
		let sequence = localOrder(window)
		for node in window
		{
			multiplicity[node] += 1
		}
		let lines = sequence.map { root.appendingPathComponent(members[$0].relativePath).path }
		let file = directory.appendingPathComponent(String(format: "window-%02d.txt", index + 1))
		try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

		let strayHere = index < strayMembers.count ? strayMembers[index] : []
		if !strayHere.isEmpty
		{
			let core = window.filter { !strayHere.contains($0) }
			if core.count >= keepFloor
			{
				let coreLines = localOrder(core)
					.map { root.appendingPathComponent(members[$0].relativePath).path }
				try? coreLines.joined(separator: "\n").write(
					to: coreDirectory.appendingPathComponent(
						String(format: "window-%02d.txt", index + 1)),
					atomically: true, encoding: .utf8)
				coreCount += 1
				hasCore[index] = true
			}
		}

		// **撮影順の「塊」の数**。四分位範囲（散らばり）では、別日に同じ場所を
		// 撮った窓が正しくても大きく出てしまい、混入と区別が付かない。
		// 「2〜3 個の塊で大半を占める」＝再訪、「細かい塊に散る」＝混入。
		let positions = window.compactMap { captureIndex[members[$0].relativePath] }.sorted()
		var runs: [Int] = []
		var current = 0
		for (order, value) in positions.enumerated()
		{
			if order > 0, value - positions[order - 1] > 10
			{
				runs.append(current)
				current = 0
			}
			current += 1
		}
		if current > 0
		{
			runs.append(current)
		}
		let largest = runs.max() ?? 0
		let share = positions.isEmpty ? 0.0 : Double(largest) / Double(positions.count)
		let structure = interiorStructure(window)
		let supports = (index < supportsPerWindow.count ? supportsPerWindow[index] : []).sorted()
		let medianSupport = supports.isEmpty ? 0 : supports[supports.count / 2]
		print(String(
			format: "               %4d %5d %7d %7d %5@ %9@ %6@ %9@ %10d %14@",
			index + 1, window.count, strayHere.count, maximumShared[index],
			format(structure.connected, 2) as NSString,
			format(structure.degree, 1) as NSString,
			format(structure.core, 2) as NSString,
			format(structure.largest, 2) as NSString,
			medianSupport,
			format(conductance(window), 3) as NSString))
		verification.append((index + 1, runs.count, share, window.count - positions.count,
			index < crossingsPerWindow.count ? crossingsPerWindow[index] : 0))
		// **型注釈を付けておく。** 要素の多い配列リテラルは型推論が重く、
		// このリポジトリでは実際に型検査が終わらなくなったことがある。
		let columns: [String] = [
			String(format: "window-%02d.txt", index + 1),
			String(window.count),
			String(strayHere.count),
			String(maximumShared[index]),
			format(structure.connected, 4),
			format(structure.degree, 3),
			format(structure.core, 4),
			format(structure.largest, 4),
			String(medianSupport),
			format(conductance(window), 4),
			String(index < crossingsPerWindow.count ? crossingsPerWindow[index] : 0),
			String(runs.count),
			format(share, 4),
		]
		machineRows.append(columns.joined(separator: "\t"))
	}

	print("  【検算・EXIF】  番号  撮影順の塊  最大の塊  時刻なし  細い繋ぎ目")
	for row in verification
	{
		print(String(
			format: "               %4d %11d %9@ %9d %11d",
			row.0, row.1, format(row.2, 2) as NSString, row.3, row.4))
	}

	var histogram: [Int: Int] = [:]
	for value in multiplicity
	{
		histogram[value, default: 0] += 1
	}
	// --- 分割案の書き出し ---
	//
	// **error 6 で落ちた窓は、その場で半分に割って試せるようにしておく。**
	// 実機で「散っている窓（撮影順の塊 23 個）」が落ちたが、同じ現場の写真である
	// 以上、まとまりさえすればモデルになるはず。設計 §3.6 の「縮めて再試行」を
	// 往復無しでできるよう、窓の中でもう一度支持成長を回した結果を添えておく。
	let splitDirectory = directory.appendingPathComponent("split", isDirectory: true)
	try? FileManager.default.createDirectory(
		at: splitDirectory, withIntermediateDirectories: true)

	/// 与えられた集合の中だけで支持成長する（窓を割るため）。
	func growWithin(_ nodes: [Int], from seed: Int, capacity: Int) -> [Int]
	{
		let allowed = Set(nodes)
		var inside: Set<Int> = [seed]
		var order = [seed]
		var support: [Int: Int] = [:]
		for node in graph[seed] where allowed.contains(node)
		{
			support[node, default: 0] += 1
		}
		while inside.count < capacity, !support.isEmpty
		{
			var bestNode = -1
			var bestSupport = -1
			for (node, value) in support
			{
				if value > bestSupport || (value == bestSupport && node < bestNode)
				{
					bestNode = node
					bestSupport = value
				}
			}
			support.removeValue(forKey: bestNode)
			inside.insert(bestNode)
			order.append(bestNode)
			for next in graph[bestNode] where allowed.contains(next) && !inside.contains(next)
			{
				support[next, default: 0] += 1
			}
		}
		return order
	}

	var splitCount = 0
	var splitsPerWindow = [Int](repeating: 0, count: windows.count)
	for (index, window) in windows.enumerated() where window.count >= keepFloor * 3
	{
		let half = (window.count + 1) / 2
		var remaining = Set(window)
		var parts: [[Int]] = []
		while !remaining.isEmpty, parts.count < 4
		{
			// 種は残りのうち次数が最大のもの（同数なら添字の小さいほう）。
			var seed = -1
			var seedDegree = -1
			for node in remaining.sorted()
			{
				let degree = graph[node].filter { remaining.contains($0) }.count
				if degree > seedDegree
				{
					seed = node
					seedDegree = degree
				}
			}
			let part = growWithin(Array(remaining), from: seed, capacity: half)
			parts.append(part)
			remaining.subtract(part)
		}
		for (order, part) in parts.enumerated() where part.count >= keepFloor
		{
			let sequence = localOrder(part)
			let lines = sequence.map { root.appendingPathComponent(members[$0].relativePath).path }
			let name = String(
				format: "window-%02d%@.txt", index + 1,
				String(UnicodeScalar(UInt8(97 + min(order, 25)))))
			try? lines.joined(separator: "\n")
				.write(to: splitDirectory.appendingPathComponent(name),
					atomically: true, encoding: .utf8)
			splitCount += 1
			splitsPerWindow[index] += 1
		}
	}

	// --- 機械可読の指標（windows.tsv）---
	//
	// **反復（設計 §3.10）を人が表を読みながら回すのは現実的でない。** 1 巡ごとに
	// 「どの窓を次に投げるか」を選ぶ必要があり、それが数十回続く。選び方そのものは
	// 上の表に出ている数字だけで決まるので、同じ数字を機械可読で置いておく。
	// **人が読む表と 1 つも違う数字を出さない**（食い違えば、どちらを信じるかが
	// 分からなくなる）。
	let tsvHeader = "#name\tphotos\tstrays\tshared\tconnected\tavgdeg\tkcore"
		+ "\tkcorecomp\tmedsupport\tconductance\tthin\truns\tlargestrun\thascore\tsplits"
	var tsvLines: [String] = [
		"# measure-ordering --windows \(capacity) --neighbours \(neighbourCount)"
			+ " --overlap-ratio \(format(overlapRatio, 2))"
			+ (growFull ? " --grow-full" : ""),
		"# total=\(total) edges=\(edgesAfter) isolated=\(isolated) windows=\(windows.count)"
			+ " strays=\(strayCount) judgedwindows=\(judgedWindows) judgededges=\(judgedEdges)"
			+ " confirmed=\(confirmedEdges) removed=\(removedEdges)",
		tsvHeader,
	]
	for (index, row) in machineRows.enumerated()
	{
		tsvLines.append(row + "\t" + (hasCore[index] ? "1" : "0")
			+ "\t" + String(splitsPerWindow[index]))
	}
	try? tsvLines.joined(separator: "\n").appending("\n").write(
		to: directory.appendingPathComponent("windows.tsv"),
		atomically: true, encoding: .utf8)
	print("  分割案: \(splitCount) 個を \(splitDirectory.lastPathComponent)/ へ書き出し"
		+ "（error 6 の窓はこちらで再試行できる）")
	print("  はぐれ抜きの芯: \(coreCount) 個を \(coreDirectory.lastPathComponent)/ へ書き出し"
		+ "（**最大成分が 1.00 未満の窓は、はぐれが原因**。まずこちらで試す）")

	print("  所属する窓の数の分布: "
		+ histogram.sorted { $0.key < $1.key }.map { "\($0.key)個×\($0.value)枚" }
			.joined(separator: " "))
	print("  → **0 個が 1 枚でもあれば被覆が壊れている**（設計 §3.2）")
	print("  → 撮影順の塊は検算用（窓を作るのには使っていない）。**塊が少なく最大の")
	print("    塊が大半を占めていれば健全**。別日の再訪でも塊は 2〜3 個で収まる。")
	print("    細かい塊に散っていたら混入（設計 §9-2 のかたまりの空似）")
	print("  書き出し先: \(directory.path)")
	print("  機械可読の指標: \(directory.appendingPathComponent("windows.tsv").path)"
		+ "（trial-clustering.sh が次に投げる窓を選ぶのに使う）")

	// --- 前の巡の窓との突き合わせ（--compare-windows） ---
	//
	// **窓は毎巡グラフから作り直すので、辺が直れば悪い窓は作られなくなるはず。**
	// ただし成長は決定的（乱数なし・同数なら添字の小さいほう）なので、
	// **その領域の近傍で辺が 1 本も変わらなければ、まったく同じ窓が再び出る**。
	// つまり「悪い窓が消えるかどうか」は自動ではなく、修正がそこまで届いたかの
	// 関数になる。それを見るための突き合わせ（設計 §3.10）。
	if !previousWindowDirectory.isEmpty
	{
		var indexOfPath: [String: Int] = [:]
		for (index, record) in members.enumerated()
		{
			indexOfPath[root.appendingPathComponent(record.relativePath).path] = index
		}
		let names = ((try? FileManager.default.contentsOfDirectory(
			atPath: previousWindowDirectory)) ?? [])
			.filter { $0.hasPrefix("window-") && $0.hasSuffix(".txt") }
			.sorted()
		var previous: [(name: String, members: Set<Int>)] = []
		for name in names
		{
			let path = (previousWindowDirectory as NSString).appendingPathComponent(name)
			guard let text = try? String(contentsOfFile: path, encoding: .utf8)
			else
			{
				continue
			}
			let indices = text.split(separator: "\n").compactMap { indexOfPath[String($0)] }
			if !indices.isEmpty
			{
				previous.append((name, Set(indices)))
			}
		}
		print("")
		if previous.isEmpty
		{
			print("■ 前の巡の窓が読めませんでした: \(previousWindowDirectory)")
		}
		print("■ 前の巡の窓との突き合わせ（\(previousWindowDirectory)）")
		print("  前の窓  枚数  いちばん近い今の窓  一致度  そのまま残ったか")
		var identical = 0
		for (name, before) in previous
		{
			var bestIndex = -1
			var bestScore = 0.0
			for (index, window) in windows.enumerated()
			{
				let after = Set(window)
				let union = before.union(after).count
				let score = union > 0
					? Double(before.intersection(after).count) / Double(union) : 0
				if score > bestScore
				{
					bestScore = score
					bestIndex = index
				}
			}
			let same = bestScore >= 0.999
			if same
			{
				identical += 1
			}
			print(String(format: "  %-12@ %5d %18@ %7@ %@",
				name as NSString, before.count,
				(bestIndex >= 0 ? String(format: "window-%02d", bestIndex + 1) : "—") as NSString,
				format(bestScore, 2) as NSString,
				(same ? "**そのまま**" : "作り直された") as NSString))
		}
		print("  そのまま残った窓: \(identical) / \(previous.count) 個")
		print("  → **落ちた窓がそのまま残っているなら、修正がその近傍まで届いていない**")
		print("    （成長は決定的なので、辺が変わらなければ同じ窓が再び出る）")
	}
}

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
