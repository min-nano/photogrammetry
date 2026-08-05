//
//  measure-poses.swift
//
//  **実機の Object Capture に窓を投げて、何が起きるかを測る**スクリプト。
//  docs/design-loose-clustering.md §5.3 / §5.4 の測定はこれで行う。
//
//  当初は二巡構成（§3.7）のコストを測るためだけのものだったが、1 回目の実測で
//  **もっと手前の前提が崩れている**ことが分かったので、対象を広げた。
//
//    - 撮影順に連続した 100 枚が、場所によっては丸ごと error 6（位置合わせ失敗）
//      になる。「連続区間なら再構成できる」という設計の土台が成り立っていない
//    - 成功した窓でも姿勢が付いたのは 100 枚中 65 枚
//
//  したがって測るのは 5 つ。
//
//    1. **窓が成立する場所としない場所の地図**（`--starts` を振る）。どこが
//       駄目なのかが分からないと、窓の作り方を直しようがない
//    2. **窓の大きさへの感度**（`--counts`）。小さくすれば通るのか
//    3. **`--ordering` と `--sensitivity` の効き**。`sequential` は実測で
//       start=0 の error 6 を成功へひっくり返した。`featureSensitivity = .high` は
//       「特徴の少ない被写体」向けの設定で、白い壁ばかりの室内はまさにそれ
//    4. **段階ごとの所要時間**。対応付けとメッシュ生成の比率（二巡構成の成否）
//    5. **窓の中身**（レンズの混在・撮影の所要時間）。error 6 との相関を見る
//
//  なぜ本体（photogrammetry-cli）に足さないのか:
//    これは「何を作るべきか」を決めるための計測だから。**測ってから入れる**
//    （#11 / #12 は測る前に入れて 2 度戻した）。
//
//  使い方（Object Capture が動く実機で）:
//
//    swiftc -O scripts/measure-poses.swift -o /tmp/measure-poses
//    /tmp/measure-poses ~/Pictures/現場 --starts 0,200,400,600,800 --counts 100 \
//        --mode poses | tee -a /tmp/poses.txt
//
//  **必ず tee -a でファイルへ残すこと。** CorePhotogrammetry は内部エラーで
//  abort() することがあり（CLAUDE.md）、その場合このプロセスごと落ちる。
//  1 件ずつ結果を吐いて flush してあるので、落ちてもそこまでの測定値は残る。
//
//  オプション:
//    --counts 100,200       試す枚数（既定 100）
//    --starts 0,400,600     撮影順の何枚目から取るか（既定 0）。`--start` も可
//    --mode both|poses|model  既定 poses（both は同じ窓で両方測って倍率を出す）
//    --ordering unordered|sequential|both  既定 unordered
//    --sensitivity normal|high|both  既定 normal（high は特徴の少ない被写体向け）
//    --detail reduced       model のときの詳細度（既定 reduced＝**保守的**。
//                           medium / full ほどメッシュ側が重くなるので、
//                           reduced で得た倍率は二巡構成に最も不利な値になる）
//    --subject scene|object 既定 scene（建物・部屋。object マスキングを切る）
//    --timeout 1800         1 回の実行の上限（秒）。超えたら中断して次へ進む
//    --window-dir DIR       measure-ordering --windows が書き出した窓を順に投げる。
//                           **支持成長で作った窓が実際に通るかの検証**（設計 §9-1）
//    --window-file FILE     窓を 1 つだけ投げる（複数指定可）
//    --poses-out DIR        写真ごとの「姿勢が付いたか」と 3 次元位置を書き出す。
//                           measure-ordering --feedback に渡すと、**OC の結果で
//                           共視グラフを直せる**（かたまりの空似への唯一の手）
//    --points-out DIR       **点群も同じセッションで書き出す**（<ラベル>.points.bin）。
//                           Pose は位置と回転しか返さないので、「2 枚が実際に
//                           重なっているか」を言うには面の側が要る。姿勢と同じ
//                           座標系かどうかも、この出力で確かめられる
//    --models-out DIR       **3D モデル（usdz）も同じセッションで書き出す**。
//                           位置合わせが所要の 95% なので、モデルはほぼ無料で
//                           付いてくる（設計 §3.7）。姿勢の枚数は「繋がったか」
//                           しか言わないが、モデルは何がどう繋がったかを見せる
//    --drop-blurriest 20    窓の中でブレの大きい下位 N% を落としてから投げる。
//                           既存の QualityFilter が error 6 を救えるかを試す
//    --download             iCloud Drive の未ダウンロードをまとめて落としてから進む
//    --list                 添字 → ファイル名の対応を出して終わる。どの写真が
//                           start=N にあるかを手元で確かめるため（**ファイル名を
//                           含むので共有向けではない**）
//

import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import simd

// ---------------------------------------------------------------------
// 引数
// ---------------------------------------------------------------------

func fail(_ message: String) -> Never
{
	FileHandle.standardError.write(Data("\(message)\n".utf8))
	exit(2)
}

