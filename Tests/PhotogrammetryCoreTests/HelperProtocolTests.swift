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
	}

	func testRoundTrip()
	{
		XCTAssertEqual(roundTrip(.progress(0.25)), .event(.progress(0.25)))
		XCTAssertEqual(roundTrip(.note("写真 3 をスキップしました")), .event(.note("写真 3 をスキップしました")))
		XCTAssertEqual(roundTrip(.cancelled), .event(.cancelled))
		XCTAssertEqual(
			roundTrip(.completed(URL(fileURLWithPath: "/tmp/a b.usdz"))),
			.event(.completed(URL(fileURLWithPath: "/tmp/a b.usdz"))))
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
