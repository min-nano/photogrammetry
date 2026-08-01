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
	/// モデルの詳細度。
	public var detail: Detail
	/// 写真の並び。連続撮影（隣接写真が近い）なら .sequential が速い。
	public var sampleOrdering: SampleOrdering
	/// 特徴点検出の感度。写真が少ない・質感が乏しい対象は .high。
	public var featureSensitivity: FeatureSensitivity

	public init(
		inputFolder: URL,
		outputFile: URL,
		detail: Detail = .medium,
		sampleOrdering: SampleOrdering = .unordered,
		featureSensitivity: FeatureSensitivity = .normal)
	{
		self.inputFolder = inputFolder
		self.outputFile = outputFile
		self.detail = detail
		self.sampleOrdering = sampleOrdering
		self.featureSensitivity = featureSensitivity
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
	}
}

public enum RequestError: Error, LocalizedError, Equatable
{
	case inputNotDirectory(String)
	case outputExtensionInvalid(String)

	public var errorDescription: String?
	{
		switch self
		{
			case .inputNotDirectory(let path):
				return "入力フォルダが見つかりません（フォルダを指定してください）: \(path)"
			case .outputExtensionInvalid(let path):
				return "出力ファイルは拡張子 .usdz を指定してください: \(path)"
		}
	}
}
