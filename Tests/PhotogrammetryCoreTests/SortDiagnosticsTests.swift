//
//  SortDiagnosticsTests.swift
//
//  診断（設計メモ §4.6）を固定する。**黙って悪い結果を出さない**という原則の
//  実装なので、「足りないときに必ず言う」ことをテストで担保する。
//

import XCTest

@testable import PhotogrammetryCore

final class SortDiagnosticsTests: XCTestCase
{
	func makeRequest() -> SortRequest
	{
		SortRequest(
			inputFolder: URL(fileURLWithPath: "/tmp/in", isDirectory: true),
			outputFolder: URL(fileURLWithPath: "/tmp/out", isDirectory: true))
	}

	func makeGrouping(photos: [PhotoMetadata]) -> GroupingResult
	{
		PhotoGrouping.group(photos: photos)
	}

	func evaluate(
		plan: SortPlan,
		photos: [PhotoMetadata] = [],
		hardwareLimit: Int? = nil) -> [SortDiagnostic]
	{
		let grouping = makeGrouping(photos: photos)
		let quality = QualityFilter.Outcome(kept: photos, excluded: [])
		return SortDiagnostics.evaluate(
			plan: plan,
			grouping: grouping,
			quality: quality,
			request: makeRequest(),
			hardwareLimit: hardwareLimit)
	}

	func group(_ id: String, count: Int, shared: Int = 0) -> SortPlan.Group
	{
		let photos = (0 ..< count).map { "\(id)-\($0).HEIC" }
		return SortPlan.Group(
			id: id,
			photos: photos,
			shared: Array(photos.prefix(shared)),
			evidence: [.time])
	}

	func codes(_ diagnostics: [SortDiagnostic]) -> Set<String>
	{
		Set(diagnostics.map(\.code))
	}

	// -----------------------------------------------------------------

	func testTooFewSharedPhotosIsReported()
	{
		let plan = SortPlan(
			groups: [group("group-01", count: 40), group("group-02", count: 40)],
			adjacency: [
				SortPlan.Adjacency(
					a: "group-01", b: "group-02",
					sharedPhotos: ["a.HEIC", "b.HEIC", "c.HEIC", "d.HEIC"],
					confidence: 0.6,
					viewpointSpread: 0.5),
			],
			unassigned: [])
		let diagnostics = evaluate(plan: plan)
		XCTAssertTrue(codes(diagnostics).contains("sharedPhotosTooFew"))
		let message = diagnostics.first { $0.code == "sharedPhotosTooFew" }?.message ?? ""
		// 「どこを撮り足せばよいか」が名前で分かること。
		XCTAssertTrue(message.contains("group-01"))
		XCTAssertTrue(message.contains("group-02"))
	}

	func testEnoughSharedPhotosIsNotReported()
	{
		let shared = (0 ..< 12).map { "s\($0).HEIC" }
		let plan = SortPlan(
			groups: [group("group-01", count: 40), group("group-02", count: 40)],
			adjacency: [
				SortPlan.Adjacency(
					a: "group-01", b: "group-02", sharedPhotos: shared,
					confidence: 0.6, viewpointSpread: 0.5),
			],
			unassigned: [])
		XCTAssertFalse(codes(evaluate(plan: plan)).contains("sharedPhotosTooFew"))
	}

	func testDegenerateViewpointIsReported()
	{
		let shared = (0 ..< 12).map { "s\($0).HEIC" }
		let plan = SortPlan(
			groups: [group("group-01", count: 40), group("group-02", count: 40)],
			adjacency: [
				SortPlan.Adjacency(
					a: "group-01", b: "group-02", sharedPhotos: shared,
					confidence: 0.6, viewpointSpread: 0.05),
			],
			unassigned: [])
		XCTAssertTrue(codes(evaluate(plan: plan)).contains("viewpointDegenerate"))
	}

	func testIsolatedAndDisconnectedGroupsAreReported()
	{
		let plan = SortPlan(
			groups: [
				group("group-01", count: 40),
				group("group-02", count: 40),
				group("group-03", count: 40),
			],
			adjacency: [
				SortPlan.Adjacency(
					a: "group-01", b: "group-02",
					sharedPhotos: (0 ..< 12).map { "s\($0).HEIC" },
					confidence: 0.6, viewpointSpread: 0.5),
			],
			unassigned: [])
		let result = codes(evaluate(plan: plan))
		XCTAssertTrue(result.contains("isolatedGroup"))
		// 島が 2 つ = 1 つの座標系にまとめられない。これは error。
		XCTAssertTrue(result.contains("disconnected"))
	}

