//
//  InputStaging.swift
//
//  生成の入力写真を、**アプリのキャッシュ（ローカルディスク）へ複製してから**
//  処理するための層。処理が終わったら複製は捨てる。
//
//  なぜ要るか:
//  写真を iCloud Drive・Dropbox・Google ドライブなどのクラウド同期領域に置いた
//  まま生成すると、(1) 実体が未ダウンロード（`.icloud` プレースホルダ）の写真は
//  そもそも読めず、(2) 実体があっても処理中に OS やクライアントが退避（evict）
//  すると読み取りに失敗する。生成は建築規模なら数時間かかるので、その間ずっと
//  実体が残っている保証は無い。**先に全部ローカルへ写してしまえばこの手の失敗は
//  起きない**（従来は「~/Pictures へコピーしてから実行してください」と警告する
//  だけで、コピーは人手だった）。
//
//  置き場所はモデルキャッシュ（ModelCache）と同じ `~/Library/Caches/<バンドル
//  ID>/` の下。キャッシュは OS が「消えてもよい場所」として扱う領域で、複製の
//  置き場所としての性質が一致する。
//
//  取り残しへの備え:
//  CorePhotogrammetry は内部エラーで abort() することがあり（HelperProcessEngine
//  のコメント参照）、そのときは後始末が走らない。複製は数 GB になりうるので、
//  次回のコピー開始時に古い残骸（staleAge 超過）を掃除する。
//
//  判断（どのファイルを写すか・残骸か否か・ログの文言）は純ロジックとして
//  切り出してあり、ファイルシステムに触れるのは stage / discard / purgeStale の
//  3 つだけ。
//

import Foundation

public enum InputStaging
{
	/// キャッシュ配下で複製を作る親フォルダ名。
	public static let directoryName = "StagedInput"

	/// バンドル ID が分からない実行形態（素の CLI）で使うフォルダ名。
	/// キャッシュ直下を汚さないための名前で、値そのものに意味は無い。
	public static let fallbackBundleDirectoryName = "photogrammetry"

	/// これより古い複製は「異常終了で取り残されたもの」とみなして掃除する。
	/// 生成 1 回が数時間かかるので、実行中のものを巻き込まない余裕を取る。
	public static let staleAge: TimeInterval = 24 * 60 * 60

	/// 未ダウンロードの写真 1 枚を待つ上限。ここを無制限にすると、同期が
	/// 止まっている環境で永久に返らない。
	public static let downloadTimeout: TimeInterval = 300

	/// 未ダウンロードの写真の実体が現れたかを見に行く間隔。
	static let downloadPollInterval: TimeInterval = 0.2

	/// 進捗のログを出す間隔（枚）。1 枚ごとに出すと数千行になる。
	static let noteInterval = 200

	// -----------------------------------------------------------------
	// 複製の結果
	// -----------------------------------------------------------------

	/// 作った複製。後始末（discard）に必要な情報を持つ。
	public struct Staged: Equatable, Sendable
	{
		/// 入力フォルダを複製先へ差し替えたリクエスト。実行にはこちらを使う。
		public var request: ReconstructionRequest
		/// 複製先フォルダ（処理が終わったら丸ごと消す）。
		public var directory: URL
		/// 写した枚数。
		public var fileCount: Int
		/// 写した合計バイト数。
		public var byteCount: Int64

		public init(request: ReconstructionRequest, directory: URL, fileCount: Int, byteCount: Int64)
		{
			self.request = request
			self.directory = directory
			self.fileCount = fileCount
			self.byteCount = byteCount
		}
	}

	/// 入力フォルダ直下の名前一覧から「写すもの」を選んだ結果。
	public struct Selection: Equatable, Sendable
	{
		/// 写すファイル名（プレースホルダは実体の名前へ直したもの）。
		public var names: [String]
		/// そのうち、まだ実体が無い（ダウンロードが要る）ファイル名。
		public var pending: [String]

		public init(names: [String], pending: [String])
		{
			self.names = names
			self.pending = pending
		}
	}

	// -----------------------------------------------------------------
	// 純ロジック
	// -----------------------------------------------------------------

