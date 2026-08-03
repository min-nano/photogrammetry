//
//  OverlapGraph.swift
//
//  「どの 2 枚が実際に重なって写っているか」の集合と、限られた確認回数を
//  どのペアに使うかを決める純ロジック（設計メモ §4.9）。Vision を叩くのは
//  `ImageRegistrar`、画素から一致度を測るのは `OverlapMeasurement` の仕事で、
//  ここは**測った結果と、次に何を測るか**だけを扱う。
//
//  **なぜグループ分けの一次証拠にできるか。** 測っているのが**再構成が成立する
//  条件そのもの**（同じ面が両方に写っているか）だから。時刻・GPS・露出・
//  feature print の距離はどれもその推定でしかなく、しかも尺度が現場ごとにずれる。
//
//  **ただし「どう測るか」で結果はまるで変わる。** 重なり範囲全体の相関で判定して
//  いた最初の版は、実データ 1424 枚で分布に谷が出ず、隣り合う写真の 45% しか
//  拾えなかった（設計メモ §4.9.1）。1 枚の射影変換は平面しか記述できないので、
//  視差のある 2 枚では本当に重なっていても相関が落ちるため。いまはブロックごとの
//  局所一致（インライア率）で判定する — 視差はブロック単位の小さなずれとして
//  現れるので、探せば見つかる。
//
//  **問題はコストだけ。** 1424 枚なら全ペアは 101 万組で、1 組ごとにデコードと
//  Vision の推論が走る以上そのままでは回らない。そこで EXIF（撮影の流れ）を
//  **重なりの事前確率**として使い、限られた回数を当たりやすい順に、かつ
//  「答えが変わる組」から配る。これが「EXIF は主に処理効率の向上に使う」の実装形。
//

import Foundation

/// どこから「重なっている」と言うか。**判断はここ 1 か所**で、ラッパー
/// （`ImageRegistrar`）は数値を返すだけ（設計メモ §4.6.1 の層の分け方）。
public struct OverlapCriteria: Equatable, Sendable
{
	/// 局所的に一致し、かつずれ方が揃っていたブロックの割合の下限。
	///
	/// **判定はこれで行う（設計メモ §4.9.1）。** 当初は重なり範囲全体の相関
	/// （`PhotoOverlap.agreement`）で判定していたが、実データ 1424 枚で分布に
	/// 谷が出ず、隣り合う写真の 45% しか拾えなかった。1 枚の射影変換は平面しか
	/// 記述できないので、視差のある 2 枚では本当に重なっていても全体の相関が
	/// 落ちるため。ブロック単位なら視差は小さなずれとして現れるので拾える。
	public var minimumInlierRatio: Double
	/// 重なりの広さ（基準画像の面積比）の下限。帯のように少ししか重なっていない
	/// 組は対応点にならない。
	public var minimumSharedArea: Double
	/// 一致して揃っていたブロック数の下限（**割合ではなく実数**）。
	///
	/// 割合だけを課すと「判定に使えたブロックが 6 つで 2 つ揃えば 0.33」が通って
	/// しまう。絵のごく一部がたまたま合っただけの組がここを抜けると、無関係な
	/// 場所どうしが繋がる。格子は 8×6 なので、重なりが広ければ揃うブロックは
	/// 必ずこれ以上ある。
	public var minimumCoherentBlocks: Int

	public init(
		minimumInlierRatio: Double = 0.3,
		minimumSharedArea: Double = 0.15,
		minimumCoherentBlocks: Int = 6)
	{
		self.minimumInlierRatio = minimumInlierRatio
		self.minimumSharedArea = minimumSharedArea
		self.minimumCoherentBlocks = minimumCoherentBlocks
	}

	/// 測った重なりを 3 つのどれかに振り分ける。
	public func judge(_ overlap: PhotoOverlap?) -> OverlapVerdict
	{
		guard let overlap
		else
		{
			return .undecided
		}
		guard overlap.inlierRatio >= minimumInlierRatio,
			overlap.sharedArea >= minimumSharedArea,
			overlap.coherentBlocks >= minimumCoherentBlocks
		else
		{
			return .separate(overlap)
		}
		return .overlapping(overlap)
	}
}

