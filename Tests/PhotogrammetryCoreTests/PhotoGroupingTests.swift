//
//  PhotoGroupingTests.swift
//
//  グルーピング（設計メモ §4.1〜§4.3）を合成メタデータで固定する。
//
//  確かめたいのは「特定の手がかりに依存しない」こと。時刻がある現場・無い現場・
//  GPS が信用できない現場（屋内）を並べて、**あるものだけで成立する**ことを
//  見る。実写真も GPU もネットワークも要らないので CI で常時回る。
//

import XCTest

@testable import PhotogrammetryCore

final class PhotoGroupingTests: XCTestCase
{
	/// 「部屋 A を 30 枚 → 10 分移動 → 部屋 B を 30 枚」。
	func makeTwoRooms() -> [PhotoMetadata]
	{
		SamplePhoto.sequence(start: 1, count: 30, startTime: 0, hashSeed: 0)
			+ SamplePhoto.sequence(
				start: 101, count: 30, startTime: 700, hashSeed: 0xFFFF_FFFF_0000_0000)
	}

	// -----------------------------------------------------------------
	// 基本
	// -----------------------------------------------------------------

	func testTimeAndVisualEvidenceSeparateTwoRooms()
	{
		let result = PhotoGrouping.group(photos: makeTwoRooms())
		XCTAssertEqual(result.groups.count, 2)
		XCTAssertEqual(result.groups.map { $0.members.count }, [30, 30])
		XCTAssertEqual(result.groups.map(\.id), ["group-01", "group-02"])
		XCTAssertTrue(result.usedEvidence.contains(.time))
		XCTAssertTrue(result.usedEvidence.contains(.visual))
		// 時刻が使えるなら連番は混ぜない（情報の少ない代役なので）。
		XCTAssertFalse(result.usedEvidence.contains(.sequence))
	}

	func testAdjacentGroupsAreLinked()
	{
		// **隣接が作られること自体が合成の前提。** 切ったエッジが隣接の証拠。
		let result = PhotoGrouping.group(photos: makeTwoRooms())
		XCTAssertEqual(result.links.count, 1)
		let link = try? XCTUnwrap(result.links.first)
		XCTAssertEqual(link?.a, 0)
		XCTAssertEqual(link?.b, 1)
		XCTAssertFalse(link?.candidates.isEmpty ?? true)
		// 候補は「a 側の写真, b 側の写真」の順に揃えてある。
		for candidate in link?.candidates ?? []
		{
			XCTAssertTrue(result.groups[0].members.contains(candidate.i))
			XCTAssertTrue(result.groups[1].members.contains(candidate.j))
		}
	}

	func testEveryPhotoEndsUpSomewhere()
	{
		let photos = makeTwoRooms()
		let result = PhotoGrouping.group(photos: photos)
		let assigned = result.groups.flatMap(\.members) + result.unassigned
		XCTAssertEqual(Set(assigned).count, photos.count)
	}

	func testSinglePhotoAndEmptyInput()
	{
		XCTAssertTrue(PhotoGrouping.group(photos: []).groups.isEmpty)
		let single = PhotoGrouping.group(photos: [SamplePhoto.make(index: 1, hash: 0)])
		XCTAssertEqual(single.groups.count, 1)
		XCTAssertEqual(single.groups.first?.members, [0])
	}

	// -----------------------------------------------------------------
	// 上限による分割
	// -----------------------------------------------------------------

	func testOversizedGroupIsSplitAtWeakestSeam()
	{
		// 一続きの撮影 100 枚。時刻の切れ目が無くても、上限で必ず割れる。
		let photos = SamplePhoto.sequence(start: 1, count: 100, startTime: 0, hashSeed: 0)
		var settings = GroupingSettings()
		settings.maxPerGroup = 30
		settings.minPerGroup = 10
		let result = PhotoGrouping.group(photos: photos, settings: settings)
		XCTAssertGreaterThanOrEqual(result.groups.count, 4)
		for group in result.groups
		{
			XCTAssertLessThanOrEqual(group.members.count, 30)
		}
		XCTAssertEqual(result.groups.reduce(0) { $0 + $1.members.count }, 100)
		// 分割は撮影順の連続した区間になる（合成の足がかりを残すため）。
		for group in result.groups
		{
			let members = group.members
			XCTAssertEqual(members, Array(members.sorted()))
			XCTAssertEqual(members.last! - members.first!, members.count - 1)
		}
	}

