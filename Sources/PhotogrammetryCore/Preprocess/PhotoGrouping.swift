//
//  PhotoGrouping.swift
//
//  写真のメタデータだけを見て「どの写真が同じ場所の塊か」を決める純ロジック
//  （設計メモ §4.1〜§4.3）。ここが仕分けの中身で、Vision も ImageIO も
//  RealityKit も import しない。したがって合成メタデータだけで挙動を固定できる。
//
//  設計の核は「特定の手がかりに依存しない」こと。現場によって撮り方が違う
//  （連続撮影・記録用のバラバラ・iPhone で GPS 付き・階ごとにフォルダ分け）ので、
//  手がかりを**証拠として並列に扱い、あるものだけ使う**。利用できない証拠は
//  重みを 0 にして正規化し直すので、「時刻が使える現場では時刻が主導し、
//  使えない現場では見た目が主導する」が自動的に成立する。
//
//  屋内（床下・小屋裏）を強く意識している。GPS は「付いていること」を信用の
//  根拠にしない（PhotoMetadata.hasTrustworthyLocation）。代わりに、屋外から
//  潜り込むと露出が数段変わることを環境の切れ目として使う。
//
//  グループ分けの方針は「まず繋げて、大きすぎるものを撮影の流れの切れ目で割る」。
//  切りすぎると隣接（＝合成の足がかり）そのものを失うが、大きすぎるグループは
//  枚数で必ず割れるので、**過剰結合の側へ倒すほうが安全**という判断による。
//

import Foundation

/// グルーピングに使える手がかりの種類。rawValue は manifest に載る語彙。
public enum EvidenceKind: String, Codable, CaseIterable, Equatable, Sendable
{
	/// 入力フォルダのサブフォルダ（撮影者が既に階・部屋で分けている）。
	case folder
	/// 撮影時刻の近接。
	case time
	/// ファイル名の連番（時刻が無いときの代替）。
	case sequence
	/// GPS の水平位置。
	case gps
	/// GPS の高度（階の分離）。
	case altitude
	/// カメラの方位（外壁の面の判定）。
	case heading
	/// 露出値（屋外 ⇄ 屋内・床下の環境の切れ目）。
	case exposure
	/// 知覚ハッシュによる見た目の近さ。
	case visual

	/// 診断レポートに出す日本語名。
	public var displayName: String
	{
		switch self
		{
			case .folder:
				return "フォルダ分け"
			case .time:
				return "撮影時刻"
			case .sequence:
				return "ファイル名の連番"
			case .gps:
				return "GPS 位置"
			case .altitude:
				return "GPS 高度"
			case .heading:
				return "撮影方位"
			case .exposure:
				return "露出"
			case .visual:
				return "見た目の近さ"
		}
	}
}

/// グルーピングの設定。距離の「効き幅」をすべて外から差し替えられるように
/// してあるのは、現場（屋外の外周・狭い床下）で妥当な尺度が違うため。
public struct GroupingSettings: Equatable, Sendable
{
	/// 撮影時刻の効き幅（秒）。この差で類似度が 1/e になる。撮影ガイド §12-2
	/// 「場所を移るときは 5 秒立ち止まる」を判定する尺度でもある。
	public var timeGap: TimeInterval
	/// ファイル名連番の効き幅（枚）。
	public var sequenceSpan: Double
	/// GPS の効き幅（m）。実際には測位誤差で広げる。
	public var gpsRadius: Double
	/// 階高（m）。高度差の効き幅の基準。
	public var floorHeight: Double
	/// 露出値の効き幅（EV）。
	public var exposureSpan: Double
	/// 知覚ハッシュの正規化距離の効き幅。
	public var visualSpan: Double
	/// GPS をこの水平誤差（m）より悪いときは使わない。
	public var maximumGPSAccuracy: Double
	/// 測位時刻が撮影時刻からこれ以上ずれていたら使わない（秒）。
	public var maximumGPSAge: TimeInterval
	/// 1 グループの上限枚数。
	public var maxPerGroup: Int
	/// 1 グループの下限枚数。これを下回るグループは隣へ吸収するか除ける。
	public var minPerGroup: Int
	/// 結合スコアの閾値。nil なら分布から自動決定する。
	public var threshold: Double?
	/// 撮影順で前後この枚数までを必ず比較する。
	public var neighborWindow: Int
	/// 知覚ハッシュが近い上位この件数を、撮影順から離れていても比較する
	/// （同じ場所へ戻ってきた撮影を繋ぐ）。
	public var visualNeighbors: Int
	/// 1 グループが持つ隣接の上限。総当たりで隣接を作ると合成時の
	/// 重複写真が増えすぎるので、強いものから採る。
	public var maxLinksPerGroup: Int
	/// 証拠として採用するのに必要な「その項目を持つ写真の割合」。
	public var minimumEvidenceCoverage: Double
	/// 証拠ごとの重み。
	public var weights: [EvidenceKind: Double]

