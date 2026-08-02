//
//  HelperProtocolTests.swift
//
//  ヘルパープロセス（photogrammetry-cli）と GUI の間の行書式をテストする。
//  ここが崩れると進捗が出なくなる・完了を取りこぼすので、往復を固定しておく。
//

import XCTest

@testable import PhotogrammetryCore

final class HelperProtocolTests: XCTestCase
{
	private func roundTrip(_ event: ReconstructionEvent) -> HelperMessage?
	{
		HelperProtocol.decode(line: HelperProtocol.encode(event))
	}

	func testEncodeFormats()
	{
		XCTAssertEqual(HelperProtocol.encode(.progress(0.5)), "progress=0.500")
		XCTAssertEqual(HelperProtocol.encode(.note("こんにちは")), "note=こんにちは")
		XCTAssertEqual(
			HelperProtocol.encode(.completed(URL(fileURLWithPath: "/tmp/model.usdz"))),
			"output=/tmp/model.usdz")
		XCTAssertEqual(HelperProtocol.encode(.cancelled), "cancelled")
		XCTAssertEqual(HelperProtocol.encode(.stage(.imageAlignment)), "stage=imageAlignment")
		XCTAssertEqual(HelperProtocol.encode(.estimatedRemainingTime(1830)), "eta=1830")
	}

	func testEstimatedRemainingTimeIsRoundedToWholeSeconds()
	{
		// 秒未満の精度は意味を持たない。負の見積もりが来ても 0 で止める
		// （読み手が負の残り時間を表示しないため）。
		XCTAssertEqual(HelperProtocol.encode(.estimatedRemainingTime(12.4)), "eta=12")
		XCTAssertEqual(HelperProtocol.encode(.estimatedRemainingTime(12.6)), "eta=13")
		XCTAssertEqual(HelperProtocol.encode(.estimatedRemainingTime(-5)), "eta=0")
	}

	func testRoundTrip()
	{
		XCTAssertEqual(roundTrip(.progress(0.25)), .event(.progress(0.25)))
		XCTAssertEqual(roundTrip(.note("写真 3 をスキップしました")), .event(.note("写真 3 をスキップしました")))
		XCTAssertEqual(roundTrip(.cancelled), .event(.cancelled))
		XCTAssertEqual(
			roundTrip(.completed(URL(fileURLWithPath: "/tmp/a b.usdz"))),
			.event(.completed(URL(fileURLWithPath: "/tmp/a b.usdz"))))
		XCTAssertEqual(roundTrip(.stage(.textureMapping)), .event(.stage(.textureMapping)))
		XCTAssertEqual(
			roundTrip(.estimatedRemainingTime(90)),
			.event(.estimatedRemainingTime(90)))
	}

	func testDecodeIgnoresUnknownStage()
	{
		// 新しいヘルパー + 古い GUI の組み合わせ。知らない段階名で
		// 進捗表示が壊れないこと。
		XCTAssertNil(HelperProtocol.decode(line: "stage=quantumRefinement"))
		XCTAssertNil(HelperProtocol.decode(line: "eta=まだ"))
	}

	func testNoteIsFlattenedToOneLine()
	{
		// 改行入りの note が 2 行になると、読み取り側が 2 行目を捨ててしまう。
		let encoded = HelperProtocol.encode(.note("1 行目\n2 行目"))
		XCTAssertFalse(encoded.contains("\n"))
		XCTAssertEqual(HelperProtocol.decode(line: encoded), .event(.note("1 行目 2 行目")))
	}

	func testDecodeFinishedLine()
	{
		XCTAssertEqual(HelperProtocol.decode(line: HelperProtocol.finishedLine), .finished)
		XCTAssertEqual(HelperProtocol.decode(line: "ok\n"), .finished)
	}

	func testDecodeIgnoresUnknownLines()
	{
		// RealityKit などがヘルパーの stdout へ直接吐くログで壊れないこと。
		XCTAssertNil(HelperProtocol.decode(line: ""))
		XCTAssertNil(HelperProtocol.decode(line: "   "))
		XCTAssertNil(HelperProtocol.decode(line: "2026-08-02 CoreOC: something happened"))
		XCTAssertNil(HelperProtocol.decode(line: "unknown=1"))
		XCTAssertNil(HelperProtocol.decode(line: "progress=abc"))
	}

	func testDecodeNoteKeepsEqualSigns()
	{
		XCTAssertEqual(
			HelperProtocol.decode(line: "note=key=value"),
			.event(.note("key=value")))
	}
}
