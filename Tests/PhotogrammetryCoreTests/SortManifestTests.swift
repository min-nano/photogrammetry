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
				link: .hardlink),
			evidence: SortManifest.Evidence(
				used: ["time", "visual"],
				coverage: ["time": 1.0, "gps": 0.0]),
			statistics: SortManifest.Statistics(
				inputCount: 812,
				keptCount: 770,
				groupCount: 8,
				excludedByReason: ["blur": 30, "duplicate": 12],
				scoreHistogram: [1, 2, 3],
				sharpnessMedian: 40),
			groups: [
				SortManifest.Group(
					id: "group-01",
					photos: ["IMG_0001.HEIC", "IMG_0118.HEIC"],
					shared: ["IMG_0118.HEIC"],
					evidence: ["time", "visual"],
					captureStart: Date(timeIntervalSince1970: 1_700_000_100),
					captureEnd: Date(timeIntervalSince1970: 1_700_000_200)),
			],
			adjacency: [
				SortManifest.Adjacency(
					a: "group-01",
					b: "group-02",
					sharedPhotos: ["IMG_0118.HEIC"],
					confidence: 0.82,
					viewpointSpread: 0.31),
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
		XCTAssertEqual(SortManifest.currentVersion, 1)
	}

	func testJSONKeysAreStable() throws
	{
		// merge（フェーズ 3）はこのキーを読む。名前が変わると契約が壊れる。
		let json = try XCTUnwrap(String(data: makeManifest().encoded(), encoding: .utf8))
		for key in [
			"\"version\"", "\"source\"", "\"settings\"", "\"groups\"", "\"adjacency\"",
			"\"excluded\"", "\"unassigned\"", "\"diagnostics\"", "\"sharedPhotos\"",
			"\"confidence\"", "\"viewpointSpread\"", "\"overlap\"", "\"evidence\"",
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
		manifest.groups[0].captureStart = nil
		manifest.groups[0].captureEnd = nil
		let restored = try SortManifest.decoded(from: manifest.encoded())
		XCTAssertEqual(restored, manifest)
		XCTAssertNil(restored.adjacency[0].viewpointSpread)
	}

	func testFileName()
	{
		XCTAssertEqual(SortManifest.fileName, "manifest.json")
	}
}
