//
//  SortPlanTests.swift
//
//  重複付き分割（設計メモ §4.4）を固定する。**共有写真が両方のフォルダに
//  入ること**が本設計の要で、これが崩れるとフェーズ 3 の合成が対応点を
//  得られなくなる。ここは最も壊してはいけない性質。
//

import XCTest

@testable import PhotogrammetryCore

final class SortPlanTests: XCTestCase
{
	func makeGrouping() -> GroupingResult
	{
		let photos = SamplePhoto.sequence(start: 1, count: 30, startTime: 0, hashSeed: 0)
			+ SamplePhoto.sequence(
				start: 101, count: 30, startTime: 700, hashSeed: 0xFFFF_FFFF_0000_0000)
		return PhotoGrouping.group(photos: photos)
	}

	func testSharedPhotosAppearInBothGroups()
	{
		let grouping = makeGrouping()
		let plan = SortPlanner.plan(grouping: grouping)
		XCTAssertEqual(plan.groups.count, 2)
		XCTAssertEqual(plan.adjacency.count, 1)

		let adjacency = plan.adjacency[0]
		XCTAssertFalse(adjacency.sharedPhotos.isEmpty)
		let first = plan.groups[0]
		let second = plan.groups[1]
		for photo in adjacency.sharedPhotos
		{
			// **同じファイルが両方のフォルダに入る。** これが対応点になる。
			XCTAssertTrue(first.photos.contains(photo), "\(photo) が \(first.id) にありません")
			XCTAssertTrue(second.photos.contains(photo), "\(photo) が \(second.id) にありません")
		}
	}

	func testSharedCountRespectsOverlapSetting()
	{
		let grouping = makeGrouping()
		let plan = SortPlanner.plan(grouping: grouping, settings: SortPlanner.Settings(overlap: 6))
		XCTAssertEqual(plan.adjacency[0].sharedPhotos.count, 6)
	}

	func testZeroOverlapProducesNoAdjacency()
	{
		// 共有 0 枚は「合成しない」の意思表示。隣接を作らない。
		let grouping = makeGrouping()
		let plan = SortPlanner.plan(grouping: grouping, settings: SortPlanner.Settings(overlap: 0))
		XCTAssertTrue(plan.adjacency.isEmpty)
		for group in plan.groups
		{
			XCTAssertTrue(group.shared.isEmpty)
		}
	}

	func testGroupPhotosAreOwnMembersPlusShared()
	{
		let grouping = makeGrouping()
		let plan = SortPlanner.plan(grouping: grouping)
		for (index, group) in plan.groups.enumerated()
		{
			let members = grouping.groups[index].members.count
			XCTAssertEqual(group.photos.count, members + group.shared.count)
			// 自分の写真は共有として二重に数えない。
			XCTAssertTrue(Set(group.shared).isDisjoint(
				with: Set(grouping.groups[index].members.map { grouping.photos[$0].relativePath })))
		}
	}

	func testCaptureRangeIsRecorded()
	{
		let plan = SortPlanner.plan(grouping: makeGrouping())
		let first = plan.groups[0]
		XCTAssertNotNil(first.captureStart)
		XCTAssertNotNil(first.captureEnd)
		XCTAssertLessThanOrEqual(first.captureStart ?? .distantFuture, first.captureEnd ?? .distantPast)
	}

	// -----------------------------------------------------------------
	// 視覚的に見つけた場所（フェーズ 2）
	// -----------------------------------------------------------------

	/// 1 つの部屋を 60 枚。上限で 2 グループに割れるが、**場所は 1 つ**。
	func makeSingleRoomGrouping() -> GroupingResult
	{
		var settings = GroupingSettings()
		settings.maxPerGroup = 30
		settings.minPerGroup = 10
		let photos = (0 ..< 60).map
		{ index in
			SamplePhoto.make(
				index: index + 1,
				secondsFromEpoch: Double(index) * 3,
				hash: 0x0F0F_0F0F_0F0F_0F0F,
				featurePrint: SamplePhoto.featurePrint(room: 0, step: index))
		}
		return PhotoGrouping.group(photos: photos, settings: settings)
	}

