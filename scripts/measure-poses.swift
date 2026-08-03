//
//  measure-poses.swift
//
//  **二巡構成（docs/design-loose-clustering.md §3.7）が成立するかを測る**
//  スクリプト。設計上のリスク 6 —「`--poses-only` が十分速いことに依存している」—
//  を、実機の Object Capture で確かめるためのもの。
//
//  測るのは 3 つ。
//
//    1. 姿勢だけ求める実行は、メッシュまで作る実行の何倍速いか
//       → 1 巡目のコスト。ここが 0.8 倍しか速くならないなら二巡構成は割に合わない
//    2. 姿勢だけなら窓を何枚まで大きくできるか
//       → メモリを食うのはメッシュ生成以降のはずなので、1 巡目はずっと大きく
//         取れる可能性がある。取れるほど全体座標系の継ぎ目が減る
//    3. **段階ごとの所要時間**（preProcessing / imageAlignment /
//       pointCloudGeneration / meshGeneration / textureMapping / optimization）
//       → 1 回の本番実行だけでも「対応付けが全体の何割か」が分かる。これが
//         8 割なら、メッシュを飛ばしても大して速くならないと事前に言える
//
//  ついでに **どの写真が捨てられたか**（skipped / invalid）と、**姿勢が付いた
//  枚数**も数える。§3.7 の「姿勢が付かなかった写真＝本当に使えない写真」が
//  実際にどれくらい出るのかは、ここで初めて分かる。
//
//  なぜ本体（photogrammetry-cli）に `--poses-only` を足さないのか:
//    足すかどうかを決めるための計測だから。**測ってから入れる**（#11 / #12 は
//    測る前に入れて 2 度戻した）。二巡構成を採ると決まったら正式な入口を作る。
//
//  使い方（Object Capture が動く実機で）:
//
//    swiftc -O scripts/measure-poses.swift -o /tmp/measure-poses
//    /tmp/measure-poses ~/Pictures/現場 --counts 100,200,400 | tee /tmp/poses.txt
//
//  **必ず tee でファイルへ残すこと。** CorePhotogrammetry は内部エラーで
//  abort() することがあり（CLAUDE.md）、その場合このプロセスごと落ちる。
//  1 件ずつ結果を吐いて flush してあるので、落ちてもそこまでの測定値は残る。
//
//  オプション:
//    --counts 100,200,400   試す枚数（小さい順に。既定 100,200,400）
//    --start N              撮影順の何枚目から取るか（既定 0）
//    --mode both|poses|model  既定 both（同じ枚数で両方を測って比べる）
//    --detail reduced       model のときの詳細度（既定 reduced＝**保守的**。
//                           medium / full ほどメッシュ側が重くなるので、
//                           reduced で得た倍率は二巡構成に最も不利な値になる）
//    --subject scene|object 既定 scene（建物・部屋。object マスキングを切る）
//    --ordering unordered|sequential  既定 unordered（§3.2.1）
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
var counts = [100, 200, 400]
var start = 0
var modeName = "both"
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
	switch argument
	{
		case "--counts":
			counts = value().split(separator: ",").compactMap { Int($0) }.sorted()
		case "--start":
			start = Int(value()) ?? 0
		case "--mode":
			modeName = value()
		case "--detail":
			detailName = value()
		case "--subject":
			subjectName = value()
		case "--ordering":
			orderingName = value()
		case "-h", "--help":
			print("使い方: measure-poses <写真フォルダ> [--counts 100,200,400] "
				+ "[--start N] [--mode both|poses|model] [--detail reduced] "
				+ "[--subject scene|object] [--ordering unordered|sequential]")
			exit(0)
		default:
			if argument.hasPrefix("-") || inputPath != nil
			{
				fail("不明な引数: \(argument)")
			}
			inputPath = argument
	}
}

guard let inputPath, !counts.isEmpty
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

/// EXIF 撮影時刻。**窓は撮影順の連続区間なので、ここも撮影順で切り出す**
/// （設計 §3.2 の窓と同じ形で測らないと、測定が本番とずれる）。
func captureDate(of url: URL) -> Date?
{
	guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
		let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
		let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
	else
	{
		return nil
	}
	let formatter = DateFormatter()
	formatter.locale = Locale(identifier: "en_US_POSIX")
	formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
	return formatter.date(from: text)
}

let allFiles = imageFiles(in: root)
guard !allFiles.isEmpty
else
{
	fail("画像が 1 枚も見つかりませんでした: \(root.path)")
}

