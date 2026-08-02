//
//  HelperProcessEngineTests.swift
//
//  生成を別プロセスで走らせるエンジンのテスト。ヘルパーは差し替えられる
//  （helperURL を受け取る）ので、本物の photogrammetry-cli も GPU も要らず、
//  「進捗を出す」「SIGABRT で落ちる」「エラー終了する」「中断する」の 4 つの
//  終わり方をシェルスクリプトで再現して確認できる。
//
//  この SIGABRT のケースが、実機で報告された
//  「com.apple.CorePhotogrammetry.session.recon で abort()」に相当する。
//  ここが通る限り、内部エラーでアプリ本体が道連れになることはない。
//

import XCTest

@testable import PhotogrammetryCore

final class HelperProcessEngineTests: XCTestCase
{
	private var workDir: URL!
	private var request: ReconstructionRequest!

	override func setUpWithError() throws
	{
		workDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("HelperProcessEngineTests-\(UUID().uuidString)")
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

	/// ヘルパーの代わりに走らせるシェルスクリプトを作る。
	private func makeHelper(_ body: String) throws -> URL
	{
		let url = workDir.appendingPathComponent("helper-\(UUID().uuidString).sh")
		try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o755],
			ofItemAtPath: url.path)
		return url
	}

	// -----------------------------------------------------------------
	// 正常系
	// -----------------------------------------------------------------

	func testStreamsEventsAndFinishes() async throws
	{
		// $1 = 入力フォルダ, $2 = 出力ファイル（APICommand.arguments の並び）。
		let helper = try makeHelper(
			"""
			echo "note=開始"
			echo "progress=0.500"
			echo "output=$2"
			echo "ok"
			""")
		let engine = HelperProcessEngine(helperURL: helper)
		let events = EventLog()

		try await engine.process(request) { events.append($0) }

		XCTAssertEqual(events.all, [
			.note("開始"),
			.progress(0.5),
			.completed(request.outputFile),
		])
	}

	func testPassesRequestAsArguments() async throws
	{
		// 引数がそのまま CLI の語彙で届くこと（APICommand.arguments との対）。
		let helper = try makeHelper(
			"""
			echo "note=$*"
			echo "ok"
			""")
		var request = self.request!
		request.detail = .full
		request.subject = .scene
		let engine = HelperProcessEngine(helperURL: helper)
		let events = EventLog()

		try await engine.process(request) { events.append($0) }

		guard case .note(let line)? = events.all.first
		else
		{
			return XCTFail("note が届いていない: \(events.all)")
		}
		XCTAssertTrue(line.contains("--detail full"), line)
		XCTAssertTrue(line.contains("--subject scene"), line)
	}

	// -----------------------------------------------------------------
	// 異常終了（実機で起きているクラッシュ）
	// -----------------------------------------------------------------

	func testCrashIsReportedAsErrorInsteadOfKillingUs() async throws
	{
		let helper = try makeHelper(
			"""
			echo "progress=0.490"
			kill -ABRT $$
			""")
		let engine = HelperProcessEngine(helperURL: helper)
		do
		{
			try await engine.process(request) { _ in }
			XCTFail("異常終了が報告されていない")
		}
		catch let error as HelperProcessError
		{
			guard case .crashed(let signal, let lastProgress, _) = error
			else
			{
				return XCTFail("crashed 以外が返った: \(error)")
			}
			XCTAssertEqual(signal, SIGABRT)
			XCTAssertEqual(lastProgress ?? 0, 0.49, accuracy: 0.001)
			// クラッシュ報告を読まなくても原因と対処が分かる文面であること。
			let message = error.localizedDescription
			XCTAssertTrue(message.contains("SIGABRT"), message)
			XCTAssertTrue(message.contains("49%"), message)
			XCTAssertTrue(message.contains("詳細度"), message)
		}
	}

	func testFailedExitReportsHelperMessage() async throws
	{
		let helper = try makeHelper(
			"""
			echo "error: ばくはつ" >&2
			exit 1
			""")
		let engine = HelperProcessEngine(helperURL: helper)
		do
		{
			try await engine.process(request) { _ in }
			XCTFail("エラー終了が報告されていない")
		}
		catch let error as HelperProcessError
		{
			XCTAssertEqual(error, .failed(exitCode: 1, message: "error: ばくはつ"))
			XCTAssertEqual(error.localizedDescription, "error: ばくはつ")
		}
	}

	func testLaunchFailure() async throws
	{
		let engine = HelperProcessEngine(
			helperURL: workDir.appendingPathComponent("no-such-helper"))
		do
		{
			try await engine.process(request) { _ in }
			XCTFail("起動失敗が報告されていない")
		}
		catch let error as HelperProcessError
		{
			guard case .launchFailed = error
			else
			{
				return XCTFail("launchFailed 以外が返った: \(error)")
			}
		}
	}

	// -----------------------------------------------------------------
	// キャンセル
	// -----------------------------------------------------------------

	func testCancelStopsHelperAndReportsCancelled() async throws
	{
		// SIGINT を受けたら cancelled を出して正常終了する（本物の CLI と同じ挙動）。
		let helper = try makeHelper(
			"""
			trap 'echo "cancelled"; exit 0' INT
			echo "progress=0.100"
			i=0
			while [ $i -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
			echo "ok"
			""")
		let engine = HelperProcessEngine(helperURL: helper)
		let events = EventLog()
		let request = self.request!

		let task = Task
		{
			try await engine.process(request) { events.append($0) }
		}

		// 起動して進捗が出てからキャンセルする。
		var waited = 0
		while !events.all.contains(.progress(0.1))
		{
			try await Task.sleep(nanoseconds: 50_000_000)
			waited += 1
			if waited > 100
			{
				engine.cancel()
				return XCTFail("ヘルパーが進捗を出さなかった")
			}
		}
		engine.cancel()
		try await task.value

		XCTAssertTrue(events.all.contains(.cancelled), "\(events.all)")
	}
}

/// イベントは任意のスレッドから届くので、配列はロックで守る。
private final class EventLog: @unchecked Sendable
{
	private let lock = NSLock()
	private var events: [ReconstructionEvent] = []

	func append(_ event: ReconstructionEvent)
	{
		lock.lock()
		events.append(event)
		lock.unlock()
	}

	var all: [ReconstructionEvent]
	{
		lock.lock()
		defer { lock.unlock() }
		return events
	}
}
