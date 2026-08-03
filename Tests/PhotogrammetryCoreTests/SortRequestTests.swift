//
//  SortRequestTests.swift
//
//  仕分け 1 回分の指示の検証と、各段の設定への翻訳を固定する。
//

import XCTest

@testable import PhotogrammetryCore

final class SortRequestTests: XCTestCase
{
	var temporary: URL!

	override func setUpWithError() throws
	{
		temporary = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("sort-request-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws
	{
		try? FileManager.default.removeItem(at: temporary)
	}

	func makeRequest() -> SortRequest
	{
		SortRequest(
			inputFolder: temporary,
			outputFolder: temporary.appendingPathComponent("out"))
	}

	// -----------------------------------------------------------------
	// validate
	// -----------------------------------------------------------------

	func testValidateAcceptsExistingInputAndFreshOutput() throws
	{
		XCTAssertNoThrow(try makeRequest().validate())
	}

	func testValidateRejectsMissingInput()
	{
		let missing = temporary.appendingPathComponent("missing")
		let request = SortRequest(
			inputFolder: missing,
			outputFolder: temporary.appendingPathComponent("out"))
		XCTAssertThrowsError(try request.validate())
		{ error in
			XCTAssertEqual(error as? SortRequestError, .inputNotDirectory(missing.path))
		}
	}

	func testValidateRejectsNonEmptyOutput() throws
	{
		let output = temporary.appendingPathComponent("out")
		try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
		try Data().write(to: output.appendingPathComponent("group-01"))
		// 前回の結果と混ざると、どの写真がどのグループのものか分からなくなる。
		XCTAssertThrowsError(try makeRequest().validate())
	}

	func testDryRunIgnoresNonEmptyOutput() throws
	{
		let output = temporary.appendingPathComponent("out")
		try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
		try Data().write(to: output.appendingPathComponent("group-01"))
		var request = makeRequest()
		request.dryRun = true
		XCTAssertNoThrow(try request.validate())
	}

	func testValidateRejectsOutputEqualToInput()
	{
		let request = SortRequest(inputFolder: temporary, outputFolder: temporary)
		XCTAssertThrowsError(try request.validate())
	}

	func testValidateRejectsNonsenseSettings()
	{
		var request = makeRequest()
		request.overlap = -1
		XCTAssertThrowsError(try request.validate())

		request = makeRequest()
		request.maxPerGroup = 5
		XCTAssertThrowsError(try request.validate())

		request = makeRequest()
		request.minPerGroup = 0
		XCTAssertThrowsError(try request.validate())

		request = makeRequest()
		request.minPerGroup = 200
		XCTAssertThrowsError(try request.validate())

		request = makeRequest()
		request.duplicateDistance = 65
		XCTAssertThrowsError(try request.validate())

		request = makeRequest()
		request.groupThreshold = 1.5
		XCTAssertThrowsError(try request.validate())

		request = makeRequest()
		request.visualThreshold = -0.1
		XCTAssertThrowsError(try request.validate())
	}

	func testErrorDescriptions()
	{
		// エラーは「投げられること」しか確認していないケースが多いので、
		// メッセージの中身自体をここで確かめる。
		XCTAssertEqual(
			SortRequestError.inputNotDirectory("/tmp/x").errorDescription,
			"入力フォルダが見つかりません（フォルダを指定してください）: /tmp/x")
		XCTAssertEqual(
			SortRequestError.outputNotEmpty("/tmp/y").errorDescription,
			"仕分け先フォルダが空ではありません（前回の結果と混ざるため中断しました）: /tmp/y")
		XCTAssertEqual(
			SortRequestError.outputInsideInput("/tmp/z").errorDescription,
			"仕分け先に入力フォルダ自身は指定できません: /tmp/z")
		XCTAssertEqual(
			SortRequestError.invalidSetting("overlap", "0 以上").errorDescription,
			"overlap の値が不正です（0 以上）。")
	}

	// -----------------------------------------------------------------
	// 設定への翻訳
	// -----------------------------------------------------------------

	func testGroupingLimitReservesRoomForSharedPhotos()
	{
		// 共有写真はあとから両側へ入る。上限をそのまま渡すと、仕分け直後は
		// 上限内でも共有を足した時点で超える。
		var request = makeRequest()
		request.maxPerGroup = 150
		request.overlap = 15
		XCTAssertEqual(request.groupingSettings.maxPerGroup, 120)
	}

	func testGroupingLimitFallsBackWhenReservationWouldBeAbsurd()
	{
		// 余裕を引くと下限を割るような設定では、上限をそのまま使う
		// （1 枚ずつのグループを作らない。超過は診断で報告する）。
		var request = makeRequest()
		request.maxPerGroup = 40
		request.minPerGroup = 20
		request.overlap = 15
		XCTAssertEqual(request.groupingSettings.maxPerGroup, 40)
	}

	func testSettingsAreCarriedIntoEachStage()
	{
		var request = makeRequest()
		request.timeGap = 120
		request.groupThreshold = 0.5
		request.minimumSharpness = 30
		request.duplicateDistance = 8
		request.overlap = 7
		XCTAssertEqual(request.groupingSettings.timeGap, 120)
		XCTAssertEqual(request.groupingSettings.threshold, 0.5)
		XCTAssertEqual(request.qualitySettings.minimumSharpness, 30)
		XCTAssertEqual(request.qualitySettings.duplicateDistance, 8)
		XCTAssertEqual(request.plannerSettings.overlap, 7)
	}

	func testVisualSettingsAreCarriedIntoEachStage()
	{
		var request = makeRequest()
		request.visualThreshold = 0.45
		XCTAssertEqual(request.groupingSettings.roomClustering.threshold, 0.45)
		XCTAssertTrue(request.inspectionOptions.featurePrints)
		XCTAssertEqual(request.groupingSettings.weights[.room], GroupingSettings.defaultWeights[.room])

		// 切ったときは読み取りでも重みでも使わない。
		request.visualEvidence = false
		XCTAssertFalse(request.inspectionOptions.featurePrints)
		XCTAssertEqual(request.groupingSettings.weights[.scene], 0)
		XCTAssertEqual(request.groupingSettings.weights[.room], 0)
		// 既存の証拠の重みには手を触れない（フェーズ 1 と同じ配分に戻す）。
		XCTAssertEqual(
			request.groupingSettings.weights[.time], GroupingSettings.defaultWeights[.time])
	}
}
