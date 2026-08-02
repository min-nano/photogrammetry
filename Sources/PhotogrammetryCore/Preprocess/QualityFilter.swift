//
//  QualityFilter.swift
//
//  再構成に寄与しない写真を落とす純ロジック（設計メモ §4.2）。**これだけでも
//  「枚数がハードウェア上限を超える」に直接効く。**
//
//  落とすのは 4 種類。
//
//    ブレ        ラプラシアン分散が現場の分布から見て明らかに低い
//    露出破綻    白飛び・黒つぶれが画面の大半を占める（小屋裏のフラッシュ、床下の暗所）
//    ほぼ同一    連写・立ち止まったままのシャッター連打。知覚ハッシュで検出し、
//                同じ塊からは**最も鮮鋭な 1 枚だけ**残す
//    形が不適    パノラマ・極端に小さい画像（Object Capture が扱いを誤る）
//
//  閾値は固定しない。ブレの絶対値は被写体の模様で桁が変わるので、分布から
//  自動決定する（ThresholdEstimator）。かつ**山が 1 つしか無いときは切らない**
//  ため、ブレた写真が無い現場で良品を捨てることがない。
//
//  除外した写真は捨てず `_excluded/` へ理由付きで退避する（判断を後から
//  見直せるように）。ここはその判断だけを行い、ファイル操作は PhotoSorter。
//

import Foundation

/// 除外の理由。rawValue は manifest に載る語彙なので変更しない。
public enum ExclusionReason: String, Codable, CaseIterable, Equatable, Sendable
{
	/// ブレ・ピンボケ。
	case blur
	/// 白飛びが画面の大半を占める。
	case overexposed
	/// 黒つぶれが画面の大半を占める。
	case underexposed
	/// ほぼ同一の写真が他にあり、そちらを残した。
	case duplicate
	/// 画素数が少なすぎる（サムネイル・スクリーンショットの混入）。
	case tooSmall
	/// パノラマなど極端な縦横比。
	case panorama
	/// 画像として読めなかった。
	case unreadable

	/// 診断レポートに出す日本語名。
	public var displayName: String
	{
		switch self
		{
			case .blur:
				return "ブレ"
			case .overexposed:
				return "白飛び"
			case .underexposed:
				return "黒つぶれ"
			case .duplicate:
				return "ほぼ同一"
			case .tooSmall:
				return "画素数不足"
			case .panorama:
				return "パノラマ"
			case .unreadable:
				return "読み取り失敗"
		}
	}
}

/// 除外された写真 1 枚分の記録。
public struct ExcludedPhoto: Equatable, Sendable
{
	/// 入力フォルダからの相対パス。
	public var photo: String
	public var reason: ExclusionReason
	/// 判断の根拠になった数値（ブレなら鮮鋭度、ほぼ同一ならハミング距離）。
	/// 後から閾値を見直すためのもの。
	public var score: Double

	public init(photo: String, reason: ExclusionReason, score: Double)
	{
		self.photo = photo
		self.reason = reason
		self.score = score
	}
}

public enum QualityFilter
{
	/// 判定の設定。閾値を明示すると自動決定より優先される（逃げ道）。
	public struct Settings: Equatable, Sendable
	{
		/// 鮮鋭度の閾値。nil なら分布から自動決定する。
		public var minimumSharpness: Double?
		/// 白飛び・黒つぶれがこの割合を超えたら除外する。
		public var maximumClipping: Double
		/// 長辺がこの画素数未満なら除外する。
		public var minimumLongSide: Int
		/// この縦横比を超えたらパノラマとみなす。
		public var maximumAspectRatio: Double
		/// ほぼ同一とみなすハミング距離（0〜64）。連写の除去に使う。
		public var duplicateDistance: Int
		/// ブレ判定で全体のこの割合を超えて落ちる場合は、判定そのものを
		/// 無効にする。分布の推定が外れたときに現場写真を大量に失わないための
		/// 安全弁で、代わりに診断で「ブレ判定を見送った」と報告する。
		public var maximumBlurFraction: Double

		public init(
			minimumSharpness: Double? = nil,
			maximumClipping: Double = 0.6,
			minimumLongSide: Int = 800,
			maximumAspectRatio: Double = 2.2,
			duplicateDistance: Int = 4,
			maximumBlurFraction: Double = 0.4)
		{
			self.minimumSharpness = minimumSharpness
			self.maximumClipping = maximumClipping
			self.minimumLongSide = minimumLongSide
			self.maximumAspectRatio = maximumAspectRatio
			self.duplicateDistance = duplicateDistance
			self.maximumBlurFraction = maximumBlurFraction
		}
	}

