//
//  HelperProcessEngine.swift
//
//  生成処理を**別プロセス**（同梱の photogrammetry-cli）で実行するエンジン。
//  PhotogrammetryEngine と同じ ReconstructionEvent を流すので、フロントエンドは
//  どちらで動いているかを意識しなくてよい。
//
//  なぜ別プロセスにするか:
//  RealityKit の PhotogrammetrySession の実体（CorePhotogrammetry）は、内部で
//  致命的な状況に陥ると **abort() でプロセスごと落とす**。実際に
//  「com.apple.CorePhotogrammetry.session.recon キューで SIGABRT」という
//  クラッシュが報告されている。これは Swift の try/catch では捕まえられず、
//  同一プロセスで動かしている限り GUI（とログ）ごと道連れになる。
//  子プロセスで走らせておけば、落ちるのは子だけで、親は終了状況（シグナル）を
//  読み取って原因の手掛かりと対処方法をユーザーへ提示できる。
//
//  ヘルパーとの通信は stdout の行（HelperProtocol）だけで、標準入力は使わない。
//

import Foundation

public final class HelperProcessEngine
{
	/// .app に同梱するヘルパー実行ファイルの名前（package-app.sh が
	/// Contents/MacOS/ へ置く名前と一致させること）。
	public static let executableName = "photogrammetry-cli"

	/// 実行中のプロセスから見えるヘルパーの場所を探す。GUI（.app の
	/// Contents/MacOS/）でも `swift run`（.build/debug/）でも、ヘルパーは
	/// 自分自身の実行ファイルと同じディレクトリに置かれる。
	public static func bundledHelperURL(fileManager: FileManager = .default) -> URL?
	{
		helperURL(besideExecutable: Bundle.main.executableURL, fileManager: fileManager)
	}

	/// 指定した実行ファイルの隣にあるヘルパーを返す（無ければ nil）。
	/// 実行ファイルの位置を引数に取るのは、探索規則をテストできるようにするため
	/// （Bundle.main はテスト実行時には xctest を指し、差し替えられない）。
	public static func helperURL(
		besideExecutable executable: URL?,
		fileManager: FileManager = .default) -> URL?
	{
		guard let executable
		else
		{
			return nil
		}
		let candidate = executable.deletingLastPathComponent()
			.appendingPathComponent(executableName)
		guard fileManager.isExecutableFile(atPath: candidate.path)
		else
		{
			return nil
		}
		return candidate
	}

	/// 実行するヘルパーの場所。
	public let helperURL: URL

	private let state = RunState()

	public init(helperURL: URL)
	{
		self.helperURL = helperURL
	}

	/// ヘルパープロセスを起動して完了まで待つ。進捗は onEvent へ随時通知される。
	/// ヘルパーが異常終了した場合は HelperProcessError.crashed を throw する。
	///
	/// インスタンスは 1 回の生成につき 1 つ（使い回さない）。起動前に届いた
	/// cancel を取りこぼさないよう、状態はインスタンスの寿命と揃えてある。
	public func process(
		_ request: ReconstructionRequest,
		onEvent: @escaping @Sendable (ReconstructionEvent) -> Void) async throws
	{
		// 引数を組む前に、プロセスを起こさなくても分かる誤りを弾く。
		try request.validate()

		let process = Process()
		process.executableURL = helperURL
		// 引数の語彙は APICommand が唯一の定義（CLI・URL スキームと共通）。
		process.arguments = APICommand.arguments(for: request)

		let standardOutput = Pipe()
		let standardError = Pipe()
		process.standardOutput = standardOutput
		process.standardError = standardError

		let state = self.state

		standardOutput.fileHandleForReading.readabilityHandler =
		{ handle in
			let data = handle.availableData
			if data.isEmpty
			{
				return
			}
			state.consumeStandardOutput(data, onEvent: onEvent)
		}
		// stderr は貯めるだけ。ここを読まずに放置するとパイプが詰まって
		// ヘルパーが書き込みでブロックするため、ハンドラで吸い出しておく。
		standardError.fileHandleForReading.readabilityHandler =
		{ handle in
			let data = handle.availableData
			if data.isEmpty
			{
				return
			}
			state.appendStandardError(data)
		}

		// terminationHandler は run より前に付ける（起動直後に終わる場合がある）。
		let exited = ExitSignal()
		process.terminationHandler =
		{ _ in
			exited.signal()
		}

		do
		{
			try process.run()
		}
		catch
		{
			standardOutput.fileHandleForReading.readabilityHandler = nil
			standardError.fileHandleForReading.readabilityHandler = nil
			throw HelperProcessError.launchFailed(
				path: helperURL.path,
				reason: error.localizedDescription)
		}
		state.setProcess(process)
		// 起動前に cancel が来ていた場合の取りこぼしを防ぐ。
		if state.isCancelRequested
		{
			process.interrupt()
		}

		await exited.wait()

		// ハンドラを外してから残りを読み切る（終了直前の行を落とさないため）。
		standardOutput.fileHandleForReading.readabilityHandler = nil
		standardError.fileHandleForReading.readabilityHandler = nil
		state.consumeStandardOutput(
			standardOutput.fileHandleForReading.readDataToEndOfFile(),
			onEvent: onEvent)
		state.flushPartialStandardOutput(onEvent: onEvent)
		state.appendStandardError(standardError.fileHandleForReading.readDataToEndOfFile())
		state.setProcess(nil)

		let status = process.terminationStatus
		let crashed = (process.terminationReason == .uncaughtSignal)
		let cancelRequested = state.isCancelRequested

		// キャンセル要求の結末は、ヘルパーが cancelled を出した場合と、
		// シグナルで落ちた場合（ハンドラに届く前）の両方がありうる。
		if cancelRequested, crashed || status == 0
		{
			if !state.sawCancelled
			{
				onEvent(.cancelled)
			}
			return
		}
		if crashed
		{
			throw HelperProcessError.crashed(
				signal: status,
				lastProgress: state.lastProgress,
				message: state.standardErrorText)
		}
		if status != 0
		{
			throw HelperProcessError.failed(
				exitCode: status,
				message: state.standardErrorText)
		}
	}

