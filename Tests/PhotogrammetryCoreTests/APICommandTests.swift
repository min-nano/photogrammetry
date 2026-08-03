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
		let request = try parseProcess(url: url)
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
		let request = try parseProcess(url: url)
		XCTAssertEqual(request.detail, .full)
		XCTAssertEqual(request.sampleOrdering, .sequential)
		XCTAssertEqual(request.featureSensitivity, .high)
		XCTAssertEqual(request.subject, .scene)
	}

	func testParseURLInvalidSubject()
	{
		let url = URL(
			string: "photogrammetry://process?input=/a&output=/b.usdz&subject=person")!
		XCTAssertThrowsError(try parseProcess(url: url))
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
		let request = try parseProcess(url: url)
		XCTAssertEqual(request.inputFolder.path, "/tmp/my photos")
	}

	func testParseURLMissingInput()
	{
		let url = URL(string: "photogrammetry://process?output=/tmp/model.usdz")!
		XCTAssertThrowsError(try parseProcess(url: url))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingParameter("input"))
		}
	}

	func testParseURLUnknownCommand()
	{
		let url = URL(string: "photogrammetry://export?input=/a&output=/b.usdz")!
		XCTAssertThrowsError(try parseProcess(url: url))
		{ error in
			XCTAssertEqual(error as? APICommandError, .unsupportedCommand("export"))
		}
	}

	func testParseURLInvalidDetail()
	{
		let url = URL(
			string: "photogrammetry://process?input=/a&output=/b.usdz&detail=ultra")!
		XCTAssertThrowsError(try parseProcess(url: url))
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
		XCTAssertThrowsError(try parseProcess(url: url))
		{ error in
			XCTAssertEqual(error as? APICommandError, .unsupportedCommand(""))
		}
	}

	func testParseURLWithoutQueryStringHasNoQueryItems()
	{
		// "?" 自体が無ければ queryItems は nil（空配列とは区別される）。
		let url = URL(string: "photogrammetry://process")!
		XCTAssertThrowsError(try parseProcess(url: url))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingParameter("input"))
		}
	}

	func testParseURLQueryItemWithoutValue()
	{
		// "input" だけで "=" が無いクエリ項目は value が nil になる
		// （空文字と区別される）。
		let url = URL(string: "photogrammetry://process?input&output=/b.usdz")!
		XCTAssertThrowsError(try parseProcess(url: url))
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
		XCTAssertEqual(
			APICommandError.missingSortArguments.errorDescription,
			"引数が不足しています（sort <入力フォルダ> <仕分け先フォルダ> が必要です）。")
	}

	// -----------------------------------------------------------------
	// CLI 引数
	// -----------------------------------------------------------------

	func testParseArgumentsMinimal() throws
	{
		let request = try parseProcess(arguments: ["/tmp/photos", "/tmp/model.usdz"])
		XCTAssertEqual(request.inputFolder.path, "/tmp/photos")
		XCTAssertEqual(request.outputFile.path, "/tmp/model.usdz")
		XCTAssertEqual(request.detail, .medium)
	}

	func testParseArgumentsWithOptions() throws
	{
		let request = try parseProcess(arguments: [
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
			try parseProcess(arguments: ["/a", "/b.usdz", "--subject", "person"]))
		{ error in
			XCTAssertEqual(
				error as? APICommandError,
				.invalidValue(parameter: "--subject", value: "person"))
		}
	}

	func testParseArgumentsShortOptionsAndOrder() throws
	{
		// オプションは位置引数の前後どちらでもよい。
		let request = try parseProcess(arguments: [
			"-d", "preview", "/tmp/photos", "/tmp/model.usdz",
		])
		XCTAssertEqual(request.detail, .preview)
	}

	func testParseArgumentsUnknownOption()
	{
		XCTAssertThrowsError(
			try parseProcess(arguments: ["/a", "/b.usdz", "--turbo"]))
		{ error in
			XCTAssertEqual(error as? APICommandError, .unknownOption("--turbo"))
		}
	}

	func testParseArgumentsMissingPositional()
	{
		XCTAssertThrowsError(try parseProcess(arguments: ["/a"]))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingArguments)
		}
	}

	func testParseArgumentsMissingOptionValue()
	{
		XCTAssertThrowsError(
			try parseProcess(arguments: ["/a", "/b.usdz", "--detail"]))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingParameter("--detail"))
		}
	}

	func testParseArgumentsInvalidValue()
	{
		XCTAssertThrowsError(
			try parseProcess(arguments: ["/a", "/b.usdz", "--detail", "gigantic"]))
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

	// -----------------------------------------------------------------
	// sort コマンド
	//
	// 外部連携の語彙は APICommand に 1 か所だけ、というルールを守るため、
	// URL と CLI で同じ意味になることをここで固定する。
	// -----------------------------------------------------------------

	func testParseSortURL() throws
	{
		let url = URL(
			string: "photogrammetry://sort?input=/tmp/photos&output=/tmp/sorted"
				+ "&overlap=8&maxPerGroup=120&minPerGroup=15&timeGap=120"
				+ "&groupThreshold=0.4&minSharpness=12.5&duplicateDistance=6"
				+ "&visual=false&visualThreshold=0.45"
				+ "&overlapCheck=false&overlapInliers=0.5"
				+ "&overlapGrouping=false&overlapBudget=5000"
				+ "&link=copy&recursive=false&dryRun=true")!
		let request = try parseSort(url: url)
		XCTAssertEqual(request.inputFolder.path, "/tmp/photos")
		XCTAssertEqual(request.outputFolder.path, "/tmp/sorted")
		XCTAssertEqual(request.overlap, 8)
		XCTAssertEqual(request.maxPerGroup, 120)
		XCTAssertEqual(request.minPerGroup, 15)
		XCTAssertEqual(request.timeGap, 120)
		XCTAssertEqual(request.groupThreshold, 0.4)
		XCTAssertEqual(request.minimumSharpness, 12.5)
		XCTAssertEqual(request.duplicateDistance, 6)
		XCTAssertFalse(request.visualEvidence)
		XCTAssertEqual(request.visualThreshold, 0.45)
		XCTAssertFalse(request.overlapCheck)
		XCTAssertEqual(request.overlapInliers, 0.5)
		XCTAssertFalse(request.overlapGrouping)
		XCTAssertEqual(request.overlapBudget, 5000)
		XCTAssertEqual(request.link, .copy)
		XCTAssertFalse(request.recursive)
		XCTAssertTrue(request.dryRun)
	}

	func testParseSortURLMinimalUsesDefaults() throws
	{
		let url = URL(string: "photogrammetry://sort?input=/tmp/photos&output=/tmp/sorted")!
		let request = try parseSort(url: url)
		XCTAssertEqual(request.overlap, 15)
		XCTAssertEqual(request.maxPerGroup, 150)
		// 閾値は既定で「分布から自動決定」。固定値を持たない（設計メモ §10-5）。
		XCTAssertNil(request.groupThreshold)
		XCTAssertNil(request.minimumSharpness)
		XCTAssertNil(request.visualThreshold)
		XCTAssertNil(request.overlapInliers)
		// 視覚解析も重なりの確認も既定で入れる（切るのは逃げ道）。
		XCTAssertTrue(request.visualEvidence)
		XCTAssertTrue(request.overlapCheck)
		// グループ分けにも重なりを使うのが既定（設計メモ §4.9）。回数の上限は
		// 枚数から決めるので既定では指定しない。
		XCTAssertTrue(request.overlapGrouping)
		XCTAssertNil(request.overlapBudget)
		XCTAssertTrue(request.recursive)
		XCTAssertFalse(request.dryRun)
	}

	func testParseSortURLInvalidNumber()
	{
		let url = URL(
			string: "photogrammetry://sort?input=/a&output=/b&overlap=many")!
		XCTAssertThrowsError(try APICommand.parse(url: url))
		{ error in
			XCTAssertEqual(
				error as? APICommandError, .invalidValue(parameter: "overlap", value: "many"))
		}
	}

	func testParseSortURLBooleanForms() throws
	{
		for (text, expected) in [("true", true), ("1", true), ("yes", true),
			("false", false), ("0", false), ("no", false)]
		{
			let url = URL(
				string: "photogrammetry://sort?input=/a&output=/b&dryRun=\(text)")!
			XCTAssertEqual(try parseSort(url: url).dryRun, expected)
		}
		let bad = URL(string: "photogrammetry://sort?input=/a&output=/b&dryRun=maybe")!
		XCTAssertThrowsError(try APICommand.parse(url: bad))
	}

	func testParseSortArguments() throws
	{
		let request = try parseSort(arguments: [
			"sort", "/tmp/photos", "/tmp/sorted",
			"--overlap", "8",
			"--max-per-group", "120",
			"--min-per-group", "15",
			"--time-gap", "120",
			"--group-threshold", "0.4",
			"--min-sharpness", "12.5",
			"--duplicate-distance", "6",
			"--visual-threshold", "0.45",
			"--no-visual",
			"--overlap-inliers", "0.5",
			"--no-overlap-check",
			"--no-overlap-grouping",
			"--overlap-budget", "5000",
			"--link", "symlink",
			"--no-recursive",
			"--dry-run",
		])
		XCTAssertEqual(request.inputFolder.path, "/tmp/photos")
		XCTAssertEqual(request.outputFolder.path, "/tmp/sorted")
		XCTAssertEqual(request.overlap, 8)
		XCTAssertEqual(request.visualThreshold, 0.45)
		XCTAssertFalse(request.visualEvidence)
		XCTAssertEqual(request.overlapInliers, 0.5)
		XCTAssertFalse(request.overlapCheck)
		XCTAssertFalse(request.overlapGrouping)
		XCTAssertEqual(request.overlapBudget, 5000)
		XCTAssertEqual(request.link, .symlink)
		XCTAssertFalse(request.recursive)
		XCTAssertTrue(request.dryRun)
	}

	func testParseSortArgumentsMissingPositional()
	{
		XCTAssertThrowsError(try APICommand.parse(arguments: ["sort", "/tmp/photos"]))
		{ error in
			XCTAssertEqual(error as? APICommandError, .missingSortArguments)
		}
	}

	func testParseSortArgumentsUnknownOption()
	{
		XCTAssertThrowsError(
			try APICommand.parse(arguments: ["sort", "/a", "/b", "--turbo"]))
		{ error in
			XCTAssertEqual(error as? APICommandError, .unknownOption("--turbo"))
		}
	}

	func testProcessSubcommandIsAccepted() throws
	{
		// 明示的な process も受ける（URL スキームと語彙を揃えるため）。
		let request = try parseProcess(arguments: ["process", "/tmp/photos", "/tmp/model.usdz"])
		XCTAssertEqual(request.inputFolder.path, "/tmp/photos")
	}

	func testExistingPositionalFormStaysBackwardCompatible() throws
	{
		// サブコマンド名が無ければ従来どおり生成。既存のスクリプトを壊さない。
		let command = try APICommand.parse(arguments: ["/tmp/photos", "/tmp/model.usdz"])
		guard case .process = command
		else
		{
			return XCTFail("サブコマンド省略時は process になりません")
		}
	}

	func testSortArgumentsRoundTrip() throws
	{
		var request = SortRequest(
			inputFolder: URL(fileURLWithPath: "/tmp/photos", isDirectory: true),
			outputFolder: URL(fileURLWithPath: "/tmp/sorted", isDirectory: true),
			overlap: 9,
			maxPerGroup: 90,
			minPerGroup: 12,
			timeGap: 240,
			groupThreshold: 0.35,
			minimumSharpness: 8,
			duplicateDistance: 5,
			visualEvidence: false,
			visualThreshold: 0.45,
			overlapCheck: false,
			overlapInliers: 0.5,
			overlapGrouping: false,
			overlapBudget: 5000,
			link: .copy,
			recursive: false,
			dryRun: true)
		XCTAssertEqual(try parseSort(arguments: APICommand.arguments(for: request)), request)

		// 自動決定に任せた項目は引数に出さない（出すと「自動」が失われる）。
		request.groupThreshold = nil
		request.minimumSharpness = nil
		request.visualThreshold = nil
		request.visualEvidence = true
		request.overlapInliers = nil
		request.overlapCheck = true
		request.overlapGrouping = true
		request.overlapBudget = nil
		let arguments = APICommand.arguments(for: request)
		XCTAssertFalse(arguments.contains("--group-threshold"))
		XCTAssertFalse(arguments.contains("--min-sharpness"))
		XCTAssertFalse(arguments.contains("--visual-threshold"))
		XCTAssertFalse(arguments.contains("--no-visual"))
		XCTAssertFalse(arguments.contains("--overlap-inliers"))
		XCTAssertFalse(arguments.contains("--no-overlap-check"))
		XCTAssertFalse(arguments.contains("--no-overlap-grouping"))
		XCTAssertFalse(arguments.contains("--overlap-budget"))
		XCTAssertEqual(try parseSort(arguments: arguments), request)
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
		let parsed = try parseProcess(arguments: APICommand.arguments(for: request))
		XCTAssertEqual(parsed, request)
	}
}
