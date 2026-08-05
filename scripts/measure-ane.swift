//
//  measure-ane.swift
//
//  **ANE モデルのコンパイル失敗が、投げる写真の枚数（＝メモリの山）で
//  起きたり起きなかったりするのか**を測るための、最小の Object Capture 実行体。
//
//  観測されている故障は次の 1 行で、`ModelCache`（Sources/PhotogrammetryCore/
//  ModelCache.swift）が既に名指ししている。
//
//    E5RT encountered an STL exception. msg = MILCompilerForANE error:
//    failed to compile ANE model using ANEF. Error=_ANECompiler : ANECCompile() FAILED.
//
//  本体（アプリ）はこれを「キャッシュを消して作り直す」で回避しているが、
//  **なぜコンパイルが失敗するのか**は分かっていない。仮説はいくつかあり、
//  そのうち「メモリ不足」だけは手元で振れる変数（＝枚数）を持つ。この実行体は
//  その 1 変数だけを動かせるように、測定に要らないものを全部削ってある。
//
//  **この実行体が単独では答えを出せないこと**（driver が要る理由）:
//
//    ANE 用モデルのコンパイルは**キャッシュが空のときにしか走らない**。
//    一度成功すると ~/Library/Caches/<プロセス名>/com.apple.e5rt.e5bundlecache
//    に残り、以降の実行はコンパイルせずそれを読む。つまり素朴に枚数を変えて
//    2 回目・3 回目を回しても、**コンパイルの成否は 1 回しか観測できない**。
//    試行ごとにキャッシュを消して条件を揃えるのは scripts/trial-ane-memory.sh
//    の仕事で、こちらは「1 回投げて何が起きたかを機械可読に吐く」だけを担う。
//
//  出力（driver が読む。人間も読める）:
//
//    # ane-cache: <キャッシュの場所>
//    SAMPLE t=12.0 footprint=1234567890 stage=imageAlignment
//    RESULT count=100 elapsed=812.3 peak_bytes=5033164800 peak_stage=imageAlignment \
//           posed=88 total=100 outcome=ok
//
//  E5RT / ANECCompile の行は**フレームワークが直接標準エラーへ書く**ので、
//  この実行体は捕まえない（driver がログ全体を見て判定する）。同じ理由で、
//  CorePhotogrammetry が abort() したときもここには何も残らない — その場合は
//  プロセスがシグナルで死ぬので、driver が終了コードで見分ける。
//
//  使い方（Object Capture が動く実機で）:
//
//    swiftc -O scripts/measure-ane.swift -o /tmp/measure-ane
//    /tmp/measure-ane ~/Pictures/現場 --count 100
//
//  **実行体の名前を変えないこと。** ANE キャッシュの置き場はバンドル ID の
//  無い実行体ではプロセス名で切られるので、名前を変えると driver が消す場所と
//  ずれる（driver は自分がビルドした実行体のパスから場所を組み立てる）。
//
//  オプション:
//    --count 100          投げる枚数（既定 100）
//    --start 0            撮影順（ファイル名順）で何枚目から取るか
//    --mode poses|model   既定 poses。model はメッシュまで作るのでメモリの山が
//                         数倍高くなる（設計 §6.2.7 の実測で 4.7GB → 14.4GB）
//    --detail reduced     model のときの詳細度
//    --ordering unordered|sequential   既定 unordered
//    --sensitivity normal|high         既定 normal
//    --subject scene|object            既定 scene（建物・部屋）
//    --timeout 1800       1 回の上限（秒）。超えたら中断して timeout を返す
//    --purge-cache        始める前に ANE キャッシュを消す
//    --ballast 8          **測定ではなく重し**。8GiB を確保して触って居座る
//                         （driver が「わざとメモリを詰める」ために使う）
//    --selftest           実行環境と ANE キャッシュの場所を出して終わる
//
//  終了コード: 0 成功 / 2 使い方 / 3 セッションのエラー / 4 時間切れ。
//  シグナル死（abort）は driver 側が 128+N で見分ける。
//

