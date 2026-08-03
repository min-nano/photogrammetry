//
//  SortManifestTests.swift
//
//  manifest.json は `sort` と `merge`（フェーズ 3）の唯一の契約なので、
//  往復とキー名を固定する。**片方を変えるときは両方＋テストを更新すること。**
//

import XCTest

@testable import PhotogrammetryCore

final class SortManifestTests: XCTestCase
{
	func makeManifest() -> SortManifest
	{
		SortManifest(
			generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
			source: "/Users/me/現場写真",
			settings: SortManifest.Settings(
				overlap: 15,
				maxPerGroup: 150,
				minPerGroup: 20,
				timeGap: 300,
				groupThreshold: 0.42,
				groupThresholdWasAutomatic: true,
				sharpnessThreshold: 12.5,
				duplicateDistance: 4,
				visualEvidence: true,
				visualThreshold: 0.38,
				visualThresholdWasAutomatic: true,
				overlapCheck: true,
				overlapInliers: 0.35,
				overlapGrouping: true,
				overlapBudget: 12_320,
				link: .hardlink),
			evidence: SortManifest.Evidence(
				used: ["time", "visual", "scene", "room"],
				coverage: ["time": 1.0, "gps": 0.0, "scene": 1.0]),
			statistics: SortManifest.Statistics(
				inputCount: 812,
				keptCount: 770,
				groupCount: 8,
				roomCount: 5,
				excludedByReason: ["blur": 30, "duplicate": 12],
				scoreHistogram: [1, 2, 3],
				visualDistanceHistogram: [4, 5, 6],
				sharpnessMedian: 40,
				overlapChecks: SortManifest.Statistics.OverlapChecks(
					verified: 34, rejected: 9, undecided: 2),
				overlapGraph: SortManifest.Statistics.OverlapGraphStatistics(
					checked: 9_840,
					budget: 12_320,
					budgetExhausted: false,
					overlapping: 6_102,
					separate: 3_610,
					undecided: 128,
					degreeHistogram: [3, 12, 40],
					inlierHistogram: [11, 2, 60],
					agreementHistogram: [7, 8, 9],
					chainHitRate: 0.86)),
			groups: [
				SortManifest.Group(
					id: "group-01",
					photos: ["IMG_0001.HEIC", "IMG_0118.HEIC"],
					shared: ["IMG_0118.HEIC"],
					evidence: ["time", "visual", "scene", "room"],
					rooms: ["room-01", "room-02"],
					captureStart: Date(timeIntervalSince1970: 1_700_000_100),
					captureEnd: Date(timeIntervalSince1970: 1_700_000_200)),
			],
			adjacency: [
				SortManifest.Adjacency(
					a: "group-01",
					b: "group-02",
					sharedPhotos: ["IMG_0118.HEIC"],
					confidence: 0.82,
					viewpointSpread: 0.31,
					sharedRoom: "room-02",
					overlapVerified: true),
			],
			excluded: [
				SortManifest.Excluded(photo: "IMG_0044.HEIC", reason: .blur, score: 0.12),
			],
			unassigned: ["IMG_0500.HEIC"],
			diagnostics: [
				SortDiagnostic(severity: .warning, code: "sharedPhotosTooFew", message: "共有 4 枚"),
			])
	}

	func testRoundTrip() throws
	{
		let manifest = makeManifest()
		let restored = try SortManifest.decoded(from: manifest.encoded())
		XCTAssertEqual(restored, manifest)
	}

	func testVersionIsRecorded()
	{
		XCTAssertEqual(makeManifest().version, SortManifest.currentVersion)
		// 4 = グループ分けそのものを重なりで決める（設計メモ §4.9）。
		// overlapGraph / overlapGrouping / overlapBudget を足したときに上げた。
		XCTAssertEqual(SortManifest.currentVersion, 4)
	}

	func testJSONKeysAreStable() throws
	{
		// merge（フェーズ 3）はこのキーを読む。名前が変わると契約が壊れる。
		let json = try XCTUnwrap(String(data: makeManifest().encoded(), encoding: .utf8))
		for key in [
			"\"version\"", "\"source\"", "\"settings\"", "\"groups\"", "\"adjacency\"",
			"\"excluded\"", "\"unassigned\"", "\"diagnostics\"", "\"sharedPhotos\"",
			"\"confidence\"", "\"viewpointSpread\"", "\"overlap\"", "\"evidence\"",
			// フェーズ 2。merge は「どのグループが同じ場所を写しているか」を
			// ここから読む（時刻が離れていても成立する繋ぎ目）。
			"\"rooms\"", "\"sharedRoom\"", "\"roomCount\"", "\"visualThreshold\"",
			// §4.6.1。merge は「実際に重なっていると確かめた隣接か」をここから読む。
			"\"overlapVerified\"", "\"overlapChecks\"", "\"overlapCheck\"",
			"\"overlapInliers\"",
			// §4.9。merge は「グループが重なりグラフの連結成分になっているか」を
			// ここから読む（なっていれば、どのグループも再構成が成立する）。
			"\"overlapGraph\"", "\"overlapGrouping\"", "\"overlapBudget\"",
			"\"budgetExhausted\"", "\"agreementHistogram\"",
			// §4.9.1。判定に使うのはインライア率で、的中率は測り方が効いているかを
			// 1 つの数字で示す。
			"\"inlierHistogram\"", "\"chainHitRate\"", "\"overlapInliers\"",
			// 順序のヒントを使ってよいか。撮影順が途切れたグループに sequential を
			// 与えると、隣り合わない 2 枚を隣だと言うことになる。
			"\"sequential\"",
		]
		{
			XCTAssertTrue(json.contains(key), "\(key) が manifest にありません")
		}
		// パスはエスケープせずそのまま読める形にする。
		XCTAssertTrue(json.contains("/Users/me/現場写真"))
	}

	func testOptionalFieldsSurviveRoundTrip() throws
	{
		var manifest = makeManifest()
		manifest.settings.sharpnessThreshold = nil
		manifest.statistics.sharpnessMedian = nil
		manifest.adjacency[0].viewpointSpread = nil
		manifest.adjacency[0].sharedRoom = nil
		manifest.statistics.overlapChecks = nil
		manifest.statistics.overlapGraph = nil
		manifest.settings.overlapBudget = nil
		manifest.statistics.overlapGraph?.chainHitRate = nil
		manifest.groups[0].captureStart = nil
		manifest.groups[0].captureEnd = nil
		let restored = try SortManifest.decoded(from: manifest.encoded())
		XCTAssertEqual(restored, manifest)
		XCTAssertNil(restored.adjacency[0].viewpointSpread)
		XCTAssertNil(restored.adjacency[0].sharedRoom)
		XCTAssertNil(restored.statistics.overlapChecks)
		XCTAssertNil(restored.statistics.overlapGraph)
		XCTAssertNil(restored.settings.overlapBudget)
	}

	func testFileName()
	{
		XCTAssertEqual(SortManifest.fileName, "manifest.json")
	}
}