	/// 既定の重み。時刻と見た目を主軸にし、方位・露出は補助に留める
	/// （どちらも単独では別の場所を同じと言いうるため）。
	public static let defaultWeights: [EvidenceKind: Double] = [
		.folder: 1.0,
		.time: 1.0,
		.sequence: 0.5,
		.gps: 0.8,
		.altitude: 0.5,
		.heading: 0.3,
		.exposure: 0.3,
		.visual: 1.0,
	]

	public init(
		timeGap: TimeInterval = 300,
		sequenceSpan: Double = 10,
		gpsRadius: Double = 8,
		floorHeight: Double = 2.0,
		exposureSpan: Double = 3,
		visualSpan: Double = 0.25,
		maximumGPSAccuracy: Double = 30,
		maximumGPSAge: TimeInterval = 120,
		maxPerGroup: Int = 150,
		minPerGroup: Int = 20,
		threshold: Double? = nil,
		neighborWindow: Int = 60,
		visualNeighbors: Int = 12,
		maxLinksPerGroup: Int = 4,
		minimumEvidenceCoverage: Double = 0.5,
		weights: [EvidenceKind: Double] = defaultWeights)
	{
		self.timeGap = timeGap
		self.sequenceSpan = sequenceSpan
		self.gpsRadius = gpsRadius
		self.floorHeight = floorHeight
		self.exposureSpan = exposureSpan
		self.visualSpan = visualSpan
		self.maximumGPSAccuracy = maximumGPSAccuracy
		self.maximumGPSAge = maximumGPSAge
		self.maxPerGroup = maxPerGroup
		self.minPerGroup = minPerGroup
		self.threshold = threshold
		self.neighborWindow = neighborWindow
		self.visualNeighbors = visualNeighbors
		self.maxLinksPerGroup = maxLinksPerGroup
		self.minimumEvidenceCoverage = minimumEvidenceCoverage
		self.weights = weights
	}
}

/// 写真ペアと、その結合スコア。添字は GroupingResult.photos に対するもの。
public struct PairScore: Equatable, Sendable
{
	public var i: Int
	public var j: Int
	public var score: Double

	public init(i: Int, j: Int, score: Double)
	{
		self.i = i
		self.j = j
		self.score = score
	}
}

/// 1 つのグループ。
public struct PhotoGroup: Equatable, Sendable
{
	/// group-01 のような識別子。出力フォルダ名になる。
	public var id: String
	/// GroupingResult.photos への添字（撮影順）。
	public var members: [Int]

	public init(id: String, members: [Int])
	{
		self.id = id
		self.members = members
	}
}

/// グループ同士の隣接。**切ったエッジこそが隣接の証拠**なので、閾値を下回った
/// ペアも含めてここに集める（設計メモ §4.4）。
public struct GroupLink: Equatable, Sendable
{
	/// GroupingResult.groups への添字（a < b）。
	public var a: Int
	public var b: Int
	/// 隣接の確からしさ（0.0〜1.0）。上位のエッジの平均。
	public var confidence: Double
	/// 共有写真の候補（スコア降順）。
	public var candidates: [PairScore]

	public init(a: Int, b: Int, confidence: Double, candidates: [PairScore])
	{
		self.a = a
		self.b = b
		self.confidence = confidence
		self.candidates = candidates
	}
}

