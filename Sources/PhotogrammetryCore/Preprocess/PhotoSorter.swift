//
//  PhotoSorter.swift
//
//  仕分けの実行。走査 → 解析 → 品質フィルタ → グルーピング → 計画 → 配置 →
//  manifest 書き出し、を順に呼ぶだけの薄い層で、判断は各段（純ロジック）が持つ。
//
//  ファイルシステムに触れるのはここ。写真の読み取りは PhotoMetadataReading 越しに
//  行うので、テストでは実画像を用意せずに配置・manifest・診断まで確かめられる
//  （HelperProcessEngine をシェルスクリプトで差し替えられるようにしてあるのと
//  同じ考え方）。
//

import Foundation

/// 仕分け先のフォルダ構成（設計メモ §4.5）。名前は manifest と対で外部に
/// 見える約束なので、ここ 1 か所に置く。
public enum SortLayout
{
	/// 品質フィルタで落とした写真の退避先。理由ごとのサブフォルダを作る。
	public static let excludedFolder = "_excluded"
	/// どのグループにも入らなかった写真の退避先。
	public static let unassignedFolder = "_unassigned"

	/// 相対パスを、フォルダ直下に置ける 1 つのファイル名へ潰す。
	///
	/// PhotogrammetrySession は入力フォルダの**直下**しか見ないので、サブ
	/// フォルダ付きで取り込んだ写真もグループ内では平らに並べる必要がある。
	/// 単にファイル名だけにすると別フォルダの同名ファイル（IMG_0001.HEIC が
	/// 階ごとにある、は普通に起きる）が衝突するため、区切りを `_` へ替えて
	/// 経路ごと名前にする。
	public static func flattenedName(for relativePath: String) -> String
	{
		relativePath.replacingOccurrences(of: "/", with: "_")
	}
}

/// 仕分けの中断フラグ。数千枚のデコードは数分かかることがあるので、フォルダを
/// 選び間違えたときに待たされないための逃げ道を用意する。
///
/// 生成（`PhotogrammetryEngine.cancel`）と違ってセッションを持たないため、
/// 「各段の切れ目で見る真偽値」で足りる。スレッドを跨ぐのでロックで守る。
public final class SortCancellation: @unchecked Sendable
{
	private let lock = NSLock()
	private var cancelled = false

	public init() {}

	public func cancel()
	{
		lock.lock()
		cancelled = true
		lock.unlock()
	}

	public var isCancelled: Bool
	{
		lock.lock()
		defer { lock.unlock() }
		return cancelled
	}
}

public struct PhotoSorter: Sendable
{
	/// 写真からメタデータを読む役。
	public var reader: PhotoMetadataReading
	/// この Mac の 1 セッション上限枚数（診断に使う）。分からなければ nil。
	public var hardwareLimit: Int?

	public init(reader: PhotoMetadataReading = PhotoInspector(), hardwareLimit: Int? = nil)
	{
		self.reader = reader
		self.hardwareLimit = hardwareLimit
	}

	/// 仕分けを実行して manifest を返す。`request.dryRun` が true ならファイルは
	/// 一切作らず、解析と診断だけを行う（現場で撮り直しを判断するための経路）。
	@discardableResult
	public func run(
		_ request: SortRequest,
		fileManager: FileManager = .default,
		cancellation: SortCancellation? = nil,
		progress: @escaping @Sendable (ReconstructionEvent) -> Void = { _ in }) throws
		-> SortManifest
	{
		try request.validate(fileManager: fileManager)

		// 中断は各段の切れ目で見る。途中まで作ったフォルダを残すと「前回の結果と
		// 混ざる」ので、配置を始める前に必ず抜ける。
		func checkCancellation() throws
		{
			if cancellation?.isCancelled == true
			{
				throw SortError.cancelled
			}
		}

		// --- 走査 ---
		let outputPath = request.outputFolder.standardizedFileURL.path
		let files = PhotoInspector.imageFiles(
			in: request.inputFolder,
			recursive: request.recursive,
			fileManager: fileManager)
			// 仕分け先が入力フォルダの中にある場合、前回の結果を取り込まない。
			.filter { !$0.url.standardizedFileURL.path.hasPrefix(outputPath + "/") }
		guard !files.isEmpty
		else
		{
			throw SortError.noImages(request.inputFolder.path)
		}
		progress(.note("写真 \(files.count) 枚を解析します…"))

		// --- 解析（時間の大半はここ） ---
		let inspected = readAll(files, cancellation: cancellation, progress: progress)
		try checkCancellation()
		if !inspected.unreadable.isEmpty
		{
			progress(.note("読み取れなかったファイル: \(inspected.unreadable.count) 件"))
		}
		progress(.progress(0.6))

		// --- 品質フィルタ → グルーピング → 計画 ---
		var quality = QualityFilter.apply(to: inspected.photos, settings: request.qualitySettings)
		quality.excluded.append(contentsOf: inspected.unreadable.map
		{
			ExcludedPhoto(photo: $0, reason: .unreadable, score: 0)
		})
		progress(.progress(0.7))

		let grouping = PhotoGrouping.group(
			photos: quality.kept, settings: request.groupingSettings)
		progress(.progress(0.8))

		let plan = SortPlanner.plan(grouping: grouping, settings: request.plannerSettings)
		let diagnostics = SortDiagnostics.evaluate(
			plan: plan,
			grouping: grouping,
			quality: quality,
			request: request,
			hardwareLimit: hardwareLimit)
		for diagnostic in diagnostics
		{
			progress(.note(message(for: diagnostic)))
		}

		let manifest = makeManifest(
			request: request,
			plan: plan,
			grouping: grouping,
			quality: quality,
			inputCount: files.count,
			diagnostics: diagnostics)

		// --- 配置 ---
		guard !request.dryRun
		else
		{
			progress(.progress(1.0))
			progress(.note("--dry-run のためファイルは作成していません。"))
			return manifest
		}

		try checkCancellation()
		// 配置元は「走査で見つかった全ファイル」から引く。読めなかったファイルも
		// _excluded/unreadable/ へ残すため（除外した写真は捨てない）。
		let sources = Dictionary(
			files.map { ($0.relativePath, $0.url) },
			uniquingKeysWith: { first, _ in first })
		try place(
			plan: plan,
			quality: quality,
			request: request,
			sources: sources,
			fileManager: fileManager,
			progress: progress)

		let manifestURL = request.outputFolder.appendingPathComponent(SortManifest.fileName)
		try manifest.encoded().write(to: manifestURL, options: .atomic)
		progress(.progress(1.0))
		progress(.completed(manifestURL))
		return manifest
	}