import CoreGraphics
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
var count = 100
var start = 0
var modeName = "poses"
var detailName = "reduced"
var orderingName = "unordered"
// **既定を high にしてある。** この道具の目的は位置合わせの品質を測ることでは
// なく、**ANE モデルのコンパイルが走るところまで到達すること**。normal で
// error 6 になる窓は imageAlignment で終わるので、ANE の問いに一切触れずに
// 終わる（実測で 12 試行すべてがこれだった）。high は特徴の少ない面から特徴を
// 拾うので、死んでいた区間が生き返る（design-loose-clustering §6.2）。
var sensitivityName = "high"
var subjectName = "scene"
/// 窓の一覧ファイル（`--window-file`）。1 行 1 パスで、**その順序がそのまま
/// Object Capture へ渡す並び**になる。measure-ordering が書き出した「通る窓」を
/// そのまま投げれば、ANE の段階まで確実に届く。
var windowFile = ""
/// iCloud の未ダウンロードをまとめて落としてから進む（`--download`）。
var downloadFirst = false
var timeoutSeconds: TimeInterval = 1800
var ballastGigabytes = 0
var selftestOnly = false
var purgeCache = false

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
		case "--count":
			count = Int(value()) ?? count
		case "--start":
			start = Int(value()) ?? start
		case "--mode":
			modeName = value()
		case "--detail":
			detailName = value()
		case "--ordering":
			orderingName = value()
		case "--sensitivity":
			sensitivityName = value()
		case "--subject":
			subjectName = value()
		case "--timeout":
			timeoutSeconds = Double(value()) ?? timeoutSeconds
		case "--ballast":
			ballastGigabytes = Int(value()) ?? 0
		case "--purge-cache":
			purgeCache = true
		case "--window-file":
			windowFile = value()
		case "--download":
			downloadFirst = true
		case "--selftest":
			selftestOnly = true
		case "-h", "--help":
			print("使い方: measure-ane <写真フォルダ> [--count 100] [--start 0] "
				+ "[--mode poses|model] [--detail reduced] "
				+ "[--ordering unordered|sequential] [--sensitivity normal|high] "
				+ "[--subject scene|object] [--timeout 1800] [--purge-cache] "
				+ "[--window-file FILE] [--download] [--ballast GiB] [--selftest]")
			exit(0)
		default:
			if argument.hasPrefix("-") || inputPath != nil
			{
				fail("不明な引数: \(argument)")
			}
			inputPath = argument
	}
}

// **綴り違いを黙って別の設定へ落とさない**（measure-poses と同じ方針。
// `--sensitivity hight` が normal として走り、測定を丸ごと無駄にした前例がある）。
func validate(_ name: String, _ value: String, _ allowed: [String])
{
	guard allowed.contains(value)
	else
	{
		fail("\(name) の値が不正です: \(value)（使えるのは \(allowed.joined(separator: " / "))）")
	}
}
validate("--mode", modeName, ["poses", "model"])
validate("--ordering", orderingName, ["unordered", "sequential"])
validate("--sensitivity", sensitivityName, ["normal", "high"])
validate("--detail", detailName, ["preview", "reduced", "medium", "full", "raw"])
validate("--subject", subjectName, ["scene", "object"])

func log(_ message: String)
{
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}

/// 機械可読な 1 行。**必ず flush する** — CorePhotogrammetry は内部エラーで
/// abort() することがあり、そのときバッファに残った行は失われるため。
func emit(_ line: String)
{
	print(line)
	fflush(stdout)
}

// ---------------------------------------------------------------------
// ANE キャッシュの場所（ModelCache と対。名前は E5RT が決めている）
// ---------------------------------------------------------------------

/// バンドル ID の無い素の実行体では**プロセス名**で切られる
/// （実機で `~/Library/Caches/measure-poses/…` を確認済み）。
let modelCacheDirectory: URL? = FileManager.default
	.urls(for: .cachesDirectory, in: .userDomainMask).first?
	.appendingPathComponent(
		Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
	.appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)

// ---------------------------------------------------------------------
// 重し（--ballast）。**測定ではない。**
// ---------------------------------------------------------------------
//
// 「メモリ不足なら枚数を減らせば防げる」を確かめるだけなら枚数を振れば足りるが、
// それだけでは**枚数と失敗が無関係だった場合に「メモリのせいではない」と言い切れ
// ない**（そのマシンでは元々足りていただけかもしれない）。逆向きの実験 —
// わざと空きを潰して失敗を**呼び出せるか** — が要る。呼び出せたならメモリが
// 原因だと確定し、呼び出せないならメモリ以外を疑う番になる。
//
// 触らないと物理ページが割り当たらない（確保だけでは重しにならない）ので、
// 1 ページごとに書き込む。

