//
//  SortDiagnostics.swift
//
//  診断モード（設計メモ §4.6）。**これが §4.0 の原則「撮影者のスキルに依存
//  しない」を実際に機能させる仕組み。**
//
//  再構成は時間がかかる（建築規模なら数時間）。撮影が不十分だったと分かるのが
//  帰社後では遅い。`sort` は再構成を伴わないので数分で終わるから、仕分けと
//  同時に「この写真群は合成まで到達できるか」を判定して報告する。撮影者が
//  不慣れでも「group-03 と group-04 の間を数枚撮り足してください」という指示は
//  誰でも実行できる。
//
//  出力は**統計と名前だけで、写真そのものを含まない**。現場の写真を共有せずに
//  閾値の妥当性を検討できるようにするため（設計メモ §10-10）。
//
//  ここは数値と文字列だけの純ロジック（InputInspection.notes と同じ考え方）。
//

import Foundation

/// 診断 1 件。`code` は機械可読な識別子で、`message` は人が読む日本語。
public struct SortDiagnostic: Codable, Equatable, Sendable
{
	public enum Severity: String, Codable, Equatable, Sendable
	{
		/// 参考情報。
		case info
		/// 結果は出るが品質が落ちる・鵜呑みにできない。
		case warning
		/// このままでは目的（合成）を達成できない。
		case error
	}

	public var severity: Severity
	public var code: String
	public var message: String

	public init(severity: Severity, code: String, message: String)
	{
		self.severity = severity
		self.code = code
		self.message = message
	}
}

public enum SortDiagnostics
{
	/// 合成が安定するのに必要な共有写真の枚数。これを下回ると変換推定の
	/// 外れ値耐性が無くなる（RANSAC が回らない）。
	public static let recommendedSharedPhotos = 10
	/// 共有写真の視点の散らばりの下限。これを下回ると対応点が一直線に並び、
	/// 相似変換の解が一意に定まらなくなる（設計メモ §5.3 の退化）。
	public static let minimumViewpointSpread = 0.15
	/// グループの写真のうち、最も多い場所（視覚クラスタ）が占めるべき割合。
	/// これを下回るグループは別々の場所が混ざっており、1 回のセッションでは
	/// 位置合わせが途切れやすい。
	public static let minimumRoomPurity = 0.7

