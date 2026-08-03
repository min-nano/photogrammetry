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
	/// Vision の視覚特徴の近さ（同じ場所を別の角度から撮った写真が近くなる）。
	case scene
	/// 視覚クラスタリングで「同じ場所」と判定されたか（RoomClustering）。
	case room
	/// **実際に重なって写っているか**（画像レジストレーション。設計メモ §4.9）。
	/// 他の証拠と違い、これは重み付き平均に加わらない — 加わるのではなく
	/// **エッジ集合そのものを置き換える**。語彙を揃えるために同じ enum に置いて
	/// あるので、`affinity` の中には現れない。
	case overlap

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
			case .scene:
				return "視覚特徴の近さ"
			case .room:
				return "同じ場所の判定"
			case .overlap:
				return "実際の重なり"
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
	/// 視覚特徴（feature print）の距離の効き幅。
	public var sceneSpan: Double
	/// 視覚クラスタリング（「同じ部屋」の判定）の設定。
	public var roomClustering: RoomClustering.Settings
	/// 重なりの確認をどのペアに何回使うか（設計メモ §4.9）。実際に確認するか
	/// どうかは `group(photos:settings:verifyOverlap:)` に役が渡されたかで決まる。
	public var overlapSurvey: OverlapSurvey.Settings
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
	/// 小さすぎるグループを隣へ吸収するのに必要な結び付きの強さ。nil なら
	/// 結合スコアの閾値から決める（`absorptionThresholdRatio`）。
	public var minimumAbsorptionScore: Double?
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
	/// 1 つの場所が写真全体のこの割合を超えて占めるなら、場所の判定は証拠に
	/// 使わない。**全ペアで「同じ」になる証拠は何も区別しない**うえ、重みのぶん
	/// だけ他の証拠を薄めるため（フォルダが 1 つのときと同じ扱い）。
	public var maximumRoomDominance: Double
	/// 証拠ごとの重み。
	public var weights: [EvidenceKind: Double]

	/// 既定の重み。時刻と見た目を主軸にし、方位・露出は補助に留める
	/// （どちらも単独では別の場所を同じと言いうるため）。
	///
	/// **フェーズ 2 で `room` を最も重くした。** 実写真では「同じ部屋を行き来
	/// しながら撮る」「隣の部屋を続けて撮る」が普通に起き、時刻や露出だけでは
	/// どちらも取り違える。場所そのものの同一性を言えるのは視覚特徴だけなので、
	/// フォルダ分け（撮影者が既に分けている＝最も強い証拠）より重くする。
	///
	/// 既存の証拠の重みは**一切変えていない**。視覚特徴が取れない現場
	/// （`--no-visual`・Vision が使えない）では、フェーズ 1 とまったく同じ
	/// 重み配分に戻るようにするため。
	public static let defaultWeights: [EvidenceKind: Double] = [
		.folder: 1.0,
		.time: 1.0,
		.sequence: 0.5,
		.gps: 0.8,
		.altitude: 0.5,
		.heading: 0.3,
		.exposure: 0.3,
		.visual: 1.0,
		.scene: 1.0,
		.room: 1.5,
	]

	public init(
		timeGap: TimeInterval = 300,
		sequenceSpan: Double = 10,
		gpsRadius: Double = 8,
		floorHeight: Double = 2.0,
		exposureSpan: Double = 3,
		visualSpan: Double = 0.25,
		sceneSpan: Double = 0.35,
		roomClustering: RoomClustering.Settings = RoomClustering.Settings(),
		overlapSurvey: OverlapSurvey.Settings = OverlapSurvey.Settings(),
		maximumGPSAccuracy: Double = 30,
		maximumGPSAge: TimeInterval = 120,
		maxPerGroup: Int = 150,
		minPerGroup: Int = 20,
		threshold: Double? = nil,
		minimumAbsorptionScore: Double? = nil,
		neighborWindow: Int = 60,
		visualNeighbors: Int = 12,
		maxLinksPerGroup: Int = 4,
		minimumEvidenceCoverage: Double = 0.5,
		maximumRoomDominance: Double = 0.9,
		weights: [EvidenceKind: Double] = defaultWeights)
	{
		self.timeGap = timeGap
		self.sequenceSpan = sequenceSpan
		self.gpsRadius = gpsRadius
		self.floorHeight = floorHeight
		self.exposureSpan = exposureSpan
		self.visualSpan = visualSpan
		self.sceneSpan = sceneSpan
		self.roomClustering = roomClustering
		self.overlapSurvey = overlapSurvey
		self.maximumGPSAccuracy = maximumGPSAccuracy
		self.maximumGPSAge = maximumGPSAge
		self.maxPerGroup = maxPerGroup
		self.minPerGroup = minPerGroup
		self.threshold = threshold
		self.minimumAbsorptionScore = minimumAbsorptionScore
		self.neighborWindow = neighborWindow
		self.visualNeighbors = visualNeighbors
		self.maxLinksPerGroup = maxLinksPerGroup
		self.minimumEvidenceCoverage = minimumEvidenceCoverage
		self.maximumRoomDominance = maximumRoomDominance
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
	/// 実際に確かめた重なり（フェーズ 2.6）。確かめなかったときは nil。
	///
	/// **「確かめた」と「それでグループ分けを決めた」は別**。判定できた組が少なす
	/// ぎれば合算スコアへ戻るが、測った結果自体は捨てない（共有写真の選定で
	/// 使い回すため）。グループ分けを決めたかどうかは
	/// `usedEvidence.contains(.overlap)` で分かる（設計メモ §4.9）。
	public var overlap: OverlapGraph?
	/// 視覚クラスタリングの結果（＝見つかった「場所」。フェーズ 2）。
	/// グループとは別の軸で、**1 つの場所が複数のグループに分かれることも、
	/// 1 つのグループが複数の場所を含むこともある**。前者は合成の手がかりに、
	/// 後者は「混ざっている」という診断になる。
	public var rooms: RoomClusteringResult
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
		rooms: RoomClusteringResult,
		overlap: OverlapGraph? = nil,
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
		self.rooms = rooms
		self.overlap = overlap
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

	/// 小さすぎるグループを隣へ吸収するのに要求する強さ（結合スコアの閾値に
	/// 対する割合）。閾値そのものは要求しない — それを満たすなら最初から
	/// 同じ連結成分になっているはずで、上限枚数で割った区間まで
	/// `_unassigned` へ送ってしまう。
	public static let absorptionThresholdRatio = 0.5

	/// 切れ目を測るときに見る前後の枚数。**この幅の前後がどれだけ繋がって
	/// いるか**だけで判定する（離れた写真どうしの組は全体の構造の話であって、
	/// 切れ目の判定材料ではない）。狭すぎると 1 枚のブレで誤判定し、広すぎると
	/// 位置ごとの本数の違いが偏りになる。
	public static let seamWindow = 10

	/// 写真をグループへ分ける。入力の順序は問わない（内部で撮影順へ並べ直す）。
	///
	/// - Parameters:
	///   - verifyOverlap: 2 枚が**実際に重なって写っているか**を確かめる役
	///     （設計メモ §4.9）。渡すと、グループ分けのエッジ集合が合算スコアから
	///     実測へ置き換わる。nil ならフェーズ 1／2 と同じ動作。
	///   - isCancelled: 数分かかりうる段なので中断を受け取る。
	///   - progress: 確かめた回数と予算。
	public static func group(
		photos input: [PhotoMetadata],
		settings: GroupingSettings = GroupingSettings(),
		verifyOverlap: OverlapSurvey.Probe? = nil,
		isCancelled: () -> Bool = { false },
		progress: (Int, Int) -> Void = { _, _ in })
		-> GroupingResult
	{
		let photos = PhotoOrdering.sorted(input)
		// **視覚クラスタリングが先。** 「同じ場所か」はペアの結合スコアの証拠に
		// なるうえ、近傍の計算結果は候補ペアの選定にもそのまま使い回す。
		let rooms = RoomClustering.cluster(
			prints: photos.map(\.featurePrint), settings: settings.roomClustering)
		var coverage = evidenceCoverage(photos: photos, rooms: rooms, settings: settings)
		var usable = usableEvidence(coverage: coverage, settings: settings)

		guard photos.count > 1
		else
		{
			let groups = photos.isEmpty ? [] : [PhotoGroup(id: identifier(0), members: [0])]
			return GroupingResult(
				photos: photos,
				groups: groups,
				links: [],
				unassigned: [],
				rooms: rooms,
				usedEvidence: EvidenceKind.allCases.filter { usable.contains($0) },
				evidenceCoverage: coverage,
				threshold: 0,
				thresholdWasAutomatic: settings.threshold == nil,
				scoreHistogram: [Int](repeating: 0, count: histogramBins))
		}

		// --- ペアの事前確率（フェーズ 1／2 の合算スコア）---
		// 重なりを確かめるときは、これは「どのペアを確かめるか」の順番付けに降りる
		// （設計メモ §4.9）。確かめないときは従来どおりこれがグループ分けを決める。
		let prior = candidatePairs(photos: photos, rooms: rooms, settings: settings).map
		{ pair in
			PairScore(
				i: pair.0,
				j: pair.1,
				score: affinity(
					photos[pair.0],
					photos[pair.1],
					rooms: (rooms.labels[pair.0], rooms.labels[pair.1]),
					settings: settings,
					usable: usable))
		}

		// --- 実際の重なりを確かめる（フェーズ 2.6）---
		let graph = verifyOverlap.map
		{ probe in
			OverlapSurvey.survey(
				urls: photos.map(\.url),
				prior: prior,
				settings: settings.overlapSurvey,
				isCancelled: isCancelled,
				progress: progress,
				probe: probe)
		}
		coverage[.overlap] = graph.map { overlapCoverage(graph: $0) } ?? 0
		// **判定できた組が半分の写真に届かないときは合算スコアへ戻る。**
		// 他の証拠と同じ足切り（`minimumEvidenceCoverage`）で、確認が答えを出せない
		// 現場（模様の無い写真ばかり）で歯止めまで失うと確認前より悪くなる。
		let measured: OverlapGraph? = {
			guard let graph, graph.isUsable,
				(coverage[.overlap] ?? 0) >= settings.minimumEvidenceCoverage
			else
			{
				return nil
			}
			return graph
		}()

		// --- エッジ集合 ---
		// 重なりが使えるならエッジは実測に置き換わる。閾値は分布から推定しない
		// （一致度は現場に依存しない目盛りを持つため。設計メモ §4.9）。
		let scored: [PairScore]
		let threshold: Double
		let thresholdWasAutomatic: Bool
		if let measured
		{
			usable.insert(.overlap)
			scored = measured.edges()
			threshold = settings.threshold ?? measured.criteria.minimumInlierRatio
			thresholdWasAutomatic = false
		}
		else
		{
			scored = prior
			threshold = settings.threshold ?? automaticThreshold(scores: prior.map(\.score))
			thresholdWasAutomatic = settings.threshold == nil
		}
		let histogram = ThresholdEstimator.histogram(
			values: scored.map(\.score), bins: histogramBins, lower: 0, upper: 1)

		// --- 連結成分 → 大きすぎるものを撮影の流れの切れ目で分割 ---
		var components = connectedComponents(count: photos.count, edges: scored, threshold: threshold)
		components.sort(by: startsBefore)

		var parts: [[Int]] = []
		for component in components
		{
			parts.append(contentsOf: split(
				members: component,
				edges: scored,
				maxPerGroup: max(2, settings.maxPerGroup),
				minPerGroup: max(1, min(settings.minPerGroup, settings.maxPerGroup / 3))))
		}
		parts.sort(by: startsBefore)

		// --- 小さすぎるグループの吸収 ---
		// 吸収を認める強さの下限は結合スコアの閾値から決める。閾値そのものを
		// 課すと「同じグループにできるほど強い繋がり」を要求することになり、
		// 上限枚数で割った区間まで `_unassigned` へ行ってしまう。
		let absorbed = absorbSmallGroups(
			parts: parts,
			edges: scored,
			bar: settings.minimumAbsorptionScore ?? threshold * absorptionThresholdRatio,
			settings: settings)
		let groups = absorbed.parts.enumerated().map
		{ index, members in
			PhotoGroup(id: identifier(index), members: members)
		}

		// 隣接の候補からは**証明済みに重なっていない組だけ**を外す（設計メモ §4.9）。
		//
		// **測っていない組は必ず残す。** ここを「実測で重なっている組だけ」に絞ると
		// 共有写真が枯れる — 実データ 1424 枚で隣接 19 本すべてが共有 2〜8 枚
		// （推奨 10）になり、確認の候補も全部で 31 組しか無かった。グループの
		// 境目をまたぐ組は元々少ないので、絞った時点で選びようが無くなる。
		// 未測定の組はスコアを閾値未満へ落として並べる（実測で重なっている組が
		// 必ず先に来るようにするだけで、候補からは外さない）。
		let linkEdges = linkCandidates(
			prior: prior, measured: measured, scored: scored, count: photos.count)
		let links = buildLinks(groups: groups, edges: linkEdges, rooms: rooms, settings: settings)

		return GroupingResult(
			photos: photos,
			groups: groups,
			links: links,
			unassigned: absorbed.unassigned.sorted(),
			rooms: rooms,
			overlap: measured ?? graph,
			usedEvidence: EvidenceKind.allCases.filter { usable.contains($0) },
			evidenceCoverage: coverage,
			threshold: threshold,
			thresholdWasAutomatic: thresholdWasAutomatic,
			scoreHistogram: histogram)
	}

	/// 隣接の候補にするエッジ。
	///
	/// 重なりを使わなかったときは事前確率のエッジをそのまま。使ったときは
	/// **実測で重なっている組 ＋ まだ測っていない事前候補**で、証明済みに重なって
	/// いない組だけを外す。後者のスコアは閾値未満へ押し下げるので、`buildLinks` の
	/// 確からしさ（上位のエッジの平均）は実測のある隣接ほど高くなる。
	static func linkCandidates(
		prior: [PairScore],
		measured: OverlapGraph?,
		scored: [PairScore],
		count: Int) -> [PairScore]
	{
		guard let measured
		else
		{
			return prior
		}
		let bar = measured.criteria.minimumInlierRatio
		var result = scored.filter { $0.score > 0 }
		for candidate in prior where measured.verdict(candidate.i, candidate.j) == nil
		{
			// 未測定は「実測で重なっている組より下」に置く。順番付けにだけ効く。
			result.append(PairScore(
				i: candidate.i, j: candidate.j, score: candidate.score * bar * 0.99))
		}
		return result.sorted { $0.i == $1.i ? $0.j < $1.j : $0.i < $1.i }
	}

	/// 重なりを証拠として使えるか。**判定できた組を 1 つでも持つ写真の割合**で測る
	/// （他の証拠の coverage と揃えて「その項目を持つ写真の割合」にする）。
	static func overlapCoverage(graph: OverlapGraph) -> Double
	{
		guard graph.photoCount > 0
		else
		{
			return 0
		}
		var decided = [Bool](repeating: false, count: graph.photoCount)
		for (key, verdict) in graph.verdicts where verdict != .undecided
		{
			decided[key / graph.photoCount] = true
			decided[key % graph.photoCount] = true
		}
		return Double(decided.filter { $0 }.count) / Double(graph.photoCount)
	}

	/// group-01 形式の識別子。100 グループを超えても桁が増えるだけで壊れない。
	public static func identifier(_ index: Int) -> String
	{
		String(format: "group-%02d", index + 1)
	}

	/// 添字の集合を「先頭の添字（＝撮影順で最初の写真）」で比べる。グループの
	/// 並びを撮影順に揃えるために使う。
	///
	/// 空の集合は作らない設計だが、`$0.first ?? 0` と書くと**決して評価されない
	/// 既定値**が残る。ここは判定を明示して、到達しないコードを持たないようにする。
	static func startsBefore(_ a: [Int], _ b: [Int]) -> Bool
	{
		guard let left = a.first
		else
		{
			return false
		}
		guard let right = b.first
		else
		{
			return true
		}
		return left < right
	}

	// -----------------------------------------------------------------
	// 証拠
	// -----------------------------------------------------------------

	/// 証拠ごとに「その項目を持つ写真の割合」を数える。
	static func evidenceCoverage(
		photos: [PhotoMetadata],
		rooms: RoomClusteringResult,
		settings: GroupingSettings)
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
			.scene: Double(photos.filter { $0.featurePrint != nil }.count) / count,
			.room: roomCoverage(rooms: rooms, settings: settings),
		]
	}

	/// 場所の判定を証拠として使えるか。使えるならその割合、使えないなら 0。
	///
	/// **見つかった場所が 1 つ、あるいはほぼ全部が 1 か所にまとまってしまった
	/// ときは使わない。** フォルダが 1 つのときとまったく同じ理屈で、全ペアが
	/// 「同じ」になる証拠は何も区別しないどころか、重みのぶんだけ他の証拠を
	/// 薄める。実データ（1424 枚・屋外と屋内）で 97% が 1 か所にまとまり、
	/// **屋外と室内が同じグループに入る**原因になっていた — 時刻や露出で
	/// 分かれるはずのペアが、この証拠の重みで閾値を超えてしまうため。
	static func roomCoverage(rooms: RoomClusteringResult, settings: GroupingSettings) -> Double
	{
		guard rooms.clusters.count > 1
		else
		{
			return 0
		}
		let labelled = rooms.clusters.reduce(0) { $0 + $1.members.count }
		let largest = rooms.clusters.reduce(0) { max($0, $1.members.count) }
		guard labelled > 0,
			Double(largest) / Double(labelled) <= settings.maximumRoomDominance
		else
		{
			return 0
		}
		return rooms.coverage
	}

	/// 実際に使う証拠を決める。半分以上の写真が持っていない項目は、あるペアと
	/// 無いペアで尺度が変わってしまうので使わない。
	static func usableEvidence(coverage: [EvidenceKind: Double], settings: GroupingSettings)
		-> Set<EvidenceKind>
	{
		var usable = Set<EvidenceKind>()
		for kind in EvidenceKind.allCases
		{
			guard let weight = settings.weights[kind], weight > 0
			else
			{
				continue
			}
			guard let available = coverage[kind], available >= settings.minimumEvidenceCoverage
			else
			{
				continue
			}
			usable.insert(kind)
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
	///
	/// - Parameter rooms: 2 枚それぞれの視覚クラスタの添字（判定できなければ nil）。
	static func affinity(
		_ a: PhotoMetadata,
		_ b: PhotoMetadata,
		rooms: (Int?, Int?),
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
		if let left = a.featurePrint, let right = b.featurePrint
		{
			add(.scene, exp(-left.distance(to: right) / max(0.01, settings.sceneSpan)))
		}
		if let left = rooms.0, let right = rooms.1
		{
			// 同じ場所と判定されたかどうか。フォルダ分けと同じ二値の証拠で、
			// **時刻が離れていても同じ部屋なら繋ぎ、時刻が近くても別の部屋なら
			// 引き離す**という、フェーズ 1 に無かった働きをする。
			add(.room, left == right ? 1 : 0)
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
	///
	/// 近傍は 2 種類入れる。知覚ハッシュ（ほぼ同じ構図で撮り直した写真に強い）と、
	/// 視覚特徴（同じ場所を別の角度から撮った写真に強い）。**後者が
	/// フェーズ 2 の肝で**、部屋を出入りしながら撮った現場でここが効く。
	/// 視覚特徴の近傍は RoomClustering が既に計算しているのでそのまま使う。
	static func candidatePairs(
		photos: [PhotoMetadata],
		rooms: RoomClusteringResult,
		settings: GroupingSettings) -> [(Int, Int)]
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

		for index in 0 ..< min(count, rooms.neighbors.count)
		{
			for neighbor in rooms.neighbors[index]
			{
				add(index, neighbor.index)
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
		guard let percentile = ThresholdEstimator.percentile(scores, 0.2)
		else
		{
			return 0.15
		}
		return max(0.15, percentile)
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
	/// 切れ目は、**その位置をまたぐ「近くのペア」だけの平均**が最小になる場所。
	/// **部屋を移るときに立ち止まれば、そこがそのまま最小になる**（撮影ガイド
	/// §12-2 が効くのはここ）。守られていなくても必ずどこかで切れるので、
	/// 撮影が推奨から外れていても破綻しない。
	///
	/// **「近くのペアだけ」が要点。** 位置の良し悪しは「直前の数枚と直後の数枚が
	/// どれだけ繋がっているか」で決まる。候補ペアには離れた写真どうしの組
	/// （一度離れて戻ってきた撮影を繋ぐためのもの）も入っているが、それらは
	/// 全体の構造の話であって切れ目の判定材料ではない。混ぜると、位置ごとに
	/// **何本またぐか**が違うせいで内容と無関係な偏りが出る。
	///
	/// 実データ（1424 枚）ではこの偏りが決定的だった。60 グループ中 57 グループが
	/// **ちょうど下限枚数（20 枚）の連続ブロック**（IMG_3619〜3638、3639〜3658、…）
	/// になり、切れ目は毎回いちばん端に来ていた。合計を平均に替えても直らず、
	/// 近傍だけに絞って初めて「場所の変わり目で切る」が成立する。
	/// **屋外と室内が同じグループに入るのはこれが原因。**
	///
	/// 近傍の幅は前後 `seamWindow` 枚。余白がそれより狭いときは余白に合わせる
	/// （どの位置でも同じ本数を見るためで、これも偏りを作らないため）。
	static func split(members: [Int], edges: [PairScore], maxPerGroup: Int, minPerGroup: Int)
		-> [[Int]]
	{
		guard members.count > maxPerGroup
		else
		{
			return [members]
		}
		// 端に寄りすぎた切れ目は避ける（1 枚だけのグループを作らない）。
		let margin = max(1, min(minPerGroup, members.count / 4))
		// 見るのは前後この枚数まで。どの位置でも同じ本数を見るために余白で抑える。
		let span = max(1, min(seamWindow, margin))

		let positions = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1, $0) })
		// 位置 p と p+1 の間をまたぐ「近くのペア」の重みの合計と本数。
		// 差分配列で全位置を一度に求める。
		var crossing = [Double](repeating: 0, count: members.count)
		var spanning = [Double](repeating: 0, count: members.count)
		for edge in edges
		{
			guard let left = positions[edge.i], let right = positions[edge.j]
			else
			{
				continue
			}
			let low = min(left, right)
			let high = max(left, right)
			guard high > low, high - low <= span
			else
			{
				continue
			}
			// エッジは位置 low 〜 high-1 の切れ目をまたぐ。差分配列なので
			// 始点で足して終点で引く（high は必ず配列内）。
			crossing[low] += edge.score
			crossing[high] -= edge.score
			spanning[low] += 1
			spanning[high] -= 1
		}
		var runningWeight = 0.0
		var runningCount = 0.0
		var weights = [Double](repeating: 0, count: members.count)
		for index in 0 ..< members.count
		{
			runningWeight += crossing[index]
			runningCount += spanning[index]
			// 1 本もまたがない位置は「完全に切れている」ので最小（0）でよい。
			weights[index] = runningCount > 0 ? runningWeight / runningCount : 0
		}

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
			// したい（設計メモ §5.4）。条件を `||` / `&&` で繋がず分けて書くのは、
			// 短絡評価の右辺が到達しないコードとして残らないようにするため。
			let isBetter: Bool
			if weight < bestWeight - 1e-9
			{
				isBetter = true
			}
			else if abs(weight - bestWeight) <= 1e-9
			{
				isBetter = abs(Double(position) - center) < abs(Double(bestPosition) - center)
			}
			else
			{
				isBetter = false
			}
			if isBetter
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
	///
	/// **結び付きの強さは「上位のエッジの平均」で測る（合計ではない）。**
	/// 合計にすると、弱い繋がりでもエッジの本数が多い大きなグループが必ず勝つ。
	/// 実データ（1424 枚）では、SNS 経由で受け取った EXIF の無い写真が作る
	/// 小さな塊が、まったく別の場所の大きなグループへ次々と吸い込まれていた。
	/// `buildLinks` の confidence と同じ測り方に揃えてある。
	///
	/// **そのうえで、強さが `bar` に届かない吸収は行わない。** 「小さいから
	/// どこかへ入れる」は、無関係な写真をグループへ持ち込むだけで再構成の役に
	/// 立たない。行き先が無いことは `_unassigned` として必ず伝える（§4.0 の
	/// 「黙って悪い結果を出さない」）。
	///
	/// - Parameter bar: 吸収を認める結び付きの強さの下限。
	static func absorbSmallGroups(
		parts: [[Int]],
		edges: [PairScore],
		bar: Double,
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
			var scores: [Int: [Double]] = [:]
			for edge in edges
			{
				guard let left = membership[edge.i], let right = membership[edge.j], left != right
				else
				{
					continue
				}
				if left == index
				{
					scores[right, default: []].append(edge.score)
				}
				else if right == index
				{
					scores[left, default: []].append(edge.score)
				}
			}
			let strength = scores.mapValues(linkStrength)
			let target = strength
				.filter { result[$0.key].count + small.count <= settings.maxPerGroup }
				.filter { $0.value >= bar }
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
		result.sort(by: startsBefore)
		return (result, unassigned)
	}

	/// 2 つのグループの結び付きの強さ。**上位のエッジの平均**（`buildLinks` の
	/// confidence と同じ測り方）。何本繋がっているかではなく、いちばん強い
	/// 繋がりがどれだけ強いかを見る。
	static func linkStrength(_ scores: [Double]) -> Double
	{
		let top = scores.sorted(by: >).prefix(linkSampleSize)
		guard !top.isEmpty
		else
		{
			return 0
		}
		return top.reduce(0, +) / Double(top.count)
	}

	/// 結び付きの強さを測るときに見るエッジの本数。
	static let linkSampleSize = 5

	/// グループ間の隣接を作る。**閾値を下回ったエッジも含める**のが要点で、
	/// 切れ目をまたぐ写真こそが合成の対応点になる（設計メモ §4.4）。
	static func buildLinks(
		groups: [PhotoGroup],
		edges: [PairScore],
		rooms: RoomClusteringResult,
		settings: GroupingSettings)
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

		// 同じ場所（視覚クラスタ）を含むグループの組を先に知っておく。
		let roomsByGroup = groups.map
		{ group in
			Set(group.members.compactMap { rooms.labels[$0] })
		}

		var all: [(link: GroupLink, sharesRoom: Bool)] = []
		for (key, candidates) in buckets
		{
			let sorted = candidates.sorted
			{
				$0.score == $1.score ? ($0.i == $1.i ? $0.j < $1.j : $0.i < $1.i) : $0.score > $1.score
			}
			let confidence = linkStrength(sorted.map(\.score))
			let a = key / groups.count
			let b = key % groups.count
			all.append((
				GroupLink(a: a, b: b, confidence: confidence, candidates: sorted),
				!roomsByGroup[a].isDisjoint(with: roomsByGroup[b])))
		}
		// 並べる順がそのまま「上限に達したときどれを残すか」になる。**同じ場所を
		// 含むグループ同士の隣接を最優先**にするのがフェーズ 2 の要点で、これは
		// 合成でいうループ閉じ込み — 一度離れて戻ってきた撮影の繋ぎ目にあたる。
		// 結合スコアだけで並べると、撮影順に隣り合う組に上限を使い切られて
		// 真っ先に落ちる（＝一番欲しい繋ぎが消える）。
		all.sort
		{ left, right in
			if left.sharesRoom != right.sharesRoom
			{
				return left.sharesRoom
			}
			if left.link.confidence != right.link.confidence
			{
				return left.link.confidence > right.link.confidence
			}
			return left.link.a == right.link.a ? left.link.b < right.link.b : left.link.a < right.link.a
		}

		// 各グループが持つ隣接を上位のみに絞る（総当たりだと共有写真が増えすぎる）。
		var counts = [Int](repeating: 0, count: groups.count)
		var kept: [GroupLink] = []
		for entry in all
		{
			guard counts[entry.link.a] < settings.maxLinksPerGroup,
				counts[entry.link.b] < settings.maxLinksPerGroup
			else
			{
				continue
			}
			counts[entry.link.a] += 1
			counts[entry.link.b] += 1
			kept.append(entry.link)
		}
		kept.sort { $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }
		return kept
	}
}
