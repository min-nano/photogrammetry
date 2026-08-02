//
//  ProcessingStageTests.swift
//
//  処理段階の語彙（CLI の `stage=` に出る rawValue）と、進捗 1 行の組み立てを
//  テストする。rawValue は外部連携の約束なので、うっかり変えたら落ちるように
//  文字列を直書きして固定する。
//

import XCTest

@testable import PhotogrammetryCore

final class ProcessingStageTests: XCTestCase
{
	func testRawValuesAreStableAPIVocabulary()
	{
		XCTAssertEqual(
			ProcessingStage.allCases.map(\.rawValue),
			[
				"preProcessing",
				"imageAlignment",
				"pointCloudGeneration",
				"meshGeneration",
				"textureMapping",
				"optimization",
			])
	}

	func testInitFromRawValue()
	{
		XCTAssertEqual(ProcessingStage(rawValue: "imageAlignment"), .imageAlignment)
		XCTAssertNil(ProcessingStage(rawValue: "unknownStage"))
	}

	func testDisplayNameIsProvidedForEveryStage()
	{
		for stage in ProcessingStage.allCases
		{
			XCTAssertFalse(stage.displayName.isEmpty, "\(stage) の表示名が空")
			// 表示名は日本語。rawValue（API 語彙）をそのまま出していないこと。
			XCTAssertNotEqual(stage.displayName, stage.rawValue)
		}
	}

	// -----------------------------------------------------------------
	// 残り時間の文字列（分・時間へ丸める）
	// -----------------------------------------------------------------

	func testRemainingTextUnderOneMinute()
	{
		XCTAssertEqual(ProcessingStage.remainingText(0), "残り 1 分未満")
		XCTAssertEqual(ProcessingStage.remainingText(59), "残り 1 分未満")
		// 見積もりが負になることがある（終盤・OS の揺れ）。崩れずに出る。
		XCTAssertEqual(ProcessingStage.remainingText(-10), "残り 1 分未満")
	}

	func testRemainingTextInMinutes()
	{
		XCTAssertEqual(ProcessingStage.remainingText(60), "残り約 1 分")
		XCTAssertEqual(ProcessingStage.remainingText(1830), "残り約 31 分")
		XCTAssertEqual(ProcessingStage.remainingText(3569), "残り約 59 分")
	}

	func testRemainingTextInHours()
	{
		XCTAssertEqual(ProcessingStage.remainingText(3600), "残り約 1 時間")
		XCTAssertEqual(ProcessingStage.remainingText(7800), "残り約 2 時間 10 分")
	}

	// -----------------------------------------------------------------
	// 進捗 1 行（段階・残り時間のどちらも欠けうる）
	// -----------------------------------------------------------------

	func testProgressTextWithBothValues()
	{
		XCTAssertEqual(
			ProcessingStage.progressText(stage: .imageAlignment, remaining: 1800),
			"画像の位置合わせ中 — 残り約 30 分")
	}

	func testProgressTextWithOnlyOneValue()
	{
		XCTAssertEqual(
			ProcessingStage.progressText(stage: .meshGeneration, remaining: nil),
			"メッシュの生成中")
		XCTAssertEqual(
			ProcessingStage.progressText(stage: nil, remaining: 120),
			"残り約 2 分")
	}

	func testProgressTextIsNilWhenNothingIsKnown()
	{
		XCTAssertNil(ProcessingStage.progressText(stage: nil, remaining: nil))
	}
}
