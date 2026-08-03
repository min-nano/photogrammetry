//
//  RoomClustering.swift
//
//  視覚特徴だけを見て「どの写真が同じ場所（部屋）を写しているか」を決める純ロジック
//  （フェーズ 2）。Vision も ImageIO も import しない — 入力は FeaturePrint の
//  配列だけなので、合成ベクトルで挙動を固定できる。
//
//  **なぜ要るか。** フェーズ 1 の手がかり（時刻・GPS・露出・知覚ハッシュ）は
//  「撮影の流れ」を捉えるものばかりで、**場所そのものの同一性**は見ていない。
//  実写真で仕分けの精度が出ないのはここが理由で、
//
//    - 同じ部屋を行き来しながら撮ると、時刻が離れた写真が別グループへ分かれる
//    - 隣り合う部屋を続けて撮ると、時刻が近いだけで別の場所が 1 つになる
//
//  のどちらも起きる。feature print は**同じ場所を別の角度から撮った写真**が近く
//  なるので、この 2 つを直接是正できる。
//
//  作るのは近傍グラフの連結成分。閾値で全ペアを切るのではなく **k 近傍の相互
//  リンク**（互いに相手を上位 k 件に入れている）だけを繋ぐのが要点で、
//
//    - 部屋どうしが数枚の似た写真（白い壁・同じ建具）で数珠つなぎになりにくい
//    - 部屋の枚数が k を超えていれば、近傍は自然にその部屋の中で閉じる
//
//  という性質が出る。閾値は例によって固定せず分布から決め、**山が 1 つのとき
//  （＝一続きの場所）は切らない**側へ倒す（設計メモ §10-5 と同じ判断。切って
//  しまった隣接は取り戻せないため）。
//
//  計算量は O(n² × 次元)。設計メモ §10-6 が「フェーズ 2 で詰める」としていた点で、
//  結論は**全ペアをそのまま計算する**。数千枚でも数秒（距離は単純な内積で、
//  支配的なのは写真のデコードと Vision の推論のほう）で、近似を入れて
//  「同じ部屋を見つけそこねる」ほうが害が大きいと判断した。
//

import Foundation

/// 近傍 1 件（添字と距離）。候補ペアの選定でも使い回す。
public struct SceneNeighbor: Equatable, Sendable
{
	public var index: Int
	public var distance: Double

	public init(index: Int, distance: Double)
	{
		self.index = index
		self.distance = distance
	}
}

/// 視覚的に同一と判定した写真の集まり（＝1 つの部屋・1 つの面）。
public struct RoomCluster: Equatable, Sendable
{
	/// room-01 のような識別子。manifest と診断に出る語彙。
	public var id: String
	/// 入力配列への添字（昇順）。
	public var members: [Int]

	public init(id: String, members: [Int])
	{
		self.id = id
		self.members = members
	}
}

/// クラスタリングの結果。
public struct RoomClusteringResult: Equatable, Sendable
{
	public var clusters: [RoomCluster]
	/// 入力添字 → clusters への添字。特徴が取れなかった写真は nil。
	public var labels: [Int?]
	/// 入力添字 → 近い順の近傍。**グルーピングの候補ペアに再利用する**
	/// （同じ距離を 2 度計算しないため）。
	public var neighbors: [[SceneNeighbor]]
	/// 同じ場所とみなす距離の閾値。
	public var threshold: Double
	public var thresholdWasAutomatic: Bool
	/// 距離分布の分離度（低い＝山が 1 つ＝一続きの場所）。診断に出す。
	public var separability: Double
	/// 近傍距離の分布（0.0〜1.0 を 20 分割）。**写真そのものを含まない統計**なので、
	/// 現場の写真を共有せずに閾値を検討できる（設計メモ §10-10）。
	public var distanceHistogram: [Int]
	/// 近傍距離の中央値。**この現場で「近い」と言える距離の目安**で、絶対値の
	/// 尺度が現場ごとに違う（屋内の白い壁ばかりだと全体に詰まる）ことへの答え。
	/// 共有写真の選定はこれを基準にする。判定材料が無ければ nil。
	public var medianNeighborDistance: Double?
	/// 視覚特徴を取れた写真の割合。
	public var coverage: Double