/// グルーピングの結果。
public struct GroupingResult: Equatable, Sendable
{
	/// 撮影順に並べ直した写真。groups / links の添字はこの配列に対するもの。
	public var photos: [PhotoMetadata]
	public var groups: [PhotoGroup]
	public var links: [GroupLink]
	/// どのグループにも入らなかった写真（`_unassigned/` へ送る）。
	public var unassigned: [Int]
	/// 実際に使った証拠。
	public var usedEvidence: [EvidenceKind]
	/// 証拠ごとの「その項目を持つ写真の割合」。診断で「なぜ GPS を使わなかったか」
	/// を説明するために持つ。
	public var evidenceCoverage: [EvidenceKind: Double]
	/// 使った結合スコアの閾値。
	public var threshold: Double
	/// 閾値を自動決定したか。
	public var thresholdWasAutomatic: Bool
	/// 結合スコアの分布（0.0〜1.0 を 20 分割）。**写真そのものを含まない統計**なので、
	/// 現場の写真を共有せずに閾値を調整できる（設計メモ §10-10）。
	public var scoreHistogram: [Int]

	public init(
		photos: [PhotoMetadata],
		groups: [PhotoGroup],
		links: [GroupLink],
		unassigned: [Int],
		usedEvidence: [EvidenceKind],
		evidenceCoverage: [EvidenceKind: Double],
		threshold: Double,
		thresholdWasAutomatic: Bool,
		scoreHistogram: [Int])
	{
		self.photos = photos
		self.groups = groups
		self.links = links
		self.unassigned = unassigned
		self.usedEvidence = usedEvidence
		self.evidenceCoverage = evidenceCoverage
		self.threshold = threshold
		self.thresholdWasAutomatic = thresholdWasAutomatic
		self.scoreHistogram = scoreHistogram
	}
}

public enum PhotoGrouping
{
	/// スコア分布のヒストグラムの分割数。
	public static let histogramBins = 20

	/// 写真をグループへ分ける。入力の順序は問わない（内部で撮影順へ並べ直す）。
	public static func group(photos input: [PhotoMetadata], settings: GroupingSettings = GroupingSettings())
		-> GroupingResult
	{
		let photos = PhotoOrdering.sorted(input)
		let coverage = evidenceCoverage(photos: photos, settings: settings)
		let usable = usableEvidence(coverage: coverage, settings: settings)

		guard photos.count > 1
		else
		{
			let groups = photos.isEmpty ? [] : [PhotoGroup(id: identifier(0), members: [0])]
			return GroupingResult(
				photos: photos,
				groups: groups,
				links: [],
				unassigned: [],
				usedEvidence: EvidenceKind.allCases.filter { usable.contains($0) },
				evidenceCoverage: coverage,
				threshold: 0,
				thresholdWasAutomatic: settings.threshold == nil,
				scoreHistogram: [Int](repeating: 0, count: histogramBins))
		}

		// --- ペアの結合スコア ---
		let scored = candidatePairs(photos: photos, settings: settings).map
		{ pair in
			PairScore(
				i: pair.0,
				j: pair.1,
				score: affinity(photos[pair.0], photos[pair.1], settings: settings, usable: usable))
		}
		let histogram = ThresholdEstimator.histogram(
			values: scored.map(\.score), bins: histogramBins, lower: 0, upper: 1)
		let threshold = settings.threshold ?? automaticThreshold(scores: scored.map(\.score))

		// --- 連結成分 → 大きすぎるものを撮影の流れの切れ目で分割 ---
		var components = connectedComponents(count: photos.count, edges: scored, threshold: threshold)
		components.sort { ($0.first ?? 0) < ($1.first ?? 0) }

		var parts: [[Int]] = []
		for component in components
		{
			parts.append(contentsOf: split(
				members: component,
				edges: scored,
				maxPerGroup: max(2, settings.maxPerGroup),
				minPerGroup: max(1, min(settings.minPerGroup, settings.maxPerGroup / 3))))
		}
		parts.sort { ($0.first ?? 0) < ($1.first ?? 0) }

		// --- 小さすぎるグループの吸収 ---
		let absorbed = absorbSmallGroups(
			parts: parts, edges: scored, settings: settings)
		let groups = absorbed.parts.enumerated().map
		{ index, members in
			PhotoGroup(id: identifier(index), members: members)
		}

		let links = buildLinks(groups: groups, edges: scored, settings: settings)

		return GroupingResult(
			photos: photos,
			groups: groups,
			links: links,
			unassigned: absorbed.unassigned.sorted(),
			usedEvidence: EvidenceKind.allCases.filter { usable.contains($0) },
			evidenceCoverage: coverage,
			threshold: threshold,
			thresholdWasAutomatic: settings.threshold == nil,
			scoreHistogram: histogram)
	}

