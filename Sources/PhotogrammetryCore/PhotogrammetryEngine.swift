//
//  PhotogrammetryEngine.swift
//
//  RealityKit の PhotogrammetrySession を包む唯一の層。Apple 公式サンプル
//  HelloPhotogrammetry の処理の流れ（Configuration → Request.modelFile →
//  session.outputs の監視）をそのまま踏襲している。
//
//  RealityKit の型がこのファイルの外へ漏れないようにしてあるので、GUI・CLI・
//  外部アプリは ReconstructionRequest と Event だけを知っていればよい。
//

import Foundation
import RealityKit

public final class PhotogrammetryEngine
{
	/// 処理中にフロントエンドへ流す進捗イベント。UI スレッドへの hop は
	/// 受け取り側の責任（このエンジンはスレッドを知らない）。
	public enum Event: Sendable
	{
		/// リクエスト全体の進捗（0.0〜1.0）。
		case progress(Double)
		/// 個々の写真のスキップ・無効などの注意情報（処理は続行している）。
		case note(String)
		/// モデルファイルが書き出された。
		case completed(URL)
		/// キャンセルにより中断した。
		case cancelled
	}

	/// この Mac が Object Capture に対応しているか（GPU 要件がある）。
	public static var isSupported: Bool
	{
		PhotogrammetrySession.isSupported
	}

	private var session: PhotogrammetrySession?

	public init() {}

	/// 写真フォルダから 3D モデルを生成する。完了（または キャンセル・エラー）まで
	/// 返らない。進捗は onEvent へ随時通知される。
	public func process(
		_ request: ReconstructionRequest,
		onEvent: @escaping @Sendable (Event) -> Void) async throws
	{
		try request.validate()

		var configuration = PhotogrammetrySession.Configuration()
		configuration.sampleOrdering = request.sampleOrdering.realityKitValue
		configuration.featureSensitivity = request.featureSensitivity.realityKitValue

		let session = try PhotogrammetrySession(
			input: request.inputFolder,
			configuration: configuration)
		self.session = session
		defer
		{
			self.session = nil
		}

		try session.process(requests: [
			.modelFile(url: request.outputFile, detail: request.detail.realityKitValue)
		])

		// outputs は処理完了（またはキャンセル）で終端する AsyncSequence。
		// requestError はセッション全体の失敗として throw し、呼び出し側の
		// エラー表示へ乗せる。未知の case（将来 OS が増やすもの）は無視する。
		for try await output in session.outputs
		{
			switch output
			{
				case .requestProgress(_, let fractionComplete):
					onEvent(.progress(fractionComplete))
				case .requestComplete(_, let result):
					if case .modelFile(let url) = result
					{
						onEvent(.completed(url))
					}
				case .requestError(_, let error):
					throw error
				case .processingComplete:
					return
				case .processingCancelled:
					onEvent(.cancelled)
					return
				case .invalidSample(let id, let reason):
					onEvent(.note("写真 \(id) を使用できません: \(reason)"))
				case .skippedSample(let id):
					onEvent(.note("写真 \(id) をスキップしました"))
				case .automaticDownsampling:
					onEvent(.note("メモリ節約のため自動的にダウンサンプリングします"))
				case .inputComplete:
					onEvent(.note("写真の取り込みが完了しました。モデルを生成中…"))
				default:
					break
			}
		}
	}

	/// 実行中の処理を中断する。process 側には processingCancelled が届く。
	public func cancel()
	{
		session?.cancel()
	}
}

// ---------------------------------------------------------------------
// 自前 enum → RealityKit 型の変換。この対応表は API（rawValue の語彙）と
// RealityKit を結ぶ唯一の場所で、他のファイルには置かない。
// ---------------------------------------------------------------------

private extension ReconstructionRequest.Detail
{
	var realityKitValue: PhotogrammetrySession.Request.Detail
	{
		switch self
		{
			case .preview:
				return .preview
			case .reduced:
				return .reduced
			case .medium:
				return .medium
			case .full:
				return .full
			case .raw:
				return .raw
		}
	}
}

private extension ReconstructionRequest.SampleOrdering
{
	var realityKitValue: PhotogrammetrySession.Configuration.SampleOrdering
	{
		switch self
		{
			case .unordered:
				return .unordered
			case .sequential:
				return .sequential
		}
	}
}

private extension ReconstructionRequest.FeatureSensitivity
{
	var realityKitValue: PhotogrammetrySession.Configuration.FeatureSensitivity
	{
		switch self
		{
			case .normal:
				return .normal
			case .high:
				return .high
		}
	}
}
