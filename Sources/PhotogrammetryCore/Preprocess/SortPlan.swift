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

		public init(
			a: String,
			b: String,
			sharedPhotos: [String],
			confidence: Double,
			viewpointSpread: Double? = nil,
			sharedRoom: String? = nil)
		{
			self.a = a
			self.b = b
			self.sharedPhotos = sharedPhotos
			self.confidence = confidence
			self.viewpointSpread = viewpointSpread
			self.sharedRoom = sharedRoom
		}
	}

	public var groups: [Group]
	public var adjacency: [Adjacency]
	/// どのグループにも入らなかった写真（`_unassigned/`）。
	public var unassigned: [String]

	public init(groups: [Group], adjacency: [Adjacency], unassigned: [String])
	{
		self.groups = groups
		self.adjacency = adjacency
		self.unassigned = unassigned
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

		public init(
			overlap: Int = 15,
			diversityDistance: Int = 6,
			diversityHeading: Double = 15,
			diversityDistanceMeters: Double = 1.0,
			diversitySceneDistance: Double = 0.12)
		{
			self.overlap = overlap
			self.diversityDistance = diversityDistance
			self.diversityHeading = diversityHeading
			self.diversityDistanceMeters = diversityDistanceMeters
			self.diversitySceneDistance = diversitySceneDistance
		}
	}

	/// 視点の散らばりを 0.0〜1.0 へ正規化するときの基準（この平均ハミング距離で 1.0）。
	static let spreadReferenceDistance = 0.35
	/// 同上、視覚特徴の平均距離での基準。
	static let spreadReferenceSceneDistance = 0.25

	/// グルーピング結果から仕分け計画を作る。
	public static func plan(
		grouping: GroupingResult,
		settings: Settings = Settings()) -> SortPlan
	{
		let photos = grouping.photos
		// グループ添字で引く配列にしておく（辞書だと毎回 Optional の既定値を
		// 書くことになり、決して評価されない分岐が残る）。
		var sharedByGroup = [Set<Int>](repeating: [], count: grouping.groups.count)
		var adjacency: [SortPlan.Adjacency] = []

		for link in grouping.links
		{
			let selected = selectSharedPhotos(link: link, photos: photos, settings: settings)
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
				sharedRoom: sharedRoom(of: selected, link: link, grouping: grouping)))
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
			unassigned: grouping.unassigned.map { photos[$0].relativePath })
	}

	/// 隣接 1 本ぶんの共有写真を選ぶ。
	///
	/// 結合スコアの高い順に候補のペアを見て、その両端の写真を採っていく。ただし
	/// **既に選んだ写真と視点が近すぎるものは飛ばす**（同じ場所から向きだけ変えた
	/// 写真ばかりだと、合成時に対応点が一直線に並んで解が定まらない）。
	/// 散らばりを求めた結果、枚数が足りなくなるくらいなら枚数を優先する
	/// （2 周目で条件を外して埋める）。共有写真が少ないほうが合成には致命的なため。
	static func selectSharedPhotos(
		link: GroupLink,
		photos: [PhotoMetadata],
		settings: Settings) -> [Int]
	{
		guard settings.overlap > 0
		else
		{
			return []
		}
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
			for candidate in link.candidates
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
