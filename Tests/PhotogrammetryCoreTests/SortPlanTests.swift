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
		let grouping = makeSingleRoomGrouping()
		XCTAssertEqual(grouping.rooms.clusters.count, 1)
		XCTAssertEqual(grouping.groups.count, 2)

		let plan = SortPlanner.plan(grouping: grouping)
		// **合成では最も信頼できる繋ぎ目。** 同じ場所を写しているグループ同士だと
		// 分かっていれば、対応点が期待できる。
		XCTAssertEqual(plan.adjacency.first?.sharedRoom, "room-01")
		for group in plan.groups
		{
			XCTAssertEqual(group.rooms, ["room-01"])
		}
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
			link: link, photos: photos, settings: SortPlanner.Settings(overlap: 8))
		XCTAssertEqual(selected.count, 8)
	}
}
