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
//    3. **`--ordering` の効き**（`sequential` / `unordered`）。窓が撮影順の連続
//       区間なら sequential を名乗れる。位置合わせの戦略が変わるので効きうる
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
//    --detail reduced       model のときの詳細度（既定 reduced＝**保守的**。
//                           medium / full ほどメッシュ側が重くなるので、
//                           reduced で得た倍率は二巡構成に最も不利な値になる）
//    --subject scene|object 既定 scene（建物・部屋。object マスキングを切る）
//

import Foundation
import ImageIO
import RealityKit

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
		case "-h", "--help":
			print("使い方: measure-poses <写真フォルダ> [--counts 100,200] "
				+ "[--starts 0,400,600] [--mode poses|model|both] "
				+ "[--ordering unordered|sequential|both] [--detail reduced] "
				+ "[--subject scene|object]")
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
let root = URL(fileURLWithPath: inputPath, isDirectory: true).standardizedFileURL

func log(_ message: String)
{
	FileHandle.standardError.write(Data("\(message)\n".utf8))
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

/// EXIF から撮影時刻と焦点距離を 1 回のオープンで読む。**窓は撮影順の連続区間
/// なので、ここも撮影順で切り出す**（測定が本番とずれないように）。
func readPhoto(_ url: URL) -> Photo
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
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
		date = formatter.date(from: text)
	}
	let focal = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue
	return Photo(url: url, date: date, focal35: focal)
}

let allFiles = imageFiles(in: root)
guard !allFiles.isEmpty
else
{
	fail("画像が 1 枚も見つかりませんでした: \(root.path)")
}

/// 撮影順（EXIF 時刻。無いものは末尾へ）。
let ordered = allFiles
	.map(readPhoto)
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

log("画像 \(ordered.count) 枚（撮影順）")

/// 指定区間の窓を作る。ハードリンク（同一ボリューム外ならコピー）。
func makeWindow(start: Int, count: Int) throws -> URL
{
	let folder = FileManager.default.temporaryDirectory
		.appendingPathComponent("measure-poses-\(start)-\(count)", isDirectory: true)
	try? FileManager.default.removeItem(at: folder)
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	for (index, photo) in ordered.dropFirst(start).prefix(count).enumerated()
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
	return folder
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

/// 処理中のフットプリントの最大値を別スレッドで拾う。
final class PeakMemory: @unchecked Sendable
{
	private let lock = NSLock()
	private var peak: UInt64 = 0
	private var running = true

	func start()
	{
		Thread.detachNewThread
		{ [self] in
			while true
			{
				lock.lock()
				let keepGoing = running
				if keepGoing
				{
					peak = max(peak, physicalFootprint())
				}
				lock.unlock()
				guard keepGoing
				else
				{
					return
				}
				Thread.sleep(forTimeInterval: 0.5)
			}
		}
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
	var peakBytes: UInt64 = 0
	/// 段階名 → その段階が最初に現れた時刻（開始からの秒）。
	var stageStarts: [(String, TimeInterval)] = []
	var outcome = "ok"
}

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

func measure(mode: Mode, start: Int, count: Int, ordering: String) async -> Measurement
{
	var measurement = Measurement()
	let peak = PeakMemory()
	let began = Date()

	let folder: URL
	do
	{
		folder = try makeWindow(start: start, count: count)
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

	var configuration = PhotogrammetrySession.Configuration()
	configuration.sampleOrdering = ordering == "sequential" ? .sequential : .unordered
	// 建物・部屋ではオブジェクトマスキングを切る（切らないと前景の切り出しが
	// 破綻してアライメントが落ちる。PhotogrammetryEngine と同じ判断）。
	configuration.isObjectMaskingEnabled = (subjectName == "object")

	let output = FileManager.default.temporaryDirectory
		.appendingPathComponent("measure-poses-\(start)-\(count).usdz")
	defer
	{
		try? FileManager.default.removeItem(at: output)
	}

	do
	{
		let session = try PhotogrammetrySession(input: folder, configuration: configuration)
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
				requests = [.poses]
			case .model:
				let detail: PhotogrammetrySession.Request.Detail
				switch detailName
				{
					case "preview": detail = .preview
					case "medium": detail = .medium
					case "full": detail = .full
					case "raw": detail = .raw
					default: detail = .reduced
				}
				requests = [.modelFile(url: output, detail: detail)]
		}

		peak.start()
		try session.process(requests: requests)

		for try await event in session.outputs
		{
			switch event
			{
				case .requestProgressInfo(_, let info):
					if let stage = info.processingStage
					{
						let name = stageName(stage)
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
					}
				case .requestError(_, let error):
					measurement.outcome = "error: \(error.localizedDescription)"
				case .skippedSample:
					measurement.skipped += 1
				case .invalidSample:
					measurement.invalid += 1
				case .automaticDownsampling:
					measurement.downsampled = true
				case .processingComplete:
					measurement.elapsed = Date().timeIntervalSince(began)
					measurement.peakBytes = peak.stop()
					return measurement
				case .processingCancelled:
					measurement.outcome = "cancelled"
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
	measurement.peakBytes = peak.stop()
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
	mode: Mode, start: Int, count: Int, ordering: String, _ measurement: Measurement) -> String
{
	let stages = measurement.stageStarts
		.map { String(format: "%@:%.0f", $0.0, $0.1) }
		.joined(separator: ",")
	let window = describeWindow(start: start, count: count)
	return String(
		format: "run mode=%@ start=%d count=%d ordering=%@ elapsed=%.1f posed=%d skipped=%d "
			+ "invalid=%d downsampled=%@ peak=%@ span=%.0f lenses=%@ stages=%@ result=%@",
		mode.rawValue, start, count, ordering, measurement.elapsed, measurement.posed,
		measurement.skipped, measurement.invalid,
		measurement.downsampled ? "yes" : "no",
		gigabytes(measurement.peakBytes),
		window.span, window.lenses,
		stages.isEmpty ? "-" : stages,
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
			var elapsedByMode: [Mode: TimeInterval] = [:]
			for ordering in orderings
			{
				for mode in modes
				{
					log("測定中: mode=\(mode.rawValue) start=\(start) count=\(count) "
						+ "ordering=\(ordering) …")
					let measurement = await measure(
						mode: mode, start: start, count: count, ordering: ordering)
					emit(line(
						mode: mode, start: start, count: count, ordering: ordering,
						measurement))
					// 倍率は**両方成功したときだけ**出す。error 6 どうしの比は
					// 「どちらも位置合わせで死んだ」を意味するだけで、二巡構成の
					// 判断材料にならない（実際 0.98 という無意味な値が出た）。
					if measurement.outcome == "ok"
					{
						elapsedByMode[mode] = measurement.elapsed
					}
				}
				if let poses = elapsedByMode[.poses], let model = elapsedByMode[.model], poses > 0
				{
					emit(String(
						format: "ratio start=%d count=%d ordering=%@ poses=%.1f model=%.1f "
							+ "speedup=%.2f",
						start, count, ordering, poses, model, model / poses))
				}
				elapsedByMode.removeAll()
			}
		}
	}
	emit("done")
	exit(0)
}

// RealityKit が main キューへ処理を投げても詰まらないようにする
// （セマフォで待つと、そのときデッドロックしうる）。
dispatchMain()