	/// 判定の結果。
	public struct Outcome: Equatable, Sendable
	{
		/// 残った写真（入力の順序を保つ）。
		public var kept: [PhotoMetadata]
		/// 除外した写真。
		public var excluded: [ExcludedPhoto]
		/// 実際に使ったブレの閾値（判定を見送った場合は nil）。
		public var sharpnessThreshold: Double?
		/// 鮮鋭度の分布の中央値（診断・閾値調整用）。
		public var sharpnessMedian: Double?
		/// ブレ判定を安全弁で見送ったか。
		public var blurFilterSuppressed: Bool

		public init(
			kept: [PhotoMetadata],
			excluded: [ExcludedPhoto],
			sharpnessThreshold: Double? = nil,
			sharpnessMedian: Double? = nil,
			blurFilterSuppressed: Bool = false)
		{
			self.kept = kept
			self.excluded = excluded
			self.sharpnessThreshold = sharpnessThreshold
			self.sharpnessMedian = sharpnessMedian
			self.blurFilterSuppressed = blurFilterSuppressed
		}
	}

	/// 分布から見て明らかに低い側を切るときの上限。**中央値のこの割合より
	/// 鮮鋭な写真は決して落とさない。** 自動決定が暴走しても良品を失わない
	/// ための歯止め。
	static let maximumCutFactor = 0.6
	/// 分布が 1 つの山しか持たないとき（＝ブレた写真がほとんど無いとき）に使う
	/// 保守的な閾値。中央値のこの割合を下回るものだけ落とす。
	static let relativeFloorFactor = 0.2
	/// 判別分析の結果を採用するために必要な分離度。
	static let requiredSeparability = 0.55
	/// 判別分析が「下位クラス」と判定した割合の上限。これを超える答えは
	/// 谷を捉え損ねているとみなす。
	static let maximumLowerFraction = 0.35
	/// 鮮鋭度の分布推定に必要な最低枚数。
	static let minimumSampleCount = 8

	/// 品質フィルタを適用する。写真の順序は撮影順（PhotoOrdering）で解釈するので、
	/// 呼び出し側は並べ替えなくてよい。
	public static func apply(to photos: [PhotoMetadata], settings: Settings = Settings())
		-> Outcome
	{
		var excluded: [ExcludedPhoto] = []
		var survivors: [PhotoMetadata] = []

		// --- 形と露出。分布に依らず単独で判断できるものを先に落とす。 ---
		for photo in photos
		{
			if photo.pixelWidth > 0, photo.pixelHeight > 0,
				max(photo.pixelWidth, photo.pixelHeight) < settings.minimumLongSide
			{
				excluded.append(ExcludedPhoto(
					photo: photo.relativePath,
					reason: .tooSmall,
					score: Double(max(photo.pixelWidth, photo.pixelHeight))))
				continue
			}
			if photo.aspectRatio > settings.maximumAspectRatio
			{
				excluded.append(ExcludedPhoto(
					photo: photo.relativePath,
					reason: .panorama,
					score: photo.aspectRatio))
				continue
			}
			if let quality = photo.quality
			{
				if quality.clippedHighlights > settings.maximumClipping
				{
					excluded.append(ExcludedPhoto(
						photo: photo.relativePath,
						reason: .overexposed,
						score: quality.clippedHighlights))
					continue
				}
				if quality.clippedShadows > settings.maximumClipping
				{
					excluded.append(ExcludedPhoto(
						photo: photo.relativePath,
						reason: .underexposed,
						score: quality.clippedShadows))
					continue
				}
			}
			survivors.append(photo)
		}

		// --- ブレ。閾値は分布から決める（固定値を持たない）。 ---
		let sharpnessValues = survivors.compactMap { $0.quality?.sharpness }
		let median = ThresholdEstimator.median(sharpnessValues)
		var threshold = settings.minimumSharpness
			?? estimateSharpnessThreshold(values: sharpnessValues)
		var suppressed = false

		if let candidate = threshold
		{
			let wouldDrop = survivors.filter { ($0.quality?.sharpness ?? .infinity) < candidate }
			// 大量に落ちるときは推定が外れている。判定ごと見送って診断で伝える。
			if !survivors.isEmpty,
				Double(wouldDrop.count) / Double(survivors.count) > settings.maximumBlurFraction
			{
				threshold = nil
				suppressed = true
			}
		}

		if let candidate = threshold
		{
			var kept: [PhotoMetadata] = []
			for photo in survivors
			{
				if let sharpness = photo.quality?.sharpness, sharpness < candidate
				{
					excluded.append(ExcludedPhoto(
						photo: photo.relativePath,
						reason: .blur,
						score: sharpness))
				}
				else
				{
					kept.append(photo)
				}
			}
			survivors = kept
		}

		// --- ほぼ同一。撮影順に並べ、連続する塊から 1 枚だけ残す。 ---
		let ordered = PhotoOrdering.sorted(survivors)
		var keptPaths = Set<String>()
		var runStart = 0
		var index = 1
		func closeRun(_ range: Range<Int>)
		{
			guard !range.isEmpty
			else
			{
				return
			}
			// 塊の代表は最も鮮鋭な 1 枚（同点なら撮影が早いほう）。
			var best = range.lowerBound
			for candidate in range
			{
				let bestSharpness = ordered[best].quality?.sharpness ?? 0
				let candidateSharpness = ordered[candidate].quality?.sharpness ?? 0
				if candidateSharpness > bestSharpness
				{
					best = candidate
				}
			}
			keptPaths.insert(ordered[best].relativePath)
			for candidate in range where candidate != best
			{
				let distance = ordered[candidate].fingerprint.flatMap
				{ hash in
					ordered[best].fingerprint.map { Double(hash.distance(to: $0)) }
				}
				excluded.append(ExcludedPhoto(
					photo: ordered[candidate].relativePath,
					reason: .duplicate,
					score: distance ?? 0))
			}
		}
		while index <= ordered.count
		{
			let isSameRun: Bool
			if index == ordered.count
			{
				isSameRun = false
			}
			else if let a = ordered[runStart].fingerprint, let b = ordered[index].fingerprint
			{
				isSameRun = a.distance(to: b) <= settings.duplicateDistance
			}
			else
			{
				// 指紋が無い写真は判定できない。塊にしない（消さない側に倒す）。
				isSameRun = false
			}
			if !isSameRun
			{
				closeRun(runStart ..< index)
				runStart = index
			}
			index += 1
		}

		return Outcome(
			kept: survivors.filter { keptPaths.contains($0.relativePath) },
			excluded: excluded,
			sharpnessThreshold: threshold,
			sharpnessMedian: median,
			blurFilterSuppressed: suppressed)
	}