	func testSplitCutsWhereTheFlowIsWeakestNotWhereItIsConvenient()
	{
		// **実データで露見した性質。** その位置をまたぐエッジの「合計」で切ると、
		// またぐ本数（中央ほど多い）に引きずられて、内容と無関係に端が最小になる。
		// 1424 枚の現場では 63 グループ中 57 グループがちょうど下限枚数で切られ、
		// グループ間の時刻差の中央値は 2 秒だった（＝撮影の途中で切っていた）。
		//
		// 実データと同じ形にする（候補ペアの窓 60 枚 > 余白 20 枚）。位置 120 に
		// 本物の切れ目を置くが、**谷は緩やか**にする — 屋外から室内へ歩いて入る
		// 場面では時刻も位置も連続していて、変わるのは見た目と露出だけなので、
		// 結び付きは「弱くなる」だけで断ち切れはしない。
		var edges: [PairScore] = []
		for i in 0 ..< 200
		{
			for j in (i + 1) ..< min(200, i + 61)
			{
				let crossesSeam = i <= 120 && j > 120
				edges.append(PairScore(i: i, j: j, score: crossesSeam ? 0.6 : 0.9))
			}
		}
		// **離れた写真どうしの組も混ぜる。** 実データにはこれがあり（一度離れた
		// 場所へ行って戻ってきた撮影を繋ぐための候補ペア）、位置ごとに本数が
		// 違うせいで判定を歪めていた。切れ目の判定はこれに影響されてはいけない。
		for i in 0 ..< 200
		{
			for j in stride(from: i + 80, to: 200, by: 7)
			{
				edges.append(PairScore(i: i, j: j, score: 0.2))
			}
		}
		let parts = PhotoGrouping.split(
			members: Array(0 ..< 200), edges: edges, maxPerGroup: 150, minPerGroup: 20)
		XCTAssertEqual(parts.count, 2)
		XCTAssertEqual(parts.first?.count, 121)
		XCTAssertEqual(parts.last?.first, 121)
	}

	func testSplitDoesNotProduceMinimumSizedSlices()
	{
		// **実データの症状そのもの。** 60 グループ中 57 グループがちょうど
		// 下限枚数（20 枚）の連続ブロックになっていた。切れ目が毎回いちばん端に
		// 来ると、上限を割るまで「端から下限枚数ずつ」削ぎ落とすことになる。
		// 一様に繋がった列（本物の切れ目が無い）では、そうならないことを見る。
		var edges: [PairScore] = []
		for i in 0 ..< 300
		{
			for j in (i + 1) ..< min(300, i + 61)
			{
				// 撮影順が近いほど強い、という自然な減衰だけを与える。
				edges.append(PairScore(i: i, j: j, score: 0.95 - Double(j - i) * 0.01))
			}
		}
		let parts = PhotoGrouping.split(
			members: Array(0 ..< 300), edges: edges, maxPerGroup: 120, minPerGroup: 20)
		XCTAssertEqual(parts.reduce(0) { $0 + $1.count }, 300)
		for part in parts
		{
			XCTAssertLessThanOrEqual(part.count, 120)
			// 下限ちょうどの薄切りが並ぶ形になっていないこと。
			XCTAssertGreaterThan(part.count, 20, "下限ちょうどの薄切りになっています")
		}
	}

	func testSplitGroupsRemainLinked()
	{
		let photos = SamplePhoto.sequence(start: 1, count: 100, startTime: 0, hashSeed: 0)
		var settings = GroupingSettings()
		settings.maxPerGroup = 30
		settings.minPerGroup = 10
		let result = PhotoGrouping.group(photos: photos, settings: settings)
		// 分割で生まれた境界には必ず隣接がある（＝あとで合成できる）。
		XCTAssertGreaterThanOrEqual(result.links.count, result.groups.count - 1)
	}

	func testSmallGroupThatMatchesNothingGoesToUnassigned()
	{
		// 30 枚 + 3 枚。3 枚は 12 分後・見た目もまるで違う（別の場所を数枚だけ
		// 撮った、あるいは SNS 経由で紛れ込んだ写真）。**3 枚では再構成が成立
		// しないが、だからといって隣のグループへ混ぜてよいことにはならない**
		// （設計メモ §4.6.2）。黙って混ぜず _unassigned へ送り、診断で伝える。
		let photos = SamplePhoto.sequence(start: 1, count: 30, startTime: 0, hashSeed: 0)
			+ SamplePhoto.sequence(
				start: 101, count: 3, startTime: 700, hashSeed: 0xFFFF_FFFF_0000_0000)
		let result = PhotoGrouping.group(photos: photos)
		XCTAssertEqual(result.groups.count, 1)
		XCTAssertEqual(result.groups.first?.members.count, 30)
		XCTAssertEqual(result.unassigned.count, 3)
	}

