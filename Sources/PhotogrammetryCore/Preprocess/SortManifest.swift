//
//  SortManifest.swift
//
//  `sort` が書き出す manifest.json の定義（設計メモ §4.5）。
//
//  **`sort` と `merge` の契約はこの manifest 1 つ。** `UpdateFeed` と `build.yml`
//  が機械可読形式で対になっているのと同じ関係なので、**片方を変えるときは
//  両方＋テストを更新する**こと。特に `adjacency` はフェーズ 3 の `merge` が
//  そのまま読む（どのグループ同士がどの写真を共有しているか＝対応点の在処）。
//
//  ここは Codable の定義だけを持つ純ロジックで、ファイルシステムには触らない。
//

import Foundation

/// 仕分け結果の機械可読な記録。
public struct SortManifest: Codable, Equatable, Sendable
{
	/// 形式のバージョン。互換性を壊す変更を入れるときだけ上げる。
	public static let currentVersion = 1

	public var version: Int
	/// 書き出した時刻。
	public var generatedAt: Date
	/// 入力フォルダの絶対パス。
	public var source: String
	public var settings: Settings
	public var evidence: Evidence
	public var statistics: Statistics
	public var groups: [Group]
	public var adjacency: [Adjacency]
	public var excluded: [Excluded]
	public var unassigned: [String]
	/// 診断（撮り直しの判断材料）。写真そのものは一切含まない。
	public var diagnostics: [SortDiagnostic]

	public init(
		version: Int = SortManifest.currentVersion,
		generatedAt: Date,
		source: String,
		settings: Settings,
		evidence: Evidence,
		statistics: Statistics,
		groups: [Group],
		adjacency: [Adjacency],
		excluded: [Excluded],
		unassigned: [String],
		diagnostics: [SortDiagnostic])
	{
		self.version = version
		self.generatedAt = generatedAt
		self.source = source
		self.settings = settings
		self.evidence = evidence
		self.statistics = statistics
		self.groups = groups
		self.adjacency = adjacency
		self.excluded = excluded
		self.unassigned = unassigned
		self.diagnostics = diagnostics
	}

	/// 実際に使った設定。自動決定した閾値もここに残す（後から同じ結果を
	/// 再現できるようにするため）。
	public struct Settings: Codable, Equatable, Sendable
	{
		public var overlap: Int
		public var maxPerGroup: Int
		public var minPerGroup: Int
		public var timeGap: TimeInterval
		/// 結合スコアの閾値。
		public var groupThreshold: Double
		/// 閾値を分布から自動決定したか。
		public var groupThresholdWasAutomatic: Bool
		/// ブレ判定に使った鮮鋭度の閾値（判定を見送った場合は nil）。
		public var sharpnessThreshold: Double?
		/// ほぼ同一とみなしたハミング距離。
		public var duplicateDistance: Int
		/// ファイルの配置方法。
		public var link: LinkStrategy

		public init(
			overlap: Int,
			maxPerGroup: Int,
			minPerGroup: Int,
			timeGap: TimeInterval,
			groupThreshold: Double,
			groupThresholdWasAutomatic: Bool,
			sharpnessThreshold: Double?,
			duplicateDistance: Int,
			link: LinkStrategy)
		{
			self.overlap = overlap
			self.maxPerGroup = maxPerGroup
			self.minPerGroup = minPerGroup
			self.timeGap = timeGap
			self.groupThreshold = groupThreshold
			self.groupThresholdWasAutomatic = groupThresholdWasAutomatic
			self.sharpnessThreshold = sharpnessThreshold
			self.duplicateDistance = duplicateDistance
			self.link = link
		}
	}

	/// どの手がかりを使い、どれをなぜ使わなかったか。
	public struct Evidence: Codable, Equatable, Sendable
	{
		/// 実際に使った証拠（EvidenceKind の rawValue）。
		public var used: [String]
		/// 証拠ごとの「その項目を持つ写真の割合」。使わなかった理由がここで分かる
		/// （例: GPS 0.0 = 屋内で測位が信用できない）。
		public var coverage: [String: Double]