	func testSharedRoomIsRecordedWhenBothGroupsSeeTheSamePlace()
	{
		// 場所は 1 つでも、上限枚数で複数のグループに割れる（分割は撮影順の
		// 最も弱い切れ目で行うので、均等に 2 つとは限らない）。
		let grouping = makeSingleRoomGrouping()
		XCTAssertEqual(grouping.rooms.clusters.count, 1)
		XCTAssertGreaterThan(grouping.groups.count, 1)

		let plan = SortPlanner.plan(grouping: grouping)
		XCTAssertFalse(plan.adjacency.isEmpty)
		// **合成では最も信頼できる繋ぎ目。** 同じ場所を写しているグループ同士だと
		// 分かっていれば、対応点が期待できる。
		for adjacency in plan.adjacency
		{
			XCTAssertEqual(adjacency.sharedRoom, "room-01")
		}
		for group in plan.groups
		{
			XCTAssertEqual(group.rooms, ["room-01"])
		}
	}

	func testGroupRoomsAreOrderedByPhotoCount()
	{
		// 1 つのグループに複数の場所が混ざるときの並び。**枚数の多い順**で、
		// 同数なら識別子の若い順（manifest と診断の文面がこの順に従う）。
		let mixed = manualGrouping(
			groups: [Array(0 ..< 10)],
			labels: [1, 1, 1, 0, 0, 0, 0, 0, 0, 0])
		XCTAssertEqual(
			SortPlanner.rooms(of: Array(0 ..< 10), grouping: mixed),
			["room-01", "room-02"])

		let tied = manualGrouping(
			groups: [Array(0 ..< 4)],
			labels: [1, 1, 0, 0])
		XCTAssertEqual(SortPlanner.rooms(of: Array(0 ..< 4), grouping: tied), ["room-01", "room-02"])
	}

	func testDifferentPlacesHaveNoSharedRoom()
	{
		let photos = (0 ..< 60).map
		{ index in
			SamplePhoto.make(
				index: index + 1,
				secondsFromEpoch: Double(index) * 3,
				hash: 0x0F0F_0F0F_0F0F_0F0F,
				featurePrint: SamplePhoto.featurePrint(room: index < 30 ? 0 : 6, step: index % 30))
		}
		let grouping = PhotoGrouping.group(photos: photos)
		let plan = SortPlanner.plan(grouping: grouping)
		XCTAssertEqual(plan.groups.map(\.rooms), [["room-01"], ["room-02"]])
		XCTAssertNil(plan.adjacency.first?.sharedRoom)
	}

	// -----------------------------------------------------------------
	// 視点の散らばり（共線退化の予防）
	// -----------------------------------------------------------------

	func testDistinctViewpointUsesWhicheverEvidenceExists()
	{
		let settings = SortPlanner.Settings()
		// 位置が離れていれば別視点。
		let a = SamplePhoto.make(index: 1, latitude: 35.0, longitude: 139.0, hash: 0)
		let b = SamplePhoto.make(index: 2, latitude: 35.0001, longitude: 139.0, hash: 0)
		XCTAssertTrue(SortPlanner.isDistinctViewpoint(a, b, settings: settings))

		// 同じ場所・同じ向き・同じ見た目なら別視点ではない。
		let c = SamplePhoto.make(index: 3, heading: 10, hash: 0xFF)
		let d = SamplePhoto.make(index: 4, heading: 12, hash: 0xFF)
		XCTAssertFalse(SortPlanner.isDistinctViewpoint(c, d, settings: settings))

		// 判定材料が何も無ければ通す（分からないことを理由に捨てない）。
		let e = SamplePhoto.make(index: 5, hash: nil)
		let f = SamplePhoto.make(index: 6, hash: nil)
		XCTAssertTrue(SortPlanner.isDistinctViewpoint(e, f, settings: settings))
	}