	// -----------------------------------------------------------------
	// 証拠の取捨
	// -----------------------------------------------------------------

	func testUntrustworthyLocationIsNotUsed()
	{
		// 屋内で撮ると、直前の屋外の測位が誤差つきで残る。**位置が付いている
		// ことを信用の根拠にしない。**
		let photos = (0 ..< 20).map
		{ index in
			SamplePhoto.make(
				index: index,
				secondsFromEpoch: Double(index) * 3,
				latitude: 35.0,
				longitude: 139.0,
				accuracy: 500,
				hash: UInt64(index))
		}
		let result = PhotoGrouping.group(photos: photos)
		XCTAssertFalse(result.usedEvidence.contains(.gps))
		XCTAssertEqual(result.evidenceCoverage[.gps], 0)
	}

	func testAccurateLocationIsUsed()
	{
		let photos = (0 ..< 20).map
		{ index in
			SamplePhoto.make(
				index: index,
				secondsFromEpoch: Double(index) * 3,
				latitude: 35.0 + Double(index) * 0.00001,
				longitude: 139.0,
				accuracy: 5,
				hash: UInt64(index))
		}
		let result = PhotoGrouping.group(photos: photos)
		XCTAssertTrue(result.usedEvidence.contains(.gps))
	}

	func testVisualEvidenceAloneCanGroupPhotosWithoutExif()
	{
		// 転送アプリで EXIF が剥がれた写真（時刻も位置も無い）。見た目と
		// ファイル名の連番だけで塊になる。
		let photos = (0 ..< 20).map
		{ index in
			SamplePhoto.make(index: index, hash: index < 10 ? 0x0F : 0xFFFF_FFFF_FF00)
		}
		let result = PhotoGrouping.group(photos: photos)
		XCTAssertTrue(result.usedEvidence.contains(.visual))
		XCTAssertTrue(result.usedEvidence.contains(.sequence))
		XCTAssertFalse(result.usedEvidence.contains(.time))
	}

	func testFolderStructureIsUsedWhenPresent()
	{
		// 撮影者が階ごとにフォルダを分けている＝最も信頼できる区切り。
		let photos = SamplePhoto.sequence(
			start: 1, count: 20, startTime: 0, hashSeed: 0, folder: "1F")
			+ SamplePhoto.sequence(
				start: 101, count: 20, startTime: 60, hashSeed: 0xFFFF_0000_0000_0000,
				folder: "2F")
		let result = PhotoGrouping.group(photos: photos)
		XCTAssertTrue(result.usedEvidence.contains(.folder))
		XCTAssertEqual(result.groups.count, 2)
	}

	func testEvidenceCoverageIsReported()
	{
		// 診断で「なぜ GPS を使わなかったか」を説明するための材料。
		let result = PhotoGrouping.group(photos: makeTwoRooms())
		XCTAssertEqual(result.evidenceCoverage[.time], 1)
		XCTAssertEqual(result.evidenceCoverage[.visual], 1)
		XCTAssertEqual(result.evidenceCoverage[.gps], 0)
		XCTAssertEqual(result.evidenceCoverage[.heading], 0)
	}

	// -----------------------------------------------------------------
	// 閾値と統計
	// -----------------------------------------------------------------

	func testExplicitThresholdIsRecorded()
	{
		var settings = GroupingSettings()
		settings.threshold = 0.42
		let result = PhotoGrouping.group(photos: makeTwoRooms(), settings: settings)
		XCTAssertEqual(result.threshold, 0.42)
		XCTAssertFalse(result.thresholdWasAutomatic)
	}

	func testAutomaticThresholdStaysInRange()
	{
		let result = PhotoGrouping.group(photos: makeTwoRooms())
		XCTAssertTrue(result.thresholdWasAutomatic)
		XCTAssertGreaterThanOrEqual(result.threshold, 0.15)
		XCTAssertLessThanOrEqual(result.threshold, 0.8)
	}

