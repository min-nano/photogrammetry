//
//  InputInspectionTests.swift
//
//  入力フォルダの事前チェックをテストする。判定（notes）は数値と真偽値だけで
//  決まる純ロジックなので文字列で書け、走査（inspect）は一時ディレクトリで確認する。
//

import XCTest

@testable import PhotogrammetryCore

final class InputInspectionTests: XCTestCase
{
	private var workDir: URL!

	override func setUpWithError() throws
	{
		workDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("InputInspectionTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws
	{
		try? FileManager.default.removeItem(at: workDir)
	}

	private func touch(_ name: String) throws
	{
		try Data().write(to: workDir.appendingPathComponent(name))
	}

	// -----------------------------------------------------------------
	// 走査
	// -----------------------------------------------------------------

	func testInspectCountsImagesAndPlaceholders() throws
	{
		try touch("a.jpg")
		try touch("b.HEIC")
		try touch("readme.txt")
		try touch(".c.jpg.icloud")

		let summary = InputInspection.inspect(folder: workDir, maximumImageCount: 1000)
		XCTAssertEqual(summary.imageCount, 2)
		XCTAssertEqual(summary.placeholderCount, 1)
		XCTAssertEqual(summary.maximumImageCount, 1000)
		XCTAssertFalse(summary.isCloudStorage)
	}

	func testInspectMissingFolder()
	{
		let summary = InputInspection.inspect(
			folder: workDir.appendingPathComponent("nope"),
			maximumImageCount: 100)
		XCTAssertEqual(summary.imageCount, 0)
		XCTAssertEqual(summary.placeholderCount, 0)
	}

	func testIsCloudStoragePath()
	{
		XCTAssertTrue(InputInspection.isCloudStoragePath(
			"/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Downloads/photos"))
		XCTAssertFalse(InputInspection.isCloudStoragePath("/Users/me/Pictures/photos"))
	}

	// -----------------------------------------------------------------
	// 文章化
	// -----------------------------------------------------------------

	func testNotesNormalCase()
	{
		let notes = InputInspection.notes(for: .init(imageCount: 53, maximumImageCount: 1000))
		XCTAssertEqual(notes.count, 1)
		XCTAssertTrue(notes[0].contains("53"))
		XCTAssertTrue(notes[0].contains("1000"))
	}

	func testNotesOverMaximum()
	{
		let notes = InputInspection.notes(for: .init(imageCount: 1200, maximumImageCount: 1000))
		XCTAssertTrue(notes[0].hasPrefix("警告:"))
		XCTAssertTrue(notes[0].contains("1200"))
	}

	func testNotesEmptyFolder()
	{
		let notes = InputInspection.notes(for: .init(imageCount: 0, maximumImageCount: 1000))
		XCTAssertEqual(notes.count, 2)
		XCTAssertTrue(notes[1].contains("1 枚も見つかりません"))
	}

	func testNotesPlaceholdersWarnEvenOnCloud()
	{
		// 未ダウンロードがある場合は、クラウド上という一般論ではなく
		// 「ダウンロードしてから実行」を出す（より具体的な指示を優先）。
		let notes = InputInspection.notes(for: .init(
			imageCount: 53,
			placeholderCount: 4,
			isCloudStorage: true,
			maximumImageCount: 1000))
		XCTAssertEqual(notes.count, 2)
		XCTAssertTrue(notes[1].contains(".icloud"))
		XCTAssertTrue(notes[1].contains("4"))
	}

	func testNotesCloudStorage()
	{
		let notes = InputInspection.notes(for: .init(
			imageCount: 53,
			isCloudStorage: true,
			maximumImageCount: 1000))
		XCTAssertEqual(notes.count, 2)
		XCTAssertTrue(notes[1].contains("iCloud Drive"))
	}
}