/// 1 組を確かめた結果。**「重なっていない」と「判定できなかった」を混ぜない**のが
/// この型の存在理由で、前者は積極的な拒否（グループを切る根拠になる）、後者は
/// 何も言えないという意味（候補を落とす理由にしてはいけない）。
public enum OverlapVerdict: Equatable, Sendable
{
	case overlapping(PhotoOverlap)
	case separate(PhotoOverlap)
	/// 模様が無さすぎる・読めない。§4.6.1 の「落とさない」対象。
	case undecided

	public var isOverlapping: Bool
	{
		if case .overlapping = self
		{
			return true
		}
		return false
	}

	/// 測れた重なり（判定できなかったときは nil）。
	public var overlap: PhotoOverlap?
	{
		switch self
		{
			case .overlapping(let value), .separate(let value):
				return value
			case .undecided:
				return nil
		}
	}
}

/// 実際に確かめた重なりの集合。**測っていない組と、測って重なっていなかった組を
/// 区別して持つ**（前者は無言、後者は拒否）。
public struct OverlapGraph: Equatable, Sendable
{
	/// ヒストグラムの分割数（他の統計と揃える）。
	public static let histogramBins = 20

	/// 添字の上限（`PhotoGrouping` の `photos` の枚数）。
	public var photoCount: Int
	/// 判定に使った基準。manifest に載せて再現できるようにする。
	public var criteria: OverlapCriteria
	/// 確かめた組。キーは `key(i, j)`。
	public var verdicts: [Int: OverlapVerdict]
	/// 確かめた回数（＝`verdicts` の件数。予算との対比で診断に使う）。
	public var checked: Int
	/// 使ってよい回数の上限。
	public var budget: Int
	/// 骨格として確かめた「撮影順で前後何枚まで」。的中率を出すのに要る。
	public var chainWindow: Int
	/// 上限を使い切ったか。**使い切ったなら見落とした繋がりがありうる**ので、
	/// 診断で必ず伝える（設計メモ §4.9）。
	public var budgetExhausted: Bool

	public init(
		photoCount: Int,
		criteria: OverlapCriteria = OverlapCriteria(),
		verdicts: [Int: OverlapVerdict] = [:],
		checked: Int = 0,
		budget: Int = 0,
		chainWindow: Int = 1,
		budgetExhausted: Bool = false)
	{
		self.chainWindow = chainWindow
		self.photoCount = photoCount
		self.criteria = criteria
		self.verdicts = verdicts
		self.checked = checked
		self.budget = budget
		self.budgetExhausted = budgetExhausted
	}

	/// 組を 1 つの整数へ潰す。**必ず小さいほうを先に**（向きを持たない関係なので）。
	public static func key(_ a: Int, _ b: Int, photoCount: Int) -> Int
	{
		min(a, b) * photoCount + max(a, b)
	}

	func key(_ a: Int, _ b: Int) -> Int
	{
		Self.key(a, b, photoCount: photoCount)
	}

	/// 確かめた結果を引く。**nil は「確かめていない」**（`.undecided` とは違う）。
	public func verdict(_ a: Int, _ b: Int) -> OverlapVerdict?
	{
		verdicts[key(a, b)]
	}

	/// 実際に重なっていると確かめた組数。
	public var overlappingCount: Int
	{
		verdicts.values.filter(\.isOverlapping).count
	}

	/// 重なっていないと確かめた組数。
	public var separateCount: Int
	{
		verdicts.values.filter
		{
			if case .separate = $0
			{
				return true
			}
			return false
		}.count
	}

	/// 判定できなかった組数。
	public var undecidedCount: Int
	{
		verdicts.values.filter { $0 == .undecided }.count
	}

	/// **判定できた組が 1 つでもあるか。** 1 つも無ければ確認そのものが答えを
	/// 出せていないので、呼び出し側は合算スコアへ戻る（設計メモ §4.9 末尾）。
	public var isUsable: Bool
	{
		verdicts.values.contains { $0 != .undecided }
	}

