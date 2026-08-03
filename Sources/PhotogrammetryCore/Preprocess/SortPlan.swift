//
//  SortPlan.swift
//
//  グループと隣接から「どのフォルダへどのファイルを入れるか」を決める純ロジック
//  （設計メモ §4.4）。ファイル操作は PhotoSorter の仕事で、ここは計画だけを作る。
//
//  **ここが本設計の要。** グループをきれいに切り分けてはいけない。隣接グループには
//  同じ写真を両方に入れる。この共有写真が、フェーズ 3 の合成でそのまま対応点に
//  なる（各グループの再構成結果から得られる Poses が写真ファイル URL に紐づく
//  ので、両方に入っている写真の姿勢を突き合わせれば相似変換が解ける）。
//
//  選び方には条件がある。**カメラ位置が一直線に並ぶと変換推定が退化する**ので、
//  結合スコアが高い順に採るだけでなく、視点が散らばるように選ぶ。廊下を直進
//  しながら撮った区間ではここが効いてくる。
//

import Foundation

/// 仕分けの計画。相対パスだけで表現してあるので、実行前に内容を確認できる
/// （`--dry-run` はこれを作って診断まで出し、ファイルは触らない）。
public struct SortPlan: Equatable, Sendable
{
	/// 出力フォルダ 1 つ分。
	public struct Group: Equatable, Sendable
	{
		public var id: String
		/// このフォルダへ入れる全ファイル（撮影順・共有写真を含む）。
		public var photos: [String]
		/// うち隣接グループとの共有として入ったもの。
		public var shared: [String]
		/// このグループの写真で実際に使えた証拠。
		public var evidence: [EvidenceKind]
		/// このグループが写している場所（視覚クラスタ）の識別子。枚数の多い順。
		/// **2 つ以上あればグループに別の場所が混ざっている**（診断で指摘する）。
		public var rooms: [String]
		/// 撮影時刻の範囲（分かる場合）。診断で「どの時間帯の塊か」を示す。
		public var captureStart: Date?
		public var captureEnd: Date?

		public init(
			id: String,
			photos: [String],
			shared: [String],
			evidence: [EvidenceKind],
			rooms: [String] = [],
			captureStart: Date? = nil,
			captureEnd: Date? = nil)
		{
			self.id = id
			self.photos = photos
			self.shared = shared
			self.evidence = evidence
			self.rooms = rooms
			self.captureStart = captureStart
			self.captureEnd = captureEnd
		}
	}

	/// グループ同士の隣接。フェーズ 3 の `merge` はここだけを読む。
	public struct Adjacency: Equatable, Sendable
	{
		public var a: String
		public var b: String
		/// 両方のフォルダに入れた写真。
		public var sharedPhotos: [String]
		public var confidence: Double
		/// 共有写真の視点の散らばり（0.0〜1.0）。低いと共線退化の予兆になる。
		/// 判定材料（方位・位置・見た目）がまったく無ければ nil。
		public var viewpointSpread: Double?
		/// 両方のグループが写している共通の場所（視覚クラスタ）。**同じ部屋を
		/// 別々のグループで撮っている**ことの証拠で、合成では最も信頼できる
		/// 繋ぎ目になる（時刻が離れていても成立する）。無ければ nil。
		public var sharedRoom: String?
		/// 共有写真が**実際に重なって写っていることを確かめた**か（§4.6.1）。
		/// false は「確かめていない」で、「重なっていない」ではない（視覚特徴が
		/// 取れない現場・`--no-overlap-check`）。合成はこれが true の隣接を
		/// 最も信頼してよい。
		public var overlapVerified: Bool

		public init(
			a: String,
			b: String,
			sharedPhotos: [String],
			confidence: Double,
			viewpointSpread: Double? = nil,
			sharedRoom: String? = nil,
			overlapVerified: Bool = false)
		{
			self.a = a
			self.b = b
			self.sharedPhotos = sharedPhotos
			self.confidence = confidence
			self.viewpointSpread = viewpointSpread
			self.sharedRoom = sharedRoom
			self.overlapVerified = overlapVerified
		}
	}