	public init(
		clusters: [RoomCluster],
		labels: [Int?],
		neighbors: [[SceneNeighbor]],
		threshold: Double,
		thresholdWasAutomatic: Bool,
		separability: Double,
		distanceHistogram: [Int],
		medianNeighborDistance: Double? = nil,
		coverage: Double)
	{
		self.clusters = clusters
		self.labels = labels
		self.neighbors = neighbors
		self.threshold = threshold
		self.thresholdWasAutomatic = thresholdWasAutomatic
		self.separability = separability
		self.distanceHistogram = distanceHistogram
		self.medianNeighborDistance = medianNeighborDistance
		self.coverage = coverage
	}

	/// 写真 1 枚が属する部屋の識別子。判定できなければ nil。
	public func identifier(forPhoto index: Int) -> String?
	{
		guard labels.indices.contains(index), let label = labels[index]
		else
		{
			return nil
		}
		return clusters[label].id
	}
}

public enum RoomClustering
{
	/// 距離分布のヒストグラムの分割数（GroupingResult.scoreHistogram と揃える）。
	public static let histogramBins = 20

	public struct Settings: Equatable, Sendable
	{
		/// 各写真が持つ近傍の数。**部屋 1 つの枚数より十分小さく**取る
		/// （大きすぎると近傍が隣の部屋まで届き、部屋どうしが繋がる）。
		public var neighbors: Int
		/// 同じ場所とみなす距離の閾値。nil なら分布から自動決定する。
		public var threshold: Double?
		/// これを下回るクラスタは、最も近いクラスタへ吸収する。1 枚だけの
		/// 「部屋」は判断材料にならないため。
		public var minimumClusterSize: Int
		/// 判別分析の結果を採用するのに必要な分離度。
		public var requiredSeparability: Double
		/// 山が 1 つのときに使う分位点。**ほぼ全ての近傍を残す**側へ倒す。
		public var fallbackPercentile: Double
		/// 自動決定した閾値の下限・上限。推定が振り切れても極端な値にしない。
		public var minimumThreshold: Double
		public var maximumThreshold: Double

		public init(
			neighbors: Int = 8,
			threshold: Double? = nil,
			minimumClusterSize: Int = 3,
			requiredSeparability: Double = 0.5,
			fallbackPercentile: Double = 0.95,
			minimumThreshold: Double = 0.05,
			maximumThreshold: Double = 0.9)
		{
			self.neighbors = neighbors
			self.threshold = threshold
			self.minimumClusterSize = minimumClusterSize
			self.requiredSeparability = requiredSeparability
			self.fallbackPercentile = fallbackPercentile
			self.minimumThreshold = minimumThreshold
			self.maximumThreshold = maximumThreshold
		}
	}

	/// room-01 形式の識別子。
	public static func identifier(_ index: Int) -> String
	{
		String(format: "room-%02d", index + 1)
	}

