//
//  APICommandTests.swift
//
//  外部連携 API（URL スキーム / CLI 引数）の解釈をテストする。
//  ファイルシステムに触れない純ロジックなので、文字列だけで書ける。
//

import XCTest

@testable import PhotogrammetryCore

final class APICommandTests: XCTestCase
{
	// -----------------------------------------------------------------
	// URL スキーム
	// -----------------------------------------------------------------

	func testParseURLMinimal() throws
	{
		let url = URL(string: "photogrammetry://process?input=/tmp/photos&output=/tmp/model.usdz")!
		let request = try APICommand.parse(url: url)
		XCTAssertEqual(request.inputFolder.path, "/tmp/photos")
		XCTAssertEqual(request.outputFile.path, "/tmp/model.usdz")
		// 省略時は既定値。
		XCTAssertEqual(request.detail, .medium)
		XCTAssertEqual(request.sampleOrdering, .unordered)
		XCTAssertEqual(request.featureSensitivity, .normal)
	}

	func testParseURLAllParameters() throws
	{
		let url = URL(
			string: "photogrammetry://process?input=/a&output=/b.usdz"
				+ "&detail=full&ordering=sequential&sensitivity=high")!
		let request = try APICommand.parse(url: url)
		XCTAssertEqual(request.detail, .full)
		XCTAssertEqual(request.sampleOrdering, .sequential)
		XCTAssertEqual(request.featureSensitivity, .high)
	}

	func testParseURLPercentEncodedPath() throws
	{
		// スペースを含むパスはパーセントエンコードされて届く。
		let url = URL(
			string: "photogrammetry://process?input=/tmp/my%20photos&output=/tmp/out.usdz")!
		let request = try APICommand.parse(url: url)
		XCTAssertEqual(request.inputFolder.path, "/tmp/my photos")
	}

	func testParseURLMissingInput()
	{
		let url = URL(string: "photogrammetry://process?output=/tmp/model.usdz")!
		XCTAssertThrowsError(try APICommand.parse(url: url))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingParameter("input"))
		}
	}

	func testParseURLUnknownCommand()
	{
		let url = URL(string: "photogrammetry://export?input=/a&output=/b.usdz")!
		XCTAssertThrowsError(try APICommand.parse(url: url))
		{ error in
			XCTAssertEqual(error as? APICommandError, .unsupportedCommand("export"))
		}
	}

	func testParseURLInvalidDetail()
	{
		let url = URL(
			string: "photogrammetry://process?input=/a&output=/b.usdz&detail=ultra")!
		XCTAssertThrowsError(try APICommand.parse(url: url))
		{ error in
			XCTAssertEqual(
				error as? APICommandError, .invalidValue(parameter: "detail", value: "ultra"))
		}
	}

	// -----------------------------------------------------------------
	// CLI 引数
	// -----------------------------------------------------------------

	func testParseArgumentsMinimal() throws
	{
		let request = try APICommand.parse(arguments: ["/tmp/photos", "/tmp/model.usdz"])
		XCTAssertEqual(request.inputFolder.path, "/tmp/photos")
		XCTAssertEqual(request.outputFile.path, "/tmp/model.usdz")
		XCTAssertEqual(request.detail, .medium)
	}

	func testParseArgumentsWithOptions() throws
	{
		let request = try APICommand.parse(arguments: [
			"/tmp/photos", "/tmp/model.usdz",
			"--detail", "raw",
			"--sample-ordering", "sequential",
			"--feature-sensitivity", "high",
		])
		XCTAssertEqual(request.detail, .raw)
		XCTAssertEqual(request.sampleOrdering, .sequential)
		XCTAssertEqual(request.featureSensitivity, .high)
	}

	func testParseArgumentsShortOptionsAndOrder() throws
	{
		// オプションは位置引数の前後どちらでもよい。
		let request = try APICommand.parse(arguments: [
			"-d", "preview", "/tmp/photos", "/tmp/model.usdz",
		])
		XCTAssertEqual(request.detail, .preview)
	}

	func testParseArgumentsUnknownOption()
	{
		XCTAssertThrowsError(
			try APICommand.parse(arguments: ["/a", "/b.usdz", "--turbo"]))
		{ error in
			XCTAssertEqual(error as? APICommandError, .unknownOption("--turbo"))
		}
	}

	func testParseArgumentsMissingPositional()
	{
		XCTAssertThrowsError(try APICommand.parse(arguments: ["/a"]))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingArguments)
		}
	}

	func testParseArgumentsMissingOptionValue()
	{
		XCTAssertThrowsError(
			try APICommand.parse(arguments: ["/a", "/b.usdz", "--detail"]))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingParameter("--detail"))
		}
	}

	func testParseArgumentsInvalidValue()
	{
		XCTAssertThrowsError(
			try APICommand.parse(arguments: ["/a", "/b.usdz", "--detail", "gigantic"]))
		{ error in
			XCTAssertEqual(
				error as? APICommandError,
				.invalidValue(parameter: "--detail", value: "gigantic"))
		}
	}
}