	/// 仕分け結果を診断する。
	///
	/// - Parameters:
	///   - plan: 仕分け計画（フォルダの中身と隣接）。
	///   - grouping: グルーピングの結果（証拠・閾値の情報を使う）。
	///   - quality: 品質フィルタの結果。
	///   - request: 使った設定。
	///   - hardwareLimit: この Mac の 1 セッション上限枚数（分かる場合）。
	public static func evaluate(
		plan: SortPlan,
		grouping: GroupingResult,
		quality: QualityFilter.Outcome,
		request: SortRequest,
		hardwareLimit: Int? = nil) -> [SortDiagnostic]
	{
		var diagnostics: [SortDiagnostic] = []

		// --- 全体像 ---
		if plan.groups.isEmpty
		{
			diagnostics.append(SortDiagnostic(
				severity: .error,
				code: "noGroups",
				message: "グループが 1 つも作れませんでした。入力フォルダに写真があるか確認してください。"))
			return diagnostics
		}

		diagnostics.append(SortDiagnostic(
			severity: .info,
			code: "summary",
			message: "\(quality.kept.count) 枚を \(plan.groups.count) グループに仕分けました"
				+ "（除外 \(quality.excluded.count) 枚）。"))

		// 次にやることを必ず 1 行で示す。仕分けただけでは何も出来上がっていないので、
		// ここで手が止まると `sort` の価値が出ない。オプションの推奨には理由がある
		// — グループは撮影順の連続区間になるので sequential が効き、建物・部屋は
		// オブジェクトマスキングが破綻するので scene が要る（README「エラー 6」）。
		diagnostics.append(SortDiagnostic(
			severity: .info,
			code: "nextStep",
			message: "次はグループごとに再構成します。例: "
				+ "photogrammetry-cli <仕分け先>/\(plan.groups[0].id) \(plan.groups[0].id).usdz"
				+ " --subject scene --sample-ordering sequential"))

		if plan.groups.count == 1
		{
			diagnostics.append(SortDiagnostic(
				severity: .info,
				code: "singleGroup",
				message: "グループは 1 つです。分割せずにそのまま再構成できます"
					+ "（合成は不要です）。"))
		}

		// --- グループの大きさ ---
		let effectiveLimit = hardwareLimit.map { min($0, request.maxPerGroup) } ?? request.maxPerGroup
		for group in plan.groups
		{
			if group.photos.count > effectiveLimit
			{
				diagnostics.append(SortDiagnostic(
					severity: .warning,
					code: "groupTooLarge",
					message: "\(group.id) は \(group.photos.count) 枚で上限 \(effectiveLimit) 枚を"
						+ "超えています（共有写真 \(group.shared.count) 枚を含む）。"
						+ "--max-per-group を下げるか --overlap を減らしてください。"))
			}
			else if group.photos.count < request.minPerGroup
			{
				diagnostics.append(SortDiagnostic(
					severity: .warning,
					code: "groupTooSmall",
					message: "\(group.id) は \(group.photos.count) 枚しかありません。"
						+ "再構成が成立しない可能性があります（目安 20 枚以上）。"))
			}
		}

		// --- 隣接ごとの共有写真 ---
		for adjacency in plan.adjacency
		{
			if adjacency.sharedPhotos.count < recommendedSharedPhotos
			{
				diagnostics.append(SortDiagnostic(
					severity: .warning,
					code: "sharedPhotosTooFew",
					message: "\(adjacency.a) ↔ \(adjacency.b): 共有 "
						+ "\(adjacency.sharedPhotos.count) 枚（推奨 \(recommendedSharedPhotos) 枚以上）"
						+ " — 合成が不安定になります。この 2 か所の境目を数枚撮り足してください。"))
			}
			if let spread = adjacency.viewpointSpread, spread < minimumViewpointSpread
			{
				diagnostics.append(SortDiagnostic(
					severity: .warning,
					code: "viewpointDegenerate",
					message: "\(adjacency.a) ↔ \(adjacency.b): 共有写真の視点がほぼ一直線です"
						+ " — 2〜3 歩ずつ立ち位置を変えた写真を数枚追加してください。"))
			}
		}

		// --- 孤立と非連結 ---
		var connected = Set<String>()
		for adjacency in plan.adjacency where !adjacency.sharedPhotos.isEmpty
		{
			connected.insert(adjacency.a)
			connected.insert(adjacency.b)
		}
		for group in plan.groups where !connected.contains(group.id) && plan.groups.count > 1
		{
			diagnostics.append(SortDiagnostic(
				severity: .warning,
				code: "isolatedGroup",
				message: "\(group.id) はどのグループとも共有写真がありません"
					+ " — この範囲は単独のモデルになります（他と合成できません）。"))
		}

		let islands = countIslands(plan: plan)
		if islands > 1
		{
			diagnostics.append(SortDiagnostic(
				severity: .error,
				code: "disconnected",
				message: "グループ全体が \(islands) つの塊に分かれています"
					+ " — 1 つの座標系へまとめられません。塊どうしをつなぐ位置で"
					+ "写真を撮り足してください。"))
		}

		// --- 品質フィルタの内訳 ---
		var byReason: [ExclusionReason: Int] = [:]
		for excluded in quality.excluded
		{
			byReason[excluded.reason, default: 0] += 1
		}
		if !byReason.isEmpty
		{
			let breakdown = ExclusionReason.allCases.compactMap
			{ reason -> String? in
				guard let count = byReason[reason], count > 0
				else
				{
					return nil
				}
				return "\(reason.displayName) \(count) 枚"
			}.joined(separator: "・")
			diagnostics.append(SortDiagnostic(
				severity: .info,
				code: "excludedBreakdown",
				message: "除外の内訳: \(breakdown)（_excluded/ に理由別で退避しています）"))
		}
		if quality.blurFilterSuppressed
		{
			diagnostics.append(SortDiagnostic(
				severity: .warning,
				code: "blurFilterSuppressed",
				message: "ブレ判定を見送りました（分布からは大半がブレていると判定されたため）。"
					+ "全体的に手ブレしている可能性があります。立ち止まって撮り直すか、"
					+ "--min-sharpness で閾値を明示してください。"))
		}

		// --- 視覚的に見つけた場所（フェーズ 2） ---
		diagnostics.append(contentsOf: roomDiagnostics(plan: plan, grouping: grouping))

		// --- 使えた証拠 ---
		diagnostics.append(contentsOf: evidenceDiagnostics(grouping: grouping))

		// --- 機材の混在（iPhone はレンズが自動で切り替わる） ---
		diagnostics.append(contentsOf: equipmentDiagnostics(photos: quality.kept))

		if !plan.unassigned.isEmpty
		{
			diagnostics.append(SortDiagnostic(
				severity: .warning,
				code: "unassigned",
				message: "\(plan.unassigned.count) 枚がどのグループにも入りませんでした"
					+ "（_unassigned/ に退避）。他と繋がらない単発の写真です。"))
		}

		return diagnostics
	}