	func testViewpointSpreadIsHigherForScatteredViews()
	{
		let photos = [
			SamplePhoto.make(index: 1, heading: 0, hash: 0x0000_0000_0000_0000),
			SamplePhoto.make(index: 2, heading: 90, hash: 0xFFFF_FFFF_FFFF_FFFF),
		]
		let scattered = SortPlanner.viewpointSpread(of: [0, 1], photos: photos)
		let identical = SortPlanner.viewpointSpread(
			of: [0, 1],
			photos: [
				SamplePhoto.make(index: 1, heading: 0, hash: 7),
				SamplePhoto.make(index: 2, heading: 1, hash: 7),
			])
		XCTAssertNotNil(scattered)
		XCTAssertNotNil(identical)
		XCTAssertGreaterThan(scattered ?? 0, identical ?? 1)
		XCTAssertLessThan(identical ?? 1, SortDiagnostics.minimumViewpointSpread)
	}

	func testViewpointSpreadCanBeJudgedFromFeaturePrintsAlone()
	{
		// 方位も知覚ハッシュも無い写真（EXIF が剥がれている）。視覚特徴だけでも
		// 「立ち位置を変えたか」は言える。
		let photos = [
			SamplePhoto.make(index: 1, hash: nil, featurePrint: SamplePhoto.featurePrint(room: 0, step: 0)),
			SamplePhoto.make(index: 2, hash: nil, featurePrint: SamplePhoto.featurePrint(room: 0, step: 40)),
		]
		let close = [
			SamplePhoto.make(index: 3, hash: nil, featurePrint: SamplePhoto.featurePrint(room: 0, step: 0)),
			SamplePhoto.make(index: 4, hash: nil, featurePrint: SamplePhoto.featurePrint(room: 0, step: 1)),
		]
		let scattered = SortPlanner.viewpointSpread(of: [0, 1], photos: photos)
		let identical = SortPlanner.viewpointSpread(of: [0, 1], photos: close)
		XCTAssertNotNil(scattered)
		XCTAssertNotNil(identical)
		XCTAssertGreaterThan(scattered ?? 0, identical ?? 1)
		XCTAssertLessThan(identical ?? 1, SortDiagnostics.minimumViewpointSpread)
	}

	func testViewpointSpreadNeedsAtLeastTwoPhotos()
	{
		XCTAssertNil(SortPlanner.viewpointSpread(
			of: [0], photos: [SamplePhoto.make(index: 1, hash: 1)]))
	}

	// -----------------------------------------------------------------
	// 共有写真は「実際に重なっている」ものだけ
	// -----------------------------------------------------------------

	func testSharedPhotosArePickedByVisualOverlapNotByScore()
	{
		// **実データで起きた失敗。** 結合スコア（時刻・GPS・露出の合算）が高い
		// だけのペアを採ると、700 枚離れた別の場所の写真が共有写真として入る。
		// 共有写真は合成の対応点なので、両側に重なって写っていることがすべて。
		let photos = [
			// 0〜1: 本当に重なっている組（視覚特徴が近い）。ただしスコアは低い。
			SamplePhoto.make(index: 1, hash: 0x0F, featurePrint: SamplePhoto.featurePrint(room: 0, step: 0)),
			SamplePhoto.make(index: 2, hash: 0x0F, featurePrint: SamplePhoto.featurePrint(room: 0, step: 1)),
			// 2〜3: 別の場所どうし（視覚特徴が遠い）。スコアだけは高い。
			SamplePhoto.make(index: 3, hash: 0xF0, featurePrint: SamplePhoto.featurePrint(room: 0, step: 0)),
			SamplePhoto.make(index: 4, hash: 0xF0, featurePrint: SamplePhoto.featurePrint(room: 6, step: 0)),
		]
		let link = GroupLink(
			a: 0, b: 1, confidence: 0.8,
			candidates: [PairScore(i: 2, j: 3, score: 0.95), PairScore(i: 0, j: 1, score: 0.30)])

		// 判定材料があるときは、重なっている組だけを採る。
		let selected = SortPlanner.selectSharedPhotos(
			link: link, photos: photos, sceneBar: 0.2, settings: SortPlanner.Settings(overlap: 4))
		XCTAssertEqual(selected.photos.sorted(), [0, 1])

		// 判定材料が無ければ従来どおりスコア順（視覚特徴が取れない現場で
		// 隣接が 1 本も作れなくなってはいけない）。
		let fallback = SortPlanner.selectSharedPhotos(
			link: link, photos: photos, sceneBar: nil, settings: SortPlanner.Settings(overlap: 4))
		XCTAssertEqual(fallback.photos.sorted(), [0, 1, 2, 3])
	}