	func testScoreHistogramIsProduced()
	{
		// 写真を含まない統計だけで閾値を検討できるようにするため（§10-10）。
		let result = PhotoGrouping.group(photos: makeTwoRooms())
		XCTAssertEqual(result.scoreHistogram.count, PhotoGrouping.histogramBins)
		XCTAssertGreaterThan(result.scoreHistogram.reduce(0, +), 0)
	}

	// -----------------------------------------------------------------
	// 視覚特徴（フェーズ 2）
	//
	// フェーズ 1 の手がかりは「撮影の流れ」しか見ておらず、**場所そのものの
	// 同一性**を判定できない。ここで見るのは、実写真で実際に起きる 2 つの
	// 取り違えを視覚特徴が是正することと、特徴が無い現場ではフェーズ 1 と
	// まったく同じ挙動に戻ること。
	// -----------------------------------------------------------------

	/// 「隣り合う部屋を続けて撮った」。**時刻は途切れず、白い壁ばかりで知覚
	/// ハッシュもまったく変化しない**現場で、フェーズ 1 の手がかりでは
	/// 見分けようがない（実際に精度が出なかったのはこの形）。
	func makeAdjacentRooms(withFeaturePrints: Bool) -> [PhotoMetadata]
	{
		(0 ..< 60).map
		{ index in
			SamplePhoto.make(
				index: index + 1,
				secondsFromEpoch: Double(index) * 3,
				hash: 0x0F0F_0F0F_0F0F_0F0F,
				featurePrint: withFeaturePrints
					? SamplePhoto.featurePrint(room: index < 30 ? 0 : 6, step: index % 30)
					: nil)
		}
	}

	func testVisualSceneSeparatesRoomsThatTimeAndHashCannot()
	{
		// フェーズ 1 の手がかりだけでは 1 つの塊にしか見えない。
		let withoutPrints = PhotoGrouping.group(photos: makeAdjacentRooms(withFeaturePrints: false))
		XCTAssertEqual(withoutPrints.groups.count, 1)
		XCTAssertFalse(withoutPrints.usedEvidence.contains(.scene))
		XCTAssertFalse(withoutPrints.usedEvidence.contains(.room))

		// 視覚特徴を足すと、同じ入力が場所ごとに分かれる。
		let result = PhotoGrouping.group(photos: makeAdjacentRooms(withFeaturePrints: true))
		XCTAssertTrue(result.usedEvidence.contains(.scene))
		XCTAssertTrue(result.usedEvidence.contains(.room))
		XCTAssertEqual(result.rooms.clusters.count, 2)
		XCTAssertEqual(result.groups.count, 2)
		XCTAssertEqual(result.groups.map { $0.members.count }, [30, 30])
		// 切ったところに隣接がある（＝あとで合成できる）。
		XCTAssertEqual(result.links.count, 1)
	}

	func testReturningToTheSameRoomIsGroupedTogether()
	{
		// 部屋 A → 部屋 B → 部屋 A。時刻でも位置でも A の 2 区画は繋がらないが、
		// 見た目では同じ場所だと分かる。
		let photos = SamplePhoto.sequence(
			start: 1, count: 20, startTime: 0, hashSeed: 0, room: 0)
			+ SamplePhoto.sequence(
				start: 101, count: 20, startTime: 3000, hashSeed: 0xFFFF_FFFF_0000_0000, room: 6)
			+ SamplePhoto.sequence(
				start: 201, count: 20, startTime: 6000, hashSeed: 0, room: 0)
		let result = PhotoGrouping.group(photos: photos)
		XCTAssertEqual(result.rooms.clusters.count, 2)
		// 部屋 A の 2 区画が 1 つのクラスタに入っている。
		XCTAssertEqual(result.rooms.labels[0], result.rooms.labels[59])
		XCTAssertNotEqual(result.rooms.labels[0], result.rooms.labels[20])
		// そして同じグループになる（＝あとで 1 つのモデルとして再構成できる）。
		XCTAssertEqual(result.groups.count, 2)
		let first = result.groups[0].members
		XCTAssertTrue(first.contains(0))
		XCTAssertTrue(first.contains(59))
	}