	/// 複製を置く親フォルダ（`stage` / `withStagedInput` へ明示的に渡す）。
	/// ModelCache と同じ `~/Library/Caches/<バンドル ID>/` の下に作る。バンドル ID が無い実行形態でも動かせるよう、こちらは nil を
	/// 返さない（コピーできる場所さえあれば目的は果たせるため）。
	public static func root(
		bundleIdentifier: String? = Bundle.main.bundleIdentifier,
		fileManager: FileManager = .default) -> URL
	{
		let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
			?? fileManager.temporaryDirectory
		let identifier = (bundleIdentifier?.isEmpty == false)
			? bundleIdentifier!
			: fallbackBundleDirectoryName
		return caches
			.appendingPathComponent(identifier, isDirectory: true)
			.appendingPathComponent(directoryName, isDirectory: true)
	}

	/// 未ダウンロードの iCloud ファイルのプレースホルダ名（`.名前.jpg.icloud`）を
	/// 実体の名前（`名前.jpg`）へ直す。画像でないものは nil。
	public static func placeholderRealName(_ name: String) -> String?
	{
		guard name.hasPrefix("."),
			(name as NSString).pathExtension.lowercased() == InputInspection.placeholderExtension
		else
		{
			return nil
		}
		let real = (String(name.dropFirst()) as NSString).deletingPathExtension
		guard !real.isEmpty,
			ReconstructionRequest.imageExtensions.contains((real as NSString).pathExtension.lowercased())
		else
		{
			return nil
		}
		return real
	}

	/// フォルダ直下の名前一覧から写す対象を選ぶ。
	///
	/// PhotogrammetrySession は入力フォルダの**直下だけ**を見るので、ここも
	/// 直下だけを対象にする（サブフォルダは元々使われない）。未ダウンロードの
	/// 写真はプレースホルダしか見えないため、実体の名前へ直したうえで
	/// 「ダウンロード待ちが要るもの」として別に数える。
	public static func select(names: [String]) -> Selection
	{
		var images: Set<String> = []
		var pending: Set<String> = []
		for name in names
		{
			if ReconstructionRequest.imageExtensions.contains(
				(name as NSString).pathExtension.lowercased())
			{
				images.insert(name)
			}
			else if let real = placeholderRealName(name)
			{
				pending.insert(real)
			}
		}
		// 実体が見えている写真はダウンロード待ちに数えない（プレースホルダが
		// 消え残っている場合がある）。
		pending.subtract(images)
		images.formUnion(pending)
		return Selection(names: images.sorted(), pending: pending.sorted())
	}

	/// 複製先フォルダの名前。どの入力フォルダの複製かを人が見て分かるように
	/// 名前を残しつつ、同時実行や連続実行でぶつからないよう一意な接尾辞を付ける。
	public static func stagedDirectoryName(for folder: URL, unique: String) -> String
	{
		let component = folder.standardizedFileURL.lastPathComponent
		// ルート（lastPathComponent が "/"）や名前を取れない場合でも成立する
		// 名前を返す。フォルダ名に使えない文字は潰す。
		let base = ["", "/", ".", ".."].contains(component)
			? "input"
			: component
				.replacingOccurrences(of: "/", with: "_")
				.replacingOccurrences(of: ":", with: "_")
		// 長すぎる名前は切る（ファイル名の上限は 255 バイト）。
		return String(base.prefix(64)) + "-" + unique
	}

	/// 取り残しとみなす経過時間を超えているか。
	public static func isStale(modifiedAt: Date, now: Date, staleAge: TimeInterval = InputStaging.staleAge)
		-> Bool
	{
		now.timeIntervalSince(modifiedAt) > staleAge
	}