	/// 実行中のヘルパーへ中断を要求する（SIGINT）。ヘルパー側はセッションを
	/// cancel して正常終了するので、呼び出し側には .cancelled が届く。
	public func cancel()
	{
		state.requestCancel()
	}
}

// ---------------------------------------------------------------------
// 実行中の状態。readabilityHandler（別スレッド）と process(...) の両方から
// 触るので、ロックで守る。
// ---------------------------------------------------------------------

private final class RunState: @unchecked Sendable
{
	private let lock = NSLock()
	private var process: Process?
	private var cancelRequested = false
	private var pendingOutput = Data()
	private var errorData = Data()
	private var progress: Double?
	private var cancelled = false

	func setProcess(_ process: Process?)
	{
		lock.lock()
		defer { lock.unlock() }
		self.process = process
	}

	func requestCancel()
	{
		lock.lock()
		cancelRequested = true
		let running = process
		lock.unlock()
		running?.interrupt()
	}

	var isCancelRequested: Bool
	{
		lock.lock()
		defer { lock.unlock() }
		return cancelRequested
	}

	var lastProgress: Double?
	{
		lock.lock()
		defer { lock.unlock() }
		return progress
	}

	var sawCancelled: Bool
	{
		lock.lock()
		defer { lock.unlock() }
		return cancelled
	}

	var standardErrorText: String
	{
		lock.lock()
		defer { lock.unlock() }
		return String(decoding: errorData, as: UTF8.self)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	func appendStandardError(_ data: Data)
	{
		if data.isEmpty
		{
			return
		}
		lock.lock()
		defer { lock.unlock() }
		// 際限なく溜めない（エラー表示に使うのは末尾ではなく冒頭の説明なので前を残す）。
		if errorData.count < 64 * 1024
		{
			errorData.append(data)
		}
	}

	/// 受け取ったバイト列を行に切り出してイベントへ変換する。改行で終わって
	/// いない末尾は次の呼び出しまで持ち越す。
	func consumeStandardOutput(_ data: Data, onEvent: @Sendable (ReconstructionEvent) -> Void)
	{
		if data.isEmpty
		{
			return
		}
		lock.lock()
		pendingOutput.append(data)
		var lines: [String] = []
		while let newline = pendingOutput.firstIndex(of: UInt8(ascii: "\n"))
		{
			let line = pendingOutput[pendingOutput.startIndex ..< newline]
			pendingOutput.removeSubrange(pendingOutput.startIndex ... newline)
			lines.append(String(decoding: line, as: UTF8.self))
		}
		lock.unlock()

		for line in lines
		{
			emit(line, onEvent: onEvent)
		}
	}

	/// 改行で終わらなかった最後の 1 行を処理する（プロセス終了後に 1 回だけ）。
	func flushPartialStandardOutput(onEvent: @Sendable (ReconstructionEvent) -> Void)
	{
		lock.lock()
		let rest = pendingOutput
		pendingOutput = Data()
		lock.unlock()
		if rest.isEmpty
		{
			return
		}
		emit(String(decoding: rest, as: UTF8.self), onEvent: onEvent)
	}

	private func emit(_ line: String, onEvent: @Sendable (ReconstructionEvent) -> Void)
	{
		guard case .event(let event)? = HelperProtocol.decode(line: line)
		else
		{
			return
		}
		switch event
		{
			case .progress(let fraction):
				lock.lock()
				progress = fraction
				lock.unlock()
			case .cancelled:
				lock.lock()
				cancelled = true
				lock.unlock()
			default:
				break
		}
		onEvent(event)
	}
}

/// terminationHandler（任意のスレッド）から async な待ち側へ 1 回だけ合図する。
/// 合図が待ち始めるより先に来る場合（プロセスが即終了）と後から来る場合の
/// 両方があるので、internal にしてどちらの順序も単体テストで確かめている。
final class ExitSignal: @unchecked Sendable
{
	private let lock = NSLock()
	private var hasExited = false
	private var continuation: CheckedContinuation<Void, Never>?