	/// group-01 形式の識別子。100 グループを超えても桁が増えるだけで壊れない。
	public static func identifier(_ index: Int) -> String
	{
		String(format: "group-%02d", index + 1)
	}

	// -----------------------------------------------------------------
	// 証拠
	// -----------------------------------------------------------------

	/// 証拠ごとに「その項目を持つ写真の割合」を数える。
	static func evidenceCoverage(photos: [PhotoMetadata], settings: GroupingSettings)
		-> [EvidenceKind: Double]
	{
		guard !photos.isEmpty
		else
		{
			return [:]
		}
		let count = Double(photos.count)
		let trustworthy = photos.filter
		{
			$0.hasTrustworthyLocation(
				maximumAccuracy: settings.maximumGPSAccuracy,
				maximumAge: settings.maximumGPSAge)
		}
		// フォルダは「2 つ以上に分かれている」ことに意味がある。1 つしか無ければ
		// 全ペアで 1 になるだけで、何も区別しない証拠になる。
		let folders = Set(photos.map(\.sourceFolder))
		return [
			.folder: folders.count > 1 ? 1 : 0,
			.time: Double(photos.filter { $0.captureDate != nil }.count) / count,
			.sequence: Double(photos.filter { $0.sequenceNumber != nil }.count) / count,
			.gps: Double(trustworthy.count) / count,
			.altitude: Double(trustworthy.filter { $0.location?.altitude != nil }.count) / count,
			.heading: Double(photos.filter { $0.heading != nil }.count) / count,
			.exposure: Double(photos.filter { $0.exposureValue != nil }.count) / count,
			.visual: Double(photos.filter { $0.fingerprint != nil }.count) / count,
		]
	}

	/// 実際に使う証拠を決める。半分以上の写真が持っていない項目は、あるペアと
	/// 無いペアで尺度が変わってしまうので使わない。
	static func usableEvidence(coverage: [EvidenceKind: Double], settings: GroupingSettings)
		-> Set<EvidenceKind>
	{
		var usable = Set<EvidenceKind>()
		for kind in EvidenceKind.allCases
		{
			guard (settings.weights[kind] ?? 0) > 0
			else
			{
				continue
			}
			if (coverage[kind] ?? 0) >= settings.minimumEvidenceCoverage
			{
				usable.insert(kind)
			}
		}
		// 連番は時刻の代役。時刻が使えるなら混ぜない（連番は撮影順の粗い写しで、
		// 時刻より情報が少ないうえフォルダをまたぐと意味が変わる）。
		if usable.contains(.time)
		{
			usable.remove(.sequence)
		}
		return usable
	}

