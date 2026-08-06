//
//  ReconstructionService.swift
//
//  フロントエンド（GUI・組み込み先アプリ）が呼ぶ入口。「同一プロセスで動かすか、
//  ヘルパープロセスへ出すか」の判断をここ 1 か所に置く。GUI にこの判断を書くと
//  ロジックが GUI 側へ漏れるため（CLAUDE.md「ロジックと GUI の完全分離」）。
//
//  既定はヘルパープロセス。CorePhotogrammetry は内部エラーで abort() する
//  ことがあり、同一プロセスだとアプリごと落ちるため（HelperProcessEngine の
//  コメント参照）。ヘルパーが見つからない場合だけ同一プロセスで実行する。
//
//  CLI（photogrammetry-cli）自身はヘルパーの実体なので、ここではなく
//  PhotogrammetryEngine を直接使う。
//

import Foundation

/// 生成エンジンの差し替え口。実体は `PhotogrammetryEngine`（RealityKit）だが、
/// 同一プロセス経路の**前後**（写真の複製・後始末・中断の受け渡し）は GPU 無しで
/// 確かめたいので、テストから偽物を挿せるようにしてある（`PhotoMetadataReading` や
/// `HelperProcessEngine.helperURL` と同じ考え方。再構成そのものは相変わらず
/// 自動テストしない）。
public protocol ReconstructionEngine: AnyObject
{
	func process(
		_ request: ReconstructionRequest,
		onEvent: @escaping @Sendable (ReconstructionEvent) -> Void) async throws
	func cancel()
}

public final class ReconstructionService
{
	/// 実行方式。
	public enum Mode: Equatable, Sendable
	{
		/// 別プロセス（同梱ヘルパー）で実行する。
		case helperProcess(URL)
		/// 同一プロセスで実行する（ヘルパー未同梱の開発ビルドなど）。
		case inProcess
	}

	/// この Mac が Object Capture に対応しているか（判定は RealityKit 側）。
	public static var isSupported: Bool
	{
		PhotogrammetryEngine.isSupported
	}

	/// この Mac が 1 セッションで受け付ける写真の上限枚数。Object Capture に
	/// 対応していなければ nil。仕分け（PhotoSorter）が「グループが上限を超えて
	/// いないか」を診断するのに使う — 上限を知っているのは RealityKit だけなので、
	/// 取り出し口を Core 側の 1 か所にまとめておく。
	public static var maximumImageCount: Int?
	{
		isSupported ? PhotogrammetryEngine.maximumImageCount : nil
	}

	/// 同梱ヘルパーがあればそれを使う方式を返す。
	public static func resolveMode(fileManager: FileManager = .default) -> Mode
	{
		guard let helper = HelperProcessEngine.bundledHelperURL(fileManager: fileManager)
		else
		{
			return .inProcess
		}
		return .helperProcess(helper)
	}

	/// 実行方式をログへ残す 1 行。クラッシュ報告を読むとき「どちらで動いて
	/// いたか」が分からないと切り分けられないので必ず出す。
	public static func note(for mode: Mode) -> String
	{
		switch mode
		{
			case .helperProcess(let url):
				return "実行方式: 別プロセス（\(url.path)）"
			case .inProcess:
				return "実行方式: 同一プロセス（ヘルパー \(HelperProcessEngine.executableName) が"
					+ "見つかりません）。生成中の内部エラーではアプリごと終了する場合があります。"
		}
	}

	public let mode: Mode

	private let helperEngine: HelperProcessEngine?
	private let engine: ReconstructionEngine?
	/// 同一プロセス実行での中断フラグ。セッションが始まる前（写真の複製中）に
	/// 届いたキャンセルを取りこぼさないために持つ。
	private let cancellation = CancellationFlag()
	/// 写真の複製先（同一プロセス実行のとき）。テストで差し替える。
	let stagingRoot: URL

	public init(mode: Mode = ReconstructionService.resolveMode())
	{
		self.mode = mode
		stagingRoot = InputStaging.root()
		switch mode
		{
			case .helperProcess(let url):
				helperEngine = HelperProcessEngine(helperURL: url)
				engine = nil
			case .inProcess:
				helperEngine = nil
				engine = PhotogrammetryEngine()
		}
	}

	/// エンジンと複製先を差し替えて同一プロセス経路を組み立てる（テスト用）。
	init(engine: ReconstructionEngine, stagingRoot: URL)
	{
		mode = .inProcess
		helperEngine = nil
		self.engine = engine
		self.stagingRoot = stagingRoot
	}

	/// 写真フォルダから 3D モデルを生成する。完了（またはキャンセル・エラー）まで
	/// 返らない。
	public func process(
		_ request: ReconstructionRequest,
		onEvent: @escaping @Sendable (ReconstructionEvent) -> Void) async throws
	{
		onEvent(.note(Self.note(for: mode)))
		if let helperEngine
		{
			// 別プロセス実行では、写真の複製もヘルパー（＝写真を読む側）が行う。
			// 指示は APICommand の引数に乗って伝わるので、ここでは何もしない。
			try await helperEngine.process(request, onEvent: onEvent)
			return
		}
		guard let engine
		else
		{
			return
		}
		// 同一プロセス実行のときは、ヘルパーが担っている複製をここで行う
		// （どちらの実行方式でも request の指示どおりに振る舞わせるため）。
		//
		// withStagedInput（クロージャ版）を使わずに書き下しているのは、テストで
		// 踏めないクロージャを作らないため（関数カバレッジのしきい値は 100%）。
		let staged = try InputStaging.stageIfRequested(
			request,
			root: stagingRoot,
			cancellation: cancellation,
			onEvent: onEvent)
		var effective = request
		if let staged
		{
			effective = staged.request
		}
		do
		{
			try await engine.process(effective, onEvent: onEvent)
		}
		catch
		{
			InputStaging.discard(staged)
			throw error
		}
		InputStaging.discard(staged)
	}

	/// 実行中の処理を中断する。
	public func cancel()
	{
		cancellation.cancel()
		helperEngine?.cancel()
		engine?.cancel()
	}
}