	func testAdjacencyIsDroppedWhenNothingActuallyOverlaps()
	{
		// 重なっている写真が 1 枚も無ければ隣接そのものを作らない。無関係な
		// 写真をグループへ持ち込むぶん、有害だから。
		let photos = [
			SamplePhoto.make(index: 1, hash: 0x0F, featurePrint: SamplePhoto.featurePrint(room: 0, step: 0)),
			SamplePhoto.make(index: 2, hash: 0xF0, featurePrint: SamplePhoto.featurePrint(room: 6, step: 0)),
		]
		let link = GroupLink(
			a: 0, b: 1, confidence: 0.9, candidates: [PairScore(i: 0, j: 1, score: 0.95)])
		XCTAssertTrue(SortPlanner.selectSharedPhotos(
			link: link, photos: photos, sceneBar: 0.2, settings: SortPlanner.Settings()).photos.isEmpty)
	}

	func testSharedPhotoSelectionFallsBackWhenDiversityCannotBeMet()
	{
		// 廊下を直進しながら撮った区間。視点が散らばらなくても、枚数を
		// 優先して埋める（共有が少ないほうが合成には致命的）。
		let photos = (0 ..< 20).map { SamplePhoto.make(index: $0, heading: 0, hash: 0xAA) }
		let candidates = (0 ..< 10).map
		{ index in
			PairScore(i: index, j: index + 10, score: 1 - Double(index) * 0.01)
		}
		let link = GroupLink(a: 0, b: 1, confidence: 0.9, candidates: candidates)
		let selected = SortPlanner.selectSharedPhotos(
			link: link, photos: photos, sceneBar: nil, settings: SortPlanner.Settings(overlap: 8))
		XCTAssertEqual(selected.photos.count, 8)
	}

	// -----------------------------------------------------------------
	// 実際に重なっているかの検証（設計メモ §4.6.1）
	// -----------------------------------------------------------------

	/// 問い合わせを記録する差し替え用の検証役。判定は「相対パスの組」で決める。
	final class FakeOverlapProbe: @unchecked Sendable
	{
		/// 重なっていると答える写真の添字（両方が含まれる組だけを認める）。
		let overlapping: Set<Int>
		/// 判定できないと答える写真の添字。
		let undecided: Set<Int>
		private let lock = NSLock()
		private(set) var asked: [OverlapQuery] = []

		init(overlapping: Set<Int>, undecided: Set<Int> = [])
		{
			self.overlapping = overlapping
			self.undecided = undecided
		}

		/// 添字は SamplePhoto.make(index:) の番号（ファイル名から復元する）。
		func number(of url: URL) -> Int
		{
			let name = url.deletingPathExtension().lastPathComponent
			return Int(name.replacingOccurrences(of: "IMG_", with: "")) ?? -1
		}

		var probe: SortPlanner.OverlapProbe
		{
			{ [self] queries in
				lock.lock()
				asked.append(contentsOf: queries)
				lock.unlock()
				return queries.map
				{ query in
					let a = number(of: query.a)
					let b = number(of: query.b)
					if undecided.contains(a) || undecided.contains(b)
					{
						return nil
					}
					guard overlapping.contains(a), overlapping.contains(b)
					else
					{
						return PhotoOverlap.none
					}
					return PhotoOverlap(agreement: 0.9, sharedArea: 0.6)
				}
			}
		}
	}

	func makeVerificationLink() -> (link: GroupLink, photos: [PhotoMetadata])
	{
		// 4 枚。0〜1 は本当に重なっている組で、2〜3 はスコアだけ高い別の場所。
		let photos = (1 ... 4).map { SamplePhoto.make(index: $0, hash: 0x0F) }
		let link = GroupLink(
			a: 0, b: 1, confidence: 0.9,
			candidates: [PairScore(i: 2, j: 3, score: 0.99), PairScore(i: 0, j: 1, score: 0.20)])
		return (link, photos)
	}

