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
	/// 共有写真の候補が実際に重なっているかを確かめる役（設計メモ §4.6.1）。
	public var overlapVerifier: PhotoOverlapVerifying
	/// この Mac の 1 セッション上限枚数（診断に使う）。分からなければ nil。
	public var hardwareLimit: Int?

	public init(
		reader: PhotoMetadataReading = PhotoInspector(),
		overlapVerifier: PhotoOverlapVerifying = ImageRegistrar(),
		hardwareLimit: Int? = nil)
	{
		self.reader = reader
		self.overlapVerifier = overlapVerifier
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
		let inspected = readAll(
			files,
			options: request.inspectionOptions,
			cancellation: cancellation,
			progress: progress)
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
		progress(.progress(0.65))

		// グループ分けで実際の重なりを確かめる（設計メモ §4.9）。数千枚だと数万組の
		// 位置合わせになるので、**進捗が止まったように見えないよう**先に一言出し、
		// そのあとは確認の進み具合をそのまま流す。
		let surveying = request.usesOverlapGrouping
		if surveying
		{
			progress(.note("どの写真どうしが実際に重なっているかを確認しています…"))
		}
		let surveyProgress = ProgressThrottle(scale: 0.15, offset: 0.65)
		{ fraction in
			progress(.progress(fraction))
		}
		let grouping = PhotoGrouping.group(
			photos: quality.kept,
			settings: request.groupingSettings,
			verifyOverlap: surveying ? overlapProbe(cancellation: cancellation) : nil,
			isCancelled: { cancellation?.isCancelled == true })
		{ checked, budget in
			guard budget > 0
			else
			{
				return
			}
			surveyProgress.record(Double(checked) / Double(budget))
		}
		try checkCancellation()
		progress(.progress(0.8))

		// 共有写真の候補を実際に位置合わせして確かめる（設計メモ §4.6.1）。
		// 数十組ぶんのデコードと推論なので、進捗が止まったように見えないよう
		// 先に一言出す。
		if request.overlapCheck
		{
			progress(.note("共有写真の候補が実際に重なっているかを確認しています…"))
		}
		let plan = SortPlanner.plan(
			grouping: grouping,
			settings: request.plannerSettings,
			verifyOverlap: overlapProbe(for: request, cancellation: cancellation))
		try checkCancellation()
		progress(.progress(0.85))
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
		// _excluded/unreadable/ へ残すため（除外した写真は捨てない）。相対パスは
		// 走査の時点で一意なので、重複の解決規則は要らない。
		var sources: [String: URL] = [:]
		for file in files
		{
			sources[file.relativePath] = file.url
		}
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

	/// 読み取り。並行にするかどうかは読み手の都合なので、ここでは実装の種類で
	/// 分岐しない（PhotoMetadataReading.readAll に任せる）。
	///
	/// 進捗は解析全体の前半 50% に割り当てる。数千枚のデコードが処理時間の
	/// 大半を占めるため。
	func readAll(
		_ files: [PhotoFile],
		options: PhotoInspectionOptions,
		cancellation: SortCancellation? = nil,
		progress: @escaping @Sendable (ReconstructionEvent) -> Void)
		-> (photos: [PhotoMetadata], unreadable: [String])
	{
		// 進捗はイベントの氾濫を避けるため間引き、かつ並行に届く報告を
		// ロックで直列化してから流す。
		let throttle = ProgressThrottle(scale: 0.5)
		{ fraction in
			progress(.progress(fraction))
		}
		return reader.readAll(
			files,
			options: options,
			isCancelled: { cancellation?.isCancelled == true })
		{ done, total in
			throttle.record(Double(done) / Double(total))
		}
	}

	/// 重なりの検証を計画へ渡す形にする。指示が「確かめない」なら nil を返し、
	/// 計画側は従来どおり（フェーズ 2 まで）の選び方に戻る。
	///
	/// 中断は**問い合わせのたびに見る**。数千枚のデコードと同じく数分かかりうる
	/// 段なので、ここで効かないと「キャンセルが効かないボタン」になる。
	func overlapProbe(for request: SortRequest, cancellation: SortCancellation?)
		-> SortPlanner.OverlapProbe?
	{
		guard request.overlapCheck
		else
		{
			return nil
		}
		return overlapProbe(cancellation: cancellation)
	}

	/// 位置合わせの役を閉包にする。中断は**問い合わせのたびに見る**。数千枚の
	/// デコードと同じく数分かかりうる段なので、ここで効かないと「キャンセルが
	/// 効かないボタン」になる。
	func overlapProbe(cancellation: SortCancellation?) -> SortPlanner.OverlapProbe
	{
		let verifier = overlapVerifier
		let probe: SortPlanner.OverlapProbe =
		{ queries in
			verifier.overlaps(for: queries, isCancelled: { cancellation?.isCancelled == true })
		}
		return probe
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
				visualEvidence: request.visualEvidence,
				visualThreshold: grouping.rooms.threshold,
				visualThresholdWasAutomatic: grouping.rooms.thresholdWasAutomatic,
				overlapCheck: request.overlapCheck,
				overlapInliers: request.plannerSettings.minimumInlierRatio,
				overlapGrouping: grouping.usedEvidence.contains(.overlap),
				overlapBudget: grouping.overlap?.budget,
				link: request.link),
			evidence: SortManifest.Evidence(
				used: grouping.usedEvidence.map(\.rawValue),
				coverage: coverage),
			statistics: SortManifest.Statistics(
				inputCount: inputCount,
				keptCount: quality.kept.count,
				groupCount: plan.groups.count,
				roomCount: grouping.rooms.clusters.count,
				excludedByReason: byReason,
				scoreHistogram: grouping.scoreHistogram,
				visualDistanceHistogram: grouping.rooms.distanceHistogram,
				sharpnessMedian: quality.sharpnessMedian,
				overlapChecks: plan.overlapSummary.map
				{
					SortManifest.Statistics.OverlapChecks(
						verified: $0.verified, rejected: $0.rejected, undecided: $0.undecided)
				},
				overlapGraph: grouping.overlap.map
				{
					SortManifest.Statistics.OverlapGraphStatistics(
						checked: $0.checked,
						budget: $0.budget,
						budgetExhausted: $0.budgetExhausted,
						overlapping: $0.overlappingCount,
						separate: $0.separateCount,
						undecided: $0.undecidedCount,
						degreeHistogram: $0.degreeHistogram(),
						inlierHistogram: $0.inlierHistogram(),
						agreementHistogram: $0.agreementHistogram(),
						chainHitRate: $0.chainHitRate())
				}),
			groups: plan.groups.map
			{
				SortManifest.Group(
					id: $0.id,
					photos: $0.photos,
					shared: $0.shared,
					evidence: $0.evidence.map(\.rawValue),
					rooms: $0.rooms,
					sequential: $0.sequential,
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
					viewpointSpread: $0.viewpointSpread,
					sharedRoom: $0.sharedRoom,
					overlapVerified: $0.overlapVerified)
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
	private let offset: Double
	private let emit: @Sendable (Double) -> Void

	/// - Parameters:
	///   - scale: 段全体のうちこの割合を占める。
	///   - offset: 段の始まりの位置。段が全体の途中にあるとき（重なりの確認）に要る。
	init(scale: Double, offset: Double = 0, emit: @escaping @Sendable (Double) -> Void)
	{
		self.scale = scale
		self.offset = offset
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
		emit(offset + rounded * scale)
	}
}