	/// 2 枚の結合スコア（0.0〜1.0）。使える証拠だけを重み付き平均する。
	static func affinity(
		_ a: PhotoMetadata,
		_ b: PhotoMetadata,
		settings: GroupingSettings,
		usable: Set<EvidenceKind>) -> Double
	{
		var weighted = 0.0
		var total = 0.0
		func add(_ kind: EvidenceKind, _ similarity: Double)
		{
			guard usable.contains(kind), let weight = settings.weights[kind], weight > 0
			else
			{
				return
			}
			weighted += weight * similarity
			total += weight
		}

		add(.folder, a.sourceFolder == b.sourceFolder ? 1 : 0)

		if let left = a.captureDate, let right = b.captureDate
		{
			add(.time, exp(-abs(left.timeIntervalSince(right)) / max(1, settings.timeGap)))
		}
		if let left = a.sequenceNumber, let right = b.sequenceNumber
		{
			add(.sequence, exp(-Double(abs(left - right)) / max(1, settings.sequenceSpan)))
		}
		if a.hasTrustworthyLocation(
			maximumAccuracy: settings.maximumGPSAccuracy, maximumAge: settings.maximumGPSAge),
			b.hasTrustworthyLocation(
				maximumAccuracy: settings.maximumGPSAccuracy, maximumAge: settings.maximumGPSAge),
			let left = a.location, let right = b.location
		{
			// 測位誤差が大きいほど「近い」と言える範囲も広がる。誤差を無視して
			// 固定半径で見ると、屋外でも同じ面の写真が繋がらなくなる。
			let accuracy = ((left.horizontalAccuracy ?? 0) + (right.horizontalAccuracy ?? 0)) / 2
			let radius = max(settings.gpsRadius, accuracy)
			add(.gps, exp(-left.horizontalDistance(to: right) / max(1, radius)))
			if let difference = left.verticalDistance(to: right)
			{
				// 高度は GPS でも数 m 揺れる。階を分ける「ゲート」にはせず、
				// 効き幅を階高の 2 倍に取って緩やかな証拠として使う。
				add(.altitude, exp(-difference / max(0.5, settings.floorHeight * 2)))
			}
		}
		if let left = a.heading, let right = b.heading
		{
			let delta = angleDifference(left, right) * Double.pi / 180
			add(.heading, (1 + cos(delta)) / 2)
		}
		if let left = a.exposureValue, let right = b.exposureValue
		{
			add(.exposure, exp(-abs(left - right) / max(0.5, settings.exposureSpan)))
		}
		if let left = a.fingerprint, let right = b.fingerprint
		{
			add(.visual, exp(-left.normalizedDistance(to: right) / max(0.01, settings.visualSpan)))
		}

		guard total > 0
		else
		{
			return 0
		}
		return weighted / total
	}

	/// 2 つの方位の差（0〜180 度）。
	static func angleDifference(_ a: Double, _ b: Double) -> Double
	{
		let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
		return difference > 180 ? 360 - difference : difference
	}

	// -----------------------------------------------------------------
	// 候補ペア
	// -----------------------------------------------------------------

	/// スコアを計算するペアを選ぶ。全ペアは O(n²) で、数千枚になると現実的で
	/// なくなる（設計メモ §10-6）。撮影順の窓と、見た目が近い上位数件だけに
	/// 絞ることで O(n·(窓+K)) に落とす。**見た目の近傍を入れているのは、
	/// 一度離れた場所へ行って戻ってきた撮影を繋ぐため。**
	static func candidatePairs(photos: [PhotoMetadata], settings: GroupingSettings) -> [(Int, Int)]
	{
		let count = photos.count
		var seen = Set<Int>()
		var result: [(Int, Int)] = []
		func add(_ first: Int, _ second: Int)
		{
			let low = min(first, second)
			let high = max(first, second)
			guard low != high
			else
			{
				return
			}
			if seen.insert(low * count + high).inserted
			{
				result.append((low, high))
			}
		}

		let window = max(1, settings.neighborWindow)
		for index in 0 ..< count
		{
			for other in (index + 1) ..< min(count, index + 1 + window)
			{
				add(index, other)
			}
		}

		if settings.visualNeighbors > 0
		{
			for index in 0 ..< count
			{
				guard let hash = photos[index].fingerprint
				else
				{
					continue
				}
				var best: [(distance: Int, index: Int)] = []
				for other in 0 ..< count where other != index
				{
					guard let candidate = photos[other].fingerprint
					else
					{
						continue
					}
					let distance = hash.distance(to: candidate)
					if best.count >= settings.visualNeighbors,
						distance >= best[best.count - 1].distance
					{
						continue
					}
					// 小さな整列済み配列への挿入。同点は先に見つけたほう
					// （＝添字が小さいほう）を優先し、結果を決定的にする。
					var position = best.count
					while position > 0, best[position - 1].distance > distance
					{
						position -= 1
					}
					best.insert((distance, other), at: position)
					if best.count > settings.visualNeighbors
					{
						best.removeLast()
					}
				}
				for entry in best
				{
					add(index, entry.index)
				}
			}
		}

		return result.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
	}

	// -----------------------------------------------------------------
	// 閾値・連結成分・分割
	// -----------------------------------------------------------------

