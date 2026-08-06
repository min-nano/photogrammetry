//
//  InputStaging.swift
//
//  生成の入力写真を、**アプリのキャッシュ（ローカルディスク）へ複製してから**
//  処理するための層。処理が終わったら複製は捨てる。
//
//  なぜ要るか:
//  写真を iCloud Drive・Dropbox・Google ドライブなどのクラウド同期領域に置いた
//  まま生成すると、実体が処理中に OS やクライアントへ退避（evict）されて読み
//  取りに失敗することがある。生成は建築規模なら数時間かかるので、その間ずっと
//  実体が残っている保証は無い。**先に全部ローカルへ写してしまえばこの手の失敗は
//  起きない**（従来は「~/Pictures へコピーしてから実行してください」と警告する
//  だけで、コピーは人手だった）。
//
//  「オンラインのみ」（実体がまだ無い）ファイルの取り寄せは、コピーそのものが
//  起こす — File Provider（iCloud Drive・Google ドライブ・Dropbox）は**読んだ
//  瞬間に実体を取り寄せる**ので、copyItem がその引き金になる。したがって
//  ダウンロードを明示的に要求する必要は無い。例外は iCloud の**旧表現**
//  （`.名前.jpg.icloud` という別名のスタブしか見えない形）で、これは実名の
//  パスが存在せずコピーできないため、対象から外して警告する（この表現が
//  出るのは File Provider へ移行する前の macOS）。
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
		// `??` を使わないのは、右辺が自動クロージャ（= 1 つの関数）になり、
		// 踏めないぶんがカバレッジの分母に残るため。以降も同じ理由で if/guard を使う。
		let caches: URL
		if let userCaches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
		{
			caches = userCaches
		}
		else
		{
			caches = fileManager.temporaryDirectory
		}
		let identifier = (bundleIdentifier?.isEmpty == false)
			? bundleIdentifier!
			: fallbackBundleDirectoryName
		return caches
			.appendingPathComponent(identifier, isDirectory: true)
			.appendingPathComponent(directoryName, isDirectory: true)
	}

	/// フォルダ直下の名前一覧から写す対象（画像）を選ぶ。
	///
	/// PhotogrammetrySession は入力フォルダの**直下だけ**を見るので、ここも
	/// 直下だけを対象にする（サブフォルダは元々使われない）。「オンラインのみ」の
	/// ファイルも実名で見えていれば普通に選ぶ — コピーの読み取りが取り寄せを
	/// 起こすため、ここで特別扱いする必要は無い。
	public static func imageNames(in names: [String]) -> [String]
	{
		names.filter
		{ name in
			ReconstructionRequest.imageExtensions.contains(
				(name as NSString).pathExtension.lowercased())
		}.sorted()
	}

	/// 実体が無い iCloud の旧表現（`.名前.jpg.icloud`）の数。実名のパスが存在
	/// しないのでコピーできず、黙って減らすと「なぜか写真が足りない」状態に
	/// なるため、数えて警告するためだけに使う。
	public static func placeholderCount(in names: [String]) -> Int
	{
		names.filter
		{ name in
			(name as NSString).pathExtension.lowercased() == InputInspection.placeholderExtension
		}.count
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
	public static func startNote(fileCount: Int, destination: URL) -> String
	{
		"写真 \(fileCount) 枚をローカルへコピーします（\(destination.path)）。"
	}

	/// コピーできない未ダウンロードファイルがあったときの警告 1 行。
	/// 黙って対象から外すと枚数が減った理由が分からなくなる。
	public static func placeholderNote(count: Int) -> String
	{
		"警告: 未ダウンロードの写真（.\(InputInspection.placeholderExtension)）が \(count) 個"
			+ "あるためコピーできません。Finder でフォルダを「今すぐダウンロード」してから"
			+ "実行してください。"
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
		onEvent: (ReconstructionEvent) -> Void = { _ in }) throws -> Staged?
	{
		// 異常終了で取り残された複製をここで掃除する（数 GB を放置しない）。
		let purged = purgeStale(root: root, fileManager: fileManager)
		if purged > 0
		{
			onEvent(.note("前回までの取り残しを削除しました（\(purged) 件）。"))
		}

		// 読めないフォルダは複製せずそのまま渡す（存在チェックは validate の仕事で、
		// ここで別のエラーに化けさせない）。
		guard let names = try? fileManager.contentsOfDirectory(atPath: request.inputFolder.path)
		else
		{
			return nil
		}
		let selected = imageNames(in: names)
		// 実体が無い旧表現（.icloud）はコピーできない。枚数が減った理由が分かる
		// よう、外したことを必ず知らせる。
		let placeholders = placeholderCount(in: names)
		if placeholders > 0
		{
			onEvent(.note(placeholderNote(count: placeholders)))
		}
		guard !selected.isEmpty
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

		onEvent(.note(startNote(fileCount: selected.count, destination: directory)))

		var copied = 0
		var bytes: Int64 = 0
		do
		{
			for name in selected
			{
				try checkCancellation(cancellation)
				// 「オンラインのみ」のファイルはこのコピー（＝読み取り）が実体の
				// 取り寄せを起こす。完了までブロックするので、待ちを自前で
				// 用意する必要は無い。
				let source = request.inputFolder.appendingPathComponent(name)
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
					onEvent(.note("コピー中… \(copied)/\(selected.count) 枚"))
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

	/// リクエストが複製を望んでいれば複製する（望んでいなければ nil）。クロージャを
	/// 使えない呼び出し側（`ReconstructionService` の同一プロセス経路）の入口。
	public static func stageIfRequested(
		_ request: ReconstructionRequest,
		root: URL,
		fileManager: FileManager = .default,
		cancellation: CancellationFlag? = nil,
		onEvent: (ReconstructionEvent) -> Void = { _ in }) throws -> Staged?
	{
		guard request.stageInputLocally
		else
		{
			return nil
		}
		return try stage(
			request,
			root: root,
			fileManager: fileManager,
			cancellation: cancellation,
			onEvent: onEvent)
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
		let staged = try stageIfRequested(
			request,
			root: root,
			fileManager: fileManager,
			cancellation: cancellation,
			onEvent: onEvent)
		defer
		{
			discard(staged, fileManager: fileManager)
		}
		var effective = request
		if let staged
		{
			effective = staged.request
		}
		return try await body(effective)
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

	/// ファイルの大きさ（読めなければ 0）。合計の表示にしか使わないので、
	/// 読めないこと自体はエラーにしない。
	static func fileSize(of url: URL, fileManager: FileManager) -> Int64
	{
		guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
			let size = attributes[.size] as? NSNumber
		else
		{
			return 0
		}
		return size.int64Value
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
					+ "ディスクの空き容量とクラウドの同期状況を確認してください。\n"
					+ Self.optOutAdvice
		}
	}

	/// この機能を切る方法。既定で有効な処理なので、行き詰まったときの逃げ道を
	/// 必ず一緒に示す。
	static let optOutAdvice =
		"コピーせずに実行するには、GUI の「写真をローカルへコピーしてから処理する」を"
		+ "外すか、CLI に --no-stage-input を付けてください。"
}