	/// 視覚的に見つけた「場所」についての診断（フェーズ 2）。
	///
	/// **仕分けの結果を撮影者の言葉で説明できるのはここだけ。** グループは
	/// 「上限枚数で切った区間」でしかないが、場所（視覚クラスタ）は
	/// 「同じ部屋を写している写真の集まり」なので、
	///
	///   - グループに別の場所が混ざっている（＝1 回のセッションで解けない）
	///   - 同じ場所が別々のグループに分かれていて繋がっていない（＝合成できない）
	///
	/// のどちらも、撮り直しではなく**仕分けの設定で直せる**問題として名指しできる。
	static func roomDiagnostics(plan: SortPlan, grouping: GroupingResult) -> [SortDiagnostic]
	{
		var diagnostics: [SortDiagnostic] = []
		let rooms = grouping.rooms

		guard grouping.usedEvidence.contains(.scene)
		else
		{
			diagnostics.append(SortDiagnostic(
				severity: .info,
				code: "noVisualAnalysis",
				message: "視覚解析（同じ場所かどうかの判定）は使いませんでした"
					+ "（視覚特徴を取れた写真は \(percent(rooms.coverage))）。"
					+ "--no-visual を外すと、部屋を行き来しながら撮った写真でも"
					+ "同じ場所どうしをまとめられます。"))
			return diagnostics
		}

		guard rooms.clusters.count > 1
		else
		{
			diagnostics.append(SortDiagnostic(
				severity: .info,
				code: "singleRoom",
				message: "視覚的にはひと続きの場所と判定しました"
					+ "（部屋・面の切り替わりは見つかりませんでした）。"))
			return diagnostics
		}

		let breakdown = rooms.clusters.map { "\($0.id) \($0.members.count) 枚" }
			.joined(separator: "・")
		diagnostics.append(SortDiagnostic(
			severity: .info,
			code: "roomsFound",
			message: "視覚的に \(rooms.clusters.count) か所を見分けました（\(breakdown)）"
				+ String(format: "。距離の閾値 %.2f%@",
					rooms.threshold,
					rooms.thresholdWasAutomatic ? "・自動決定" : "・指定値")))

		// --- 1 つのグループに複数の場所が混ざっていないか ---
		for group in grouping.groups
		{
			let counts = roomCounts(members: group.members, rooms: rooms)
			guard counts.count > 1, let dominant = counts.map(\.value).max()
			else
			{
				continue
			}
			let total = counts.map(\.value).reduce(0, +)
			let purity = Double(dominant) / Double(total)
			guard purity < minimumRoomPurity
			else
			{
				continue
			}
			let mix = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
				.map { "\(rooms.clusters[$0.key].id) \(percent(Double($0.value) / Double(total)))" }
				.joined(separator: "・")
			diagnostics.append(SortDiagnostic(
				severity: .warning,
				code: "groupMixesRooms",
				message: "\(group.id) は視覚的に別の場所の写真が混ざっています（\(mix)）"
					+ " — 1 回のセッションでは位置合わせが途切れることがあります。"
					+ "--max-per-group を下げると場所ごとに分かれやすくなります。"))
		}

		// --- 同じ場所が別々のグループに分かれ、しかも繋がっていないか ---
		diagnostics.append(contentsOf: splitRoomDiagnostics(plan: plan, grouping: grouping))
		return diagnostics
	}