	/// 結合スコアの閾値を分布から決める（設計メモ §10-5「固定の既定値を持たない」）。
	///
	/// 谷がはっきりしていればそこで切る。1 つの山しか無いとき（=一続きの撮影）は
	/// **切りすぎない側へ倒す**。大きすぎるグループは枚数で必ず割れるが、切って
	/// しまった隣接は取り戻せないため。
	static func automaticThreshold(scores: [Double]) -> Double
	{
		guard !scores.isEmpty
		else
		{
			return 0
		}
		if let estimate = ThresholdEstimator.otsu(values: scores), estimate.separability >= 0.5
		{
			return min(0.8, max(0.15, estimate.threshold))
		}
		return max(0.15, ThresholdEstimator.percentile(scores, 0.2) ?? 0.15)
	}

	/// 閾値以上のエッジで連結成分を作る（union-find）。
	static func connectedComponents(count: Int, edges: [PairScore], threshold: Double) -> [[Int]]
	{
		var parent = Array(0 ..< count)
		func find(_ value: Int) -> Int
		{
			var root = value
			while parent[root] != root
			{
				parent[root] = parent[parent[root]]
				root = parent[root]
			}
			return root
		}
		for edge in edges where edge.score >= threshold
		{
			let left = find(edge.i)
			let right = find(edge.j)
			if left != right
			{
				parent[max(left, right)] = min(left, right)
			}
		}
		var buckets: [Int: [Int]] = [:]
		for index in 0 ..< count
		{
			buckets[find(index), default: []].append(index)
		}
		return buckets.values.map { $0.sorted() }
	}