	// -----------------------------------------------------------------
	// 各段
	// -----------------------------------------------------------------

	/// 読み取り。PhotoInspector なら並行読みの実装を使い、差し替えられた
	/// 読み手（テスト）なら 1 件ずつ順に読む。
	func readAll(
		_ files: [PhotoFile],
		cancellation: SortCancellation? = nil,
		progress: @escaping @Sendable (ReconstructionEvent) -> Void)
		-> (photos: [PhotoMetadata], unreadable: [String])
	{
		if let inspector = reader as? PhotoInspector
		{
			// 進捗はイベントの氾濫を避けるため 2% 刻みへ間引き、かつ
			// 並行に届く報告をロックで直列化してから流す。
			let throttle = ProgressThrottle(scale: 0.5)
			{ fraction in
				progress(.progress(fraction))
			}
			return inspector.inspectAll(
				files,
				isCancelled: { cancellation?.isCancelled == true })
			{ done, total in
				throttle.record(Double(done) / Double(total))
			}
		}

		var photos: [PhotoMetadata] = []
		var unreadable: [String] = []
		for (index, file) in files.enumerated()
		{
			if cancellation?.isCancelled == true
			{
				break
			}
			if let metadata = try? reader.read(file)
			{
				photos.append(metadata)
			}
			else
			{
				unreadable.append(file.relativePath)
			}
			if files.count > 0, index % 25 == 0
			{
				progress(.progress(Double(index) / Double(files.count) * 0.5))
			}
		}
		return (photos.sorted { $0.relativePath < $1.relativePath }, unreadable.sorted())
	}

	func makeManifest(
		request: SortRequest,
		plan: SortPlan,
		grouping: GroupingResult,
		quality: QualityFilter.Outcome,
		inputCount: Int,
		diagnostics: [SortDiagnostic]) -> SortManifest
	{
		var byReason: [String: Int] = [:]
		for excluded in quality.excluded
		{
			byReason[excluded.reason.rawValue, default: 0] += 1
		}
		var coverage: [String: Double] = [:]
		for (kind, value) in grouping.evidenceCoverage
		{
			coverage[kind.rawValue] = value
		}

		return SortManifest(
			generatedAt: Date(),
			source: request.inputFolder.standardizedFileURL.path,
			settings: SortManifest.Settings(
				overlap: request.overlap,
				maxPerGroup: request.maxPerGroup,
				minPerGroup: request.minPerGroup,
				timeGap: request.timeGap,
				groupThreshold: grouping.threshold,
				groupThresholdWasAutomatic: grouping.thresholdWasAutomatic,
				sharpnessThreshold: quality.sharpnessThreshold,
				duplicateDistance: request.duplicateDistance,
				link: request.link),
			evidence: SortManifest.Evidence(
				used: grouping.usedEvidence.map(\.rawValue),
				coverage: coverage),
			statistics: SortManifest.Statistics(
				inputCount: inputCount,
				keptCount: quality.kept.count,
				groupCount: plan.groups.count,
				excludedByReason: byReason,
				scoreHistogram: grouping.scoreHistogram,
				sharpnessMedian: quality.sharpnessMedian),
			groups: plan.groups.map
			{
				SortManifest.Group(
					id: $0.id,
					photos: $0.photos,
					shared: $0.shared,
					evidence: $0.evidence.map(\.rawValue),
					captureStart: $0.captureStart,
					captureEnd: $0.captureEnd)
			},
			adjacency: plan.adjacency.map
			{
				SortManifest.Adjacency(
					a: $0.a,
					b: $0.b,
					sharedPhotos: $0.sharedPhotos,
					confidence: $0.confidence,
					viewpointSpread: $0.viewpointSpread)
			},
			excluded: quality.excluded.map
			{
				SortManifest.Excluded(photo: $0.photo, reason: $0.reason, score: $0.score)
			},
			unassigned: plan.unassigned,
			diagnostics: diagnostics)
	}

