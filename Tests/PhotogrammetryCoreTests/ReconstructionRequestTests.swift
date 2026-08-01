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
