//
//  ReconstructionServiceTests.swift
//
//  実行方式（別プロセス / 同一プロセス）の解決と、フロントエンドから見た
//  振る舞いをテストする。ヘルパーはシェルスクリプトへ差し替えられるので、
//  別プロセス経路は GPU 無しで確認できる。同一プロセス経路の生成そのものは
//  GPU が要るので回さない（CLAUDE.md「テスト方針」）。
//

import XCTest

@testable import PhotogrammetryCore

final class ReconstructionServiceTests: XCTestCase
{
	private var workDir: URL!
	private var request: ReconstructionRequest!

	override func setUpWithError() throws
	{
		workDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("ReconstructionServiceTests-\(UUID().uuidString)")
		let input = workDir.appendingPathComponent("photos", isDirectory: true)
		try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
		request = ReconstructionRequest(
			inputFolder: input,
			outputFile: workDir.appendingPathComponent("model.usdz"))
	}

	override func tearDownWithError() throws
	{
		try? FileManager.default.removeItem(at: workDir)
	}

	// -----------------------------------------------------------------
	// 実行方式の解決とログ
	// -----------------------------------------------------------------

	func testMaximumImageCountFollowsSupport()
	{
		// 仕分けの診断が「グループが上限を超えていないか」を見るのに使う。
		// 対応していない Mac（CI ランナー）では nil になる — どちらの環境でも
		// 成立する関係だけを固定する。
		if ReconstructionService.isSupported
		{
			XCTAssertGreaterThan(ReconstructionService.maximumImageCount ?? 0, 0)
		}
		else
		{
			XCTAssertNil(ReconstructionService.maximumImageCount)
		}
	}

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

	func testIsSupportedMirrorsEngine()
	{
		// 対応判定は RealityKit の答えをそのまま返すだけ（GUI・CLI が同じ答えを
		// 見るために facade にも生やしてある）。
		XCTAssertEqual(ReconstructionService.isSupported, PhotogrammetryEngine.isSupported)
	}

	// -----------------------------------------------------------------
	// 別プロセス経路
	// -----------------------------------------------------------------

	func testProcessRunsHelperAndLogsMode() async throws
	{
		let helper = try FakeHelper.make(
			in: workDir,
			body: """
				echo "progress=0.250"
				echo "output=$2"
				echo "ok"
				""")
		let service = ReconstructionService(mode: .helperProcess(helper))
		let events = EventLog()

		try await service.process(request) { events.append($0) }

		XCTAssertEqual(events.all, [
			.note(ReconstructionService.note(for: .helperProcess(helper))),
			.progress(0.25),
			.completed(request.outputFile),
		])
	}

	func testCancelIsForwardedToHelper() async throws
	{
		let helper = try FakeHelper.make(in: workDir, body: FakeHelper.cancellableBody)
		let service = ReconstructionService(mode: .helperProcess(helper))
		let events = EventLog()
		let request = self.request!

		let task = Task
		{
			try await service.process(request) { events.append($0) }
		}
		let started = await events.wait(for: .progress(0.1))
		service.cancel()
		try await task.value

		XCTAssertTrue(started, "ヘルパーが進捗を出さなかった")
		XCTAssertTrue(events.all.contains(.cancelled), "\(events.all)")
	}

	// -----------------------------------------------------------------
	// 同一プロセス経路（生成は回さない）
	// -----------------------------------------------------------------

	func testInProcessModeIsConstructibleAndCancellable()
	{
		// ヘルパーが無い環境（開発ビルド）でも組み立てられ、実行前の
		// キャンセルが何も壊さないこと。
		let service = ReconstructionService(mode: .inProcess)
		XCTAssertEqual(service.mode, .inProcess)
		service.cancel()
	}
}
