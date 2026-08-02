//
//  ReconstructionServiceTests.swift
//
//  実行方式（別プロセス / 同一プロセス）の解決とログ表示をテストする。
//  実際の生成は GPU が要るので回さない（CLAUDE.md「テスト方針」）。
//

import XCTest

@testable import PhotogrammetryCore

final class ReconstructionServiceTests: XCTestCase
{
	func testNoteForHelperProcessShowsPath()
	{
		let note = ReconstructionService.note(
			for: .helperProcess(URL(fileURLWithPath: "/Applications/X.app/Contents/MacOS/cli")))
		XCTAssertTrue(note.contains("別プロセス"), note)
		XCTAssertTrue(note.contains("/Applications/X.app/Contents/MacOS/cli"), note)
	}

	func testNoteForInProcessWarns()
	{
		// 同一プロセス実行は「内部エラーでアプリごと落ちうる」状態なので、
		// ログを見ればそれと分かること（クラッシュ報告の切り分けに要る）。
		let note = ReconstructionService.note(for: .inProcess)
		XCTAssertTrue(note.contains("同一プロセス"), note)
		XCTAssertTrue(note.contains(HelperProcessEngine.executableName), note)
	}

	func testResolveModeFollowsBundledHelper()
	{
		// ヘルパーが隣にあれば別プロセス、無ければ同一プロセス。テスト実行
		// （xctest バンドル）では隣に無いので後者になる。
		if let helper = HelperProcessEngine.bundledHelperURL()
		{
			XCTAssertEqual(ReconstructionService.resolveMode(), .helperProcess(helper))
		}
		else
		{
			XCTAssertEqual(ReconstructionService.resolveMode(), .inProcess)
		}
	}
}