	/// グループ分けに渡すエッジ。**重なっていない組もスコア 0 のエッジとして残す**
	/// のが要点で、切れ目の判定では「そこは本当に切れている」という最も強い証拠に
	/// なる。判定できなかった組はエッジにしない（何も言えないため）。
	public func edges() -> [PairScore]
	{
		verdicts.compactMap
		{ key, verdict -> PairScore? in
			let i = key / photoCount
			let j = key % photoCount
			switch verdict
			{
				case .overlapping(let overlap):
					return PairScore(i: i, j: j, score: overlap.inlierRatio)
				case .separate:
					return PairScore(i: i, j: j, score: 0)
				case .undecided:
					return nil
			}
		}.sorted { $0.i == $1.i ? $0.j < $1.j : $0.i < $1.i }
	}

	/// 写真 1 枚ごとの「重なっていると確かめた相手の数」の分布。**写真そのものを
	/// 含まない統計**なので、現場の写真を共有せずに設定を検討できる（§10-10）。
	/// 添字 0 は「どの写真とも重ならなかった」。
	public func degreeHistogram(maximum: Int = 16) -> [Int]
	{
		var degrees = [Int](repeating: 0, count: photoCount)
		for (key, verdict) in verdicts where verdict.isOverlapping
		{
			degrees[key / photoCount] += 1
			degrees[key % photoCount] += 1
		}
		var histogram = [Int](repeating: 0, count: max(1, maximum) + 1)
		for degree in degrees
		{
			histogram[min(degree, maximum)] += 1
		}
		return histogram
	}

	/// **判定に使ったインライア率**の分布（0.0〜1.0 を 20 分割）。閾値が妥当
	/// だったかを写真なしで見直すための材料で、**山が 2 つに割れていれば判定は
	/// 効いている**。判定できなかった組は含まない。
	public func inlierHistogram() -> [Int]
	{
		ThresholdEstimator.histogram(
			values: verdicts.values.compactMap { $0.overlap?.inlierRatio },
			bins: Self.histogramBins,
			lower: 0,
			upper: 1)
	}

	/// 重なり範囲**全体**の相関の分布。**判定には使っていない**が、新旧の測り方を
	/// 比べられるように残す（設計メモ §4.9.1）。
	public func agreementHistogram() -> [Int]
	{
		ThresholdEstimator.histogram(
			values: verdicts.values.compactMap { $0.overlap?.agreement },
			bins: Self.histogramBins,
			lower: 0,
			upper: 1)
	}

	/// **骨格の的中率** — 撮影順で隣り合う組のうち、実際に重なっていると判定
	/// できた割合。歩きながら撮れば隣の 2 枚はまず重なるので、**測り方が効いて
	/// いるかがこの 1 つの数字で分かる**（低ければ取りこぼしている）。
	/// 隣り合う組を 1 つも測っていなければ nil。
	public func chainHitRate() -> Double?
	{
		var decided = 0
		var overlapping = 0
		for (key, verdict) in verdicts where verdict != .undecided
		{
			guard key % photoCount - key / photoCount <= max(1, chainWindow)
			else
			{
				continue
			}
			decided += 1
			if verdict.isOverlapping
			{
				overlapping += 1
			}
		}
		guard decided > 0
		else
		{
			return nil
		}
		return Double(overlapping) / Double(decided)
	}

	/// どの写真とも重なりを確かめられなかった写真の添字。**確かめた相手が 1 人も
	/// 居ない写真は含めない** — 予算外だっただけで「重なっていない」わけではない。
	public func photosWithoutOverlap() -> [Int]
	{
		var overlapping = [Bool](repeating: false, count: photoCount)
		var attempted = [Bool](repeating: false, count: photoCount)
		for (key, verdict) in verdicts
		{
			let i = key / photoCount
			let j = key % photoCount
			guard verdict != .undecided
			else
			{
				continue
			}
			attempted[i] = true
			attempted[j] = true
			if verdict.isOverlapping
			{
				overlapping[i] = true
				overlapping[j] = true
			}
		}
		return (0 ..< photoCount).filter { attempted[$0] && !overlapping[$0] }
	}
}

