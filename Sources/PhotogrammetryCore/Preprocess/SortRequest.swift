//
//  SortRequest.swift
//
//  仕分け 1 回分の指示。GUI・CLI・URL スキームのどの入口から来ても最終的に
//  この構造体 1 つへ正規化される（ReconstructionRequest と同じ役割）。
//
//  ここはファイルシステムを見るのが validate だけの純ロジックで、各段
//  （品質フィルタ・グルーピング・計画）の設定へ翻訳する責任も持つ。設定の
//  既定値をこの 1 か所に集めておくと、CLI・GUI・テストで食い違わない。
//

import Foundation

/// 仕分け先へ写真をどう置くか。
public enum LinkStrategy: String, CaseIterable, Codable, Equatable, Sendable
{
	/// ハードリンク（既定）。同じボリュームなら実体を増やさずに済むので、
	/// 数百枚〜数千枚の写真を扱ってもディスクを圧迫しない。同一ボリューム外
	/// などで失敗したときは自動でコピーへ落ちる。
	case hardlink
	/// コピー。元と切り離したいとき。
	case copy
	/// シンボリックリンク。元フォルダを消すと壊れるので既定にはしない。
	case symlink
}

public struct SortRequest: Equatable, Sendable
{
	/// 入力: 現場で撮った写真がまとめて入っているフォルダ。
	public var inputFolder: URL
	/// 出力: group-01/ … と manifest.json を作るフォルダ。
	public var outputFolder: URL
	/// 隣接グループ間で共有する写真の枚数。**合成の精度に最も効く。**
	public var overlap: Int
	/// 1 グループの上限枚数。ハードウェア上限と実用域（〜200 枚程度）の
	/// 小さいほうを指定する。
	public var maxPerGroup: Int
	/// 1 グループの下限枚数。これを下回るグループは隣へ吸収する。
	public var minPerGroup: Int
	/// 区切りとみなす撮影時刻の間隔（秒）。
	public var timeGap: TimeInterval
	/// 結合スコアの閾値。nil なら分布から自動決定する（既定）。
	public var groupThreshold: Double?
	/// ブレ判定の閾値。nil なら分布から自動決定する（既定）。
	public var minimumSharpness: Double?
	/// ほぼ同一とみなす知覚ハッシュのハミング距離。
	public var duplicateDistance: Int
	/// 視覚解析（Vision の feature print による「同じ場所」の判定）を使うか。
	/// 既定は true。切ると 1 枚あたりの解析は速くなるが、部屋を行き来しながら
	/// 撮った写真の仕分けは目に見えて悪くなる。
	public var visualEvidence: Bool
	/// 同じ場所とみなす視覚特徴の距離（0.0〜1.0）。nil なら分布から自動決定する。
	public var visualThreshold: Double?
	/// ファイルの配置方法。
	public var link: LinkStrategy
	/// サブフォルダも走査するか。撮影者が階・部屋で分けている場合、その分けかた
	/// 自体が最も信頼できる証拠になるので拾いにいく。
	public var recursive: Bool
	/// true ならファイルを作らず、解析と診断だけを行う（撮り直しの判断用）。
	public var dryRun: Bool

	public init(
		inputFolder: URL,
		outputFolder: URL,
		overlap: Int = 15,
		maxPerGroup: Int = 150,
		minPerGroup: Int = 20,
		timeGap: TimeInterval = 300,
		groupThreshold: Double? = nil,
		minimumSharpness: Double? = nil,
		duplicateDistance: Int = 4,
		visualEvidence: Bool = true,
		visualThreshold: Double? = nil,
		link: LinkStrategy = .hardlink,
		recursive: Bool = true,
		dryRun: Bool = false)
	{
		self.inputFolder = inputFolder
		self.outputFolder = outputFolder
		self.overlap = overlap
		self.maxPerGroup = maxPerGroup
		self.minPerGroup = minPerGroup
		self.timeGap = timeGap
		self.groupThreshold = groupThreshold
		self.minimumSharpness = minimumSharpness
		self.duplicateDistance = duplicateDistance
		self.visualEvidence = visualEvidence
		self.visualThreshold = visualThreshold
		self.link = link
		self.recursive = recursive
		self.dryRun = dryRun
	}