	/// **これが §4.6.1 の本題。** 見た目でも順序でも上位に来る組が、実際には
	/// 重なっていないことがある。位置合わせで確かめて落とす。
	func testOverlapVerificationDropsPairsThatDoNotActuallyOverlap()
	{
		let (link, photos) = makeVerificationLink()
		let probe = FakeOverlapProbe(overlapping: [1, 2])
		let selection = SortPlanner.selectSharedPhotos(
			link: link,
			photos: photos,
			sceneBar: nil,
			settings: SortPlanner.Settings(overlap: 4),
			verifyOverlap: probe.probe)
		XCTAssertEqual(selection.photos.sorted(), [0, 1])
		XCTAssertEqual(selection.verified, 1)
		XCTAssertEqual(selection.rejected, 1)
		XCTAssertEqual(selection.undecided, 0)
	}

	func testAdjacencyIsDroppedWhenVerificationRejectsEverything()
	{
		let (link, photos) = makeVerificationLink()
		let probe = FakeOverlapProbe(overlapping: [])
		let selection = SortPlanner.selectSharedPhotos(
			link: link,
			photos: photos,
			sceneBar: nil,
			settings: SortPlanner.Settings(overlap: 4),
			verifyOverlap: probe.probe)
		XCTAssertTrue(selection.photos.isEmpty)
		XCTAssertEqual(selection.rejected, 2)
	}

	/// 判定できなかった組は落とさない。**分からないことを理由に候補を捨てると、
	/// 白い壁ばかりの現場で隣接が 1 本も作れなくなる。**
	func testUndecidedPairsAreKept()
	{
		let (link, photos) = makeVerificationLink()
		let probe = FakeOverlapProbe(overlapping: [], undecided: [1, 2, 3, 4])
		let selection = SortPlanner.selectSharedPhotos(
			link: link,
			photos: photos,
			sceneBar: nil,
			settings: SortPlanner.Settings(overlap: 4),
			verifyOverlap: probe.probe)
		XCTAssertEqual(selection.photos.sorted(), [0, 1, 2, 3])
		XCTAssertEqual(selection.undecided, 2)
		XCTAssertEqual(selection.rejected, 0)
	}

	/// 1 組も判定できなかったときは**視覚距離の足切りに戻る**。模様の無い写真
	/// ばかり、あるいは読めない形式ばかりの現場では確認が答えを出せないので、
	/// そのままだとフェーズ 2 にあった歯止めまで失って確認前より悪くなる。
	func testFallsBackToTheDistanceCutoffWhenNothingCanBeJudged()
	{
		let photos = [
			SamplePhoto.make(index: 1, hash: 0x0F, featurePrint: SamplePhoto.featurePrint(room: 0, step: 0)),
			SamplePhoto.make(index: 2, hash: 0x0F, featurePrint: SamplePhoto.featurePrint(room: 0, step: 1)),
			SamplePhoto.make(index: 3, hash: 0xF0, featurePrint: SamplePhoto.featurePrint(room: 0, step: 0)),
			SamplePhoto.make(index: 4, hash: 0xF0, featurePrint: SamplePhoto.featurePrint(room: 6, step: 0)),
		]
		let link = GroupLink(
			a: 0, b: 1, confidence: 0.8,
			candidates: [PairScore(i: 2, j: 3, score: 0.95), PairScore(i: 0, j: 1, score: 0.30)])
		let probe = FakeOverlapProbe(overlapping: [], undecided: [1, 2, 3, 4])
		let selection = SortPlanner.selectSharedPhotos(
			link: link,
			photos: photos,
			sceneBar: 0.2,
			settings: SortPlanner.Settings(overlap: 4),
			verifyOverlap: probe.probe)
		// 遠い組（2〜3）は足切りされたまま。
		XCTAssertEqual(selection.photos.sorted(), [0, 1])
		XCTAssertEqual(selection.verified, 0)
		XCTAssertEqual(selection.rejected, 0)
	}

