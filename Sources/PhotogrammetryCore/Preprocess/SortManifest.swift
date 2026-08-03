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
	///
	/// 2 = フェーズ 2。視覚クラスタ（`groups[].rooms` / `adjacency[].sharedRoom` /
	/// `statistics.roomCount`）と視覚解析の設定を足した。
	///
	/// 3 = 重なりの検証（設計メモ §4.6.1）。`adjacency[].overlapVerified` と
	/// `statistics.overlapChecks` を足した。**合成は「実際に重なっていると
	/// 確かめた」隣接を最も信頼してよい**という情報で、`sharedRoom` より強い。
	///
	/// 4 = グループ分けそのものを重なりで決める（設計メモ §4.9）。
	/// `statistics.overlapGraph` と `settings.overlapGrouping` / `overlapBudget` を
	/// 足した。**`overlapGraph` が載っている manifest では、グループは「実際に
	/// 重なっている写真の連結成分を枚数で割ったもの」**になっている — つまり
	/// どのグループも再構成が成立する形で出ていることが構成上保証される。
	/// `settings.groupThreshold` の意味もこのとき変わり、**合算スコアではなく
	/// 画素の一致度の閾値**になる（`groupThresholdWasAutomatic` は false）。
	/// あわせて `groups[].sequential` を足した — グループが撮影順の連続区間とは
	/// 限らなくなったので、順序のヒントを使ってよいかを読み手へ伝える必要がある。
	///
	/// 項目が増えたので古い manifest はそのままでは読み戻せない。読み手はまだ
	/// 存在しない（`merge` はフェーズ 3）ので、移行の仕組みは持たない。
	public static let currentVersion = 4

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
		/// 視覚解析（Vision の feature print）を使ったか。
		public var visualEvidence: Bool
		/// 同じ場所とみなした視覚特徴の距離。使わなかった場合も実際の値を残す
		/// （後から同じ結果を再現できるようにするため）。
		public var visualThreshold: Double
		public var visualThresholdWasAutomatic: Bool
		/// 共有写真の候補を実際に位置合わせして確かめたか。
		public var overlapCheck: Bool
		/// 重なっていると認めた画素の一致度の下限（再現のため実際の値を残す）。
		public var overlapAgreement: Double
		/// グループ分けそのものを実際の重なりで決めたか（設計メモ §4.9）。
		public var overlapGrouping: Bool
		/// グループ分けで重なりを確かめた回数の上限（実際に使った値）。
		/// 確かめなかったときは nil。
		public var overlapBudget: Int?
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
			visualEvidence: Bool,
			visualThreshold: Double,
			visualThresholdWasAutomatic: Bool,
			overlapCheck: Bool,
			overlapAgreement: Double,
			overlapGrouping: Bool = false,
			overlapBudget: Int? = nil,
			link: LinkStrategy)
		{
			self.overlapGrouping = overlapGrouping
			self.overlapBudget = overlapBudget
			self.overlap = overlap
			self.maxPerGroup = maxPerGroup
			self.minPerGroup = minPerGroup
			self.timeGap = timeGap
			self.groupThreshold = groupThreshold
			self.groupThresholdWasAutomatic = groupThresholdWasAutomatic
			self.sharpnessThreshold = sharpnessThreshold
			self.duplicateDistance = duplicateDistance
			self.visualEvidence = visualEvidence
			self.visualThreshold = visualThreshold
			self.visualThresholdWasAutomatic = visualThresholdWasAutomatic
			self.overlapCheck = overlapCheck
			self.overlapAgreement = overlapAgreement
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
		/// 視覚的に見分けた場所の数（グループとは別の軸）。
		public var roomCount: Int
		/// 除外の理由ごとの枚数。
		public var excludedByReason: [String: Int]
		/// 結合スコアの分布（0.0〜1.0 を 20 分割）。
		public var scoreHistogram: [Int]
		/// 視覚特徴の近傍距離の分布（同上）。視覚解析の閾値を写真無しで
		/// 検討するための材料。
		public var visualDistanceHistogram: [Int]
		/// 鮮鋭度の中央値。閾値の妥当性を見るための基準。
		public var sharpnessMedian: Double?
		/// 重なりの検証の集計（確かめなかったときは nil）。**「共有写真が少ない」
		/// のが撮り方のせいか閾値のせいかを、写真を見ずに切り分ける材料**になる。
		public var overlapChecks: OverlapChecks?
		/// グループ分けで作った重なりグラフの統計（§4.9）。使わなかったときは nil。
		public var overlapGraph: OverlapGraphStatistics?

		public init(
			inputCount: Int,
			keptCount: Int,
			groupCount: Int,
			roomCount: Int,
			excludedByReason: [String: Int],
			scoreHistogram: [Int],
			visualDistanceHistogram: [Int],
			sharpnessMedian: Double?,
			overlapChecks: OverlapChecks? = nil,
			overlapGraph: OverlapGraphStatistics? = nil)
		{
			self.overlapChecks = overlapChecks
			self.overlapGraph = overlapGraph
			self.inputCount = inputCount
			self.keptCount = keptCount
			self.groupCount = groupCount
			self.roomCount = roomCount
			self.excludedByReason = excludedByReason
			self.scoreHistogram = scoreHistogram
			self.visualDistanceHistogram = visualDistanceHistogram
			self.sharpnessMedian = sharpnessMedian
		}

		/// 重なりの検証を何組行い、どう判定したか。**写真そのものを含まない**。
		public struct OverlapChecks: Codable, Equatable, Sendable
		{
			/// 実際に重なっていると確かめた組数。
			public var verified: Int
			/// 重なっていないと分かって落とした組数。
			public var rejected: Int
			/// 判定材料が足りず保留した組数（模様が無い・読めない）。
			public var undecided: Int

			public init(verified: Int, rejected: Int, undecided: Int)
			{
				self.verified = verified
				self.rejected = rejected
				self.undecided = undecided
			}
		}

		/// グループ分けで作った重なりグラフの統計（設計メモ §4.9）。**写真そのものを
		/// 含まない**ので、そのまま共有して設定を検討できる（§10-10）。
		public struct OverlapGraphStatistics: Codable, Equatable, Sendable
		{
			/// 実際に確かめた組数。
			public var checked: Int
			/// 使ってよかった回数の上限。
			public var budget: Int
			/// 上限を使い切ったか。**true なら見落とした繋がりがありうる**ので、
			/// `--overlap-budget` を上げて試す価値がある。
			public var budgetExhausted: Bool
			/// 重なっていると確かめた組数。
			public var overlapping: Int
			/// 重なっていないと確かめた組数（＝グループを切る根拠になった組）。
			public var separate: Int
			/// 判定できなかった組数（模様が無い・読めない）。
			public var undecided: Int
			/// 写真 1 枚ごとの「重なる相手の数」の分布。添字 0 は「どの写真とも
			/// 重ならなかった」で、**ここが大きい現場は撮影密度が足りない**。
			public var degreeHistogram: [Int]
			/// 一致度の分布（0.0〜1.0 を 20 分割）。閾値の妥当性を写真無しで見直す
			/// ための材料で、**山が 2 つに割れていれば判定は効いている**。
			public var agreementHistogram: [Int]

			public init(
				checked: Int,
				budget: Int,
				budgetExhausted: Bool,
				overlapping: Int,
				separate: Int,
				undecided: Int,
				degreeHistogram: [Int],
				agreementHistogram: [Int])
			{
				self.checked = checked
				self.budget = budget
				self.budgetExhausted = budgetExhausted
				self.overlapping = overlapping
				self.separate = separate
				self.undecided = undecided
				self.degreeHistogram = degreeHistogram
				self.agreementHistogram = agreementHistogram
			}
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
		/// このグループが写している場所（視覚クラスタ）の識別子。枚数の多い順。
		/// 2 つ以上並んでいれば、そのグループには別の場所が混ざっている。
		public var rooms: [String]
		/// このフォルダの写真が**撮影順の途切れない一続き**か。
		/// true なら再構成で `--sample-ordering sequential` を使ってよい。false は
		/// 一度離れて戻ってきた撮影が同じグループに入っている印で、そのときに
		/// 順序のヒントを与えると外れる（設計メモ §4.9）。
		public var sequential: Bool
		public var captureStart: Date?
		public var captureEnd: Date?

		public init(
			id: String,
			photos: [String],
			shared: [String],
			evidence: [String],
			rooms: [String],
			sequential: Bool = true,
			captureStart: Date?,
			captureEnd: Date?)
		{
			self.sequential = sequential
			self.id = id
			self.photos = photos
			self.shared = shared
			self.evidence = evidence
			self.rooms = rooms
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
		/// 両方のグループが写している共通の場所（視覚クラスタ）。**時刻が
		/// 離れていても成立する繋ぎ目**なので、合成では信頼できる。
		public var sharedRoom: String?
		/// 共有写真が**実際に重なって写っていることを確かめた**か（§4.6.1）。
		/// これが true の隣接は最も信頼してよい。false は「確かめていない」で、
		/// 「重なっていない」ではない。
		public var overlapVerified: Bool

		public init(
			a: String,
			b: String,
			sharedPhotos: [String],
			confidence: Double,
			viewpointSpread: Double?,
			sharedRoom: String?,
			overlapVerified: Bool = false)
		{
			self.overlapVerified = overlapVerified
			self.a = a
			self.b = b
			self.sharedPhotos = sharedPhotos
			self.confidence = confidence
			self.viewpointSpread = viewpointSpread
			self.sharedRoom = sharedRoom
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