	func testConnectedChainIsNotReportedAsDisconnected()
	{
		let plan = SortPlan(
			groups: [
				group("group-01", count: 40),
				group("group-02", count: 40),
				group("group-03", count: 40),
			],
			adjacency: [
				SortPlan.Adjacency(
					a: "group-01", b: "group-02",
					sharedPhotos: (0 ..< 12).map { "s\($0).HEIC" },
					confidence: 0.6, viewpointSpread: 0.5),
				SortPlan.Adjacency(
					a: "group-02", b: "group-03",
					sharedPhotos: (0 ..< 12).map { "t\($0).HEIC" },
					confidence: 0.6, viewpointSpread: 0.5),
			],
			unassigned: [])
		let result = codes(evaluate(plan: plan))
		XCTAssertFalse(result.contains("disconnected"))
		XCTAssertFalse(result.contains("isolatedGroup"))
	}

	func testGroupSizeWarnings()
	{
		let plan = SortPlan(
			groups: [group("group-01", count: 300), group("group-02", count: 5)],
			adjacency: [],
			unassigned: [])
		let result = codes(evaluate(plan: plan, hardwareLimit: 100))
		XCTAssertTrue(result.contains("groupTooLarge"))
		XCTAssertTrue(result.contains("groupTooSmall"))
	}

	func testEmptyPlanIsAnError()
	{
		let diagnostics = evaluate(plan: SortPlan(groups: [], adjacency: [], unassigned: []))
		XCTAssertEqual(diagnostics.map(\.code), ["noGroups"])
		XCTAssertEqual(diagnostics.first?.severity, .error)
	}

	func testNextStepIsAlwaysShown()
	{
		// 仕分けただけでは何も出来上がっていない。次の一手を必ず示す。
		let plan = SortPlan(groups: [group("group-01", count: 40)], adjacency: [], unassigned: [])
		let message = evaluate(plan: plan).first { $0.code == "nextStep" }?.message ?? ""
		XCTAssertTrue(message.contains("group-01"))
		XCTAssertTrue(message.contains("--subject scene"))
		XCTAssertTrue(message.contains("--sample-ordering sequential"))
	}

	func testSingleGroupNeedsNoMerge()
	{
		let plan = SortPlan(groups: [group("group-01", count: 40)], adjacency: [], unassigned: [])
		let result = codes(evaluate(plan: plan))
		XCTAssertTrue(result.contains("singleGroup"))
		XCTAssertFalse(result.contains("isolatedGroup"))
		XCTAssertFalse(result.contains("disconnected"))
	}

	// -----------------------------------------------------------------
	// 手がかりと機材
	// -----------------------------------------------------------------

	func testMissingCaptureTimeIsReported()
	{
		let photos = (0 ..< 20).map { SamplePhoto.make(index: $0, hash: UInt64($0)) }
		let plan = SortPlan(groups: [group("group-01", count: 20)], adjacency: [], unassigned: [])
		XCTAssertTrue(codes(evaluate(plan: plan, photos: photos)).contains("noCaptureTime"))
	}

	func testMixedFocalLengthIsReported()
	{
		// iPhone は寄ると超広角へ切り替わる。実際に起きるので必ず知らせる。
		let photos = (0 ..< 20).map
		{ index in
			SamplePhoto.make(
				index: index,
				secondsFromEpoch: Double(index),
				focalLength35mm: index < 10 ? 26 : 13,
				hash: UInt64(index))
		}
		let diagnostics = SortDiagnostics.equipmentDiagnostics(photos: photos)
		XCTAssertTrue(codes(diagnostics).contains("mixedFocalLength"))
		XCTAssertTrue(diagnostics[0].message.contains("13mm"))
	}

	func testSingleFocalLengthIsNotReported()
	{
		let photos = (0 ..< 20).map
		{ index in
			SamplePhoto.make(index: index, focalLength35mm: 26, hash: UInt64(index))
		}
		XCTAssertTrue(SortDiagnostics.equipmentDiagnostics(photos: photos).isEmpty)
	}

	func testMixedCameraIsReported()
	{
		let photos = [
			SamplePhoto.make(index: 1, cameraModel: "iPhone 15 Pro", hash: 1),
			SamplePhoto.make(index: 2, cameraModel: "ILCE-7M4", hash: 2),
		]
		XCTAssertTrue(codes(SortDiagnostics.equipmentDiagnostics(photos: photos))
			.contains("mixedCamera"))
	}