	/// 必要な枚数が集まったら確かめるのをやめる。**これがコストの歯止め**で、
	/// 1 組ごとにデコードと推論が走る以上、全候補を確かめてはいけない。
	func testVerificationStopsOnceEnoughPhotosAreFound()
	{
		let photos = (1 ... 40).map { SamplePhoto.make(index: $0, hash: 0x0F) }
		let candidates = (0 ..< 20).map
		{ index in
			PairScore(i: index, j: index + 20, score: 1 - Double(index) * 0.01)
		}
		let link = GroupLink(a: 0, b: 1, confidence: 0.9, candidates: candidates)
		let probe = FakeOverlapProbe(overlapping: Set(1 ... 40))
		let selection = SortPlanner.selectSharedPhotos(
			link: link,
			photos: photos,
			sceneBar: nil,
			settings: SortPlanner.Settings(overlap: 4, overlapCheckBatch: 2),
			verifyOverlap: probe.probe)
		XCTAssertEqual(selection.photos.count, 4)
		// 1 組で 2 枚採れるので、2 組も確かめれば足りる。
		XCTAssertLessThanOrEqual(probe.asked.count, 4)
	}

	/// 確かめる組数には上限がある（重なりが見つからない隣接でも時間を使い切らない）。
	func testVerificationStopsAtTheCheckLimit()
	{
		let photos = (1 ... 60).map { SamplePhoto.make(index: $0, hash: 0x0F) }
		let candidates = (0 ..< 30).map
		{ index in
			PairScore(i: index, j: index + 30, score: 1 - Double(index) * 0.01)
		}
		let link = GroupLink(a: 0, b: 1, confidence: 0.9, candidates: candidates)
		let probe = FakeOverlapProbe(overlapping: [])
		let selection = SortPlanner.selectSharedPhotos(
			link: link,
			photos: photos,
			sceneBar: nil,
			settings: SortPlanner.Settings(
				overlap: 15, maximumOverlapChecks: 6, overlapCheckBatch: 3),
			verifyOverlap: probe.probe)
		XCTAssertTrue(selection.photos.isEmpty)
		XCTAssertEqual(probe.asked.count, 6)
	}

	func testOverlapThresholdIsTheJudgement()
	{
		let settings = SortPlanner.Settings(
			minimumOverlapAgreement: 0.35, minimumSharedArea: 0.15)
		// 一致度も広さも足りている。
		XCTAssertTrue(SortPlanner.isOverlapping(
			PhotoOverlap(agreement: 0.4, sharedArea: 0.2), settings: settings))
		// 一致度が足りない（＝別のものが写っている）。
		XCTAssertFalse(SortPlanner.isOverlapping(
			PhotoOverlap(agreement: 0.2, sharedArea: 0.9), settings: settings))
		// 広さが足りない（＝帯のようにしか重なっていない）。
		XCTAssertFalse(SortPlanner.isOverlapping(
			PhotoOverlap(agreement: 0.9, sharedArea: 0.05), settings: settings))
	}

	func testPlanRecordsVerificationInTheManifestContract()
	{
		let grouping = makeGrouping()
		let numbers = Set(grouping.photos.compactMap { photo -> Int? in
			Int(photo.relativePath
				.replacingOccurrences(of: "IMG_", with: "")
				.replacingOccurrences(of: ".HEIC", with: ""))
		})
		let probe = FakeOverlapProbe(overlapping: numbers)
		let plan = SortPlanner.plan(grouping: grouping, verifyOverlap: probe.probe)
		XCTAssertGreaterThan(plan.overlapSummary?.verified ?? 0, 0)
		XCTAssertEqual(plan.adjacency.count, 1)
		// **合成はこの印を見て、どの隣接を最も信頼するかを決められる。**
		XCTAssertTrue(plan.adjacency[0].overlapVerified)

		// 確かめなかったときは集計ごと nil（0 件と取り違えないため）。
		let unverified = SortPlanner.plan(grouping: grouping)
		XCTAssertNil(unverified.overlapSummary)
		XCTAssertFalse(unverified.adjacency[0].overlapVerified)
	}
}