	/// 写真の集合が属する場所ごとの枚数（クラスタ添字 → 枚数）。
	static func roomCounts(members: [Int], rooms: RoomClusteringResult) -> [Int: Int]
	{
		var counts: [Int: Int] = [:]
		for member in members
		{
			guard let label = rooms.labels[member]
			else
			{
				continue
			}
			counts[label, default: 0] += 1
		}
		return counts
	}

	/// 同じ場所を写しているのに、共有写真で繋がっていないグループの組を報告する。
	///
	/// **これが「視覚的に同じ部屋を見つける」ことの実利。** 一度離れて戻ってきた
	/// 撮影は時刻でも位置でも繋がらないが、見た目では同じ場所だと分かる。繋がって
	/// いなければ合成は 2 つの島に割れるので、そうなる前に名指しで伝える。
	static func splitRoomDiagnostics(plan: SortPlan, grouping: GroupingResult) -> [SortDiagnostic]
	{
		var diagnostics: [SortDiagnostic] = []
		var groupIndex: [String: Int] = [:]
		for (position, group) in grouping.groups.enumerated()
		{
			groupIndex[group.id] = position
		}
		// 共有写真で実際に繋がっている組。
		var linked = Set<Int>()
		for adjacency in plan.adjacency where !adjacency.sharedPhotos.isEmpty
		{
			guard let a = groupIndex[adjacency.a], let b = groupIndex[adjacency.b]
			else
			{
				continue
			}
			linked.insert(min(a, b) * grouping.groups.count + max(a, b))
		}

		for (label, cluster) in grouping.rooms.clusters.enumerated()
		{
			var members: [Int] = []
			for (position, group) in grouping.groups.enumerated()
				where group.members.contains(where: { grouping.rooms.labels[$0] == label })
			{
				members.append(position)
			}
			guard members.count > 1
			else
			{
				continue
			}
			// この場所を写すグループどうしが、隣接をたどって 1 つに繋がるか。
			// 総当たりで繋がっている必要は無い（鎖状でも 1 つの座標系に載る）。
			var parent = Array(0 ..< members.count)
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
			for left in 0 ..< members.count
			{
				for right in (left + 1) ..< members.count
					where linked.contains(
						members[left] * grouping.groups.count + members[right])
				{
					let a = find(left)
					let b = find(right)
					if a != b
					{
						parent[max(a, b)] = min(a, b)
					}
				}
			}
			guard Set((0 ..< members.count).map(find)).count > 1
			else
			{
				continue
			}
			let list = members.map { grouping.groups[$0].id }.joined(separator: "・")
			diagnostics.append(SortDiagnostic(
				severity: .warning,
				code: "roomSplitWithoutLink",
				message: "\(cluster.id) は同じ場所ですが \(list) に分かれ、共有写真で"
					+ "繋がっていません — このままでは合成が別々の島になります。"
					+ "--overlap を増やすか、この場所を一度に撮り通してください。"))
		}
		return diagnostics
	}