	/// 重なりの検証をどれだけ行い、どれだけ落としたか。**検証しなかったときは
	/// nil**（0 件だったのか、そもそも確かめていないのかを取り違えないため）。
	public struct OverlapSummary: Equatable, Sendable
	{
		/// 実際に重なっていると確かめた組数。
		public var verified: Int
		/// 重なっていないと分かって落とした組数。
		public var rejected: Int
		/// 判定材料が足りず（模様が無い・読めない）判断を保留した組数。
		public var undecided: Int

		public init(verified: Int = 0, rejected: Int = 0, undecided: Int = 0)
		{
			self.verified = verified
			self.rejected = rejected
			self.undecided = undecided
		}
	}

	public var groups: [Group]
	public var adjacency: [Adjacency]
	/// どのグループにも入らなかった写真（`_unassigned/`）。
	public var unassigned: [String]
	/// 重なりの検証の集計。検証しなかったときは nil。
	public var overlapSummary: OverlapSummary?

	public init(
		groups: [Group],
		adjacency: [Adjacency],
		unassigned: [String],
		overlapSummary: OverlapSummary? = nil)
	{
		self.groups = groups
		self.adjacency = adjacency
		self.unassigned = unassigned
		self.overlapSummary = overlapSummary
	}
}

public enum SortPlanner
{
	public struct Settings: Equatable, Sendable
	{
		/// 隣接ペアごとに共有する写真の枚数（両方のフォルダへ入る）。
		public var overlap: Int
		/// 共有写真として選ぶとき、既に選んだ写真とこのハミング距離以上
		/// 離れていることを求める（視点を散らすため）。
		public var diversityDistance: Int
		/// 方位が分かる場合、これ以上向きが違えば「視点が違う」とみなす（度）。
		public var diversityHeading: Double
		/// 位置が分かる場合、これ以上離れていれば「視点が違う」とみなす（m）。
		public var diversityDistanceMeters: Double
		/// 視覚特徴がこの距離以上離れていれば「視点が違う」とみなす。
		/// 知覚ハッシュより素直に「立ち位置を変えたか」を捉える（同じ場所から
		/// 向きだけ変えた写真は、ハッシュは大きく変わるのに特徴は近いままになる）。
		public var diversitySceneDistance: Double
		/// 共有写真として認めるのに必要な、重なった範囲の画素の一致度（§4.6.1）。
		/// 実測では無関係な 2 枚が 0.05 を超えず、実際に重なる 2 枚は寄り引き・
		/// 回転が入っても 0.65 以上だったので、その間に置く。
		public var minimumOverlapAgreement: Double
		/// 同じく、重なりの広さ（基準画像の面積比）。一致度ほど強い手がかりでは
		/// ないが、**帯のように少ししか重なっていない組**は対応点にならない。
		public var minimumSharedArea: Double
		/// 隣接 1 本あたりに重なりを確かめる候補の上限。**これがコストの上限**で、
		/// 必要な枚数が集まればここまで使わずに切り上げる。
		public var maximumOverlapChecks: Int
		/// 1 度にまとめて確かめる組数。実装（Vision）が並行に処理できる粒度で、
		/// 大きいほど並列度が上がり、小さいほど「集まったら切り上げる」が効く。
		public var overlapCheckBatch: Int

		public init(
			overlap: Int = 15,
			diversityDistance: Int = 6,
			diversityHeading: Double = 15,
			diversityDistanceMeters: Double = 1.0,
			diversitySceneDistance: Double = 0.12,
			minimumOverlapAgreement: Double = 0.35,
			minimumSharedArea: Double = 0.15,
			maximumOverlapChecks: Int = 24,
			overlapCheckBatch: Int = 8)
		{
			self.overlap = overlap
			self.diversityDistance = diversityDistance
			self.diversityHeading = diversityHeading
			self.diversityDistanceMeters = diversityDistanceMeters
			self.diversitySceneDistance = diversitySceneDistance
			self.minimumOverlapAgreement = minimumOverlapAgreement
			self.minimumSharedArea = minimumSharedArea
			self.maximumOverlapChecks = maximumOverlapChecks
			self.overlapCheckBatch = overlapCheckBatch
		}
	}

	/// 候補の組が実際に重なっているかを確かめる問い合わせ。**まとめて渡す**のは、
	/// 実装（デコードと Vision）が並行に処理できるようにするため。返り値は
	/// 渡した並びと同じ長さで、nil は「判定できなかった」。
	public typealias OverlapProbe = @Sendable ([OverlapQuery]) -> [PhotoOverlap?]

