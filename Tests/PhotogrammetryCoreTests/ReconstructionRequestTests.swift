//
//  ReconstructionRequestTests.swift
//
//  リクエストの事前検証（validate）をテストする。入力フォルダの存在チェックが
//  あるので、テスト用の一時ディレクトリを使う。
//

import XCTest

@testable import PhotogrammetryCore

final class ReconstructionRequestTests: XCTestCase
{
	private var workDir: URL!

	override func setUpWithError() throws
	{
		workDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("ReconstructionRequestTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws
	{
		try? FileManager.default.removeItem(at: workDir)
	}

	func testValidateAcceptsDirectoryAndUsdz() throws
	{
		let request = ReconstructionRequest(
			inputFolder: workDir,
			outputFile: workDir.appendingPathComponent("model.usdz"))
		XCTAssertNoThrow(try request.validate())
	}

	func testValidateRejectsMissingInputFolder()
	{
		let request = ReconstructionRequest(
			inputFolder: workDir.appendingPathComponent("does-not-exist"),
			outputFile: workDir.appendingPathComponent("model.usdz"))
		XCTAssertThrowsError(try request.validate())
		{ error in
			guard case .inputNotDirectory = error as? RequestError
			else
			{
				return XCTFail("inputNotDirectory であるべき: \(error)")
			}
		}
	}

	func testValidateRejectsFileAsInput() throws
	{
		// フォルダではなくファイルを入力に指定した場合も弾く。
		let file = workDir.appendingPathComponent("photo.jpg")
		try Data().write(to: file)
		let request = ReconstructionRequest(
			inputFolder: file,
			outputFile: workDir.appendingPathComponent("model.usdz"))
		XCTAssertThrowsError(try request.validate())
	}

	func testValidateRejectsNonUsdzOutput()
	{
		let request = ReconstructionRequest(
			inputFolder: workDir,
			outputFile: workDir.appendingPathComponent("model.obj"))
		XCTAssertThrowsError(try request.validate())
		{ error in
			guard case .outputExtensionInvalid = error as? RequestError
			else
			{
				return XCTFail("outputExtensionInvalid であるべき: \(error)")
			}
		}
	}

	func testValidateAcceptsPointCloudOnly()
	{
		// メッシュを作らず点群だけを頼む形。
		let request = ReconstructionRequest(
			inputFolder: workDir,
			outputFile: nil,
			pointCloudFile: workDir.appendingPathComponent("points.ply"))
		XCTAssertNoThrow(try request.validate())
	}

	func testValidateRejectsRequestWithoutAnyOutput()
	{
		// 出力が 1 つも無ければ何も生まれない。入口ごとに散らさず、全員が
		// 通るこの 1 か所で弾く。
		let request = ReconstructionRequest(inputFolder: workDir, outputFile: nil)
		XCTAssertThrowsError(try request.validate())
		{ error in
			XCTAssertEqual(error as? RequestError, .noOutputRequested)
		}
	}

	func testValidateChecksInputBeforeOutputs()
	{
		// 入力が無いほうが利用者にとって重要な情報なので、出力の有無より先に出す。
		let request = ReconstructionRequest(
			inputFolder: workDir.appendingPathComponent("does-not-exist"),
			outputFile: nil)
		XCTAssertThrowsError(try request.validate())
		{ error in
			guard case .inputNotDirectory = error as? RequestError
			else
			{
				return XCTFail("inputNotDirectory であるべき: \(error)")
			}
		}
	}

	func testValidateAcceptsPlyPointCloud()
	{
		let request = ReconstructionRequest(
			inputFolder: workDir,
			outputFile: workDir.appendingPathComponent("model.usdz"),
			pointCloudFile: workDir.appendingPathComponent("POINTS.PLY"))
		XCTAssertNoThrow(try request.validate())
	}

	func testValidateRejectsNonPlyPointCloud()
	{
		let request = ReconstructionRequest(
			inputFolder: workDir,
			outputFile: workDir.appendingPathComponent("model.usdz"),
			pointCloudFile: workDir.appendingPathComponent("points.xyz"))
		XCTAssertThrowsError(try request.validate())
		{ error in
			guard case .pointCloudExtensionInvalid = error as? RequestError
			else
			{
				return XCTFail("pointCloudExtensionInvalid であるべき: \(error)")
			}
		}
	}

	func testRequestErrorDescriptions()
	{
		XCTAssertEqual(
			RequestError.inputNotDirectory("/tmp/x").errorDescription,
			"入力フォルダが見つかりません（フォルダを指定してください）: /tmp/x")
		XCTAssertEqual(
			RequestError.outputExtensionInvalid("/tmp/a.obj").errorDescription,
			"出力ファイルは拡張子 .usdz を指定してください: /tmp/a.obj")
		XCTAssertEqual(
			RequestError.noOutputRequested.errorDescription,
			"出力が指定されていません（3D モデル .usdz と点群 .ply の少なくとも一方を指定してください）。")
		XCTAssertEqual(
			RequestError.pointCloudExtensionInvalid("/tmp/a.xyz").errorDescription,
			"点群の出力ファイルは拡張子 .ply を指定してください: /tmp/a.xyz")
	}

	func testValidateAcceptsUppercaseExtension()
	{
		let request = ReconstructionRequest(
			inputFolder: workDir,
			outputFile: workDir.appendingPathComponent("MODEL.USDZ"))
		XCTAssertNoThrow(try request.validate())
	}

	func testImageFileCount() throws
	{
		// 大文字拡張子・HEIC を数え、画像以外は無視する。
		try Data().write(to: workDir.appendingPathComponent("a.JPG"))
		try Data().write(to: workDir.appendingPathComponent("b.heic"))
		try Data().write(to: workDir.appendingPathComponent("c.txt"))
		try Data().write(to: workDir.appendingPathComponent("d.png"))
		XCTAssertEqual(ReconstructionRequest.imageFileCount(in: workDir), 3)
	}

	func testImageFileCountMissingFolderIsZero()
	{
		XCTAssertEqual(
			ReconstructionRequest.imageFileCount(
				in: workDir.appendingPathComponent("does-not-exist")),
			0)
	}
}