/// 限られた確認回数をどのペアに使うかを決める（設計メモ §4.9「予算の配り方」）。
///
/// **判断だけを持つ純ロジック。** 実際の位置合わせは `probe` の向こう側で、
/// テストではスタブに差し替えて「予算の配り方」そのものを固定できる。
public enum OverlapSurvey
{
	public struct Settings: Equatable, Sendable
	{
		/// 骨格として撮影順で前後この枚数までの全組を確かめる。**切れ目の判定
		/// （§4.3 の最弱シーム）に要る密度もここで決まる** — どの位置も同じ本数が
		/// またぐので、実データで問題になった位置ごとの偏りが構成上生じない。
		public var chainWindow: Int
		/// 骨格が切れた位置の周りだけ、ここまで広げて確かめる。**1 枚だけ被写体が
		/// 変わったのか、本当に場所が変わったのか**を見分けるために要る。
		public var seamProbeWindow: Int
		/// 写真 1 枚あたりの確認回数（予算を指定しないときの既定）。
		public var checksPerPhoto: Int
		/// 総予算。nil なら `checksPerPhoto × 枚数`。
		public var budget: Int?
		/// 事前確率の高い組を確かめる段で、1 枚が持てる本数の上限。
		public var candidatesPerPhoto: Int
		/// 1 度にまとめて渡す組数。実装（Vision）が並行に処理できる粒度で、
		/// 小さいほど「同じ成分に入った組を落とす」が細かく効く。
		public var batchSize: Int
		/// どこから「重なっている」と言うか。
		public var criteria: OverlapCriteria

		public init(
			chainWindow: Int = 4,
			seamProbeWindow: Int = 8,
			checksPerPhoto: Int = 16,
			budget: Int? = nil,
			candidatesPerPhoto: Int = 8,
			batchSize: Int = 64,
			criteria: OverlapCriteria = OverlapCriteria())
		{
			self.chainWindow = chainWindow
			self.seamProbeWindow = seamProbeWindow
			self.checksPerPhoto = checksPerPhoto
			self.budget = budget
			self.candidatesPerPhoto = candidatesPerPhoto
			self.batchSize = batchSize
			self.criteria = criteria
		}
	}

	/// 候補の組が実際に重なっているかを確かめる役。**まとめて渡す**のは実装
	/// （デコードと Vision）が並行に処理できるようにするため。返り値は渡した
	/// 並びと同じ長さで、nil は「判定できなかった」。
	public typealias Probe = @Sendable ([OverlapQuery]) -> [PhotoOverlap?]

