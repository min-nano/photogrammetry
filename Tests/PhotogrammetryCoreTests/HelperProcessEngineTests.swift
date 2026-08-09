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

	private func makeHelper(_ body: String) throws -> URL
	{
		try FakeHelper.make(in: workDir, body: body)
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
			.completed(try XCTUnwrap(request.outputFile)),
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

	func testCrashMessageIncludesHelperOutput() async throws
	{
		let helper = try makeHelper(
			"""
			echo "CoreOC: fatal" >&2
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
			let message = error.localizedDescription
			// 進捗が 1 度も出ていないので進捗の但し書きは付かない。
			XCTAssertFalse(message.contains("進捗"), message)
			XCTAssertTrue(message.contains("ヘルパーの出力:"), message)
			XCTAssertTrue(message.contains("CoreOC: fatal"), message)
		}
	}

	func testPartialLastLineIsNotLost() async throws
	{
		// 改行で終わらないまま終了しても、最後の 1 行を取りこぼさないこと。
		let helper = try makeHelper(
			"""
			printf 'progress=0.750'
			""")
		let engine = HelperProcessEngine(helperURL: helper)
		let events = EventLog()

		try await engine.process(request) { events.append($0) }

		XCTAssertEqual(events.all, [.progress(0.75)])
	}

	func testManyLinesAreDeliveredInOrder() async throws
	{
		// 大量の行が**順序どおり・取りこぼし無く**届くこと。読み取りは
		// パイプから届いたぶんを溜めて改行で切り出すので、行がチャンクの
		// 境界にまたがっても崩れないことをここで押さえる。
		//
		// なお終了直前の取りこぼし（`.completed` が消える競合）を確実に
		// 踏ませるのは、行数を増やすほうではなく**書いてすぐ終了する**ほう
		// （testProcessRunsHelperAndLogsMode がその形）。このテストは
		// その競合の再現手段ではない。
		let helper = try makeHelper(
			"""
			i=1
			while [ $i -le 50 ]; do
				printf 'progress=0.%03d\\n' "$i"
				i=$((i + 1))
			done
			echo "output=$2"
			echo "ok"
			""")
		let engine = HelperProcessEngine(helperURL: helper)
		let events = EventLog()

		try await engine.process(request) { events.append($0) }

		let expected: [ReconstructionEvent] =
			(1 ... 50).map { .progress(Double($0) / 1000) }
				+ [.completed(try XCTUnwrap(request.outputFile))]
		XCTAssertEqual(events.all, expected)
	}

	func testFailedExitWithoutMessage() async throws
	{
		let helper = try makeHelper("exit 3")
		let engine = HelperProcessEngine(helperURL: helper)
		do
		{
			try await engine.process(request) { _ in }
			XCTFail("エラー終了が報告されていない")
		}
		catch let error as HelperProcessError
		{
			XCTAssertEqual(error, .failed(exitCode: 3, message: ""))
			XCTAssertTrue(error.localizedDescription.contains("終了コード 3"), "\(error)")
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
		let missing = workDir.appendingPathComponent("no-such-helper")
		let engine = HelperProcessEngine(helperURL: missing)
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
			// どこを探して失敗したのかが分からないと調べようがない。
			XCTAssertTrue(error.localizedDescription.contains(missing.path), "\(error)")
		}
	}

	// -----------------------------------------------------------------
	// ヘルパーの探索・終了シグナルの説明
	// -----------------------------------------------------------------

	func testHelperURLBesideExecutable() throws
	{
		let executable = workDir.appendingPathComponent("Photogrammetry")
		XCTAssertNil(HelperProcessEngine.helperURL(besideExecutable: nil))
		// 隣に無いうちは nil。
		XCTAssertNil(HelperProcessEngine.helperURL(besideExecutable: executable))
		// 実行可能なヘルパーを隣に置くと見つかる。
		let helper = workDir.appendingPathComponent(HelperProcessEngine.executableName)
		try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o755],
			ofItemAtPath: helper.path)
		XCTAssertEqual(
			HelperProcessEngine.helperURL(besideExecutable: executable)?.path,
			helper.path)
	}

	func testSignalNames()
	{
		// クラッシュ報告の切り分けに直結するので、番号ではなく意味を出す。
		XCTAssertTrue(HelperProcessError.signalName(SIGABRT).contains("SIGABRT"))
		XCTAssertTrue(HelperProcessError.signalName(SIGSEGV).contains("SIGSEGV"))
		XCTAssertTrue(HelperProcessError.signalName(SIGBUS).contains("SIGBUS"))
		XCTAssertTrue(HelperProcessError.signalName(SIGILL).contains("SIGILL"))
		XCTAssertTrue(HelperProcessError.signalName(SIGKILL).contains("メモリ不足"))
		XCTAssertTrue(HelperProcessError.signalName(SIGTERM).contains("SIGTERM"))
		XCTAssertTrue(HelperProcessError.signalName(SIGINT).contains("SIGINT"))
		XCTAssertEqual(HelperProcessError.signalName(99), "シグナル 99")
	}

	func testProgressPhrase()
	{
		XCTAssertEqual(HelperProcessError.progressPhrase(nil), "")
		XCTAssertEqual(HelperProcessError.progressPhrase(0.49), "（進捗 49% 付近）")
	}

	func testExitSignalWorksInBothOrders() async
	{
		// 合図が先（プロセスが待ち始める前に終了）でも待ちが先でも通ること。
		let early = ExitSignal()
		early.signal()
		await early.wait()

		let late = ExitSignal()
		Task
		{
			try? await Task.sleep(nanoseconds: 10_000_000)
			late.signal()
		}
		await late.wait()
	}

	// -----------------------------------------------------------------
	// キャンセル
	// -----------------------------------------------------------------

	func testCancelStopsHelperAndReportsCancelled() async throws
	{
		// SIGINT を受けたら cancelled を出して正常終了する（本物の CLI と同じ挙動）。
		let helper = try makeHelper(FakeHelper.cancellableBody)
		let engine = HelperProcessEngine(helperURL: helper)
		let events = EventLog()
		let request = self.request!

		let task = Task
		{
			try await engine.process(request) { events.append($0) }
		}

		// 起動して進捗が出てからキャンセルする。
		let started = await events.wait(for: .progress(0.1))
		engine.cancel()
		try await task.value

		XCTAssertTrue(started, "ヘルパーが進捗を出さなかった")
		XCTAssertTrue(events.all.contains(.cancelled), "\(events.all)")
	}

	func testCancelBeforeLaunchStillEndsAsCancelled() async throws
	{
		// 起動より先にキャンセルが来ても取りこぼさないこと（GUI では
		// process の Task が走り出す前にボタンを押せてしまう）。
		let helper = try makeHelper(
			"""
			i=0
			while [ $i -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
			""")
		let engine = HelperProcessEngine(helperURL: helper)
		let events = EventLog()
		let request = self.request!

		engine.cancel()
		try await engine.process(request) { events.append($0) }

		// SIGINT の既定動作で落ちても（cancelled を出す前に死んでも）、
		// 要求済みならキャンセル扱いにする。
		XCTAssertEqual(events.all, [.cancelled])
	}
}