var inputPath: String?
var counts = [100]
var starts = [0]
var modeName = "poses"
var detailName = "reduced"
var subjectName = "scene"
var orderingName = "unordered"
var sensitivityName = "normal"
/// 添字とファイル名の対応を出して終わる（`--list`）。**ファイル名を含むので
/// 手元で見るためのもの**で、共有する出力ではない。
var listOnly = false
/// 1 回の実行がこの秒数を超えたらセッションを中断して次へ進む。
/// **CorePhotogrammetry が返らなくなることがある**ので、測定が止まったまま
/// 夜を越さないための歯止め（既定 30 分）。
var timeoutSeconds: TimeInterval = 1800
/// iCloud Drive の未ダウンロードをまとめて落としてから進む（`--download`）。
var downloadFirst = false
/// 窓の中で**ブレの大きい下位 N%** を落としてから投げる（`--drop-blurriest`）。
/// 既存の QualityFilter が error 6 を救えるかを直接試すための設定。
var dropBlurriestPercent = 0
/// **窓の一覧ファイル**（`--window-file` / `--window-dir`）。
/// measure-ordering --windows が書き出したもの。1 行 1 パスで、**その順序が
/// そのまま Object Capture へ渡す並び**になる（`sequential` の中身）。
var windowFiles: [String] = []
/// **姿勢の書き出し先**（`--poses-out DIR`）。写真ごとに「姿勢が付いたか」と
/// 3 次元位置を出す。これを measure-ordering --feedback へ渡すと、
/// **Object Capture の結果で共視グラフを直せる**（設計の新しい柱）。
var posesOutDirectory = ""
/// **3D モデル（usdz）の書き出し先**（`--models-out DIR`）。指定すると
/// `mode=poses` の**同じセッション**で `.modelFile` も要求する（設計 §3.7）。
/// 位置合わせが所要の 95% なので、モデルはほぼ無料で付いてくる。
var modelsOutDirectory = ""
/// **点群の書き出し先**（`--points-out DIR`）。`.pointCloud` を同じセッションで
/// 要求する。`pointCloudGeneration` の段階は姿勢を取るときも既に走っているので、
/// 追加コストはほぼ無い。
var pointsOutDirectory = ""
/// いま投げている窓の、連番 → 元のパス。姿勢は一時フォルダの名前で返ってくる
/// ので、元の写真へ戻すために要る。
var currentWindowPaths: [String] = []
/// **測る前に ANE モデルキャッシュを消す**（`--purge-model-cache`）。壊れると
/// 以降の窓が同じところで落ち続け、測定が丸ごと無駄になる（`ModelCache` 参照）。
var purgeModelCache = false

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty
{
	let argument = arguments.removeFirst()
	func value() -> String
	{
		guard !arguments.isEmpty
		else
		{
			fail("\(argument) に値がありません")
		}
		return arguments.removeFirst()
	}
	func list() -> [Int]
	{
		value().split(separator: ",").compactMap { Int($0) }
	}
	switch argument
	{
		case "--counts":
			counts = list().sorted()
		case "--starts", "--start":
			starts = list()
		case "--mode":
			modeName = value()
		case "--detail":
			detailName = value()
		case "--subject":
			subjectName = value()
		case "--ordering":
			orderingName = value()
		case "--sensitivity":
			sensitivityName = value()
		case "--list":
			listOnly = true
		case "--download":
			downloadFirst = true
		case "--drop-blurriest":
			dropBlurriestPercent = Int(value()) ?? 0
		case "--poses-out":
			posesOutDirectory = value()
		case "--models-out":
			modelsOutDirectory = value()
		case "--points-out":
			pointsOutDirectory = value()
		case "--window-file":
			windowFiles.append(value())
		case "--window-dir":
			let directory = value()
			let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
			for name in names.sorted() where name.hasPrefix("window-") && name.hasSuffix(".txt")
			{
				windowFiles.append((directory as NSString).appendingPathComponent(name))
			}
		case "--timeout":
			timeoutSeconds = Double(value()) ?? timeoutSeconds
		case "--purge-model-cache":
			purgeModelCache = true
		case "-h", "--help":
			print("使い方: measure-poses <写真フォルダ> [--counts 100,200] "
				+ "[--starts 0,400,600] [--mode poses|model|both] "
				+ "[--ordering unordered|sequential|both] "
				+ "[--sensitivity normal|high|both] [--detail reduced] "
				+ "[--subject scene|object] [--drop-blurriest 20] [--timeout 1800] "
				+ "[--download] [--list] [--window-dir DIR] [--window-file FILE] "
				+ "[--poses-out DIR] [--models-out DIR] [--points-out DIR] "
				+ "[--purge-model-cache]")
			exit(0)
		default:
			if argument.hasPrefix("-") || inputPath != nil
			{
				fail("不明な引数: \(argument)")
			}
			inputPath = argument
	}
}

guard let inputPath, !counts.isEmpty, !starts.isEmpty
else
{
	fail("使い方: measure-poses <写真フォルダ> [オプション]")
}

// **綴り違いを黙って別の設定へ落とさない。**
// `--sensitivity hight` が `normal` として走り、15 窓ぶんの測定を無駄にした。
// 設計原則（黙って悪い結果を出さない）を、この計測スクリプト自身にも課す。
func validate(_ name: String, _ value: String, _ allowed: [String])
{
	guard allowed.contains(value)
	else
	{
		fail("\(name) の値が不正です: \(value)（使えるのは \(allowed.joined(separator: " / "))）")
	}
}
validate("--mode", modeName, ["poses", "model", "both"])
validate("--ordering", orderingName, ["unordered", "sequential", "both"])
validate("--sensitivity", sensitivityName, ["normal", "high", "both"])
validate("--detail", detailName, ["preview", "reduced", "medium", "full", "raw"])
validate("--subject", subjectName, ["scene", "object"])
let root = URL(fileURLWithPath: inputPath, isDirectory: true).standardizedFileURL

@Sendable func log(_ message: String)
{
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}

/// ANE 用にコンパイルされた ML モデルの置き場。バンドル ID の無い素の実行体では
/// プロセス名で切られる（実機で `~/Library/Caches/measure-poses/…` を確認）。
/// 名前は `ModelCache.bundleCacheDirectoryName` と対。
let modelCacheDirectory: URL? = FileManager.default
	.urls(for: .cachesDirectory, in: .userDomainMask).first?
	.appendingPathComponent(
		Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
	.appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)

if purgeModelCache
{
	if let modelCacheDirectory
	{
		let existed = FileManager.default.fileExists(atPath: modelCacheDirectory.path)
		try? FileManager.default.removeItem(at: modelCacheDirectory)
		log(existed
			? "ANE モデルキャッシュを削除しました: \(modelCacheDirectory.path)"
			: "ANE モデルキャッシュはありませんでした: \(modelCacheDirectory.path)")
	}
	else
	{
		log("ANE モデルキャッシュの場所が分かりませんでした")
	}
}

/// 1 件ごとに必ず吐き出す。abort() で落ちても、そこまでの測定値を残すため。
func emit(_ line: String)
{
	print(line)
	fflush(stdout)
}

// ---------------------------------------------------------------------
// 入力の用意
// ---------------------------------------------------------------------

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

/// 写真 1 枚ぶんの、窓を組むのに要る事実だけ。
struct Photo
{
	var url: URL
	var date: Date?
	/// 35mm 換算焦点距離。error 8 / error 6 とレンズ混在の相関を見るため。
	var focal35: Int?
}

func imageFiles(in folder: URL) -> [URL]
{
	var result: [URL] = []
	let manager = FileManager.default
	func scan(_ directory: URL)
	{
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
				scan(child)
			}
			else if imageExtensions.contains((name as NSString).pathExtension.lowercased())
			{
				result.append(child)
			}
		}
	}
	scan(folder)
	return result
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