	/// 予算の範囲で重なりを確かめ、グラフを作る。
	///
	/// - Parameters:
	///   - urls: 撮影順に並んだ写真。添字がそのままグラフの添字になる。
	///   - prior: 事前確率つきの候補（＝合算スコア）。骨格で足りない繋がりを
	///     どの順に探すかにだけ使う。**繋ぐかどうかの判断には使わない。**
	///   - progress: 確かめた回数と予算。数分かかる段なので進捗を出す。
	public static func survey(
		urls: [URL],
		prior: [PairScore],
		settings: Settings = Settings(),
		isCancelled: () -> Bool = { false },
		progress: (Int, Int) -> Void = { _, _ in },
		probe: Probe) -> OverlapGraph
	{
		let count = urls.count
		let budget = max(0, settings.budget ?? count * max(1, settings.checksPerPhoto))
		var graph = OverlapGraph(
			photoCount: count,
			criteria: settings.criteria,
			budget: budget,
			chainWindow: max(1, settings.chainWindow))
		guard count > 1, budget > 0
		else
		{
			return graph
		}

		/// 1 束ぶん確かめてグラフへ入れる。**予算を超えては呼ばない。**
		/// 中断されたときは記録せずに false を返す（中断を「判定できなかった」に
		/// すり替えると、以降の段が「模様の無い現場」と取り違える）。
		func run(_ pairs: [(Int, Int)]) -> Bool
		{
			guard !pairs.isEmpty, !isCancelled()
			else
			{
				return false
			}
			let results = probe(pairs.map { OverlapQuery(a: urls[$0.0], b: urls[$0.1]) })
			guard !isCancelled()
			else
			{
				return false
			}
			for (offset, pair) in pairs.enumerated()
			{
				let measured = results.indices.contains(offset) ? results[offset] : nil
				graph.verdicts[OverlapGraph.key(pair.0, pair.1, photoCount: count)] =
					settings.criteria.judge(measured)
			}
			graph.checked = graph.verdicts.count
			progress(graph.checked, budget)
			return true
		}

		/// 予算の残りに合わせて束へ切り出し、順に確かめる。
		func consume(_ pairs: [(Int, Int)]) -> Bool
		{
			var cursor = 0
			let size = max(1, settings.batchSize)
			while cursor < pairs.count
			{
				let remaining = budget - graph.checked
				guard remaining > 0
				else
				{
					graph.budgetExhausted = true
					return false
				}
				let upper = min(pairs.count, cursor + min(size, remaining))
				guard run(Array(pairs[cursor ..< upper]))
				else
				{
					return false
				}
				cursor = upper
			}
			return true
		}

		// --- 1. 骨格 ---
		// 近い組から先に並べる。予算が尽きても「隣り合う 2 枚」だけは全体に
		// 行き渡るようにするため（そこが最も当たりやすく、最も要る）。
		guard consume(chainPairs(count: count, window: settings.chainWindow))
		else
		{
			return graph
		}

		// **骨格が 1 組も判定できなかったら、そこで止める。** 模様の無い写真ばかり・
		// 読めない形式ばかりの現場では、この先どれだけ測っても答えは出ない。
		// 呼び出し側は合算スコアへ戻るので、残りの予算は 1 組も使わずに返すのが正しい
		// （数千枚ぶんのデコードを黙って空振りさせない）。
		guard graph.isUsable
		else
		{
			return graph
		}

		// --- 2. 切れ目の補強 ---
		guard consume(seamProbePairs(count: count, graph: graph, settings: settings))
		else
		{
			return graph
		}

		// --- 3. 繋がりうる組（まだ別々の連結成分にいる組だけ）---
		// 事前確率の高い順。同点は添字順で並べて結果を決定的にする。
		var remaining = prior.filter
		{
			graph.verdicts[OverlapGraph.key($0.i, $0.j, photoCount: count)] == nil
		}.sorted
		{
			$0.score == $1.score ? ($0.i == $1.i ? $0.j < $1.j : $0.i < $1.i) : $0.score > $1.score
		}
		var used = [Int](repeating: 0, count: count)
		while !remaining.isEmpty, graph.checked < budget
		{
			let batch = informativeBatch(
				remaining: &remaining,
				used: &used,
				graph: graph,
				settings: settings,
				budget: budget)
			guard !batch.isEmpty, consume(batch)
			else
			{
				break
			}
		}
		if graph.checked >= budget
		{
			graph.budgetExhausted = true
		}
		return graph
	}

	/// 骨格の組。撮影順で距離 1 の全組 → 距離 2 の全組 → … の順に並べる。
	static func chainPairs(count: Int, window: Int) -> [(Int, Int)]
	{
		var pairs: [(Int, Int)] = []
		for distance in 1 ... max(1, window)
		{
			for index in 0 ..< max(0, count - distance)
			{
				pairs.append((index, index + distance))
			}
		}
		return pairs
	}

	/// 骨格が切れた位置の周りを広げて確かめる組。
	///
	/// 「切れた位置」は、位置 p と p+1 の間をまたぐ骨格の組のうち **1 組も重なって
	/// いなかった**ところ。1 枚だけ被写体が変わっただけなら、その 1 枚を飛び越えた
	/// 組（距離 5〜8）が重なるので繋がり直す。本当に場所が変わったならどれも
	/// 重ならず、切れ目としての確信が上がる。
	static func seamProbePairs(count: Int, graph: OverlapGraph, settings: Settings)
		-> [(Int, Int)]
	{
		let window = max(1, settings.chainWindow)
		let outer = max(window, settings.seamProbeWindow)
		guard outer > window
		else
		{
			return []
		}
		// 位置 p をまたぐ骨格の組に「重なっている」が 1 つでもあるか。
		var connected = [Bool](repeating: false, count: max(0, count - 1))
		for (key, verdict) in graph.verdicts where verdict.isOverlapping
		{
			let low = key / count
			let high = key % count
			guard high - low <= window
			else
			{
				continue
			}
			for position in low ..< min(high, connected.count)
			{
				connected[position] = true
			}
		}

		var seen = Set<Int>()
		var pairs: [(Int, Int)] = []
		for position in 0 ..< connected.count where !connected[position]
		{
			for distance in (window + 1) ... outer
			{
				// 位置 position をまたぐ組は low <= position < low + distance。
				let lowest = max(0, position - distance + 1)
				let highest = min(position, count - 1 - distance)
				guard lowest <= highest
				else
				{
					continue
				}
				for low in lowest ... highest
				{
					let key = OverlapGraph.key(low, low + distance, photoCount: count)
					guard graph.verdicts[key] == nil, seen.insert(key).inserted
					else
					{
						continue
					}
					pairs.append((low, low + distance))
				}
			}
		}
		return pairs
	}