	/// 大きすぎるグループを「撮影の流れの最も弱い切れ目」で二分し、上限以下に
	/// なるまで繰り返す。
	///
	/// 切れ目は、撮影順に並べたときにその位置をまたぐエッジの重みの合計が最小に
	/// なる場所。**部屋を移るときに立ち止まれば、そこがそのまま最小になる**
	/// （撮影ガイド §12-2 が効くのはここ）。守られていなくても必ずどこかで切れる
	/// ので、撮影が推奨から外れていても破綻しない。
	static func split(members: [Int], edges: [PairScore], maxPerGroup: Int, minPerGroup: Int)
		-> [[Int]]
	{
		guard members.count > maxPerGroup
		else
		{
			return [members]
		}
		let positions = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1, $0) })
		// 位置 p と p+1 の間をまたぐエッジの重み合計。差分配列で一度に求める。
		var crossing = [Double](repeating: 0, count: members.count)
		for edge in edges
		{
			guard let left = positions[edge.i], let right = positions[edge.j]
			else
			{
				continue
			}
			let low = min(left, right)
			let high = max(left, right)
			guard high > low
			else
			{
				continue
			}
			// エッジは位置 low 〜 high-1 の切れ目をまたぐ。差分配列なので
			// 始点で足して終点で引く（high は必ず配列内）。
			crossing[low] += edge.score
			crossing[high] -= edge.score
		}
		var running = 0.0
		var weights = [Double](repeating: 0, count: members.count)
		for index in 0 ..< members.count
		{
			running += crossing[index]
			weights[index] = running
		}

		// 端に寄りすぎた切れ目は避ける（1 枚だけのグループを作らない）。
		let margin = max(1, min(minPerGroup, members.count / 4))
		let lower = margin - 1
		let upper = members.count - margin - 1
		guard lower <= upper
		else
		{
			return [members]
		}
		var bestPosition = lower
		var bestWeight = Double.infinity
		let center = Double(members.count - 1) / 2
		for position in lower ... upper
		{
			let weight = weights[position]
			// 同点なら中央に近いほうを選ぶ。誤差の連鎖を抑えるため木を浅く
			// したい（設計メモ §5.4）。
			if weight < bestWeight - 1e-9
				|| (abs(weight - bestWeight) <= 1e-9
					&& abs(Double(position) - center) < abs(Double(bestPosition) - center))
			{
				bestWeight = weight
				bestPosition = position
			}
		}

		let head = Array(members[0 ... bestPosition])
		let tail = Array(members[(bestPosition + 1)...])
		return split(members: head, edges: edges, maxPerGroup: maxPerGroup, minPerGroup: minPerGroup)
			+ split(members: tail, edges: edges, maxPerGroup: maxPerGroup, minPerGroup: minPerGroup)
	}

	/// 小さすぎるグループを、最も結び付きの強い隣へ吸収する。吸収できなければ
	/// `_unassigned` へ送る（黙って混ぜない）。
	static func absorbSmallGroups(
		parts: [[Int]],
		edges: [PairScore],
		settings: GroupingSettings) -> (parts: [[Int]], unassigned: [Int])
	{
		guard parts.count > 1
		else
		{
			return (parts, [])
		}
		var result = parts
		var unassigned: [Int] = []
		var changed = true
		while changed
		{
			changed = false
			// 最後の 1 つは吸収も除去もしない。写真が下限に満たない現場でも
			// 「全部が _unassigned」になっては仕分けの意味が無いため。
			guard result.count > 1,
				let index = result.firstIndex(where: { $0.count < settings.minPerGroup })
			else
			{
				break
			}
			let small = result[index]
			var membership: [Int: Int] = [:]
			for (position, part) in result.enumerated()
			{
				for member in part
				{
					membership[member] = position
				}
			}
			var strength: [Int: Double] = [:]
			for edge in edges
			{
				guard let left = membership[edge.i], let right = membership[edge.j], left != right
				else
				{
					continue
				}
				if left == index
				{
					strength[right, default: 0] += edge.score
				}
				else if right == index
				{
					strength[left, default: 0] += edge.score
				}
			}
			let target = strength
				.filter { result[$0.key].count + small.count <= settings.maxPerGroup }
				.max { left, right in
					left.value == right.value ? left.key > right.key : left.value < right.value
				}?.key
			if let target
			{
				result[target] = (result[target] + small).sorted()
				result.remove(at: index)
				changed = true
			}
			else
			{
				unassigned.append(contentsOf: small)
				result.remove(at: index)
				changed = true
			}
		}
		result.sort { ($0.first ?? 0) < ($1.first ?? 0) }
		return (result, unassigned)
	}

	/// グループ間の隣接を作る。**閾値を下回ったエッジも含める**のが要点で、
	/// 切れ目をまたぐ写真こそが合成の対応点になる（設計メモ §4.4）。
	static func buildLinks(groups: [PhotoGroup], edges: [PairScore], settings: GroupingSettings)
		-> [GroupLink]
	{
		guard groups.count > 1
		else
		{
			return []
		}
		var membership: [Int: Int] = [:]
		for (index, group) in groups.enumerated()
		{
			for member in group.members
			{
				membership[member] = index
			}
		}
		var buckets: [Int: [PairScore]] = [:]
		for edge in edges
		{
			guard let left = membership[edge.i], let right = membership[edge.j], left != right
			else
			{
				continue
			}
			// エッジの向きをグループの順（a < b）に揃えておくと、共有写真を
			// 選ぶ側で「どちらの側の写真か」を素直に判定できる。
			let ordered = left < right
				? edge
				: PairScore(i: edge.j, j: edge.i, score: edge.score)
			buckets[min(left, right) * groups.count + max(left, right), default: []].append(ordered)
		}

		var all: [GroupLink] = []
		for (key, candidates) in buckets
		{
			let sorted = candidates.sorted
			{
				$0.score == $1.score ? ($0.i == $1.i ? $0.j < $1.j : $0.i < $1.i) : $0.score > $1.score
			}
			let top = sorted.prefix(5)
			let confidence = top.isEmpty ? 0 : top.map(\.score).reduce(0, +) / Double(top.count)
			all.append(GroupLink(
				a: key / groups.count,
				b: key % groups.count,
				confidence: confidence,
				candidates: sorted))
		}
		all.sort
		{
			$0.confidence == $1.confidence
				? ($0.a == $1.a ? $0.b < $1.b : $0.a < $1.a)
				: $0.confidence > $1.confidence
		}

		// 各グループが持つ隣接を上位のみに絞る（総当たりだと共有写真が増えすぎる）。
		var counts = [Int](repeating: 0, count: groups.count)
		var kept: [GroupLink] = []
		for link in all
		{
			guard counts[link.a] < settings.maxLinksPerGroup,
				counts[link.b] < settings.maxLinksPerGroup
			else
			{
				continue
			}
			counts[link.a] += 1
			counts[link.b] += 1
			kept.append(link)
		}
		kept.sort { $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }
		return kept
	}
}
