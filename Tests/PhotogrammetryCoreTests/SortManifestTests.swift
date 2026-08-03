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
				sharpnessMedian: 40),
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
					sharedRoom: "room-02"),
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
		// 2 = フェーズ 2（視覚クラスタを足したときに上げた）。
		XCTAssertEqual(SortManifest.currentVersion, 2)
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
		manifest.groups[0].captureStart = nil
		manifest.groups[0].captureEnd = nil
		let restored = try SortManifest.decoded(from: manifest.encoded())
		XCTAssertEqual(restored, manifest)
		XCTAssertNil(restored.adjacency[0].viewpointSpread)
		XCTAssertNil(restored.adjacency[0].sharedRoom)
	}

	func testFileName()
	{
		XCTAssertEqual(SortManifest.fileName, "manifest.json")
	}
}
