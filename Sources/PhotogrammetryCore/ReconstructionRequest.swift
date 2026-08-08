//
//  ReconstructionRequest.swift
//
//  3D モデル生成 1 回分の指示。GUI・CLI・URL スキームのどの入口から来ても
//  最終的にこの構造体 1 つへ正規化され、PhotogrammetryEngine へ渡される。
//
//  RealityKit の型（PhotogrammetrySession.Request.Detail 等）を直接使わず
//  自前の enum を持つのは、(1) 引数・URL クエリの文字列と 1:1 に対応する
//  安定した API 表現にするため、(2) パース・検証ロジックを RealityKit 抜きで
//  単体テストできるようにするため。RealityKit 型への変換は
//  PhotogrammetryEngine.swift 側に閉じ込めてある。
//

import Foundation

public struct ReconstructionRequest: Equatable, Sendable
{
	/// 入力: 対象物を多方向から撮影した写真が入ったフォルダ。
	public var inputFolder: URL
	/// 出力: 生成する 3D モデルファイル（.usdz）。
	public var outputFile: URL
	/// 出力（任意）: 点群を書き出すファイル（.ply）。nil なら点群は作らない。
	///
	/// Object Capture は位置合わせの過程で色つきの 3D 点群を作っており、これを
	/// メッシュとは別に取り出せる（`PhotogrammetrySession.Request.pointCloud`）。
	/// メッシュより素直に「撮れた点」を表すので、寸法の確認や他のソフト
	/// （CloudCompare・CAD）への持ち込みに使える。形式は PLY 固定（PointCloudFile）。
	public var pointCloudFile: URL?
	/// モデルの詳細度。
	public var detail: Detail
	/// 写真の並び。連続撮影（隣接写真が近い）なら .sequential が速い。
	public var sampleOrdering: SampleOrdering
	/// 特徴点検出の感度。写真が少ない・質感が乏しい対象は .high。
	public var featureSensitivity: FeatureSensitivity
	/// 撮影対象の種類（オブジェクトマスキングの有効/無効）。
	public var subject: SubjectKind
	/// 写真をアプリのキャッシュへ複製してから処理するか（既定: true）。
	///
	/// クラウド同期領域（iCloud Drive など）に置いたままの写真は、実体が未
	/// ダウンロードだったり処理中に退避されたりして読めなくなる。生成は数時間
	/// かかることがあるので、先にローカルへ写してしまうほうが確実。複製は処理が
	/// 終わると捨てる（詳細は InputStaging）。ディスクの空きが足りないなど、
	/// 複製したくない事情があるときだけ false にする。
	public var stageInputLocally: Bool

	public init(
		inputFolder: URL,
		outputFile: URL,
		detail: Detail = .medium,
		sampleOrdering: SampleOrdering = .unordered,
		featureSensitivity: FeatureSensitivity = .normal,
		subject: SubjectKind = .object,
		stageInputLocally: Bool = true,
		// 点群は後から足した出力なので、既存の呼び出し（ライブラリとして
		// 組み込んでいる側）を壊さないよう引数の末尾に置いてある。
		pointCloudFile: URL? = nil)
	{
		self.inputFolder = inputFolder
		self.outputFile = outputFile
		self.pointCloudFile = pointCloudFile
		self.detail = detail
		self.sampleOrdering = sampleOrdering
		self.featureSensitivity = featureSensitivity
		self.subject = subject
		self.stageInputLocally = stageInputLocally
	}

	/// PhotogrammetrySession.Request.Detail に対応。rawValue が CLI /
	/// URL スキームの文字列表現そのものになる。
	public enum Detail: String, CaseIterable, Equatable, Sendable
	{
		case preview
		case reduced
		case medium
		case full
		case raw
	}

	/// PhotogrammetrySession.Configuration.SampleOrdering に対応。
	public enum SampleOrdering: String, CaseIterable, Equatable, Sendable
	{
		case unordered
		case sequential
	}

	/// PhotogrammetrySession.Configuration.FeatureSensitivity に対応。
	public enum FeatureSensitivity: String, CaseIterable, Equatable, Sendable
	{
		case normal
		case high
	}

	/// 撮影対象の種類。Object Capture は既定で「背景から単一の物体を切り出す」
	/// オブジェクトマスキングを行うため、建物・部屋のようなシーン全体の写真では
	/// 前景の切り出しが破綻し、アライメント失敗（CoreOC エラー 6）になりやすい。
	/// シーンを扱うときは .scene（マスキング無効）を選ぶ。
	public enum SubjectKind: String, CaseIterable, Equatable, Sendable
	{
		/// 単一の物体（オブジェクトマスキング有効 = RealityKit の既定）。
		case object
		/// シーン・建物全体（オブジェクトマスキング無効）。
		case scene
	}

	/// セッションを作る前に分かる誤りを検出する。ファイルシステムを見るのは
	/// ここだけで、呼び出し側（エンジン・CLI・GUI）は throw の内容をそのまま
	/// ユーザーへ提示すればよい。
	public func validate(fileManager: FileManager = .default) throws
	{
		var isDirectory: ObjCBool = false
		let exists = fileManager.fileExists(atPath: inputFolder.path, isDirectory: &isDirectory)
		guard exists, isDirectory.boolValue
		else
		{
			throw RequestError.inputNotDirectory(inputFolder.path)
		}
		// PhotogrammetrySession.Request.modelFile は .usdz のみ受け付ける。
		guard outputFile.pathExtension.lowercased() == "usdz"
		else
		{
			throw RequestError.outputExtensionInvalid(outputFile.path)
		}
		// 点群の書き出しは自前（PointCloudFile）で、形式は PLY 固定。
		if let pointCloudFile,
			pointCloudFile.pathExtension.lowercased() != PointCloudFile.fileExtension
		{
			throw RequestError.pointCloudExtensionInvalid(pointCloudFile.path)
		}
	}
}

public extension ReconstructionRequest
{
	/// 入力フォルダ直下でカウント対象にする画像拡張子。PhotogrammetrySession が
	/// 実際に受理する形式は ImageIO 依存だが、枚数上限の事前警告に使う概算には
	/// この近似で足りる。
	static let imageExtensions: Set<String> = [
		"jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "dng",
	]

	/// 入力フォルダ直下の画像ファイル数（概算）。ハードウェア上限の事前警告に
	/// 使う。フォルダが読めない場合は 0 を返す（存在チェックは validate の仕事）。
	static func imageFileCount(in folder: URL, fileManager: FileManager = .default) -> Int
	{
		guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path)
		else
		{
			return 0
		}
		return names.filter
		{ name in
			imageExtensions.contains((name as NSString).pathExtension.lowercased())
		}.count
	}
}

public enum RequestError: Error, LocalizedError, Equatable
{
	case inputNotDirectory(String)
	case outputExtensionInvalid(String)
	case pointCloudExtensionInvalid(String)

	public var errorDescription: String?
	{
		switch self
		{
			case .inputNotDirectory(let path):
				return "入力フォルダが見つかりません（フォルダを指定してください）: \(path)"
			case .outputExtensionInvalid(let path):
				return "出力ファイルは拡張子 .usdz を指定してください: \(path)"
			case .pointCloudExtensionInvalid(let path):
				return "点群の出力ファイルは拡張子 .ply を指定してください: \(path)"
		}
	}
}