	/// 計画どおりにファイルを配置する。
	func place(
		plan: SortPlan,
		quality: QualityFilter.Outcome,
		request: SortRequest,
		sources: [String: URL],
		fileManager: FileManager,
		progress: (ReconstructionEvent) -> Void) throws
	{
		try fileManager.createDirectory(
			at: request.outputFolder, withIntermediateDirectories: true)

		var placed = 0
		let total = plan.groups.reduce(0) { $0 + $1.photos.count }
			+ quality.excluded.count + plan.unassigned.count

		func copy(_ relativePath: String, into directory: URL) throws
		{
			guard let source = sources[relativePath]
			else
			{
				return
			}
			let destination = directory
				.appendingPathComponent(SortLayout.flattenedName(for: relativePath))
			try Self.place(
				source, at: destination, strategy: request.link, fileManager: fileManager)
			placed += 1
			if total > 0, placed % 50 == 0
			{
				progress(.progress(0.8 + 0.2 * Double(placed) / Double(total)))
			}
		}

		for group in plan.groups
		{
			let directory = request.outputFolder.appendingPathComponent(group.id)
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
			for photo in group.photos
			{
				try copy(photo, into: directory)
			}
		}

		for excluded in quality.excluded
		{
			// 理由ごとに分けておくと、閾値が妥当だったかを後から目で確かめられる。
			let directory = request.outputFolder
				.appendingPathComponent(SortLayout.excludedFolder)
				.appendingPathComponent(excluded.reason.rawValue)
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
			try copy(excluded.photo, into: directory)
		}

		if !plan.unassigned.isEmpty
		{
			let directory = request.outputFolder
				.appendingPathComponent(SortLayout.unassignedFolder)
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
			for photo in plan.unassigned
			{
				try copy(photo, into: directory)
			}
		}
	}

	/// 1 ファイルを配置する。ハードリンクは同一ボリューム内でしか作れないので、
	/// 失敗したらコピーへ落とす（設計メモ §4.5）。同じ写真が複数のグループへ
	/// 入る（共有写真）ので、実体を増やさない配置が既定になっている。
	static func place(
		_ source: URL,
		at destination: URL,
		strategy: LinkStrategy,
		fileManager: FileManager) throws
	{
		if fileManager.fileExists(atPath: destination.path)
		{
			try fileManager.removeItem(at: destination)
		}
		switch strategy
		{
			case .hardlink:
				do
				{
					try fileManager.linkItem(at: source, to: destination)
				}
				catch
				{
					try fileManager.copyItem(at: source, to: destination)
				}
			case .copy:
				try fileManager.copyItem(at: source, to: destination)
			case .symlink:
				try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
		}
	}

	/// 診断 1 件をログ 1 行にする。深刻度が一目で分かるよう接頭辞を付ける。
	func message(for diagnostic: SortDiagnostic) -> String
	{
		switch diagnostic.severity
		{
			case .info:
				return diagnostic.message
			case .warning:
				return "警告: \(diagnostic.message)"
			case .error:
				return "問題: \(diagnostic.message)"
		}
	}
}

public enum SortError: Error, LocalizedError, Equatable
{
	case noImages(String)
	case cancelled

	public var errorDescription: String?
	{
		switch self
		{
			case .noImages(let path):
				return "画像ファイルが見つかりません: \(path)"
			case .cancelled:
				return "仕分けを中断しました。"
		}
	}
}

/// 並行読み取りから届く進捗を間引いて流す。報告は任意のスレッドから来るので
/// ロックで直列化する（読み取り側の出力が混ざらないようにするため）。
final class ProgressThrottle: @unchecked Sendable
{
	private let lock = NSLock()
	private var last = -1.0
	private let scale: Double
	private let emit: @Sendable (Double) -> Void

	init(scale: Double, emit: @escaping @Sendable (Double) -> Void)
	{
		self.scale = scale
		self.emit = emit
	}

	func record(_ fraction: Double)
	{
		lock.lock()
		defer { lock.unlock() }
		// 2% 刻み。1 枚ごとに出すと数千行になる。
		let rounded = (fraction * 50).rounded(.down) / 50
		guard rounded > last
		else
		{
			return
		}
		last = rounded
		emit(rounded * scale)
	}
}