	func testBlurFilterSuppressionIsReported()
	{
		let plan = SortPlan(groups: [group("group-01", count: 40)], adjacency: [], unassigned: [])
		let quality = QualityFilter.Outcome(
			kept: [], excluded: [], blurFilterSuppressed: true)
		let diagnostics = SortDiagnostics.evaluate(
			plan: plan,
			grouping: makeGrouping(photos: []),
			quality: quality,
			request: makeRequest())
		XCTAssertTrue(codes(diagnostics).contains("blurFilterSuppressed"))
	}

	func testExclusionBreakdownIsReported()
	{
		let plan = SortPlan(groups: [group("group-01", count: 40)], adjacency: [], unassigned: [])
		let quality = QualityFilter.Outcome(
			kept: [],
			excluded: [
				ExcludedPhoto(photo: "a.HEIC", reason: .blur, score: 1),
				ExcludedPhoto(photo: "b.HEIC", reason: .blur, score: 1),
				ExcludedPhoto(photo: "c.HEIC", reason: .duplicate, score: 0),
			])
		let diagnostics = SortDiagnostics.evaluate(
			plan: plan,
			grouping: makeGrouping(photos: []),
			quality: quality,
			request: makeRequest())
		let message = diagnostics.first { $0.code == "excludedBreakdown" }?.message ?? ""
		XCTAssertTrue(message.contains("ブレ 2 枚"))
		XCTAssertTrue(message.contains("ほぼ同一 1 枚"))
	}

	func testUnassignedIsReported()
	{
		let plan = SortPlan(
			groups: [group("group-01", count: 40)],
			adjacency: [],
			unassigned: ["x.HEIC"])
		XCTAssertTrue(codes(evaluate(plan: plan)).contains("unassigned"))
	}

	// -----------------------------------------------------------------
	// 視覚的に見つけた場所（フェーズ 2）
	//
	// グループは「上限枚数で切った区間」でしかないが、場所は「同じ部屋を
	// 写している写真の集まり」なので、**仕分けの結果を撮影者の言葉で説明できる**。
	// -----------------------------------------------------------------

	func evaluate(plan: SortPlan, grouping: GroupingResult) -> [SortDiagnostic]
	{
		SortDiagnostics.evaluate(
			plan: plan,
			grouping: grouping,
			quality: QualityFilter.Outcome(kept: grouping.photos, excluded: []),
			request: makeRequest())
	}

	func testVisualAnalysisIsReportedAsUnusedWhenThereAreNoFeaturePrints()
	{
		// 黙って使わないのが一番困る（なぜ仕分けが悪いのか分からなくなる）。
		let plan = SortPlan(groups: [group("group-01", count: 40)], adjacency: [], unassigned: [])
		let diagnostics = evaluate(plan: plan)
		XCTAssertTrue(codes(diagnostics).contains("noVisualAnalysis"))
	}

	func testRoomsFoundIsReported()
	{
		let grouping = manualGrouping(
			groups: [Array(0 ..< 20), Array(20 ..< 40)],
			labels: (0 ..< 40).map { $0 < 20 ? 0 : 1 })
		let plan = SortPlan(
			groups: [group("group-01", count: 20), group("group-02", count: 20)],
			adjacency: [
				SortPlan.Adjacency(
					a: "group-01", b: "group-02",
					sharedPhotos: (0 ..< 12).map { "s\($0).HEIC" },
					confidence: 0.7,
					viewpointSpread: 0.5),
			],
			unassigned: [])
		let diagnostics = evaluate(plan: plan, grouping: grouping)
		let message = diagnostics.first { $0.code == "roomsFound" }?.message ?? ""
		XCTAssertTrue(message.contains("2 か所"))
		XCTAssertTrue(message.contains("room-01"))
		XCTAssertFalse(codes(diagnostics).contains("groupMixesRooms"))
		XCTAssertFalse(codes(diagnostics).contains("roomSplitWithoutLink"))
	}