	/// 隣接 1 本ぶんの選定結果。枚数だけでなく**何組を確かめ、何組を落としたか**を
	/// 返すのは、診断で「なぜ共有写真が少ないのか」を言えるようにするため。
	struct SharedSelection: Equatable
	{
		var photos: [Int] = []
		var verified = 0
		var rejected = 0
		var undecided = 0
	}

	/// 視点の散らばりを 0.0〜1.0 へ正規化するときの基準（この平均ハミング距離で 1.0）。
	static let spreadReferenceDistance = 0.35
	/// 同上、視覚特徴の平均距離での基準。
	static let spreadReferenceSceneDistance = 0.25

	/// グルーピング結果から仕分け計画を作る。
	///
	/// - Parameter verifyOverlap: 候補の組が**実際に重なって写っているか**を
	///   確かめる役（§4.6.1）。nil なら確かめない（フェーズ 2 までと同じ動作）。
	public static func plan(
		grouping: GroupingResult,
		settings: Settings = Settings(),
		verifyOverlap: OverlapProbe? = nil) -> SortPlan
	{
		let photos = grouping.photos
		// グループ添字で引く配列にしておく（辞書だと毎回 Optional の既定値を
		// 書くことになり、決して評価されない分岐が残る）。
		var sharedByGroup = [Set<Int>](repeating: [], count: grouping.groups.count)
		var adjacency: [SortPlan.Adjacency] = []
		var summary = SortPlan.OverlapSummary()

		// 共有写真として認める視覚的な距離の上限。**この現場の近傍距離の中央値**を
		// 使う（絶対値の尺度は現場ごとに違うので、固定値では意味を持たない）。
		//
		// **これは「実際に確かめられないとき」の代役**なので、重なりを確かめる
		// ときは足切りに使わない（順番付けには使う）。距離が遠くても本当に重なって
		// いる組はあり、確かめられるならそちらが答えになる。足切りを残すと、
		// 距離の帯が潰れた現場で「近い順に並んだ数組がたまたま全部外れ」→
		// 隣接が 1 本も作れない、という取りこぼしが起きる。
		let sceneBar = verifyOverlap == nil && grouping.usedEvidence.contains(.scene)
			? grouping.rooms.medianNeighborDistance
			: nil

		for link in grouping.links
		{
			let selection = selectSharedPhotos(
				link: link,
				photos: photos,
				sceneBar: sceneBar,
				settings: settings,
				verifyOverlap: verifyOverlap)
			summary.verified += selection.verified
			summary.rejected += selection.rejected
			summary.undecided += selection.undecided
			let selected = selection.photos
			guard !selected.isEmpty
			else
			{
				continue
			}
			for index in selected
			{
				sharedByGroup[link.a].insert(index)
				sharedByGroup[link.b].insert(index)
			}
			adjacency.append(SortPlan.Adjacency(
				a: grouping.groups[link.a].id,
				b: grouping.groups[link.b].id,
				sharedPhotos: selected.sorted().map { photos[$0].relativePath },
				confidence: link.confidence,
				viewpointSpread: viewpointSpread(of: selected, photos: photos),
				sharedRoom: sharedRoom(of: selected, link: link, grouping: grouping),
				overlapVerified: selection.verified > 0))
		}

		let groups = grouping.groups.enumerated().map
		{ index, group -> SortPlan.Group in
			let own = Set(group.members)
			// 自分の写真として既に入っているものは共有に数えない
			// （同じファイルを 2 回入れることはできない）。
			let shared = sharedByGroup[index].subtracting(own)
			let all = (own.union(shared)).sorted()
			let dates = group.members.compactMap { photos[$0].captureDate }.sorted()
			return SortPlan.Group(
				id: group.id,
				photos: all.map { photos[$0].relativePath },
				shared: shared.sorted().map { photos[$0].relativePath },
				evidence: grouping.usedEvidence,
				rooms: rooms(of: group.members, grouping: grouping),
				captureStart: dates.first,
				captureEnd: dates.last)
		}

		return SortPlan(
			groups: groups,
			adjacency: adjacency,
			unassigned: grouping.unassigned.map { photos[$0].relativePath },
			overlapSummary: verifyOverlap == nil ? nil : summary)
	}