/// EXIF から撮影時刻と焦点距離を 1 回のオープンで読む。**窓は撮影順の連続区間
/// なので、ここも撮影順で切り出す**（測定が本番とずれないように）。
///
/// **サブ秒とタイムゾーンまで読むのは measure-ordering.swift と揃えるため。**
/// 片方だけがサブ秒を読むと、連写（この現場は 2 秒以内の組が 966 組ある）の
/// 並びが食い違い、「区間ごとの中身」と「error 6 の地図」の添字がずれる。
@Sendable func readPhoto(_ url: URL) -> Photo
{
	guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
		let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
	else
	{
		return Photo(url: url, date: nil, focal35: nil)
	}
	var date: Date?
	if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
	{
		let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
		formatter.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? TimeZone.current
		date = formatter.date(from: text)
		if let date, let subsecond = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
			let fraction = Double("0.\(subsecond)")
		{
			return Photo(
				url: url,
				date: date.addingTimeInterval(fraction),
				focal35: (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue)
		}
	}
	let focal = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue
	return Photo(url: url, date: date, focal35: focal)
}


// ---------------------------------------------------------------------
// iCloud Drive の未ダウンロード対策
//
// 写真が iCloud Drive にあると、実体がローカルに無い（プレースホルダの）まま
// 見えている。その状態で EXIF を読むと**1 枚ずつダウンロードが走って止まる**。
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

/// まとめて並行に読む。進捗を出すのは、無音の時間を作らないため。
func readAll(_ urls: [URL]) -> [Photo]
{
	let lock = NSLock()
	var results = [Photo?](repeating: nil, count: urls.count)
	var done = 0
	DispatchQueue.concurrentPerform(iterations: urls.count)
	{ index in
		let photo = readPhoto(urls[index])
		lock.lock()
		results[index] = photo
		done += 1
		let current = done
		lock.unlock()
		if current % 200 == 0
		{
			log("  EXIF \(current)/\(urls.count)")
		}
	}
	return results.compactMap { $0 }
}

let allFiles = imageFiles(in: root)
guard !allFiles.isEmpty
else
{
	fail("画像が 1 枚も見つかりませんでした: \(root.path)")
}
// **枚数はここで出す。** 読み終えてから出していたので、EXIF の読み取りが
// 遅いときに「何も起きていない」ように見えていた。
log("画像 \(allFiles.count) 枚を見つけました。EXIF を読みます")
ensureMaterialized(allFiles, download: downloadFirst)

/// 撮影順（EXIF 時刻。無いものは末尾へ）。**読み取りは並行**（1424 枚を
/// 逐次で読むと数分かかる）。
let ordered = readAll(allFiles)
	.sorted
	{ left, right in
		switch (left.date, right.date)
		{
			case (let a?, let b?):
				return a == b ? left.url.path < right.url.path : a < b
			case (nil, _?):
				return false
			case (_?, nil):
				return true
			default:
				return left.url.path < right.url.path
		}
	}

log("EXIF の読み取りが終わりました（\(ordered.count) 枚）")

// 添字 → ファイル名。error 6 になった区間の写真を実際に見るため。
if listOnly
{
	let formatter = DateFormatter()
	formatter.locale = Locale(identifier: "en_US_POSIX")
	formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS"
	print("# index\tdate\tfocal35\tpath")
	for (index, photo) in ordered.enumerated()
	{
		print("\(index)\t\(photo.date.map(formatter.string(from:)) ?? "-")"
			+ "\t\(photo.focal35.map(String.init) ?? "-")\t\(photo.url.path)")
	}
	exit(0)
}


/// 解析用の縮小画像。**320 px は本体（PhotoInspector.thumbnailSize）と同じ。**
@Sendable func thumbnail(of url: URL) -> CGImage?
{
	guard let source = CGImageSourceCreateWithURL(url as CFURL, nil)
	else
	{
		return nil
	}
	let options: [CFString: Any] = [
		kCGImageSourceCreateThumbnailFromImageAlways: true,
		kCGImageSourceCreateThumbnailWithTransform: true,
		kCGImageSourceThumbnailMaxPixelSize: 320,
	]
	return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// ラプラシアン分散（ブレの指標）。**ImageStatistics と同じ式**にしてあるので、
/// ここで効くと分かれば `--min-sharpness` の検討にそのまま使える。
@Sendable func sharpness(of url: URL) -> Double
{
	guard let image = thumbnail(of: url)
	else
	{
		return 0
	}
	let width = image.width
	let height = image.height
	guard width > 2, height > 2,
		let context = CGContext(
			data: nil, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
			bitmapInfo: CGImageAlphaInfo.none.rawValue)
	else
	{
		return 0
	}
	context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
	guard let data = context.data
	else
	{
		return 0
	}
	let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
	let stride = context.bytesPerRow
	var sum = 0.0
	var sumOfSquares = 0.0
	var count = 0
	for y in 1 ..< (height - 1)
	{
		for x in 1 ..< (width - 1)
		{
			let value =
				Double(bytes[(y - 1) * stride + x]) + Double(bytes[(y + 1) * stride + x])
				+ Double(bytes[y * stride + x - 1]) + Double(bytes[y * stride + x + 1])
				- 4 * Double(bytes[y * stride + x])
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

/// 一覧ファイルから窓を作る。**行の順序をそのまま並びとして使う**
/// （measure-ordering が窓の中の並びまで決めて書き出しているため）。
func makeWindow(fromList path: String, label: String) throws -> (folder: URL, dropped: Int)
{
	let text = try String(contentsOfFile: path, encoding: .utf8)
	let paths = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
	let folder = FileManager.default.temporaryDirectory
		.appendingPathComponent("measure-poses-\(label)", isDirectory: true)
	try? FileManager.default.removeItem(at: folder)
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	var kept = paths
	var dropped = 0
	if dropBlurriestPercent > 0, kept.count > 2
	{
		let lock = NSLock()
		var values = [Double](repeating: 0, count: kept.count)
		DispatchQueue.concurrentPerform(iterations: kept.count)
		{ index in
			let value = sharpness(of: URL(fileURLWithPath: kept[index]))
			lock.lock()
			values[index] = value
			lock.unlock()
		}
		let threshold = values.sorted()[
			min(values.count - 1, values.count * dropBlurriestPercent / 100)]
		let survivors = kept.indices.filter { values[$0] > threshold }
		dropped = kept.count - survivors.count
		kept = survivors.map { kept[$0] }
	}
	currentWindowPaths = kept
	for (index, source) in kept.enumerated()
	{
		let url = URL(fileURLWithPath: source)
		let name = String(format: "%05d.%@", index, url.pathExtension)
		let destination = folder.appendingPathComponent(name)
		do
		{
			try FileManager.default.linkItem(at: url, to: destination)
		}
		catch
		{
			try? FileManager.default.copyItem(at: url, to: destination)
		}
	}
	return (folder, dropped)
}

/// 指定区間の窓を作る。ハードリンク（同一ボリューム外ならコピー）。
/// **ブレの大きい下位 N% を落とす**設定なら、ここで落としてから並べる。
func makeWindow(start: Int, count: Int) throws -> (folder: URL, dropped: Int)
{
	let folder = FileManager.default.temporaryDirectory
		.appendingPathComponent("measure-poses-\(start)-\(count)", isDirectory: true)
	try? FileManager.default.removeItem(at: folder)
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	var slice = Array(ordered.dropFirst(start).prefix(count))
	var dropped = 0
	if dropBlurriestPercent > 0, slice.count > 2
	{
		// 鋭さは並行に測る（1 枚ずつだと窓ごとに数十秒かかる）。
		let lock = NSLock()
		var values = [Double](repeating: 0, count: slice.count)
		let urls = slice.map(\.url)
		DispatchQueue.concurrentPerform(iterations: urls.count)
		{ index in
			let value = sharpness(of: urls[index])
			lock.lock()
			values[index] = value
			lock.unlock()
		}
		let threshold = values.sorted()[
			min(values.count - 1, values.count * dropBlurriestPercent / 100)]
		let kept = slice.indices.filter { values[$0] > threshold }
		dropped = slice.count - kept.count
		// **撮影順は保つ**（sequential を名乗るため）。
		slice = kept.map { slice[$0] }
	}
	for (index, photo) in slice.enumerated()
	{
		// 並び順が名前でも保たれるようにしておく（--ordering sequential のとき、
		// Object Capture はフォルダ内の順序を見るため）。
		let name = String(format: "%05d.%@", index, photo.url.pathExtension)
		let destination = folder.appendingPathComponent(name)
		do
		{
			try FileManager.default.linkItem(at: photo.url, to: destination)
		}
		catch
		{
			try FileManager.default.copyItem(at: photo.url, to: destination)
		}
	}
	return (folder, dropped)
}

/// 窓の中身（レンズの混在と撮影の所要時間）。error 6 との相関を見るため。
func describeWindow(start: Int, count: Int) -> (lenses: String, span: TimeInterval)
{
	let slice = Array(ordered.dropFirst(start).prefix(count))
	var histogram: [Int: Int] = [:]
	for photo in slice
	{
		histogram[photo.focal35 ?? 0, default: 0] += 1
	}
	let lenses = histogram.sorted { $0.value > $1.value }
		.map { $0.key == 0 ? "none×\($0.value)" : "\($0.key)mm×\($0.value)" }
		.joined(separator: "/")
	let dates = slice.compactMap(\.date)
	let span = (dates.max()?.timeIntervalSince(dates.min() ?? .distantPast)) ?? 0
	return (lenses.isEmpty ? "-" : lenses, dates.isEmpty ? 0 : span)
}

// ---------------------------------------------------------------------
// メモリの山を追う
// ---------------------------------------------------------------------

/// このプロセスの物理フットプリント（バイト）。**GPU 側は数えられない**ので、
/// 「落ちる直前まで行ったか」の目安として見る。
func physicalFootprint() -> UInt64
{
	var info = task_vm_info_data_t()
	var count = mach_msg_type_number_t(
		MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
	let result = withUnsafeMutablePointer(to: &info)
	{ pointer in
		pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count))
		{ rebound in
			task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
		}
	}
	return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

/// 処理中の見張り役。**3 つを 1 本のスレッドでやる。**
///
///   1. 物理フットプリントの山を拾う
///   2. **生きていることを定期的に出す**（1 回の実行が数分無音になるので、
///      止まっているのか進んでいるのかが分からないという問題が実際に起きた）
///   3. 時間切れでセッションを中断する（CorePhotogrammetry が返らなくなる
///      ことがあるので、測定が止まったまま夜を越さないための歯止め）
final class Monitor: @unchecked Sendable
{
	private let lock = NSLock()
	private var peak: UInt64 = 0
	private var running = true
	private var stage = "-"
	private var fraction = 0.0
	private let began = Date()
	private let label: String
	private let timeout: TimeInterval
	private let onTimeout: @Sendable () -> Void

	init(label: String, timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void)
	{
		self.label = label
		self.timeout = timeout
		self.onTimeout = onTimeout
	}

	func start()
	{
		Thread.detachNewThread
		{ [self] in
			var ticks = 0
			var firedTimeout = false
			while true
			{
				lock.lock()
				let keepGoing = running
				if keepGoing
				{
					peak = max(peak, physicalFootprint())
				}
				let currentStage = stage
				let currentFraction = fraction
				lock.unlock()
				guard keepGoing
				else
				{
					return
				}
				let elapsed = Date().timeIntervalSince(began)
				ticks += 1
				// 15 秒ごとに 1 行。無音を無くすのが目的なので短くしすぎない。
				if ticks % 15 == 0
				{
					log(String(
						format: "    … %@ 経過 %.0f 秒 stage=%@ 進捗 %.0f%%",
						label, elapsed, currentStage, currentFraction * 100))
				}
				if !firedTimeout, elapsed > timeout
				{
					firedTimeout = true
					log("    !! \(label) が \(Int(timeout)) 秒を超えたので中断します")
					onTimeout()
				}
				Thread.sleep(forTimeInterval: 1)
			}
		}
	}

	func update(stage newStage: String)
	{
		lock.lock()
		stage = newStage
		lock.unlock()
	}

	func update(fraction newFraction: Double)
	{
		lock.lock()
		fraction = newFraction
		lock.unlock()
	}

	func stop() -> UInt64
	{
		lock.lock()
		defer { lock.unlock() }
		running = false
		return peak
	}
}

// ---------------------------------------------------------------------
// 1 回ぶんの計測
// ---------------------------------------------------------------------

enum Mode: String
{
	case poses
	case model
}

struct Measurement
{
	var elapsed: TimeInterval = 0
	var posed = 0
	var skipped = 0
	var invalid = 0
	var downsampled = false
	/// ブレで落とした枚数（`--drop-blurriest`）。
	var dropped = 0
	var peakBytes: UInt64 = 0
	/// 段階名 → その段階が最初に現れた時刻（開始からの秒）。
	var stageStarts: [(String, TimeInterval)] = []
	var outcome = "ok"
	/// 3D モデルの結末（`--models-out` を指定したときだけ）。書けたらファイル名、
	/// 要求していなければ `-`。**姿勢とは別に持つ** — モデルだけ失敗しても
	/// 姿勢が取れていれば反復は進むので、そこを一緒くたにすると窓を落ちた扱いに
	/// して芯や分割を無駄に投げ直すことになる。
	var modelOutcome = "-"
	/// 点群の点数（`--points-out` を指定したときだけ）。-1 は要求していない。
	var points = -1
}

/// 直前に書き出した窓のカメラの位置と向き。**点群と同じ座標系かどうか**を
/// 突き合わせるために持つ（要求の完了順は決まっていないので、揃ってから比べる）。
var lastCameraPlacements: [(position: SIMD3<Float>, rotation: simd_quatf)] = []

/// 姿勢を「元の写真のパス」に紐づけて書き出す。
///
/// **窓は一時フォルダへ連番でリンクしてある**ので、返ってくる URL も連番の
/// ほう。`currentWindowPaths` で元へ戻す。
@available(macOS 14.0, *)
func writePoses(_ poses: PhotogrammetrySession.Poses, label: String)
{
	guard !posesOutDirectory.isEmpty
	else
	{
		return
	}
	let directory = URL(fileURLWithPath: posesOutDirectory, isDirectory: true)
	try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

	// **投げた写真すべてを台帳にする。** `urlsBySample` が姿勢の付いた分しか
	// 返さない可能性があり、そちらを台帳にすると「姿勢なし」の行が 1 本も出ず、
	// --feedback が反証（片方だけ姿勢＝辺を消す）を学べなくなる。落ちた写真こそ
	// 欲しい情報なので、窓のファイル一覧を土台にして姿勢を上書きする。
	// **回転も残す。** 位置だけでは「背中合わせに立った 2 枚」と「同じ壁を
	// 一緒に見ている 2 枚」を区別できない。Pose が返すのは位置と回転だけで
	// 内部パラメータ（投影）は無いので、視野の向きはここでしか手に入らない。
	// 貯め直しには窓 1 個あたり数十分かかるため、使う当てが決まる前でも取る。
	var placements = [String: (position: SIMD3<Float>, rotation: simd_quatf)]()
	for (sample, pose) in poses.posesBySample
	{
		// 00042.jpg → 42 → 元のパス。URL が無いときは標本番号を添字として使う
		// （一時フォルダへは窓の順で連番リンクしてある）。
		var index = sample
		if let url = poses.urlsBySample[sample],
			let parsed = Int(url.deletingPathExtension().lastPathComponent)
		{
			index = parsed
		}
		guard index >= 0, index < currentWindowPaths.count
		else
		{
			continue
		}
		placements[currentWindowPaths[index]] = (pose.translation, pose.rotation)
	}
	// 座標系の突き合わせ（点群と同じ系かどうか）に使う。
	lastCameraPlacements = Array(placements.values)

	let positions = placements.mapValues(\.position)
	var lines = ["# path\tposed\tx\ty\tz\tqx\tqy\tqz\tqw"]
	for path in currentWindowPaths
	{
		if let placement = placements[path]
		{
			let position = placement.position
			let rotation = placement.rotation.vector
			lines.append("\(path)\t1\t\(position.x)\t\(position.y)\t\(position.z)"
				+ "\t\(rotation.x)\t\(rotation.y)\t\(rotation.z)\t\(rotation.w)")
		}
		else
		{
			lines.append("\(path)\t0\t\t\t\t\t\t\t")
		}
	}
	// urlsBySample の中身は実測しないと分からないので、突き合わせて残す。
	log("  姿勢を書き出しました: \(label).poses.tsv"
		+ "（投入 \(currentWindowPaths.count) 枚・姿勢 \(positions.count) 枚・"
		+ "urlsBySample \(poses.urlsBySample.count) 件）")
	try? lines.joined(separator: "\n")
		.write(to: directory.appendingPathComponent("\(label).poses.tsv"),
			atomically: true, encoding: .utf8)
}

/// 点群を書き出す。**形式は自前の素朴な並び**（読み手はこちらで書くので、
/// usdz を経由するより確実で軽い）。
///
///   "OCPC1\n" + UInt32(点数) + 点数ぶんの [Float32 x, y, z, UInt8 r, g, b, a]
///
/// 1 点 16 バイト。50 万点でも 8MB で収まる。
func writePoints(_ cloud: PhotogrammetrySession.PointCloud, label: String) -> Int
{
	guard !pointsOutDirectory.isEmpty
	else
	{
		return -1
	}
	var data = Data("OCPC1\n".utf8)
	withUnsafeBytes(of: UInt32(cloud.points.count)) { data.append(contentsOf: $0) }
	for point in cloud.points
	{
		withUnsafeBytes(of: point.position.x) { data.append(contentsOf: $0) }
		withUnsafeBytes(of: point.position.y) { data.append(contentsOf: $0) }
		withUnsafeBytes(of: point.position.z) { data.append(contentsOf: $0) }
		data.append(contentsOf: [point.color.x, point.color.y, point.color.z, point.color.w])
	}
	let url = URL(fileURLWithPath: pointsOutDirectory, isDirectory: true)
		.appendingPathComponent("\(label).points.bin")
	do
	{
		try data.write(to: url, options: .atomic)
	}
	catch
	{
		log("    !! 点群を書き出せませんでした: \(error.localizedDescription)")
		return -1
	}
	if lastCameraPlacements.isEmpty
	{
		log("  （姿勢より先に点群が返ったので、座標系の突き合わせはこの窓では出せません）")
	}
	log("  点群を書き出しました: \(url.lastPathComponent)"
		+ "（\(cloud.points.count) 点・\(String(format: "%.1f", Double(data.count) / 1_048_576))MB）")
	describeGeometry(cloud.points.map(\.position))
	return cloud.points.count
}

/// **点群とカメラが同じ座標系・同じ尺度に乗っているか**を、その場で言い切る。
///
/// これが成り立たないと「実際に重なっているか」の計算が丸ごと無意味になるので、
/// 数字を出さずに前提だけ置くわけにはいかない（#12 で踏んだ形そのもの）。
///
/// **「カメラが点群の範囲の中にあるか」は判定にならない**（実データで踏んだ）。
/// 被写体を外から撮れば、カメラが外にあるのが当たり前だから。**回転を使って
/// 「点群がカメラの前方に写る位置にあるか」を見る**のが正しい問いで、座標系が
/// 無関係なら前後は半々・角度は散らばる。
func describeGeometry(_ points: [SIMD3<Float>])
{
	guard !points.isEmpty
	else
	{
		return
	}

	func bounds(_ values: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>)
	{
		var low = values[0]
		var high = values[0]
		for value in values
		{
			low = SIMD3(min(low.x, value.x), min(low.y, value.y), min(low.z, value.z))
			high = SIMD3(max(high.x, value.x), max(high.y, value.y), max(high.z, value.z))
		}
		return (low, high)
	}

	func text(_ value: SIMD3<Float>) -> String
	{
		String(format: "(%.2f, %.2f, %.2f)", value.x, value.y, value.z)
	}

	let cloud = bounds(points)
	let diagonal = simd_length(cloud.max - cloud.min)
	log("  点群の範囲 \(text(cloud.min)) 〜 \(text(cloud.max))"
		+ "  対角 \(String(format: "%.2f", diagonal))")
	guard !lastCameraPlacements.isEmpty
	else
	{
		return
	}
	let positions = lastCameraPlacements.map(\.position)
	let cameras = bounds(positions)
	log("  カメラの範囲 \(text(cameras.min)) 〜 \(text(cameras.max))"
		+ "  対角 \(String(format: "%.2f", simd_length(cameras.max - cameras.min)))")

	// 尺度が同じ桁に乗っているか。桁が違えばモデル側が正規化されている。
	let center = (cloud.min + cloud.max) / 2
	var distances = positions.map { simd_length($0 - center) }
	distances.sort()
	let median = distances[distances.count / 2]
	log("  カメラから点群の中心までの距離: 中央値 \(String(format: "%.2f", median))"
		+ "（点群の対角の \(String(format: "%.0f", Double(median / max(diagonal, 1e-6)) * 100))%"
		+ "・**撮影距離として無理のない比なら尺度は合っている**）")

	// **本命の検算。** 点をカメラ座標系へ移し、前方（RealityKit は -Z 方向を見る）
	// にどれだけ入るかと、光軸からの角度を見る。座標系が無関係なら前後は半々。
	let step = max(1, points.count / 5_000)
	let sample = stride(from: 0, to: points.count, by: step).map { points[$0] }
	var front = 0
	var back = 0
	var angles: [Double] = []
	for placement in lastCameraPlacements.prefix(64)
	{
		let inverse = placement.rotation.inverse
		for point in sample
		{
			let local = inverse.act(point - placement.position)
			if local.z < 0
			{
				front += 1
				let axial = Double(-local.z)
				let lateral = Double((local.x * local.x + local.y * local.y).squareRoot())
				angles.append(atan2(lateral, axial) * 180 / .pi)
			}
			else
			{
				back += 1
			}
		}
	}
	let total = max(1, front + back)
	log("  カメラ座標系での点の位置: 前方（-Z）\(front * 100 / total)%"
		+ "・後方 \(back * 100 / total)%")
	angles.sort()
	if !angles.isEmpty
	{
		let middle = angles[angles.count / 2]
		let quarter = angles[angles.count / 4]
		log("  前方の点の光軸からの角度: 中央値 \(String(format: "%.0f", middle))°"
			+ "・下位 25% \(String(format: "%.0f", quarter))°")
	}
	log("  → **前方が大半で角度が視野角の内側なら、点群と姿勢は同じ座標系**。"
		+ "前後が半々なら無関係")

func stageName(_ stage: PhotogrammetrySession.Output.ProcessingStage) -> String
{
	switch stage
	{
		case .preProcessing:
			return "preProcessing"
		case .imageAlignment:
			return "imageAlignment"
		case .pointCloudGeneration:
			return "pointCloudGeneration"
		case .meshGeneration:
			return "meshGeneration"
		case .textureMapping:
			return "textureMapping"
		case .optimization:
			return "optimization"
		default:
			return "unknown"
	}
}

func measure(
	mode: Mode, start: Int, count: Int, ordering: String, sensitivity: String,
	listPath: String? = nil) async -> Measurement
{
	var measurement = Measurement()
	let began = Date()

	let windowLabel = listPath
		.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".txt", with: "") }
		?? "start\(start)-count\(count)"
	let folder: URL
	do
	{
		let window: (folder: URL, dropped: Int)
		if let listPath
		{
			window = try makeWindow(fromList: listPath, label: windowLabel)
		}
		else
		{
			window = try makeWindow(start: start, count: count)
		}
		folder = window.folder
		measurement.dropped = window.dropped
	}
	catch
	{
		measurement.outcome = "window-error: \(error.localizedDescription)"
		return measurement
	}
	defer
	{
		try? FileManager.default.removeItem(at: folder)
	}

	// **姿勢と 3D モデルは同じセッションで要求する**（設計 §3.7）。段階ごとの
	// 実測で位置合わせが全体の 95%、メッシュとテクスチャは合計 2.5% しかないので、
	// **モデルはほぼ無料で付いてくる**。別のセッションで取り直すと丸ごと 2 倍。
	// 反復の途中経過を目で見られることの値打ちは大きい — 姿勢の枚数は「繋がった
	// かどうか」しか言わないが、モデルは**何がどう繋がったか**を見せる。
	let wantsModel = (mode == .poses) && !modelsOutDirectory.isEmpty
	if wantsModel
	{
		try? FileManager.default.createDirectory(
			at: URL(fileURLWithPath: modelsOutDirectory, isDirectory: true),
			withIntermediateDirectories: true)
	}

	// **点群も同じセッションで要求する。** `Pose` は外部パラメータ（位置と回転）
	// しか返さず、内部パラメータ（投影）は返ってこない。したがって「2 枚が実際に
	// 重なっているか」を言うには、**面の側**が要る。点群は
	// `pointCloudGeneration` の段階が既に走っているので、これも追加コストが
	// ほぼ無い（設計 §6.2 の段階別所要時間）。
	//
	// 内部パラメータは EXIF の 35mm 換算焦点距離から組める（測量ではなく
	// 「同じ面が両方に写っているか」の判定なので、この精度で足りる）。
	let wantsPoints = (mode == .poses) && !pointsOutDirectory.isEmpty
	if wantsPoints
	{
		try? FileManager.default.createDirectory(
			at: URL(fileURLWithPath: pointsOutDirectory, isDirectory: true),
			withIntermediateDirectories: true)
	}

	var configuration = PhotogrammetrySession.Configuration()
	configuration.sampleOrdering = ordering == "sequential" ? .sequential : .unordered
	// **白い壁ばかりの室内は特徴が少ない。** RealityKit はそのための設定を
	// 持っているので、error 6 の region で効くかどうかを測る（既定は normal）。
	configuration.featureSensitivity = sensitivity == "high" ? .high : .normal
	// 建物・部屋ではオブジェクトマスキングを切る（切らないと前景の切り出しが
	// 破綻してアライメントが落ちる。PhotogrammetryEngine と同じ判断）。
	configuration.isObjectMaskingEnabled = (subjectName == "object")

	// **残すのは --models-out を指定されたときだけ。** 測るだけの実行で
	// ディスクを埋めない（1 窓ぶんの usdz は数十 MB になる）。
	let output = wantsModel
		? URL(fileURLWithPath: modelsOutDirectory, isDirectory: true)
			.appendingPathComponent("\(windowLabel).usdz")
		: FileManager.default.temporaryDirectory
			.appendingPathComponent("measure-poses-\(start)-\(count).usdz")
	defer
	{
		if !wantsModel
		{
			try? FileManager.default.removeItem(at: output)
		}
	}
	// 前回の実行の残骸に騙されないよう、始める前に消しておく（**出来ていない
	// モデルを「出来た」と報告しない**）。
	if wantsModel
	{
		try? FileManager.default.removeItem(at: output)
	}

	do
	{
		let session = try PhotogrammetrySession(input: folder, configuration: configuration)
		let monitor = Monitor(
			label: "\(mode.rawValue) start=\(start) count=\(count) \(ordering)/\(sensitivity)",
			timeout: timeoutSeconds)
		{
			// 時間切れ。**返らなくなったセッションを放置しない**
			// （次の条件へ進めないと、一晩かけて 1 件も測れないことになる）。
			session.cancel()
		}
		let detail: PhotogrammetrySession.Request.Detail
		switch detailName
		{
			case "preview": detail = .preview
			case "medium": detail = .medium
			case "full": detail = .full
			case "raw": detail = .raw
			default: detail = .reduced
		}
		var requests: [PhotogrammetrySession.Request] = []
		switch mode
		{
			case .poses:
				guard #available(macOS 14.0, *)
				else
				{
					measurement.outcome = "poses-unavailable(macOS 14 未満)"
					return measurement
				}
				// **姿勢を先頭に置く。** 同時要求が拒まれたときは先頭だけで
				// 投げ直すので、いちばん落としたくないものを先に置いておく。
				requests = [.poses]
				if wantsModel
				{
					requests.append(.modelFile(url: output, detail: detail))
				}
				if wantsPoints
				{
					requests.append(.pointCloud)
				}
			case .model:
				requests = [.modelFile(url: output, detail: detail)]
		}

		monitor.start()
		do
		{
			try session.process(requests: requests)
		}
		catch
		{
			// **2 つの要求を同時に受け付けない OS があるかもしれない。**
			// そのときに巡ごと落とすのは高くつく（姿勢が取れれば反復は進む）ので、
			// モデルを諦めて姿勢だけで投げ直す。**諦めたことは必ず言う。**
			guard wantsModel, requests.count > 1
			else
			{
				throw error
			}
			log("    !! 姿勢とモデルの同時要求が拒まれました（\(error.localizedDescription)）。"
				+ "モデルを諦めて姿勢だけで投げ直します")
			measurement.modelOutcome = "rejected"
			requests = [requests[0]]
			try session.process(requests: requests)
		}

		for try await event in session.outputs
		{
			switch event
			{
				case .requestProgress(_, let fractionComplete):
					monitor.update(fraction: fractionComplete)
				case .requestProgressInfo(_, let info):
					if let stage = info.processingStage
					{
						let name = stageName(stage)
						monitor.update(stage: name)
						if measurement.stageStarts.last?.0 != name
						{
							measurement.stageStarts.append(
								(name, Date().timeIntervalSince(began)))
						}
					}
				case .requestComplete(_, let result):
					if #available(macOS 14.0, *), case .poses(let poses) = result
					{
						measurement.posed = poses.posesBySample.count
						writePoses(poses, label: windowLabel)
					}
					if case .modelFile(let url) = result
					{
						let attributes = try? FileManager.default
							.attributesOfItem(atPath: url.path)
						let bytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
						measurement.modelOutcome = url.lastPathComponent
						log("  3D モデルを書き出しました: \(url.path)"
							+ "（\(String(format: "%.1f", Double(bytes) / 1_048_576))MB）")
					}
					if #available(macOS 13.0, *), case .pointCloud(let cloud) = result
					{
						measurement.points = writePoints(cloud, label: windowLabel)
					}
				case .requestError(let request, let error):
					// **その場で畳む。** 以前はここで記録だけして
					// processingComplete を待っていたが、要求が失敗したあとに
					// 完了が来る保証は無く、来なければ永久に待つことになる。
					//
					// ただし**モデルだけ失敗して姿勢は取れている**なら、窓は
					// 落ちていない（姿勢が反復の燃料で、モデルは目で見るための
					// おまけ）。ここを一緒くたにすると、通った窓を落ちた扱いに
					// して芯や分割を無駄に投げ直すことになる。
					var modelOnly = false
					if case .modelFile = request, measurement.posed > 0
					{
						modelOnly = true
					}
					if modelOnly
					{
						measurement.modelOutcome = "error"
						log("    !! モデルの書き出しに失敗しました（姿勢は取れています）: "
							+ error.localizedDescription)
					}
					else
					{
						measurement.outcome = "error: \(error.localizedDescription)"
					}
					measurement.elapsed = Date().timeIntervalSince(began)
					measurement.peakBytes = monitor.stop()
					session.cancel()
					return measurement
				case .skippedSample:
					measurement.skipped += 1
				case .invalidSample:
					measurement.invalid += 1
				case .automaticDownsampling:
					measurement.downsampled = true
				case .processingComplete:
					measurement.elapsed = Date().timeIntervalSince(began)
					measurement.peakBytes = monitor.stop()
					return measurement
				case .processingCancelled:
					// 時間切れで中断したときもここへ来る。
					measurement.outcome = measurement.outcome == "ok"
						? "timeout(\(Int(timeoutSeconds))s)" : measurement.outcome
					measurement.elapsed = Date().timeIntervalSince(began)
					measurement.peakBytes = monitor.stop()
					return measurement
				default:
					break
			}
		}
	}
	catch
	{
		measurement.outcome = "throw: \(error.localizedDescription)"
	}
	measurement.elapsed = Date().timeIntervalSince(began)
	return measurement
}

// ---------------------------------------------------------------------
// 実行
// ---------------------------------------------------------------------

func gigabytes(_ bytes: UInt64) -> String
{
	String(format: "%.1fGB", Double(bytes) / 1_073_741_824)
}

func line(
	mode: Mode, start: Int, count: Int, ordering: String, sensitivity: String,
	_ measurement: Measurement) -> String
{
	let stages = measurement.stageStarts
		.map { String(format: "%@:%.0f", $0.0, $0.1) }
		.joined(separator: ",")
	let window = describeWindow(start: start, count: count)
	return String(
		format: "run mode=%@ start=%d count=%d ordering=%@ sensitivity=%@ elapsed=%.1f posed=%d "
			+ "skipped=%d invalid=%d dropped=%d downsampled=%@ peak=%@ span=%.0f lenses=%@ "
			+ "stages=%@ model=%@ points=%d result=%@",
		mode.rawValue, start, count, ordering, sensitivity, measurement.elapsed, measurement.posed,
		measurement.skipped, measurement.invalid, measurement.dropped,
		measurement.downsampled ? "yes" : "no",
		gigabytes(measurement.peakBytes),
		window.span, window.lenses,
		stages.isEmpty ? "-" : stages,
		measurement.modelOutcome,
		measurement.points,
		measurement.outcome)
}

let modes: [Mode]
switch modeName
{
	case "model": modes = [.model]
	case "both": modes = [.poses, .model]
	default: modes = [.poses]
}
let orderings = orderingName == "both" ? ["unordered", "sequential"] : [orderingName]
let sensitivities = sensitivityName == "both" ? ["normal", "high"] : [sensitivityName]

Task
{
	guard PhotogrammetrySession.isSupported
	else
	{
		emit("result=unsupported  この Mac は Object Capture に対応していません")
		exit(3)
	}
	emit("# 入力 \(ordered.count) 枚 / detail=\(detailName) / subject=\(subjectName)")
	emit("# ハードウェア上限 \(PhotogrammetrySession.limits.maximumNumberOfInputImages) 枚")
	// **ANE 用モデルキャッシュの場所を必ず出しておく。** 実機で E5RT /
	// MILCompilerForANE の例外が測定の途中から出た。これは `ModelCache` が
	// 名指ししている故障で、写真にも設定にも原因が無い一方、**出た後の窓の成否は
	// 測定として信用できない**。消す場所が分からないと手の打ちようがないので、
	// 常に案内する（Core の ModelCache と同じ場所・同じ理屈）。
	emit("# ANE モデルキャッシュ: \(modelCacheDirectory?.path ?? "（不明）")")
	emit("#   E5RT / ANECCompile / MILCompilerForANE の行が出たら、"
		+ "ここを消してから測り直す（それ以降の結果は無効）")

	// **一覧ファイルが指定されていたら、そちらだけを投げる。**
	// measure-ordering --windows が支持成長で作った窓が、実際に Object Capture を
	// 通るかどうかがこの設計の合否を決める（設計 §9-1）。
	if !windowFiles.isEmpty
	{
		emit("# 窓の一覧 \(windowFiles.count) 個 / ordering=\(orderingName) "
			+ "/ sensitivity=\(sensitivityName) / drop-blurriest=\(dropBlurriestPercent)%"
			+ (modelsOutDirectory.isEmpty
				? "" : " / models=\(modelsOutDirectory)（detail=\(detailName)）")
			+ (pointsOutDirectory.isEmpty ? "" : " / points=\(pointsOutDirectory)"))
		for path in windowFiles
		{
			let name = (path as NSString).lastPathComponent
			for ordering in orderings
			{
				for sensitivity in sensitivities
				{
					for mode in modes
					{
						log("測定中: \(name) mode=\(mode.rawValue) "
							+ "ordering=\(ordering) sensitivity=\(sensitivity) …")
						let measurement = await measure(
							mode: mode, start: 0, count: 0, ordering: ordering,
							sensitivity: sensitivity, listPath: path)
						let stages = measurement.stageStarts
							.map { String(format: "%@:%.0f", $0.0, $0.1) }
							.joined(separator: ",")
						emit(String(
							format: "window name=%@ mode=%@ ordering=%@ sensitivity=%@ "
								+ "elapsed=%.1f posed=%d skipped=%d invalid=%d dropped=%d "
								+ "peak=%@ stages=%@ model=%@ points=%d result=%@",
							name, mode.rawValue, ordering, sensitivity, measurement.elapsed,
							measurement.posed, measurement.skipped, measurement.invalid,
							measurement.dropped, gigabytes(measurement.peakBytes),
							stages.isEmpty ? "-" : stages, measurement.modelOutcome,
							measurement.points, measurement.outcome))
					}
				}
			}
		}
		emit("done")
		exit(0)
	}

	for start in starts
	{
		for count in counts
		{
			guard count <= ordered.count - start
			else
			{
				emit("# start=\(start) count=\(count) は写真が足りないので飛ばします")
				continue
			}
			for ordering in orderings
			{
				for sensitivity in sensitivities
				{
					var elapsedByMode: [Mode: TimeInterval] = [:]
					for mode in modes
					{
						log("測定中: mode=\(mode.rawValue) start=\(start) count=\(count) "
							+ "ordering=\(ordering) sensitivity=\(sensitivity) …")
						let measurement = await measure(
							mode: mode, start: start, count: count, ordering: ordering,
							sensitivity: sensitivity)
						emit(line(
							mode: mode, start: start, count: count, ordering: ordering,
							sensitivity: sensitivity, measurement))
						// 倍率は**両方成功したときだけ**出す。error 6 どうしの比は
						// 「どちらも位置合わせで死んだ」を意味するだけで、二巡構成の
						// 判断材料にならない（実際 0.98 という無意味な値が出た）。
						if measurement.outcome == "ok"
						{
							elapsedByMode[mode] = measurement.elapsed
						}
					}
					if let poses = elapsedByMode[.poses], let model = elapsedByMode[.model],
						poses > 0
					{
						emit(String(
							format: "ratio start=%d count=%d ordering=%@ sensitivity=%@ "
								+ "poses=%.1f model=%.1f speedup=%.2f",
							start, count, ordering, sensitivity, poses, model, model / poses))
					}
				}
			}
		}
	}
	emit("done")
	exit(0)
}

// RealityKit が main キューへ処理を投げても詰まらないようにする
// （セマフォで待つと、そのときデッドロックしうる）。
dispatchMain()
