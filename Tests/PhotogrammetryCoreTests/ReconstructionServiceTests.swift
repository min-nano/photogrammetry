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
	/// 同一プロセス経路の複製先（本物のキャッシュを汚さない）。
	private var stagingRoot: URL!

	override func setUpWithError() throws
	{
		workDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("ReconstructionServiceTests-\(UUID().uuidString)")
		let input = workDir.appendingPathComponent("photos", isDirectory: true)
		try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
		stagingRoot = workDir.appendingPathComponent("Caches", isDirectory: true)
		try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
		request = ReconstructionRequest(
			inputFolder: input,
			outputFile: workDir.appendingPathComponent("model.usdz"))
	}

	/// 複製の対象になる写真（中身は見ないので拡張子だけ合わせる）。
	private func makePhoto(_ name: String) throws
	{
		try Data(repeating: 0x41, count: 8)
			.write(to: request.inputFolder.appendingPathComponent(name))
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
			.completed(try XCTUnwrap(request.outputFile)),
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
		XCTAssertEqual(service.stagingRoot.lastPathComponent, InputStaging.directoryName)
		service.cancel()
	}

	// 同一プロセス経路の**前後**（複製・後始末・中断）は、エンジンを偽物へ
	// 差し替えれば GPU 無しで確かめられる。再構成そのものは相変わらず回さない。

	func testInProcessRunStagesPhotosAndCleansUp() async throws
	{
		try makePhoto("a.HEIC")
		let engine = FakeEngine()
		let service = ReconstructionService(engine: engine, stagingRoot: stagingRoot)

		try await service.process(request) { _ in }

		let seen = try XCTUnwrap(engine.seenInput)
		// エンジンが見たのは複製先（ローカル）で、元のフォルダではない。
		XCTAssertNotEqual(seen, request.inputFolder)
		XCTAssertEqual(seen.deletingLastPathComponent().path, stagingRoot.path)
		// 終わったら複製は残らない。
		XCTAssertFalse(FileManager.default.fileExists(atPath: seen.path))
	}

	func testInProcessRunDiscardsCopyWhenGenerationFails() async throws
	{
		try makePhoto("a.HEIC")
		let engine = FakeEngine()
		engine.failure = HelperProcessError.failed(exitCode: 1, message: "boom")
		let service = ReconstructionService(engine: engine, stagingRoot: stagingRoot)

		do
		{
			try await service.process(request) { _ in }
			XCTFail("エラーが伝わりません")
		}
		catch
		{
			XCTAssertEqual(error as? HelperProcessError, .failed(exitCode: 1, message: "boom"))
		}
		XCTAssertFalse(
			FileManager.default.fileExists(atPath: try XCTUnwrap(engine.seenInput).path))
	}

	func testInProcessRunUsesOriginalFolderWhenStagingIsOff() async throws
	{
		try makePhoto("a.HEIC")
		var request = self.request!
		request.stageInputLocally = false
		let engine = FakeEngine()
		let service = ReconstructionService(engine: engine, stagingRoot: stagingRoot)

		try await service.process(request) { _ in }

		XCTAssertEqual(engine.seenInput, request.inputFolder)
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path), [])
	}

	func testInProcessCancelStopsBeforeGeneration() async throws
	{
		try makePhoto("a.HEIC")
		let engine = FakeEngine()
		let service = ReconstructionService(engine: engine, stagingRoot: stagingRoot)
		// 複製が始まる前にキャンセルされた場合、生成へは進まない。
		service.cancel()

		do
		{
			try await service.process(request) { _ in }
			XCTFail("中断が伝わりません")
		}
		catch
		{
			XCTAssertEqual(error as? InputStagingError, .cancelled)
		}
		XCTAssertNil(engine.seenInput)
		XCTAssertTrue(engine.cancelled)
	}
}

/// 生成エンジンの偽物。GPU も RealityKit も要らずに、同一プロセス経路の
/// 前後（複製・後始末・中断）だけを確かめるために使う。
final class FakeEngine: ReconstructionEngine, @unchecked Sendable
{
	/// エンジンが受け取った入力フォルダ（複製先に差し替わっているか見る）。
	var seenInput: URL?
	/// 生成の失敗を再現する。
	var failure: Error?
	/// cancel が届いたか。
	var cancelled = false

	func process(
		_ request: ReconstructionRequest,
		onEvent: @escaping @Sendable (ReconstructionEvent) -> Void) async throws
	{
		seenInput = request.inputFolder
		onEvent(.progress(0.5))
		if let failure
		{
			throw failure
		}
	}

	func cancel()
	{
		cancelled = true
	}
}