	/// 隣接 1 本ぶんの共有写真を選ぶ。
	///
	/// **選ぶ順は「実際に同じものが写っている順」。** 結合スコア（時刻・GPS・
	/// 露出などの合算）が高いだけのペアを採ってはいけない。共有写真の目的は
	/// 合成の対応点なので、両側に**重なって写っている**ことがすべてで、
	/// 「同じ頃に撮った」では 1 枚も意味を持たない。
	///
	/// 実データで実際に起きた失敗がこれで、`IMG_4554` から始まる連続した塊に、
	/// 700 枚離れた `IMG_38xx`（別の場所）が共有写真として入っていた。屋外と
	/// 室内が同じフォルダに混ざるのはここが原因。
	///
	/// したがって視覚的な距離が `sceneBar` を超えるペアは**採らない**（枚数を
	/// 埋めるためでも採らない）。1 枚も残らなければ隣接そのものを作らない —
	/// 重なっていない隣接は、合成にとって無いのと同じどころか、無関係な写真を
	/// グループへ持ち込むぶん有害なため。
	///
	/// **視覚特徴の距離だけでは足りない**ことが実データで分かっている（§4.6.1）。
	/// 白い壁と同じ建具ばかりの屋内では距離が狭い帯に潰れ、上の足切りを通り抜けて
	/// 700 枚離れた別の場所の写真が残った。そこで `verifyOverlap` があるときは、
	/// 上位の候補を**実際に位置合わせして画素が一致するか**まで確かめ、一致
	/// しない組は採らない。
	///
	/// そのうえで、**既に選んだ写真と視点が近すぎるものは飛ばす**（同じ場所から
	/// 向きだけ変えた写真ばかりだと、合成時に対応点が一直線に並んで解が定まらない）。
	/// 散らばりを求めた結果、枚数が足りなくなるくらいなら枚数を優先する
	/// （2 周目で条件を外して埋める）。共有写真が少ないほうが合成には致命的なため。
	///
	/// - Parameter sceneBar: 共有写真として認める視覚的な距離の上限。判定材料が
	///   無ければ nil（そのときは従来どおり結合スコア順に採る）。
	/// - Parameter verifyOverlap: 実際に重なっているかを確かめる役。nil なら
	///   確かめない。
	static func selectSharedPhotos(
		link: GroupLink,
		photos: [PhotoMetadata],
		sceneBar: Double?,
		settings: Settings,
		verifyOverlap: OverlapProbe? = nil) -> SharedSelection
	{
		guard settings.overlap > 0
		else
		{
			return SharedSelection()
		}
		let ranked = rankedCandidates(link: link, photos: photos, sceneBar: sceneBar)
		var result = SharedSelection()
		let candidates: [PairScore]
		if let verifyOverlap
		{
			let verification = verifiedCandidates(
				ranked: ranked, photos: photos, settings: settings, verifyOverlap: verifyOverlap)
			candidates = verification.candidates
			result.verified = verification.verified
			result.rejected = verification.rejected
			result.undecided = verification.undecided
		}
		else
		{
			candidates = ranked
		}
		result.photos = select(from: candidates, photos: photos, settings: settings)
		return result
	}

	/// 候補から共有写真を採る。**既に選んだ写真と視点が近すぎるものは飛ばす**が、
	/// 枚数が足りなくなるくらいなら枚数を優先する（2 周目で条件を外して埋める）。
	static func select(
		from candidates: [PairScore],
		photos: [PhotoMetadata],
		settings: Settings) -> [Int]
	{
		var selected: [Int] = []
		var chosen = Set<Int>()

		func consider(_ index: Int, enforceDiversity: Bool)
		{
			guard selected.count < settings.overlap, !chosen.contains(index)
			else
			{
				return
			}
			if enforceDiversity,
				selected.contains(where: { !isDistinctViewpoint(photos[$0], photos[index], settings: settings) })
			{
				return
			}
			chosen.insert(index)
			selected.append(index)
		}

		for pass in 0 ... 1
		{
			for candidate in candidates
			{
				consider(candidate.i, enforceDiversity: pass == 0)
				consider(candidate.j, enforceDiversity: pass == 0)
				if selected.count >= settings.overlap
				{
					return selected
				}
			}
		}
		return selected
	}