if ballastGigabytes > 0
{
	let chunkBytes = 256 * 1024 * 1024
	let chunks = max(1, ballastGigabytes * 4)
	var held: [UnsafeMutableRawPointer] = []
	let pageSize = Int(getpagesize())
	for _ in 0 ..< chunks
	{
		guard let block = malloc(chunkBytes)
		else
		{
			log("重しの確保に失敗しました（\(held.count * chunkBytes / 1_073_741_824)GiB まで）")
			break
		}
		// ページごとに触って物理メモリを実際に占有させる。
		var offset = 0
		while offset < chunkBytes
		{
			block.storeBytes(of: UInt8(1), toByteOffset: offset, as: UInt8.self)
			offset += pageSize
		}
		held.append(block)
	}
	emit("BALLAST ready gib=\(held.count * chunkBytes / 1_073_741_824)")
	// SIGTERM が来るまで居座る（driver が試行の終わりに落とす）。
	while true
	{
		sleep(3600)
	}
}

// ---------------------------------------------------------------------
// 自己診断（--selftest）
// ---------------------------------------------------------------------

emit("# ane-cache: \(modelCacheDirectory?.path ?? "（不明）")")

if selftestOnly
{
	emit("# isSupported: \(PhotogrammetrySession.isSupported)")
	let cacheExists = modelCacheDirectory.map
	{
		FileManager.default.fileExists(atPath: $0.path)
	} ?? false
	emit("# ane-cache-exists: \(cacheExists)")
	emit("SELFTEST ok")
	exit(0)
}

guard PhotogrammetrySession.isSupported
else
{
	// **ここで止める。** 対応していないマシンで測っても、出るのは常に同じ
	// 「非対応」で、ANE の話は 1 ミリも進まない。
	emit("RESULT count=0 elapsed=0 peak_bytes=0 peak_stage=- posed=0 total=0 "
		+ "invalid=0 skipped=0 unreadable=0 cache_bundles=0 outcome=unsupported")
	log("このマシンでは Object Capture が使えません（PhotogrammetrySession.isSupported == false）")
	exit(3)
}

guard let inputPath
else
{
	fail("使い方: measure-ane <写真フォルダ> [オプション]")
}

if purgeCache, let modelCacheDirectory
{
	let existed = FileManager.default.fileExists(atPath: modelCacheDirectory.path)
	try? FileManager.default.removeItem(at: modelCacheDirectory)
	log(existed ? "ANE キャッシュを削除しました" : "ANE キャッシュはありませんでした")
}

// ---------------------------------------------------------------------
// 窓を作る（枚数だけを変えたいので、選び方は素直に「先頭から N 枚」）
// ---------------------------------------------------------------------

let root = URL(fileURLWithPath: inputPath, isDirectory: true).standardizedFileURL
let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng"]

/// EXIF の撮影時刻。**ファイル名順ではなく撮影順で切る。** 名前順で切った窓は
/// 12 試行すべてが error 6 になり、ANE の段階へ 1 度も到達しなかった
/// （複数の機材・改名が混ざると名前順は撮影順にならない）。窓が空間的に
/// 連続していないと位置合わせは繋がらないので、ここは撮影時刻で並べる。
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
	formatter.timeZone = TimeZone.current
	return formatter.date(from: text)
}

/// 画像として開けるか。**開けない写真は error 6 の最有力容疑**なので、
/// 投げる前に数えておく（iCloud のプレースホルダ・壊れたファイル）。
func isReadableImage(_ url: URL) -> Bool
{
	guard let source = CGImageSourceCreateWithURL(url as CFURL, nil)
	else
	{
		return false
	}
	return CGImageSourceGetCount(source) > 0
}

/// iCloud にまだ実体が無いもの。読むと 1 枚ずつダウンロードが走って
/// 「止まったように見える」ので、先に数えて言う（measure-poses と同じ方針）。
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
		case .some(.current), .some(.downloaded): return true
		default: return false
	}
}