	/// 仕分けを始める前に分かる誤りを検出する。
	public func validate(fileManager: FileManager = .default) throws
	{
		var isDirectory: ObjCBool = false
		let exists = fileManager.fileExists(atPath: inputFolder.path, isDirectory: &isDirectory)
		guard exists, isDirectory.boolValue
		else
		{
			throw SortRequestError.inputNotDirectory(inputFolder.path)
		}
		guard overlap >= 0
		else
		{
			throw SortRequestError.invalidSetting("overlap", "0 以上を指定してください")
		}
		guard maxPerGroup >= 10
		else
		{
			throw SortRequestError.invalidSetting("maxPerGroup", "10 以上を指定してください")
		}
		guard minPerGroup >= 1, minPerGroup <= maxPerGroup
		else
		{
			throw SortRequestError.invalidSetting(
				"minPerGroup", "1 以上 maxPerGroup 以下を指定してください")
		}
		guard (0 ... 64).contains(duplicateDistance)
		else
		{
			throw SortRequestError.invalidSetting("duplicateDistance", "0〜64 を指定してください")
		}
		if let threshold = groupThreshold, !(0 ... 1).contains(threshold)
		{
			throw SortRequestError.invalidSetting("groupThreshold", "0.0〜1.0 を指定してください")
		}
		if let threshold = visualThreshold, !(0 ... 1).contains(threshold)
		{
			throw SortRequestError.invalidSetting("visualThreshold", "0.0〜1.0 を指定してください")
		}
		// 出力フォルダの中身を黙って混ぜない。既存の group-NN が残っていると
		// 前回の仕分け結果と混ざり、どの写真がどのグループのものか分からなくなる。
		if !dryRun, let contents = try? fileManager.contentsOfDirectory(atPath: outputFolder.path),
			contents.contains(where: { !$0.hasPrefix(".") })
		{
			throw SortRequestError.outputNotEmpty(outputFolder.path)
		}
		guard outputFolder.standardizedFileURL != inputFolder.standardizedFileURL
		else
		{
			throw SortRequestError.outputInsideInput(outputFolder.path)
		}
	}

	/// 品質フィルタの設定へ翻訳する。
	public var qualitySettings: QualityFilter.Settings
	{
		QualityFilter.Settings(
			minimumSharpness: minimumSharpness,
			duplicateDistance: duplicateDistance)
	}

	/// 写真の読み取りで何を測るかへ翻訳する。
	public var inspectionOptions: PhotoInspectionOptions
	{
		PhotoInspectionOptions(featurePrints: visualEvidence)
	}

	/// グルーピングの設定へ翻訳する。
	///
	/// 上限枚数をそのまま渡さないのは、**あとから共有写真が両側へ入るため**。
	/// 隣接ぶんの余裕（overlap の 2 本ぶん）を先に引いておかないと、仕分け直後は
	/// 上限内でも共有写真を足した時点で超える。余裕を引いた結果が下限を割る
	/// ような設定では、上限をそのまま使う（設定の矛盾で 1 枚ずつのグループを
	/// 作らないため。超過は診断で報告する）。
	public var groupingSettings: GroupingSettings
	{
		let reserved = maxPerGroup - overlap * 2
		let effectiveMax = reserved >= max(minPerGroup, 10) ? reserved : maxPerGroup
		// 視覚解析を切ったときは重みも 0 にする。読み取りで特徴を取らないので
		// 実際には使われないが、**指示が「使わない」なら、たまたま特徴が付いて
		// いる写真を渡されても使わない**のが筋（ライブラリとして直接
		// PhotoGrouping を呼ばれる経路がある）。
		var weights = GroupingSettings.defaultWeights
		if !visualEvidence
		{
			weights[.scene] = 0
			weights[.room] = 0
		}
		return GroupingSettings(
			timeGap: timeGap,
			roomClustering: RoomClustering.Settings(threshold: visualThreshold),
			maxPerGroup: effectiveMax,
			minPerGroup: minPerGroup,
			threshold: groupThreshold,
			weights: weights)
	}

	/// 仕分け計画の設定へ翻訳する。
	public var plannerSettings: SortPlanner.Settings
	{
		SortPlanner.Settings(overlap: overlap)
	}
}

public enum SortRequestError: Error, LocalizedError, Equatable
{
	case inputNotDirectory(String)
	case outputNotEmpty(String)
	case outputInsideInput(String)
	case invalidSetting(String, String)

	public var errorDescription: String?
	{
		switch self
		{
			case .inputNotDirectory(let path):
				return "入力フォルダが見つかりません（フォルダを指定してください）: \(path)"
			case .outputNotEmpty(let path):
				return "仕分け先フォルダが空ではありません（前回の結果と混ざるため中断しました）: \(path)"
			case .outputInsideInput(let path):
				return "仕分け先に入力フォルダ自身は指定できません: \(path)"
			case .invalidSetting(let name, let requirement):
				return "\(name) の値が不正です（\(requirement)）。"
		}
	}
}