	/// 候補を上から順に「実際に重なっているか」で選り分ける。
	///
	/// **必要なぶんだけ確かめる。** 上位から埋まっていくので、多くの隣接では
	/// 数組で足りる。まとめて渡すのは実装が並行に処理できるようにするためで、
	/// 1 束ごとに「もう足りたか」を見て切り上げる。
	///
	/// 判定できなかった組（模様が無い・読めない）は**落とさない** — 分からない
	/// ことを理由に候補を捨てると、視覚特徴が取れない現場で隣接が 1 本も
	/// 作れなくなる（§4.4 と同じ判断）。
	static func verifiedCandidates(
		ranked: [PairScore],
		photos: [PhotoMetadata],
		settings: Settings,
		verifyOverlap: OverlapProbe)
		-> (candidates: [PairScore], verified: Int, rejected: Int, undecided: Int)
	{
		var accepted: [PairScore] = []
		var verified = 0
		var rejected = 0
		var undecided = 0
		var checked = 0
		var cursor = 0
		var endpoints = Set<Int>()

		while cursor < ranked.count, checked < settings.maximumOverlapChecks
		{
			let upper = min(
				ranked.count,
				cursor + max(1, settings.overlapCheckBatch),
				cursor + (settings.maximumOverlapChecks - checked))
			let batch = Array(ranked[cursor ..< upper])
			cursor = upper
			checked += batch.count
			let verdicts = verifyOverlap(batch.map
			{
				OverlapQuery(a: photos[$0.i].url, b: photos[$0.j].url)
			})
			for (offset, candidate) in batch.enumerated()
			{
				guard verdicts.indices.contains(offset), let verdict = verdicts[offset]
				else
				{
					undecided += 1
					accepted.append(candidate)
					endpoints.insert(candidate.i)
					endpoints.insert(candidate.j)
					continue
				}
				guard isOverlapping(verdict, settings: settings)
				else
				{
					rejected += 1
					continue
				}
				verified += 1
				accepted.append(candidate)
				endpoints.insert(candidate.i)
				endpoints.insert(candidate.j)
			}
			if endpoints.count >= settings.overlap
			{
				break
			}
		}
		return (accepted, verified, rejected, undecided)
	}

	/// 測った重なりを「共有写真に使ってよい」と言えるか。**ここが判断で、
	/// ラッパー（ImageRegistrar）は数値を返すだけ。**
	static func isOverlapping(_ overlap: PhotoOverlap, settings: Settings) -> Bool
	{
		overlap.agreement >= settings.minimumOverlapAgreement
			&& overlap.sharedArea >= settings.minimumSharedArea
	}

	/// 候補のペアを「実際に重なっている順」に並べ替える。`sceneBar` を超える
	/// ペアは落とす（枚数を埋めるためでも採らない）。判定材料が無いペアは
	/// 落とさない — 分からないことを理由に候補を捨てると、視覚特徴が取れない
	/// 現場で隣接が 1 本も作れなくなる。
	static func rankedCandidates(
		link: GroupLink,
		photos: [PhotoMetadata],
		sceneBar: Double?) -> [PairScore]
	{
		let scored = link.candidates.compactMap
		{ candidate -> (pair: PairScore, distance: Double)? in
			guard let left = photos[candidate.i].featurePrint,
				let right = photos[candidate.j].featurePrint
			else
			{
				// 判定できないペアは末尾に回す（落としはしない）。
				return (candidate, Double.infinity)
			}
			let distance = left.distance(to: right)
			if let sceneBar, distance > sceneBar
			{
				return nil
			}
			return (candidate, distance)
		}
		return scored.sorted
		{
			// 近い順。同じ距離なら結合スコアの高い順（結果を決定的にする）。
			$0.distance == $1.distance ? $0.pair.score > $1.pair.score : $0.distance < $1.distance
		}.map(\.pair)
	}

	/// 写真の集合が写している場所（視覚クラスタ）を、枚数の多い順に並べる。
	/// 同数なら識別子の若い順（結果を決定的にするため）。
	static func rooms(of members: [Int], grouping: GroupingResult) -> [String]
	{
		var counts: [Int: Int] = [:]
		for member in members
		{
			guard let label = grouping.rooms.labels[member]
			else
			{
				continue
			}
			counts[label, default: 0] += 1
		}
		return counts.sorted
		{
			$0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
		}.map { grouping.rooms.clusters[$0.key].id }
	}