	/// どの証拠が使え、どれがなぜ使えなかったか。**「GPS が付いているのに
	/// 使われていない」を黙って済ませない**のが要点で、屋内撮影では実際に
	/// 起きる（古い測位がそのまま書き込まれている）。
	static func evidenceDiagnostics(grouping: GroupingResult) -> [SortDiagnostic]
	{
		var diagnostics: [SortDiagnostic] = []
		let used = grouping.usedEvidence
		diagnostics.append(SortDiagnostic(
			severity: .info,
			code: "evidenceUsed",
			message: used.isEmpty
				? "使える手がかりがありませんでした（撮影時刻も位置も見た目も判定できません）。"
				: "使った手がかり: " + used.map(\.displayName).joined(separator: "・")
					+ String(format: "（結合スコアの閾値 %.2f%@）",
						grouping.threshold,
						grouping.thresholdWasAutomatic ? "・自動決定" : "・指定値")))

		if !used.contains(.time)
		{
			diagnostics.append(SortDiagnostic(
				severity: .warning,
				code: "noCaptureTime",
				message: "撮影時刻が読めませんでした（写真の \(percent(grouping.evidenceCoverage[.time]))）。"
					+ "転送アプリ経由で EXIF が失われている可能性があります。"
					+ "元データ（AirDrop・写真アプリの「オリジナルを書き出す」）を使うと精度が上がります。"))
		}
		if (grouping.evidenceCoverage[.gps] ?? 0) < 0.5,
			!used.contains(.gps)
		{
			diagnostics.append(SortDiagnostic(
				severity: .info,
				code: "noUsableLocation",
				message: "位置情報は手がかりに使いませんでした"
					+ "（信用できる測位は \(percent(grouping.evidenceCoverage[.gps]))）。"
					+ "屋内・床下・小屋裏では通常の結果です。"))
		}
		return diagnostics
	}

	/// 機材・レンズの混在。iPhone は被写体に寄ると超広角へ自動で切り替わることが
	/// あり、焦点距離が混ざったセッションはアライメントが不安定になる。
	static func equipmentDiagnostics(photos: [PhotoMetadata]) -> [SortDiagnostic]
	{
		var diagnostics: [SortDiagnostic] = []

		let focalLengths = photos.compactMap(\.focalLength35mm)
		let distinctFocalLengths = Set(focalLengths.map { Int($0.rounded()) })
		if distinctFocalLengths.count > 1, focalLengths.count >= photos.count / 2
		{
			let list = distinctFocalLengths.sorted().map { "\($0)mm" }.joined(separator: "・")
			diagnostics.append(SortDiagnostic(
				severity: .warning,
				code: "mixedFocalLength",
				message: "焦点距離が混在しています（35mm 換算で \(list)）。"
					+ "iPhone は近づくと超広角へ自動で切り替わります。"
					+ "同じ画角で撮り通すとアライメントが安定します。"))
		}

		let models = Set(photos.compactMap(\.cameraModel))
		if models.count > 1
		{
			diagnostics.append(SortDiagnostic(
				severity: .info,
				code: "mixedCamera",
				message: "複数の機材の写真が混ざっています（\(models.sorted().joined(separator: "・"))）。"
					+ "グループ内で機材が混ざると精度が落ちることがあります。"))
		}
		return diagnostics
	}

	/// 隣接でつながった「島」の数。1 より大きいと 1 つの座標系にまとめられない。
	static func countIslands(plan: SortPlan) -> Int
	{
		guard !plan.groups.isEmpty
		else
		{
			return 0
		}
		var index: [String: Int] = [:]
		for (position, group) in plan.groups.enumerated()
		{
			index[group.id] = position
		}
		var parent = Array(0 ..< plan.groups.count)
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
		for adjacency in plan.adjacency where !adjacency.sharedPhotos.isEmpty
		{
			guard let left = index[adjacency.a], let right = index[adjacency.b]
			else
			{
				continue
			}
			let a = find(left)
			let b = find(right)
			if a != b
			{
				parent[max(a, b)] = min(a, b)
			}
		}
		return Set((0 ..< plan.groups.count).map(find)).count
	}

	/// 割合を「87%」の形にする。nil は「0%」。
	static func percent(_ value: Double?) -> String
	{
		"\(Int(((value ?? 0) * 100).rounded()))%"
	}
}