	func testSceneAndRoomCoverageIsReported()
	{
		let result = PhotoGrouping.group(photos: makeAdjacentRooms(withFeaturePrints: true))
		XCTAssertEqual(result.evidenceCoverage[.scene], 1)
		XCTAssertEqual(result.evidenceCoverage[.room], 1)

		// 場所が 1 つしか見つからなければ、room は何も区別しない証拠になる。
		let single = PhotoGrouping.group(
			photos: SamplePhoto.sequence(start: 1, count: 20, startTime: 0, hashSeed: 0, room: 2))
		XCTAssertEqual(single.rooms.clusters.count, 1)
		XCTAssertEqual(single.evidenceCoverage[.room], 0)
		XCTAssertTrue(single.usedEvidence.contains(.scene))
		XCTAssertFalse(single.usedEvidence.contains(.room))
	}

	func testRoomEvidenceIsIgnoredWhenOnePlaceDominates()
	{
		// **実データで起きた形。** 1424 枚の現場で 97% が 1 か所にまとまり、
		// 「同じ場所」が全ペアで成り立った。区別に寄与しないのに重みは最大なので、
		// 時刻や露出で分かれるはずの屋外↔室内のペアまで繋いでしまう。
		// フォルダが 1 つのときと同じ扱いにする。
		func rooms(_ sizes: [Int]) -> RoomClusteringResult
		{
			var labels: [Int?] = []
			var clusters: [RoomCluster] = []
			for (label, size) in sizes.enumerated()
			{
				let start = labels.count
				labels.append(contentsOf: [Int?](repeating: label, count: size))
				clusters.append(RoomCluster(
					id: RoomClustering.identifier(label),
					members: Array(start ..< labels.count)))
			}
			return RoomClusteringResult(
				clusters: clusters,
				labels: labels,
				neighbors: [],
				threshold: 0.3,
				thresholdWasAutomatic: true,
				separability: 0.5,
				distanceHistogram: [],
				coverage: 1)
		}
		let settings = GroupingSettings()
		// 95% が 1 か所 → 使わない。
		XCTAssertEqual(PhotoGrouping.roomCoverage(rooms: rooms([95, 5]), settings: settings), 0)
		// 場所が 1 つしかない → 使わない（従来どおり）。
		XCTAssertEqual(PhotoGrouping.roomCoverage(rooms: rooms([100]), settings: settings), 0)
		// きちんと分かれている → 使う。
		XCTAssertEqual(PhotoGrouping.roomCoverage(rooms: rooms([60, 40]), settings: settings), 1)
	}

	func testVisualEvidenceCanBeTurnedOffByWeight()
	{
		// `--no-visual` は SortRequest が重みを 0 にすることで効く。特徴が
		// 付いている写真を渡されても使わない。
		var settings = GroupingSettings()
		settings.weights[.scene] = 0
		settings.weights[.room] = 0
		let result = PhotoGrouping.group(
			photos: makeAdjacentRooms(withFeaturePrints: true), settings: settings)
		XCTAssertFalse(result.usedEvidence.contains(.scene))
		XCTAssertFalse(result.usedEvidence.contains(.room))
		XCTAssertEqual(result.groups.count, 1)
	}

	// -----------------------------------------------------------------
	// 部品
	// -----------------------------------------------------------------

	func testIdentifierFormat()
	{
		XCTAssertEqual(PhotoGrouping.identifier(0), "group-01")
		XCTAssertEqual(PhotoGrouping.identifier(9), "group-10")
		XCTAssertEqual(PhotoGrouping.identifier(99), "group-100")
	}

	func testAngleDifferenceWrapsAround()
	{
		XCTAssertEqual(PhotoGrouping.angleDifference(10, 350), 20, accuracy: 1e-9)
		XCTAssertEqual(PhotoGrouping.angleDifference(0, 180), 180, accuracy: 1e-9)
		XCTAssertEqual(PhotoGrouping.angleDifference(90, 90), 0, accuracy: 1e-9)
	}

	func testGeoDistanceIsMetric()
	{
		// 緯度 0.001 度 ≒ 111 m。
		let a = GeoLocation(latitude: 35.0, longitude: 139.0)
		let b = GeoLocation(latitude: 35.001, longitude: 139.0)
		XCTAssertEqual(a.horizontalDistance(to: b), 111, accuracy: 2)
		XCTAssertEqual(a.horizontalDistance(to: a), 0, accuracy: 1e-6)
		XCTAssertNil(a.verticalDistance(to: b))
	}