	/// 鮮鋭度の分布からブレの閾値を決める。判定できないときは nil（＝切らない）。
	static func estimateSharpnessThreshold(values: [Double]) -> Double?
	{
		guard values.count >= minimumSampleCount, let median = ThresholdEstimator.median(values),
			median > 0
		else
		{
			return nil
		}
		let ceiling = median * maximumCutFactor
		if let estimate = ThresholdEstimator.otsu(values: values),
			estimate.separability >= requiredSeparability,
			estimate.lowerFraction <= maximumLowerFraction
		{
			// 谷がはっきりしている＝ブレた塊が実在する。ただし歯止めは効かせる。
			return min(estimate.threshold, ceiling)
		}
		// 山が 1 つ。ブレた写真はほとんど無いとみなし、極端に低いものだけ落とす。
		return median * relativeFloorFactor
	}
}

/// 写真を「撮影順」に並べる規則。時刻が無い写真（転送アプリで EXIF が剥がれた
/// もの）でもファイル名の連番で順序を復元し、最後はパスで安定させる。
/// グルーピングも重複検出も同じ順序を前提にするので、規則はここ 1 か所に置く。
public enum PhotoOrdering
{
	public static func sorted(_ photos: [PhotoMetadata]) -> [PhotoMetadata]
	{
		photos.enumerated().sorted
		{ left, right in
			isBefore(left.element, right.element, tieBreaker: (left.offset, right.offset))
		}.map { $0.element }
	}

	/// 並べ替えの比較。同じ「撮影順」を複数箇所で使うので判定を共有する。
	static func isBefore(
		_ a: PhotoMetadata,
		_ b: PhotoMetadata,
		tieBreaker: (Int, Int)) -> Bool
	{
		if let left = a.captureDate, let right = b.captureDate, left != right
		{
			return left < right
		}
		// 時刻が片方にしか無い場合、時刻を持つほうを先に置くと順序が撮影と
		// 無関係に崩れる。フォルダ → 連番 → パスの順で決める。
		if a.sourceFolder != b.sourceFolder
		{
			return a.sourceFolder < b.sourceFolder
		}
		if let left = a.sequenceNumber, let right = b.sequenceNumber, left != right
		{
			return left < right
		}
		if a.relativePath != b.relativePath
		{
			return a.relativePath < b.relativePath
		}
		return tieBreaker.0 < tieBreaker.1
	}
}