	func signal()
	{
		lock.lock()
		hasExited = true
		let waiting = continuation
		continuation = nil
		lock.unlock()
		waiting?.resume()
	}

	func wait() async
	{
		await withCheckedContinuation
		{ (continuation: CheckedContinuation<Void, Never>) in
			lock.lock()
			if hasExited
			{
				lock.unlock()
				continuation.resume()
				return
			}
			self.continuation = continuation
			lock.unlock()
		}
	}
}

// ---------------------------------------------------------------------
// エラー
// ---------------------------------------------------------------------

public enum HelperProcessError: Error, LocalizedError, Equatable
{
	/// ヘルパーを起動できなかった。
	case launchFailed(path: String, reason: String)
	/// ヘルパーがシグナルで異常終了した（＝ CorePhotogrammetry 内部のクラッシュ）。
	case crashed(signal: Int32, lastProgress: Double?, message: String)
	/// ヘルパーがエラー終了した（生成の失敗。詳細は message）。
	case failed(exitCode: Int32, message: String)

	public var errorDescription: String?
	{
		switch self
		{
			case .launchFailed(let path, let reason):
				return "生成用のヘルパーを起動できません（\(path)）: \(reason)"

			case .crashed(let signal, let lastProgress, let message):
				var lines = [
					"生成処理が異常終了しました（\(Self.signalName(signal))）。"
						+ Self.progressPhrase(lastProgress),
					"これは macOS の Object Capture（CorePhotogrammetry）の内部で起きた"
						+ "中断で、アプリ側では捕捉できません。別プロセスで実行しているため"
						+ "アプリ自体は継続しています。",
				]
				// 原因を特定できる失敗（ML モデルのキャッシュ破損）はそれと名指しする。
				// 一般論を並べても直らない一方、消すべき場所さえ分かれば確実に直るため。
				if ModelCache.isCompilationFailure(message)
				{
					lines.append(contentsOf: ModelCache.recoveryAdvice(
						directory: ModelCache.directory()))
				}
				else
				{
					lines.append(contentsOf: Self.generalAdvice)
				}
				if !message.isEmpty
				{
					lines.append("ヘルパーの出力:")
					lines.append(message)
				}
				return lines.joined(separator: "\n")

			case .failed(let exitCode, let message):
				if message.isEmpty
				{
					return "生成に失敗しました（終了コード \(exitCode)）。"
				}
				return message
		}
	}

	/// 原因を特定できないときの一般的な対処。上から効きやすい順に並べてある。
	static let generalAdvice = [
		"次を試してください:",
		"  ・詳細度を下げる（プレビュー / 低）",
		"  ・写真の枚数を減らす、または解像度の大きすぎる写真を外す",
		"  ・入力フォルダを iCloud Drive などのクラウド上ではなく"
			+ "ローカル（例: ~/Pictures）へコピーする",
		"  ・対象の種類（物体 / シーン・建物）を撮影内容に合わせる",
		"  ・他の重いアプリを閉じてメモリを空ける",
	]

	/// この異常終了が ML モデルのキャッシュ破損によるものか（GUI が復旧
	/// ボタンを出すかどうかの判断に使う。判断はここ＝Core が持つ）。
	public var isModelCacheFailure: Bool
	{
		guard case .crashed(_, _, let message) = self
		else
		{
			return false
		}
		return ModelCache.isCompilationFailure(message)
	}

	/// クラッシュの読み解きに直結するので、番号ではなく名前と意味を出す。
	static func signalName(_ signal: Int32) -> String
	{
		switch signal
		{
			case SIGABRT:
				return "シグナル \(signal): SIGABRT — 内部エラーによる中断"
			case SIGSEGV:
				return "シグナル \(signal): SIGSEGV — 不正なメモリアクセス"
			case SIGBUS:
				return "シグナル \(signal): SIGBUS — 不正なメモリアクセス"
			case SIGILL:
				return "シグナル \(signal): SIGILL — 不正な命令"
			case SIGKILL:
				return "シグナル \(signal): SIGKILL — メモリ不足などで OS に強制終了された可能性"
			case SIGTERM:
				return "シグナル \(signal): SIGTERM — 外部から終了された"
			case SIGINT:
				return "シグナル \(signal): SIGINT — 中断された"
			default:
				return "シグナル \(signal)"
		}
	}

	static func progressPhrase(_ lastProgress: Double?) -> String
	{
		guard let lastProgress
		else
		{
			return ""
		}
		return String(format: "（進捗 %.0f%% 付近）", lastProgress * 100)
	}
}