let window: [URL]
if !windowFile.isEmpty
{
	// 窓の一覧をそのまま使う（並びも一覧の順序のまま）。**通ることが分かって
	// いる窓を投げるのがいちばん確実に ANE の段階まで届く道。**
	let text = (try? String(contentsOfFile: windowFile, encoding: .utf8)) ?? ""
	let paths = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
	guard !paths.isEmpty
	else
	{
		fail("窓の一覧が空です: \(windowFile)")
	}
	window = paths.map { URL(fileURLWithPath: $0) }
	count = window.count
}
else
{
	let keys: [URLResourceKey] = [.isRegularFileKey]
	let enumerated = (try? FileManager.default.contentsOfDirectory(
		at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
	let candidates = enumerated.filter { photoExtensions.contains($0.pathExtension.lowercased()) }

	let pending = candidates.filter { !isMaterialized($0) }
	if !pending.isEmpty
	{
		guard downloadFirst
		else
		{
			log("iCloud にまだ実体の無い写真が \(pending.count)/\(candidates.count) 枚あります。"
				+ "このまま読むと 1 枚ずつダウンロードが走って止まったように見えます。"
				+ "--download を付けるか、Finder で「今すぐダウンロード」してください。")
			emit("RESULT count=0 elapsed=0 peak_bytes=0 peak_stage=- posed=0 total=0 "
				+ "invalid=0 skipped=0 unreadable=\(pending.count) cache_bundles=0 "
				+ "outcome=icloud-not-downloaded")
			exit(3)
		}
		log("iCloud からのダウンロードを開始します（\(pending.count) 枚）")
		for url in pending
		{
			try? FileManager.default.startDownloadingUbiquitousItem(at: url)
		}
		var remaining = pending
		while !remaining.isEmpty
		{
			Thread.sleep(forTimeInterval: 2)
			remaining = remaining.filter { !isMaterialized($0) }
		}
		log("ダウンロード完了")
	}

	// 撮影順に並べる。EXIF の無いものは名前順で後ろへ回す（混ぜて並びを
	// 壊すより、順序の分かるものだけで窓を作るほうが安全）。
	let dated = candidates.map { (url: $0, date: captureDate(of: $0)) }
	let ordered = dated.sorted
	{ left, right in
		switch (left.date, right.date)
		{
			case (.some(let a), .some(let b)): return a == b
				? left.url.lastPathComponent < right.url.lastPathComponent : a < b
			case (.some, .none): return true
			case (.none, .some): return false
			case (.none, .none): return left.url.lastPathComponent < right.url.lastPathComponent
		}
	}.map(\.url)
	let withoutDate = dated.filter { $0.date == nil }.count
	if withoutDate > 0
	{
		log("EXIF の撮影時刻が読めない写真が \(withoutDate)/\(candidates.count) 枚あります"
			+ "（名前順で後ろへ回しました）")
	}

	guard ordered.count >= start + count
	else
	{
		fail("写真が足りません（見つかった \(ordered.count) 枚、要求 start=\(start) count=\(count)）")
	}
	window = Array(ordered.dropFirst(start).prefix(count))
}

// **開けない写真を先に数える。** error 6 が「窓が繋がらない」なのか
// 「そもそも画像が読めていない」なのかは、これが無いと区別できない。
let unreadable = window.filter { !isReadableImage($0) }.count
if unreadable > 0
{
	log("画像として開けない写真が \(unreadable)/\(window.count) 枚あります")
}

/// セッションが「使えない」と言った枚数（`.invalidSample`）と、位置合わせから
/// 外した枚数（`.skippedSample`）。error 6 の中身を説明できる唯一の材料。
var invalidSamples = 0
var skippedSamples = 0

/// 投げるフォルダ。ハードリンク（同一ボリューム外ならコピー）で作る
/// — **写真を二重に持たない**ため（数百枚のコピーはそれ自体がディスクを食う）。
let windowFolder = FileManager.default.temporaryDirectory
	.appendingPathComponent("measure-ane-\(start)-\(count)", isDirectory: true)
try? FileManager.default.removeItem(at: windowFolder)
try FileManager.default.createDirectory(at: windowFolder, withIntermediateDirectories: true)
for (index, source) in window.enumerated()
{
	// 名前でも並びが保たれるようにしておく（sequential のとき OC はフォルダ内の
	// 順序を見る）。
	let name = String(format: "%05d.%@", index, source.pathExtension)
	let destination = windowFolder.appendingPathComponent(name)
	do
	{
		try FileManager.default.linkItem(at: source, to: destination)
	}
	catch
	{
		try FileManager.default.copyItem(at: source, to: destination)
	}
}

// ---------------------------------------------------------------------
// メモリの山を追う見張り
// ---------------------------------------------------------------------

/// このプロセスの物理フットプリント（バイト）。**GPU 側は数えられない**ので、
/// 「どこまで行ったか」の目安として見る。
func physicalFootprint() -> UInt64
{
	var info = task_vm_info_data_t()
	var size = mach_msg_type_number_t(
		MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
	let result = withUnsafeMutablePointer(to: &info)
	{ pointer in
		pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size))
		{ rebound in
			task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &size)
		}
	}
	return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

/// 見張り役。**山の高さを段階ごとに覚えておく**のがこの測定の肝で、
/// 「どの段階でメモリが天井に当たったか」が分からないと、枚数との関係を
/// 説明できない。あわせて時間切れの打ち切りも持つ（CorePhotogrammetry は
/// 返らなくなることがあり、放置すると一晩で 1 件も測れない）。
final class Monitor: @unchecked Sendable
{
	private let lock = NSLock()
	private var peak: UInt64 = 0
	private var peakStage = "-"
	private var stage = "-"
	private var running = true
	private let began = Date()
	private let timeout: TimeInterval
	private let onTimeout: () -> Void

	init(timeout: TimeInterval, onTimeout: @escaping () -> Void)
	{
		self.timeout = timeout
		self.onTimeout = onTimeout
	}

	func start()
	{
		Thread.detachNewThread
		{ [self] in
			var lastEmitted = Date.distantPast
			while true
			{
				lock.lock()
				let alive = running
				let currentStage = stage
				lock.unlock()
				guard alive
				else
				{
					return
				}
				let footprint = physicalFootprint()
				lock.lock()
				if footprint > peak
				{
					peak = footprint
					peakStage = currentStage
				}
				lock.unlock()
				// **生きていることを定期的に出す。** 1 回の実行は数分から数十分
				// 無音になるので、止まっているのか進んでいるのかが分からない。
				// 同時に、abort() で落ちても直前の値がログに残る（RESULT 行が
				// 出ないときの唯一の手掛かり）。
				if Date().timeIntervalSince(lastEmitted) >= 10
				{
					lastEmitted = Date()
					emit(String(format: "SAMPLE t=%.0f footprint=%llu stage=%@",
						Date().timeIntervalSince(began), footprint, currentStage))
				}
				if Date().timeIntervalSince(began) > timeout
				{
					onTimeout()
					return
				}
				Thread.sleep(forTimeInterval: 0.5)
			}
		}
	}

	func update(stage newStage: String)
	{
		lock.lock()
		stage = newStage
		lock.unlock()
	}

	func stop() -> (peak: UInt64, stage: String)
	{
		lock.lock()
		running = false
		let result = (peak, peakStage)
		lock.unlock()
		return result
	}
}

func stageName(_ stage: PhotogrammetrySession.Output.ProcessingStage) -> String
{
	switch stage
	{
		case .preProcessing: return "preProcessing"
		case .imageAlignment: return "imageAlignment"
		case .pointCloudGeneration: return "pointCloudGeneration"
		case .meshGeneration: return "meshGeneration"
		case .textureMapping: return "textureMapping"
		case .optimization: return "optimization"
		default: return "other"
	}
}

// ---------------------------------------------------------------------
// 1 回投げる
// ---------------------------------------------------------------------

/// driver が読む 1 行。**どの出口からも同じ書式で出す**（成功・エラー・時間切れで
/// 書式が違うと、集計側が出口ごとの分岐を持つことになり必ずずれる）。
func resultLine(
	elapsed: TimeInterval, peak: UInt64, peakStage: String, posed: Int, outcome: String) -> String
{
	// **outcome に空白を入れない。** driver は `outcome=<空白なし>` として
	// 切り出す。フレームワークは E5RT の行を改行なしで書くので、こちらの 1 行の
	// 後ろに他人の文字列が繋がることがあり、「行末まで」で取ると飲み込んでしまう。
	let flattened = outcome
		.replacingOccurrences(of: " ", with: "_")
		.replacingOccurrences(of: "\t", with: "_")
		.replacingOccurrences(of: "\n", with: "_")
	// **ANE キャッシュに何か出来たかを必ず一緒に出す。** これが 0 のままなら、
	// その試行は ANE コンパイルを 1 度も走らせていない＝ ANE の問いに対して
	// 無効な試行である。実測で 12 試行すべてがこれだったのに、RESULT 行だけを
	// 見ていては気付けなかった。
	return String(format: "RESULT count=%d elapsed=%.1f peak_bytes=%llu peak_stage=%@ "
		+ "posed=%d total=%d invalid=%d skipped=%d unreadable=%d cache_bundles=%d outcome=%@",
		count, elapsed, peak, peakStage, posed, count,
		invalidSamples, skippedSamples, unreadable, cacheBundleCount(),
		String(flattened.prefix(120)))
}

/// ANE キャッシュの中にバンドルがいくつ出来たか。
func cacheBundleCount() -> Int
{
	guard let modelCacheDirectory,
		let entries = try? FileManager.default.contentsOfDirectory(
			atPath: modelCacheDirectory.path)
	else
	{
		return 0
	}
	return entries.count
}

Task
{
	var configuration = PhotogrammetrySession.Configuration()
	configuration.sampleOrdering = orderingName == "sequential" ? .sequential : .unordered
	configuration.featureSensitivity = sensitivityName == "high" ? .high : .normal
	// 建物・部屋では被写体マスキングを切る（切らないと壁が丸ごと落ちる）。
	configuration.isObjectMaskingEnabled = subjectName == "object"

	let began = Date()
	let outputFile = FileManager.default.temporaryDirectory
		.appendingPathComponent("measure-ane-\(start)-\(count).usdz")
	try? FileManager.default.removeItem(at: outputFile)

	var posed = 0
	var outcome = "ok"

	// 投げた写真をセッションがどう見たか。**error 6 の切り分けに要る**
	// （繋がらなかったのか、そもそも使える写真が無かったのか）。

	do
	{
		let session = try PhotogrammetrySession(input: windowFolder, configuration: configuration)
		let monitor = Monitor(timeout: timeoutSeconds)
		{
			session.cancel()
			// **打ち切りが効かないことがある。** 効かないまま待ち続けると
			// 一晩で 1 件も測れないので、猶予を置いて自分で降りる。
			// driver は終了コード 4 を「時間切れ」として記録する。
			Thread.sleep(forTimeInterval: 30)
			emit(resultLine(elapsed: Date().timeIntervalSince(began),
				peak: 0, peakStage: "-", posed: 0, outcome: "timeout"))
			exit(4)
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
		var requests: [PhotogrammetrySession.Request] = [.modelFile(url: outputFile, detail: detail)]
		if modeName == "poses"
		{
			guard #available(macOS 14.0, *)
			else
			{
				fail("--mode poses は macOS 14 以降が要ります")
			}
			requests = [.poses]
		}

		monitor.start()
		try session.process(requests: requests)

		for try await event in session.outputs
		{
			switch event
			{
				case .requestProgressInfo(_, let info):
					if let stage = info.processingStage
					{
						monitor.update(stage: stageName(stage))
					}
				case .skippedSample:
					skippedSamples += 1
				case .invalidSample:
					invalidSamples += 1
				case .requestComplete(_, let result):
					if #available(macOS 14.0, *), case .poses(let poses) = result
					{
						posed = poses.posesBySample.count
					}
				case .requestError(_, let error):
					// **その場で畳む。** 要求が失敗したあとに完了が来る保証は
					// なく、来なければ永久に待つことになる。
					outcome = "error: \(error.localizedDescription)"
					let (peak, peakStage) = monitor.stop()
					emit(resultLine(elapsed: Date().timeIntervalSince(began),
						peak: peak, peakStage: peakStage, posed: posed, outcome: outcome))
					try? FileManager.default.removeItem(at: windowFolder)
					try? FileManager.default.removeItem(at: outputFile)
					exit(3)
				case .processingComplete:
					let (peak, peakStage) = monitor.stop()
					emit(resultLine(elapsed: Date().timeIntervalSince(began),
						peak: peak, peakStage: peakStage, posed: posed, outcome: outcome))
					try? FileManager.default.removeItem(at: windowFolder)
					try? FileManager.default.removeItem(at: outputFile)
					exit(0)
				case .processingCancelled:
					let (peak, peakStage) = monitor.stop()
					emit(resultLine(elapsed: Date().timeIntervalSince(began),
						peak: peak, peakStage: peakStage, posed: posed, outcome: "cancelled"))
					try? FileManager.default.removeItem(at: windowFolder)
					try? FileManager.default.removeItem(at: outputFile)
					exit(4)
				default:
					break
			}
		}
	}
	catch
	{
		emit(resultLine(elapsed: Date().timeIntervalSince(began),
			peak: 0, peakStage: "-", posed: posed,
			outcome: "throw: \(error.localizedDescription)"))
		try? FileManager.default.removeItem(at: windowFolder)
		exit(3)
	}
}

// RealityKit が main キューへ処理を投げても詰まらないようにする
// （セマフォで待つと、そのときデッドロックしうる）。
dispatchMain()