	func testVerticalDistanceNeedsAltitudeOnBothSides()
	{
		// 階の分離に使う。片方でも高度が無ければ「判定できない」を返す。
		let ground = GeoLocation(latitude: 35.0, longitude: 139.0, altitude: 12.0)
		let upstairs = GeoLocation(latitude: 35.0, longitude: 139.0, altitude: 15.2)
		XCTAssertEqual(ground.verticalDistance(to: upstairs) ?? 0, 3.2, accuracy: 1e-9)
		XCTAssertNil(ground.verticalDistance(to: GeoLocation(latitude: 35.0, longitude: 139.0)))
	}

	func testAltitudeIsUsedWhenAvailable()
	{
		let photos = (0 ..< 20).map
		{ index in
			SamplePhoto.make(
				index: index,
				secondsFromEpoch: Double(index) * 3,
				latitude: 35.0,
				longitude: 139.0,
				altitude: index < 10 ? 12.0 : 15.2,
				accuracy: 5,
				hash: UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
		}
		let result = PhotoGrouping.group(photos: photos)
		XCTAssertTrue(result.usedEvidence.contains(.altitude))
		XCTAssertEqual(result.evidenceCoverage[.altitude], 1)
	}

	func testLocationWithoutAccuracyIsStillUsable()
	{
		// EXIF に GPSHPositioningError を書かない機材もある。誤差が分からない
		// ことは「使えない」ではない（古い測位かどうかは別途見ている）。
		let photos = (0 ..< 20).map
		{ index in
			SamplePhoto.make(
				index: index,
				secondsFromEpoch: Double(index) * 3,
				latitude: 35.0 + Double(index) * 0.00001,
				longitude: 139.0,
				accuracy: nil,
				hash: UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
		}
		let result = PhotoGrouping.group(photos: photos)
		XCTAssertTrue(result.usedEvidence.contains(.gps))
		XCTAssertEqual(result.evidenceCoverage[.gps], 1)
	}

	func testSmallGroupBetweenTwoUnrelatedNeighboursIsNotForcedIntoEither()
	{
		// 両隣のどちらとも似ていない小さな塊。**どちらか近いほうへ入れる**のが
		// 以前の動きだったが、それは無関係な写真を持ち込むだけで再構成の役に
		// 立たない（設計メモ §4.6.2）。どちらのグループも汚さずに退避する。
		var settings = GroupingSettings()
		settings.minPerGroup = 8
		settings.maxPerGroup = 20
		let photos = SamplePhoto.sequence(start: 1, count: 12, startTime: 0, hashSeed: 0)
			+ SamplePhoto.sequence(
				start: 101, count: 3, startTime: 3000, hashSeed: 0x0F0F_0F0F_0F0F_0F0F)
			+ SamplePhoto.sequence(
				start: 201, count: 12, startTime: 6000, hashSeed: 0xFFFF_FFFF_FFFF_FFFF)
		let result = PhotoGrouping.group(photos: photos, settings: settings)
		XCTAssertEqual(result.groups.map { $0.members.count }.sorted(), [12, 12])
		XCTAssertEqual(result.unassigned.count, 3)
		// 写真は 1 枚も消えない（どこかに必ず現れる）。
		let assigned = result.groups.flatMap(\.members) + result.unassigned
		XCTAssertEqual(Set(assigned).count, photos.count)
	}

	func testStartsBeforeHandlesEmptySets()
	{
		// グループの並べ替えの比較。空集合は作らない設計だが、比較そのものは
		// 全順序として成立させておく。
		XCTAssertTrue(PhotoGrouping.startsBefore([1, 2], [3]))
		XCTAssertFalse(PhotoGrouping.startsBefore([3], [1, 2]))
		XCTAssertTrue(PhotoGrouping.startsBefore([1], []))
		XCTAssertFalse(PhotoGrouping.startsBefore([], [1]))
		XCTAssertFalse(PhotoGrouping.startsBefore([], []))
	}

	func testEveryEvidenceKindHasADisplayName()
	{
		// 診断で「使った手がかり」として並ぶ語彙。
		for kind in EvidenceKind.allCases
		{
			XCTAssertFalse(kind.displayName.isEmpty, "\(kind.rawValue) の表示名が空です")
			XCTAssertNotEqual(kind.displayName, kind.rawValue)
		}
		XCTAssertEqual(EvidenceKind.folder.displayName, "フォルダ分け")
	}

	func testUnassignedPhotosAreReportedWhenTheyCannotBeAbsorbed()
	{
		// 隣とまったく繋がらない小さな塊は、黙って他へ混ぜず _unassigned へ送る。
		var settings = GroupingSettings()
		settings.minPerGroup = 8
		settings.maxPerGroup = 12
		let photos = SamplePhoto.sequence(start: 1, count: 12, startTime: 0, hashSeed: 0)
			+ SamplePhoto.sequence(
				start: 101, count: 12, startTime: 4000, hashSeed: 0x0F0F_0F0F_0F0F_0F0F)
			+ SamplePhoto.sequence(
				start: 201, count: 2, startTime: 90000, hashSeed: 0xFFFF_FFFF_FFFF_FFFF)
		let result = PhotoGrouping.group(photos: photos, settings: settings)
		let assigned = result.groups.flatMap(\.members) + result.unassigned
		XCTAssertEqual(Set(assigned).count, photos.count)
	}

	// -----------------------------------------------------------------
	// 小さすぎるグループの吸収（設計メモ §4.6.1 の 2 つめの症状）
	// -----------------------------------------------------------------

	func testLinkStrengthUsesTheStrongestEdgesNotTheirNumber()
	{
		// 上位 5 本の平均。本数がいくら多くても弱ければ弱いまま。
		XCTAssertEqual(
			PhotoGrouping.linkStrength([1.0, 0.9, 0.8, 0.7, 0.6, 0.1, 0.1, 0.1]),
			0.8,
			accuracy: 1e-9)
		XCTAssertEqual(PhotoGrouping.linkStrength([0.4]), 0.4, accuracy: 1e-9)
		XCTAssertEqual(PhotoGrouping.linkStrength([]), 0)
	}

	/// **実データで起きた失敗。** 強さを合計で測ると、弱い繋がりでも本数が多い
	/// 大きなグループが必ず勝つ。EXIF の無い写真（SNS 経由）が作る小さな塊が、
	/// まったく別の場所の大きなグループへ吸い込まれていた。
	func testAbsorptionPicksTheStrongestLinkNotTheMostEdges()
	{
		var settings = GroupingSettings()
		settings.minPerGroup = 3
		settings.maxPerGroup = 100
		let small = [0, 1]
		let many = Array(2 ... 21)
		let few = [22, 23, 24]
		var edges: [PairScore] = []
		// 弱い繋がりが 20 本（合計 4.0）。
		for other in many
		{
			edges.append(PairScore(i: 0, j: other, score: 0.2))
		}
		// 強い繋がりが 3 本（合計 2.4）。
		for other in few
		{
			edges.append(PairScore(i: 1, j: other, score: 0.8))
		}
		let absorbed = PhotoGrouping.absorbSmallGroups(
			parts: [small, many, few], edges: edges, bar: 0.1, settings: settings)
		XCTAssertTrue(absorbed.unassigned.isEmpty)
		let host = absorbed.parts.first { $0.contains(0) }
		XCTAssertEqual(host, (small + few).sorted())
	}

	/// 結び付きが弱ければ吸収しない。**「小さいからどこかへ入れる」は、無関係な
	/// 写真をグループへ持ち込むだけ**なので、`_unassigned` へ送って必ず伝える。
	func testWeakLinksSendSmallGroupsToUnassigned()
	{
		var settings = GroupingSettings()
		settings.minPerGroup = 3
		settings.maxPerGroup = 100
		let small = [0, 1]
		let host = Array(2 ... 21)
		let edges = host.map { PairScore(i: 0, j: $0, score: 0.1) }
		let absorbed = PhotoGrouping.absorbSmallGroups(
			parts: [small, host], edges: edges, bar: 0.4, settings: settings)
		XCTAssertEqual(absorbed.unassigned, small)
		XCTAssertEqual(absorbed.parts, [host])
	}

	/// ただし**上限枚数で割られた区間**まで追い出してはいけない。撮影の流れが
	/// 続いている塊は結び付きが強いので、下限を課しても吸収される。
	func testContinuousShootingIsStillAbsorbed()
	{
		var settings = GroupingSettings()
		settings.minPerGroup = 8
		settings.maxPerGroup = 20
		let photos = SamplePhoto.sequence(start: 1, count: 12, startTime: 0, hashSeed: 0)
			+ SamplePhoto.sequence(start: 13, count: 3, startTime: 36, hashSeed: 0)
		let result = PhotoGrouping.group(photos: photos, settings: settings)
		XCTAssertEqual(result.groups.count, 1)
		XCTAssertTrue(result.unassigned.isEmpty)
	}
}
