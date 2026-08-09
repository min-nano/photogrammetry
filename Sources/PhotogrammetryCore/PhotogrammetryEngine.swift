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

/// 生成エンジンの差し替え口（定義は ReconstructionService.swift）。実体はこの
/// クラスで、テストの偽物と同じ形に揃えておく。
extension PhotogrammetryEngine: ReconstructionEngine {}

public final class PhotogrammetryEngine
{
	/// 処理中にフロントエンドへ流す進捗イベント。別プロセス実行
	/// （HelperProcessEngine）でも同じ型を流すので、定義は
	/// ReconstructionEvent.swift に置いてある。
	public typealias Event = ReconstructionEvent

	/// この Mac が Object Capture に対応しているか（GPU 要件がある）。
	public static var isSupported: Bool
	{
		PhotogrammetrySession.isSupported
	}

	/// この Mac のハードウェア上限: 入力画像の最大枚数。
	public static var maximumImageCount: Int
	{
		PhotogrammetrySession.limits.maximumNumberOfInputImages
	}

	/// この Mac のハードウェア上限: 入力画像の最大辺長（ピクセル）。
	public static var maximumImageDimension: Int
	{
		PhotogrammetrySession.limits.maximumInputImageDimension
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

		// 事前チェック: 枚数の上限超過・iCloud の未ダウンロードなど、失敗や
		// クラッシュの典型原因を先に知らせる。処理自体は止めない（確実な失敗と
		// 断定できないため）が、必ずログに手掛かりを残す。判定は InputInspection
		// （純ロジック）に置いてある。
		let summary = InputInspection.inspect(
			folder: request.inputFolder,
			maximumImageCount: Self.maximumImageCount)
		for note in InputInspection.notes(for: summary)
		{
			onEvent(.note(note))
		}

		var configuration = PhotogrammetrySession.Configuration()
		configuration.sampleOrdering = request.sampleOrdering.realityKitValue
		configuration.featureSensitivity = request.featureSensitivity.realityKitValue
		// 対象の種類: .object はオブジェクトマスキング有効（背景から単一の物体を
		// 切り出す = RealityKit の既定）。建物・部屋などシーン全体の写真では前景の
		// 切り出しが破綻してアライメント失敗になるため、.scene では無効にする。
		configuration.isObjectMaskingEnabled = (request.subject == .object)

		let session = try PhotogrammetrySession(
			input: request.inputFolder,
			configuration: configuration)
		self.session = session
		defer
		{
			self.session = nil
		}

		// 出力はどちらも任意で、頼まれたものだけをリクエストに積む。点群は独立した
		// リクエストとして同じセッションに乗る（位置合わせの結果を共有するので、
		// モデルと一緒に頼んでも写真を読み直す無駄は無い）。逆にモデルを頼まなければ
		// メッシュ化・テクスチャ貼りの段階がまるごと省かれる。
		// 両方 nil の指示は validate が弾いているので、ここは必ず 1 つ以上になる。
		var requests: [PhotogrammetrySession.Request] = []
		if let outputFile = request.outputFile
		{
			requests.append(
				.modelFile(url: outputFile, detail: request.detail.realityKitValue))
		}
		if request.pointCloudFile != nil
		{
			requests.append(.pointCloud)
		}
		try session.process(requests: requests)

		// outputs は処理完了（またはキャンセル）で終端する AsyncSequence。
		// requestError はセッション全体の失敗として throw し、呼び出し側の
		// エラー表示へ乗せる。未知の case（将来 OS が増やすもの）は無視する。
		for try await output in session.outputs
		{
			switch output
			{
				case .requestProgress(_, let fractionComplete):
					onEvent(.progress(fractionComplete))
				case .requestProgressInfo(_, let info):
					// 残り時間・段階は OS が返せるときだけ入る。片方だけ返る
					// こともあるので、あるものだけを別々のイベントとして流す
					// （ヘルパープロトコルが 1 イベント = 1 行のため）。
					// 未知の段階（将来 OS が増やすもの）は段階なしとして扱う。
					if let stage = info.processingStage.flatMap(ProcessingStage.init)
					{
						onEvent(.stage(stage))
					}
					if let remaining = info.estimatedRemainingTime
					{
						onEvent(.estimatedRemainingTime(remaining))
					}
				case .requestComplete(_, let result):
					switch result
					{
						case .modelFile(let url):
							onEvent(.completed(url))
						case .pointCloud(let cloud):
							// 点群は OS がファイルにしてくれないので、ここで
							// 書き出す（形式・バイト列の組み立ては PointCloudFile）。
							if let destination = request.pointCloudFile
							{
								try PointCloudFile.write(
									points: cloud.points.map { PointCloudPoint($0) },
									to: destination)
								onEvent(.completedPointCloud(destination))
							}
						default:
							break
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

private extension ProcessingStage
{
	/// RealityKit の処理段階 → 自前 enum。他の変換と向きが逆（OS から受け取る
	/// 側）なので init? にしてある。未知の段階は nil にして黙って捨てる
	/// （表示できない段階名を外へ出すより、段階なしとして扱うほうが安全）。
	init?(_ stage: PhotogrammetrySession.Output.ProcessingStage)
	{
		switch stage
		{
			case .preProcessing:
				self = .preProcessing
			case .imageAlignment:
				self = .imageAlignment
			case .pointCloudGeneration:
				self = .pointCloudGeneration
			case .meshGeneration:
				self = .meshGeneration
			case .textureMapping:
				self = .textureMapping
			case .optimization:
				self = .optimization
			default:
				return nil
		}
	}
}

private extension PointCloudPoint
{
	/// RealityKit の点 → 自前の値型。color は RGBA の順（PLY の property 宣言と
	/// 同じ並び）。この写し替えがあるおかげで、書き出し側は RealityKit を
	/// 知らずに済む。
	init(_ point: PhotogrammetrySession.PointCloud.Point)
	{
		self.init(
			x: point.position.x,
			y: point.position.y,
			z: point.position.z,
			red: point.color.x,
			green: point.color.y,
			blue: point.color.z,
			alpha: point.color.w)
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