	func testRoomsFoundButNotUsedIsReported()
	{
		// **場所を見つけたのに使わなかった**ときは必ず言う。黙って捨てると
		// 「なぜ屋外と室内が同じグループなのか」が誰にも分からなくなる。
		let grouping = manualGrouping(
			groups: [Array(0 ..< 20)],
			labels: (0 ..< 20).map { $0 < 19 ? 0 : 1 },
			usedEvidence: [.time, .scene])
		let plan = SortPlan(groups: [group("group-01", count: 20)], adjacency: [], unassigned: [])
		let diagnostics = evaluate(plan: plan, grouping: grouping)
		let message = diagnostics.first { $0.code == "roomsNotDiscriminating" }?.message ?? ""
		XCTAssertTrue(message.contains("95%"), message)
		XCTAssertTrue(message.contains("--visual-threshold"), message)
		XCTAssertEqual(
			diagnostics.first { $0.code == "roomsNotDiscriminating" }?.severity, .warning)

		// きちんと使えているときは出さない。
		let fine = manualGrouping(
			groups: [Array(0 ..< 20)],
			labels: (0 ..< 20).map { $0 < 10 ? 0 : 1 })
		XCTAssertFalse(codes(evaluate(plan: plan, grouping: fine))
			.contains("roomsNotDiscriminating"))
	}

	func testSingleRoomIsReported()
	{
		let grouping = manualGrouping(
			groups: [Array(0 ..< 20)],
			labels: [Int](repeating: 0, count: 20))
		let plan = SortPlan(groups: [group("group-01", count: 20)], adjacency: [], unassigned: [])
		XCTAssertTrue(codes(evaluate(plan: plan, grouping: grouping)).contains("singleRoom"))
	}

	func testGroupMixingPlacesIsReported()
	{
		// 1 つのグループに 2 か所が半々で混ざっている。1 回のセッションでは
		// 位置合わせが途切れやすいので警告する。
		let grouping = manualGrouping(
			groups: [Array(0 ..< 40)],
			labels: (0 ..< 40).map { $0 < 20 ? 0 : 1 })
		let plan = SortPlan(groups: [group("group-01", count: 40)], adjacency: [], unassigned: [])
		let diagnostics = evaluate(plan: plan, grouping: grouping)
		let message = diagnostics.first { $0.code == "groupMixesRooms" }?.message ?? ""
		XCTAssertTrue(message.contains("group-01"))
		XCTAssertTrue(message.contains("room-01"))
		XCTAssertTrue(message.contains("50%"))
	}

	func testDominantRoomIsNotReportedAsMixed()
	{
		// 大半が同じ場所なら混在とは言わない（境目の数枚で警告を出さない）。
		let grouping = manualGrouping(
			groups: [Array(0 ..< 40)],
			labels: (0 ..< 40).map { $0 < 36 ? 0 : 1 })
		let plan = SortPlan(groups: [group("group-01", count: 40)], adjacency: [], unassigned: [])
		XCTAssertFalse(codes(evaluate(plan: plan, grouping: grouping)).contains("groupMixesRooms"))
	}

	func testSamePlaceSplitAcrossUnlinkedGroupsIsReported()
	{
		// **一度離れて戻ってきた撮影。** 同じ場所なのに共有写真が無ければ、
		// 合成は別々の島に割れる。撮影者に言えるのはここだけ。
		let grouping = manualGrouping(
			groups: [Array(0 ..< 20), Array(20 ..< 40)],
			labels: [Int](repeating: 0, count: 40))
		let plan = SortPlan(
			groups: [group("group-01", count: 20), group("group-02", count: 20)],
			adjacency: [],
			unassigned: [])
		let diagnostics = evaluate(plan: plan, grouping: grouping)
		let message = diagnostics.first { $0.code == "roomSplitWithoutLink" }?.message ?? ""
		XCTAssertTrue(message.contains("room-01"))
		XCTAssertTrue(message.contains("group-01"))
		XCTAssertTrue(message.contains("group-02"))
	}

	func testSamePlaceSplitButLinkedIsNotReported()
	{
		let grouping = manualGrouping(
			groups: [Array(0 ..< 20), Array(20 ..< 40)],
			labels: [Int](repeating: 0, count: 40))
		let plan = SortPlan(
			groups: [group("group-01", count: 20), group("group-02", count: 20)],
			adjacency: [
				SortPlan.Adjacency(
					a: "group-01", b: "group-02",
					sharedPhotos: (0 ..< 12).map { "s\($0).HEIC" },
					confidence: 0.9,
					viewpointSpread: 0.5,
					sharedRoom: "room-01"),
			],
			unassigned: [])
		XCTAssertFalse(codes(evaluate(plan: plan, grouping: grouping))
			.contains("roomSplitWithoutLink"))
	}
}
