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
		XCTAssertEqual(request.subject, .object)
	}

	func testParseURLAllParameters() throws
	{
		let url = URL(
			string: "photogrammetry://process?input=/a&output=/b.usdz"
				+ "&detail=full&ordering=sequential&sensitivity=high&subject=scene")!
		let request = try APICommand.parse(url: url)
		XCTAssertEqual(request.detail, .full)
		XCTAssertEqual(request.sampleOrdering, .sequential)
		XCTAssertEqual(request.featureSensitivity, .high)
		XCTAssertEqual(request.subject, .scene)
	}

	func testParseURLInvalidSubject()
	{
		let url = URL(
			string: "photogrammetry://process?input=/a&output=/b.usdz&subject=person")!
		XCTAssertThrowsError(try APICommand.parse(url: url))
		{ error in
			XCTAssertEqual(
				error as? APICommandError, .invalidValue(parameter: "subject", value: "person"))
		}
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

	func testParseURLWithoutAuthorityHasNoHost()
	{
		// "//" が無い URI（photogrammetry:process）は scheme は一致するが
		// host が nil になる。呼び出し元がスキームを誤って組み立てた場合に
		// 実際に起こりうる形なので、空文字へのフォールバックごと確かめる。
		let url = URL(string: "photogrammetry:process?input=/a&output=/b.usdz")!
		XCTAssertThrowsError(try APICommand.parse(url: url))
		{ error in
			XCTAssertEqual(error as? APICommandError, .unsupportedCommand(""))
		}
	}

	func testParseURLWithoutQueryStringHasNoQueryItems()
	{
		// "?" 自体が無ければ queryItems は nil（空配列とは区別される）。
		let url = URL(string: "photogrammetry://process")!
		XCTAssertThrowsError(try APICommand.parse(url: url))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingParameter("input"))
		}
	}

	func testParseURLQueryItemWithoutValue()
	{
		// "input" だけで "=" が無いクエリ項目は value が nil になる
		// （空文字と区別される）。
		let url = URL(string: "photogrammetry://process?input&output=/b.usdz")!
		XCTAssertThrowsError(try APICommand.parse(url: url))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingParameter("input"))
		}
	}

	func testAPICommandErrorDescriptions()
	{
		// エラーは XCTAssertThrowsError で「投げられること」しか確認していない
		// ケースが多いので、ここでメッセージの中身自体を確かめる。
		XCTAssertEqual(
			APICommandError.unsupportedCommand("export").errorDescription,
			"サポートされていないコマンドです: export")
		XCTAssertEqual(
			APICommandError.missingParameter("input").errorDescription,
			"パラメータ input が指定されていません。")
		XCTAssertEqual(
			APICommandError.invalidValue(parameter: "detail", value: "ultra").errorDescription,
			"detail の値が不正です: ultra")
		XCTAssertEqual(
			APICommandError.unknownOption("--turbo").errorDescription,
			"不明なオプションです: --turbo")
		XCTAssertEqual(
			APICommandError.missingArguments.errorDescription,
			"引数が不足しています（<入力フォルダ> <出力ファイル.usdz> が必要です）。")
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
			"--subject", "scene",
		])
		XCTAssertEqual(request.detail, .raw)
		XCTAssertEqual(request.sampleOrdering, .sequential)
		XCTAssertEqual(request.featureSensitivity, .high)
		XCTAssertEqual(request.subject, .scene)
	}

	func testParseArgumentsInvalidSubject()
	{
		XCTAssertThrowsError(
			try APICommand.parse(arguments: ["/a", "/b.usdz", "--subject", "person"]))
		{ error in
			XCTAssertEqual(
				error as? APICommandError,
				.invalidValue(parameter: "--subject", value: "person"))
		}
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

	// -----------------------------------------------------------------
	// 引数の組み立て（GUI → ヘルパープロセス）
	// -----------------------------------------------------------------

	func testArgumentsForRequest()
	{
		let request = ReconstructionRequest(
			inputFolder: URL(fileURLWithPath: "/tmp/photos", isDirectory: true),
			outputFile: URL(fileURLWithPath: "/tmp/model.usdz"),
			detail: .full,
			sampleOrdering: .sequential,
			featureSensitivity: .high,
			subject: .scene)
		XCTAssertEqual(APICommand.arguments(for: request), [
			"/tmp/photos", "/tmp/model.usdz",
			"--detail", "full",
			"--sample-ordering", "sequential",
			"--feature-sensitivity", "high",
			"--subject", "scene",
		])
	}

	func testArgumentsRoundTrip() throws
	{
		// 組み立てた引数をヘルパー（CLI）が同じ Request に戻せること。ここが
		// ずれると GUI と別プロセス実行で設定が食い違う。
		let request = ReconstructionRequest(
			inputFolder: URL(fileURLWithPath: "/tmp/photos", isDirectory: true),
			outputFile: URL(fileURLWithPath: "/tmp/model.usdz"),
			detail: .reduced,
			sampleOrdering: .sequential,
			featureSensitivity: .high,
			subject: .scene)
		let parsed = try APICommand.parse(arguments: APICommand.arguments(for: request))
		XCTAssertEqual(parsed, request)
	}
}