/// 撮影順（EXIF 時刻。無いものは末尾へ）。
let ordered = allFiles
	.map { (url: $0, date: captureDate(of: $0)) }
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
	.map(\.url)

log("画像 \(ordered.count) 枚（撮影順）。\(start) 枚目から切り出して測ります")

/// 指定枚数ぶんの窓を作る。ハードリンク（同一ボリューム外ならコピー）。
func makeWindow(count: Int) throws -> URL
{
	let folder = FileManager.default.temporaryDirectory
		.appendingPathComponent("measure-poses-\(count)-\(start)", isDirectory: true)
	try? FileManager.default.removeItem(at: folder)
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	let slice = ordered.dropFirst(start).prefix(count)
	for (index, source) in slice.enumerated()
	{
		// 並び順が名前でも保たれるようにしておく（--ordering sequential のとき、
		// Object Capture はフォルダ内の順序を見るため）。
		let name = String(format: "%05d.%@", index, source.pathExtension)
		let destination = folder.appendingPathComponent(name)
		do
		{
			try FileManager.default.linkItem(at: source, to: destination)
		}
		catch
		{
			try FileManager.default.copyItem(at: source, to: destination)
		}
	}
	return folder
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

func measure(mode: Mode, count: Int) async -> Measurement
{
	var measurement = Measurement()
	let peak = PeakMemory()
	let began = Date()

	let folder: URL
	do
	{
		folder = try makeWindow(count: count)
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
	configuration.sampleOrdering = orderingName == "sequential" ? .sequential : .unordered
	// 建物・部屋ではオブジェクトマスキングを切る（切らないと前景の切り出しが
	// 破綻してアライメントが落ちる。PhotogrammetryEngine と同じ判断）。
	configuration.isObjectMaskingEnabled = (subjectName == "object")

	let output = FileManager.default.temporaryDirectory
		.appendingPathComponent("measure-poses-\(count)-\(start).usdz")
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

func line(mode: Mode, count: Int, _ measurement: Measurement) -> String
{
	let stages = measurement.stageStarts
		.map { String(format: "%@:%.0f", $0.0, $0.1) }
		.joined(separator: ",")
	return String(
		format: "run mode=%@ count=%d elapsed=%.1f posed=%d skipped=%d invalid=%d "
			+ "downsampled=%@ peak=%@ stages=%@ result=%@",
		mode.rawValue, count, measurement.elapsed, measurement.posed,
		measurement.skipped, measurement.invalid,
		measurement.downsampled ? "yes" : "no",
		gigabytes(measurement.peakBytes),
		stages.isEmpty ? "-" : stages,
		measurement.outcome)
}

let modes: [Mode]
switch modeName
{
	case "poses": modes = [.poses]
	case "model": modes = [.model]
	default: modes = [.poses, .model]
}

Task
{
	guard PhotogrammetrySession.isSupported
	else
	{
		emit("result=unsupported  この Mac は Object Capture に対応していません")
		exit(3)
	}
	emit("# 入力 \(ordered.count) 枚 / start=\(start) / detail=\(detailName) "
		+ "/ subject=\(subjectName) / ordering=\(orderingName)")
	emit("# ハードウェア上限 \(PhotogrammetrySession.limits.maximumNumberOfInputImages) 枚")

	var elapsedByKey: [String: TimeInterval] = [:]
	for count in counts
	{
		guard count <= ordered.count - start
		else
		{
			emit("# count=\(count) は写真が足りないので飛ばします")
			continue
		}
		for mode in modes
		{
			log("測定中: mode=\(mode.rawValue) count=\(count) …")
			let measurement = await measure(mode: mode, count: count)
			emit(line(mode: mode, count: count, measurement))
			elapsedByKey["\(mode.rawValue)-\(count)"] = measurement.elapsed
		}
		// 同じ枚数で両方を測ったときだけ、その場で倍率を出す（落ちても
		// そこまでの比較が残るように、最後にまとめて出すことはしない）。
		if let poses = elapsedByKey["poses-\(count)"],
			let model = elapsedByKey["model-\(count)"], poses > 0
		{
			emit(String(
				format: "ratio count=%d poses=%.1f model=%.1f speedup=%.2f",
				count, poses, model, model / poses))
		}
	}
	emit("done")
	exit(0)
}

// RealityKit が main キューへ処理を投げても詰まらないようにする
// （セマフォで待つと、そのときデッドロックしうる）。
dispatchMain()