	/// 視覚特徴から部屋を見つける。入力の並びは呼び出し側の順序（撮影順）を
	/// そのまま保つ — 添字がそのまま写真を指す約束。
	public static func cluster(prints: [FeaturePrint?], settings: Settings = Settings())
		-> RoomClusteringResult
	{
		let count = prints.count
		var labels = [Int?](repeating: nil, count: count)
		var neighbors = [[SceneNeighbor]](repeating: [], count: count)
		let present = (0 ..< count).filter { prints[$0] != nil }
		let coverage = count == 0 ? 0 : Double(present.count) / Double(count)
		let emptyHistogram = [Int](repeating: 0, count: histogramBins)

		// 2 枚未満では「分ける」も「繋ぐ」も意味を持たない。全部を 1 つの場所と
		// して返す（判定できないことを分割の理由にしない）。
		guard present.count >= 2
		else
		{
			var clusters: [RoomCluster] = []
			if !present.isEmpty
			{
				clusters = [RoomCluster(id: identifier(0), members: present)]
				for index in present
				{
					labels[index] = 0
				}
			}
			return RoomClusteringResult(
				clusters: clusters,
				labels: labels,
				neighbors: neighbors,
				threshold: settings.threshold ?? settings.maximumThreshold,
				thresholdWasAutomatic: settings.threshold == nil,
				separability: 0,
				distanceHistogram: emptyHistogram,
				coverage: coverage)
		}

		// --- k 近傍 ---
		let k = max(1, min(settings.neighbors, present.count - 1))
		for index in present
		{
			neighbors[index] = nearest(index, among: present, prints: prints, k: k)
		}
		let distances = present.flatMap { neighbors[$0].map(\.distance) }
		let histogram = ThresholdEstimator.histogram(
			values: distances, bins: histogramBins, lower: 0, upper: 1)
		let estimate = ThresholdEstimator.otsu(values: distances)
		let threshold = settings.threshold
			?? automaticThreshold(distances: distances, estimate: estimate, settings: settings)

		// --- 相互 k 近傍で繋ぐ ---
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
		func union(_ a: Int, _ b: Int)
		{
			let left = find(a)
			let right = find(b)
			if left != right
			{
				parent[max(left, right)] = min(left, right)
			}
		}
		for index in present
		{
			for neighbor in neighbors[index] where neighbor.distance <= threshold
			{
				// 片側だけが「近い」と言っている関係では繋がない。部屋の境目に
				// ある数枚で全体が数珠つなぎになるのを避けるため。
				guard neighbors[neighbor.index].contains(where: { $0.index == index })
				else
				{
					continue
				}
				union(index, neighbor.index)
			}
		}

		// --- 小さすぎるクラスタを最も近いクラスタへ吸収する ---
		absorbSmallClusters(
			present: present,
			neighbors: neighbors,
			find: find,
			union: union,
			minimumSize: settings.minimumClusterSize)

		// --- 撮影順（＝添字の小さい順）にクラスタを並べて識別子を振る ---
		var membersByRoot: [Int: [Int]] = [:]
		for index in present
		{
			membersByRoot[find(index), default: []].append(index)
		}
		// 並べ替えの規則はグループと同じ（先頭の添字＝撮影順で最初の写真）。
		let ordered = membersByRoot.values.map { $0.sorted() }
			.sorted(by: PhotoGrouping.startsBefore)
		var clusters: [RoomCluster] = []
		for (position, members) in ordered.enumerated()
		{
			clusters.append(RoomCluster(id: identifier(position), members: members))
			for member in members
			{
				labels[member] = position
			}
		}

		return RoomClusteringResult(
			clusters: clusters,
			labels: labels,
			neighbors: neighbors,
			threshold: threshold,
			thresholdWasAutomatic: settings.threshold == nil,
			separability: estimate?.separability ?? 0,
			distanceHistogram: histogram,
			medianNeighborDistance: ThresholdEstimator.median(distances),
			coverage: coverage)
	}

	// -----------------------------------------------------------------
	// 部品
	// -----------------------------------------------------------------

	/// 1 枚から見た近い順の上位 k 件。同点は添字の小さいほうを先にして、
	/// 結果を決定的にする。
	static func nearest(
		_ index: Int,
		among present: [Int],
		prints: [FeaturePrint?],
		k: Int) -> [SceneNeighbor]
	{
		guard let base = prints[index]
		else
		{
			return []
		}
		var best: [SceneNeighbor] = []
		for other in present where other != index
		{
			guard let candidate = prints[other]
			else
			{
				continue
			}
			let distance = base.distance(to: candidate)
			if best.count >= k, distance >= best[best.count - 1].distance
			{
				continue
			}
			var position = best.count
			while position > 0, best[position - 1].distance > distance
			{
				position -= 1
			}
			best.insert(SceneNeighbor(index: other, distance: distance), at: position)
			if best.count > k
			{
				best.removeLast()
			}
		}
		return best
	}