	/// 隣接する 2 グループが**どちらも写している**場所。共有写真に最も多く
	/// 現れるものを選ぶ。共通の場所が無ければ nil（時刻の切れ目だけで隣接した、
	/// 見た目には別の場所同士）。
	static func sharedRoom(of selected: [Int], link: GroupLink, grouping: GroupingResult) -> String?
	{
		let labels = grouping.rooms.labels
		let inA = Set(grouping.groups[link.a].members.compactMap { labels[$0] })
		let inB = Set(grouping.groups[link.b].members.compactMap { labels[$0] })
		var best: (label: Int, count: Int)?
		for label in inA.intersection(inB).sorted()
		{
			let count = selected.filter { labels[$0] == label }.count
			guard let current = best
			else
			{
				best = (label, count)
				continue
			}
			if count > current.count
			{
				best = (label, count)
			}
		}
		guard let best
		else
		{
			return nil
		}
		return grouping.rooms.clusters[best.label].id
	}

	/// 2 枚が「別の視点」と言えるか。判定材料が何も無ければ true
	/// （分からないことを理由に候補を捨てない）。
	static func isDistinctViewpoint(
		_ a: PhotoMetadata,
		_ b: PhotoMetadata,
		settings: Settings) -> Bool
	{
		var judged = false
		if let left = a.location, let right = b.location
		{
			if left.horizontalDistance(to: right) >= settings.diversityDistanceMeters
			{
				return true
			}
			judged = true
		}
		if let left = a.heading, let right = b.heading
		{
			if PhotoGrouping.angleDifference(left, right) >= settings.diversityHeading
			{
				return true
			}
			judged = true
		}
		if let left = a.fingerprint, let right = b.fingerprint
		{
			if left.distance(to: right) >= settings.diversityDistance
			{
				return true
			}
			judged = true
		}
		if let left = a.featurePrint, let right = b.featurePrint
		{
			if left.distance(to: right) >= settings.diversitySceneDistance
			{
				return true
			}
			judged = true
		}
		// どれか 1 つでも「離れている」と言えれば採る。材料が何も無いときは
		// 判定できないので通す（分からないことを理由に候補を捨てない）。
		return !judged
	}

	/// 選んだ共有写真の視点がどれだけ散らばっているか（0.0〜1.0）。
	/// 見た目（知覚ハッシュ）・視覚特徴・方位の広がりのうち、最も大きいものを
	/// 採る（どれか 1 つでも散っていれば退化はしにくい）。材料が無ければ nil。
	static func viewpointSpread(of selected: [Int], photos: [PhotoMetadata]) -> Double?
	{
		guard selected.count >= 2
		else
		{
			return nil
		}
		var visual: Double?
		let fingerprints = selected.compactMap { photos[$0].fingerprint }
		if fingerprints.count >= 2
		{
			var total = 0.0
			var count = 0
			for left in 0 ..< (fingerprints.count - 1)
			{
				for right in (left + 1) ..< fingerprints.count
				{
					total += fingerprints[left].normalizedDistance(to: fingerprints[right])
					count += 1
				}
			}
			visual = min(1, (total / Double(count)) / spreadReferenceDistance)
		}

		var scene: Double?
		let prints = selected.compactMap { photos[$0].featurePrint }
		if prints.count >= 2
		{
			var total = 0.0
			var count = 0
			for left in 0 ..< (prints.count - 1)
			{
				for right in (left + 1) ..< prints.count
				{
					total += prints[left].distance(to: prints[right])
					count += 1
				}
			}
			scene = min(1, (total / Double(count)) / spreadReferenceSceneDistance)
		}

		var angular: Double?
		let headings = selected.compactMap { photos[$0].heading }
		if headings.count >= 2
		{
			var widest = 0.0
			for left in 0 ..< (headings.count - 1)
			{
				for right in (left + 1) ..< headings.count
				{
					widest = max(widest, PhotoGrouping.angleDifference(headings[left], headings[right]))
				}
			}
			angular = min(1, widest / 90)
		}

		let values = [visual, scene, angular].compactMap { $0 }
		return values.isEmpty ? nil : values.max()
	}
}