		public init(used: [String], coverage: [String: Double])
		{
			self.used = used
			self.coverage = coverage
		}
	}

	/// 統計。**写真そのものを含まない**ので、現場の写真を共有せずに閾値の
	/// 妥当性を検討できる（設計メモ §10-10）。
	public struct Statistics: Codable, Equatable, Sendable
	{
		/// 入力フォルダで見つかった画像の枚数。
		public var inputCount: Int
		/// 品質フィルタを通過した枚数。
		public var keptCount: Int
		public var groupCount: Int
		/// 除外の理由ごとの枚数。
		public var excludedByReason: [String: Int]
		/// 結合スコアの分布（0.0〜1.0 を 20 分割）。
		public var scoreHistogram: [Int]
		/// 鮮鋭度の中央値。閾値の妥当性を見るための基準。
		public var sharpnessMedian: Double?

		public init(
			inputCount: Int,
			keptCount: Int,
			groupCount: Int,
			excludedByReason: [String: Int],
			scoreHistogram: [Int],
			sharpnessMedian: Double?)
		{
			self.inputCount = inputCount
			self.keptCount = keptCount
			self.groupCount = groupCount
			self.excludedByReason = excludedByReason
			self.scoreHistogram = scoreHistogram
			self.sharpnessMedian = sharpnessMedian
		}
	}

	/// 出力フォルダ 1 つ分。`photos` は共有写真を含む「フォルダの中身そのもの」で、
	/// `shared` はそのうち隣接グループから借りたぶん。
	public struct Group: Codable, Equatable, Sendable
	{
		public var id: String
		public var photos: [String]
		public var shared: [String]
		public var evidence: [String]
		public var captureStart: Date?
		public var captureEnd: Date?

		public init(
			id: String,
			photos: [String],
			shared: [String],
			evidence: [String],
			captureStart: Date?,
			captureEnd: Date?)
		{
			self.id = id
			self.photos = photos
			self.shared = shared
			self.evidence = evidence
			self.captureStart = captureStart
			self.captureEnd = captureEnd
		}
	}

	/// グループ同士の隣接。**`merge` はここを読んで対応点を作る。**
	public struct Adjacency: Codable, Equatable, Sendable
	{
		public var a: String
		public var b: String
		public var sharedPhotos: [String]
		public var confidence: Double
		/// 共有写真の視点の散らばり（低いと合成が退化しやすい）。
		public var viewpointSpread: Double?

		public init(
			a: String,
			b: String,
			sharedPhotos: [String],
			confidence: Double,
			viewpointSpread: Double?)
		{
			self.a = a
			self.b = b
			self.sharedPhotos = sharedPhotos
			self.confidence = confidence
			self.viewpointSpread = viewpointSpread
		}
	}

	/// 品質フィルタで落とした写真。
	public struct Excluded: Codable, Equatable, Sendable
	{
		public var photo: String
		public var reason: ExclusionReason
		public var score: Double

		public init(photo: String, reason: ExclusionReason, score: Double)
		{
			self.photo = photo
			self.reason = reason
			self.score = score
		}
	}

	/// manifest.json のファイル名。CLI・GUI・将来の `merge` が同じ名前を使う。
	public static let fileName = "manifest.json"

	/// 書き出し用のエンコーダ。日付は ISO 8601、キーは並べ替える
	/// （差分を取ったときに読めるようにするため）。
	public static func makeEncoder() -> JSONEncoder
	{
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return encoder
	}

	/// 読み込み用のデコーダ。
	public static func makeDecoder() -> JSONDecoder
	{
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}

	/// JSON データへ変換する。
	public func encoded() throws -> Data
	{
		try Self.makeEncoder().encode(self)
	}

	/// JSON データから読み戻す。
	public static func decoded(from data: Data) throws -> SortManifest
	{
		try makeDecoder().decode(SortManifest.self, from: data)
	}
}