	/// 次に確かめる 1 束を選ぶ。**まだ別々の連結成分にいる組だけ**を採る。
	///
	/// 呼ばれるたびに連結成分を数え直し、既に繋がった組を候補から落とす。
	/// **答えが変わらない組に予算を使わない**ための仕掛けで、これが「一度離れて
	/// 戻ってきた撮影を繋ぐ」（合成でいうループ閉じ込み）を予算内で拾う経路になる。
	///
	/// - Parameter remaining: 未確認の候補（事前確率の高い順）。**採った組と、
	///   もう意味の無い組をここから取り除く。**
	/// - Parameter used: 写真ごとに何本この段で使ったか。
	static func informativeBatch(
		remaining: inout [PairScore],
		used: inout [Int],
		graph: OverlapGraph,
		settings: Settings,
		budget: Int) -> [(Int, Int)]
	{
		let count = graph.photoCount
		var components = ComponentTracker(count: count)
		for edge in graph.edges() where edge.score >= settings.criteria.minimumInlierRatio
		{
			components.union(edge.i, edge.j)
		}
		// **束の中でも成分を繋いでいく。** 同じ 2 つの成分を橋渡しする組を何本も
		// 同じ束へ入れると、1 本当たれば済むところに予算を使ってしまう。
		var pending = components
		let cap = max(1, settings.candidatesPerPhoto)
		let size = max(1, settings.batchSize)
		var batch: [(Int, Int)] = []
		var kept: [PairScore] = []

		for candidate in remaining
		{
			// **実際にもう繋がっている／本数の上限に達した組は候補から落とす。**
			// どちらも確かめても答えが変わらない。
			guard components.find(candidate.i) != components.find(candidate.j),
				used[candidate.i] < cap, used[candidate.j] < cap
			else
			{
				continue
			}
			guard batch.count < size, graph.checked + batch.count < budget
			else
			{
				kept.append(candidate)
				continue
			}
			// この束の別の組が同じ 2 つの成分を橋渡ししている。1 本当たれば済むので
			// **今回は見送るだけ**（落としはしない — その 1 本が重なっていなければ、
			// 次の周でこちらの番になる）。
			guard pending.union(candidate.i, candidate.j)
			else
			{
				kept.append(candidate)
				continue
			}
			used[candidate.i] += 1
			used[candidate.j] += 1
			batch.append((candidate.i, candidate.j))
		}
		remaining = kept
		return batch
	}
}

/// 連結成分の追跡（union-find）。`PhotoGrouping.connectedComponents` と違って
/// **繋がったかどうかを返す**ので、「この組はもう答えが変わらない」の判定に使える。
struct ComponentTracker
{
	private var parent: [Int]

	init(count: Int)
	{
		parent = Array(0 ..< max(0, count))
	}

	mutating func find(_ value: Int) -> Int
	{
		var root = value
		while parent[root] != root
		{
			parent[root] = parent[parent[root]]
			root = parent[root]
		}
		return root
	}

	/// 2 つを繋ぐ。**既に同じ成分なら false**（＝確かめても答えが変わらない）。
	@discardableResult
	mutating func union(_ a: Int, _ b: Int) -> Bool
	{
		guard a >= 0, a < parent.count, b >= 0, b < parent.count
		else
		{
			return false
		}
		let left = find(a)
		let right = find(b)
		guard left != right
		else
		{
			return false
		}
		parent[max(left, right)] = min(left, right)
		return true
	}
}