	/// バイト数の表示。ByteCountFormatter はロケールで揺れるので自前で組む
	/// （ログの文言をテストで固定するため）。
	public static func sizeText(_ bytes: Int64) -> String
	{
		let units: [(name: String, scale: Double)] = [
			("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1000),
		]
		let value = Double(bytes)
		for unit in units where value >= unit.scale
		{
			return String(format: "%.1f %@", value / unit.scale, unit.name)
		}
		return "\(bytes) バイト"
	}

	/// コピー開始のログ 1 行。
	public static func startNote(fileCount: Int, pendingCount: Int, destination: URL) -> String
	{
		var text = "写真 \(fileCount) 枚をローカルへコピーします（\(destination.path)）。"
		if pendingCount > 0
		{
			text += "うち \(pendingCount) 枚は未ダウンロードなので、実体が届くのを待ちます。"
		}
		return text
	}

	/// コピー完了のログ 1 行。
	public static func finishNote(fileCount: Int, byteCount: Int64) -> String
	{
		"ローカルへのコピーが完了しました（\(fileCount) 枚・\(sizeText(byteCount))）。"
			+ "処理が終わると自動的に削除します。"
	}

	// -----------------------------------------------------------------
	// 実行（ファイルシステムに触れるのはここから下だけ）
	// -----------------------------------------------------------------

	/// 入力写真をキャッシュへ複製し、入力フォルダを差し替えたリクエストを返す。
	///
	/// 写すものが 1 枚も無いときは複製を作らず nil を返す（元のフォルダで
	/// そのまま実行させる。枚数 0 の警告は InputInspection の仕事）。
	/// 途中で失敗・中断したら、作りかけの複製は消してから throw する。
	public static func stage(
		_ request: ReconstructionRequest,
		root: URL,
		fileManager: FileManager = .default,
		cancellation: CancellationFlag? = nil,
		downloadTimeout: TimeInterval = InputStaging.downloadTimeout,
		onEvent: (ReconstructionEvent) -> Void = { _ in }) throws -> Staged?
	{
		// 異常終了で取り残された複製をここで掃除する（数 GB を放置しない）。
		let purged = purgeStale(root: root, fileManager: fileManager)
		if purged > 0
		{
			onEvent(.note("前回までの取り残しを削除しました（\(purged) 件）。"))
		}

		let names = (try? fileManager.contentsOfDirectory(atPath: request.inputFolder.path)) ?? []
		let selection = select(names: names)
		guard !selection.names.isEmpty
		else
		{
			return nil
		}

		let directory = root.appendingPathComponent(
			stagedDirectoryName(for: request.inputFolder, unique: UUID().uuidString),
			isDirectory: true)
		do
		{
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		}
		catch
		{
			throw InputStagingError.destinationUnavailable(
				path: directory.path, reason: error.localizedDescription)
		}

		onEvent(.note(startNote(
			fileCount: selection.names.count,
			pendingCount: selection.pending.count,
			destination: directory)))

		// 未ダウンロードのぶんは先にまとめて要求しておく。1 枚ずつ要求して待つと
		// ダウンロードが直列になり、数百枚で現実的な時間に収まらない。
		let pending = Set(selection.pending)
		for name in selection.pending
		{
			try? fileManager.startDownloadingUbiquitousItem(
				at: request.inputFolder.appendingPathComponent(name))
		}

		var copied = 0
		var bytes: Int64 = 0
		do
		{
			for name in selection.names
			{
				try checkCancellation(cancellation)
				let source = request.inputFolder.appendingPathComponent(name)
				if pending.contains(name)
				{
					try waitForDownload(
						of: source,
						timeout: downloadTimeout,
						fileManager: fileManager,
						cancellation: cancellation)
				}
				let destination = directory.appendingPathComponent(name)
				do
				{
					try fileManager.copyItem(at: source, to: destination)
				}
				catch
				{
					throw InputStagingError.copyFailed(
						name: name, reason: error.localizedDescription)
				}
				copied += 1
				bytes += fileSize(of: destination, fileManager: fileManager)
				if copied % noteInterval == 0
				{
					onEvent(.note("コピー中… \(copied)/\(selection.names.count) 枚"))
				}
			}
		}
		catch
		{
			// 作りかけを残さない。次回の掃除を待たずにここで消す。
			try? fileManager.removeItem(at: directory)
			throw error
		}

		onEvent(.note(finishNote(fileCount: copied, byteCount: bytes)))

		var staged = request
		staged.inputFolder = directory
		return Staged(request: staged, directory: directory, fileCount: copied, byteCount: bytes)
	}

	/// 複製を捨てる。後始末は失敗しても本体の結果を左右しないので投げない
	/// （消し損ねても次回の purgeStale が拾う）。
	public static func discard(_ staged: Staged?, fileManager: FileManager = .default)
	{
		guard let staged
		else
		{
			return
		}
		try? fileManager.removeItem(at: staged.directory)
	}

	/// 取り残された複製を掃除する。消した件数を返す。
	@discardableResult
	public static func purgeStale(
		root: URL,
		now: Date = Date(),
		staleAge: TimeInterval = InputStaging.staleAge,
		fileManager: FileManager = .default) -> Int
	{
		guard let entries = try? fileManager.contentsOfDirectory(
			at: root,
			includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles])
		else
		{
			return 0
		}
		var removed = 0
		for entry in entries
		{
			let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
				.contentModificationDate
			// 日時が読めないものは触らない（消してよい根拠が無い）。
			guard let modified, isStale(modifiedAt: modified, now: now, staleAge: staleAge)
			else
			{
				continue
			}
			do
			{
				try fileManager.removeItem(at: entry)
				removed += 1
			}
			catch
			{
				// 消せないものは次回また試す（掃除は best effort）。
				continue
			}
		}
		return removed
	}