	/// 近傍距離の分布から閾値を決める。
	///
	/// 谷がはっきりしていればそこで切る。1 つの山しか無いとき（＝一続きの場所を
	/// 撮り歩いた）は**ほぼ全ての近傍を残す**。近傍グラフは元々その写真から見て
	/// 近い相手しか持たないので、ここで切りすぎると同じ部屋が割れてしまう。
	///
	/// **判別分析の答えは、中央値より上にあるときだけ採る。** 距離の閾値は
	/// 「低いほど切る」ので、結合スコアの閾値（`PhotoGrouping.automaticThreshold`）
	/// とは安全な向きが逆になる。近傍は元々その写真にとって最も近い相手なのだから、
	/// その半分以上を切る閾値は、それだけで同じ場所を必ず割る。実際この歯止めが
	/// 無いと、判別分析が山の裾に谷を見つけて 1 つの部屋を刻んだ（ci-debug で確認）。
	/// 切ってしまった繋がりは取り戻せない、という §4.3 と同じ判断。
	static func automaticThreshold(
		distances: [Double],
		estimate: ThresholdEstimator.Estimate?,
		settings: Settings) -> Double
	{
		func clamp(_ value: Double) -> Double
		{
			min(settings.maximumThreshold, max(settings.minimumThreshold, value))
		}
		let median = ThresholdEstimator.median(distances)
		if let estimate, let median,
			estimate.separability >= settings.requiredSeparability,
			estimate.threshold > median
		{
			return clamp(estimate.threshold)
		}
		// 谷が無い（一続きの場所）か、谷が低すぎて信用できない。どちらも
		// **ほぼ全ての近傍を残す**側へ倒す。
		guard let percentile = ThresholdEstimator.percentile(distances, settings.fallbackPercentile)
		else
		{
			return settings.maximumThreshold
		}
		return clamp(percentile)
	}

	/// 小さすぎるクラスタを、最も近い（近傍距離が最小の）クラスタへ吸収する。
	///
	/// 吸収先が無いクラスタは**そのまま残す**（黙って消さない）。1 回の反復で
	/// 必ず「併合が 1 つ進む」か「これ以上動かせない印が 1 つ増える」ので必ず止まる。
	static func absorbSmallClusters(
		present: [Int],
		neighbors: [[SceneNeighbor]],
		find: (Int) -> Int,
		union: (Int, Int) -> Void,
		minimumSize: Int)
	{
		// minimumSize が 1 以下なら「小さすぎるクラスタ」は存在しないので、
		// 下の探索が最初の 1 周で nil を返して抜ける（専用の分岐は置かない）。
		var frozen = Set<Int>()
		while true
		{
			var membersByRoot: [Int: [Int]] = [:]
			for index in present
			{
				membersByRoot[find(index), default: []].append(index)
			}
			guard membersByRoot.count > 1
			else
			{
				return
			}
			// 対象は「小さくて、まだ諦めていない」クラスタのうち先頭のもの。
			// 根は添字の最小値なので、これで撮影順に処理できる。
			guard let smallest = membersByRoot
				.filter({ $0.value.count < minimumSize && !frozen.contains($0.key) })
				.min(by: { $0.key < $1.key })
			else
			{
				return
			}
			let root = smallest.key
			var target: (root: Int, distance: Double)?
			for member in smallest.value
			{
				for neighbor in neighbors[member]
				{
					let other = find(neighbor.index)
					guard other != root
					else
					{
						continue
					}
					// 既定値つきの比較（`?? 0`）を書くと、決して評価されない
					// 分岐が残る。最初の 1 件と 2 件目以降を分けて書く。
					guard let current = target
					else
					{
						target = (other, neighbor.distance)
						continue
					}
					if neighbor.distance < current.distance
					{
						target = (other, neighbor.distance)
					}
				}
			}
			guard let target
			else
			{
				// 近傍が全部自分のクラスタの中。繋ぎ先が無いので諦める。
				frozen.insert(root)
				continue
			}
			union(root, target.root)
		}
	}
}