	/// 複製を作って body を実行し、終わったら（成功・失敗・中断のいずれでも）捨てる。
	/// リクエストが複製を望んでいなければ、何もせず body をそのまま呼ぶ。
	public static func withStagedInput<T>(
		_ request: ReconstructionRequest,
		root: URL,
		fileManager: FileManager = .default,
		cancellation: CancellationFlag? = nil,
		onEvent: (ReconstructionEvent) -> Void = { _ in },
		body: (ReconstructionRequest) async throws -> T) async throws -> T
	{
		guard request.stageInputLocally
		else
		{
			return try await body(request)
		}
		let staged = try stage(
			request,
			root: root,
			fileManager: fileManager,
			cancellation: cancellation,
			onEvent: onEvent)
		defer
		{
			discard(staged, fileManager: fileManager)
		}
		return try await body(staged?.request ?? request)
	}

	// -----------------------------------------------------------------
	// 内部
	// -----------------------------------------------------------------

	private static func checkCancellation(_ cancellation: CancellationFlag?) throws
	{
		if cancellation?.isCancelled == true
		{
			throw InputStagingError.cancelled
		}
	}

	/// 未ダウンロードの写真の実体が届くまで待つ。届かないまま上限を過ぎたら
	/// 諦める（同期が止まっている環境で永久に返らないことを防ぐ）。
	private static func waitForDownload(
		of url: URL,
		timeout: TimeInterval,
		fileManager: FileManager,
		cancellation: CancellationFlag?) throws
	{
		let deadline = Date().addingTimeInterval(timeout)
		while !fileManager.fileExists(atPath: url.path)
		{
			try checkCancellation(cancellation)
			guard Date() < deadline
			else
			{
				throw InputStagingError.downloadTimedOut(name: url.lastPathComponent)
			}
			Thread.sleep(forTimeInterval: downloadPollInterval)
		}
	}

	private static func fileSize(of url: URL, fileManager: FileManager) -> Int64
	{
		let attributes = try? fileManager.attributesOfItem(atPath: url.path)
		return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
	}
}

public enum InputStagingError: Error, LocalizedError, Equatable
{
	/// 中断された。
	case cancelled
	/// 複製先を作れない（ディスクの空き・権限）。
	case destinationUnavailable(path: String, reason: String)
	/// 1 枚のコピーに失敗した。
	case copyFailed(name: String, reason: String)
	/// 未ダウンロードの写真の実体が届かなかった。
	case downloadTimedOut(name: String)

	public var errorDescription: String?
	{
		switch self
		{
			case .cancelled:
				return "ローカルへのコピーを中断しました。"
			case .destinationUnavailable(let path, let reason):
				return "写真のコピー先を作れません（\(path)）: \(reason)\n" + Self.optOutAdvice
			case .copyFailed(let name, let reason):
				return "写真をローカルへコピーできません（\(name)）: \(reason)\n"
					+ "ディスクの空き容量を確認してください。\n" + Self.optOutAdvice
			case .downloadTimedOut(let name):
				return "クラウドから写真をダウンロードできません（\(name)）。"
					+ "同期が進んでいるか確認してから、もう一度実行してください。"
		}
	}

	/// この機能を切る方法。既定で有効な処理なので、行き詰まったときの逃げ道を
	/// 必ず一緒に示す。
	static let optOutAdvice =
		"コピーせずに実行するには、GUI の「写真をローカルへコピーしてから処理する」を"
		+ "外すか、CLI に --no-stage-input を付けてください。"
}
