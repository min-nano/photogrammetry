//
//  InputStagingTests.swift
//
//  写真をアプリのキャッシュへ複製してから処理する動作（InputStaging）を
//  テストする。RealityKit も GPU も要らず、実画像も要らない（複製は中身を
//  見ないので、拡張子だけ揃えたダミーで十分）。
//
//  ここで固定したいのは 3 つ。
//    1. 何を写すか（直下の画像だけ。未ダウンロードは実体の名前へ直す）
//    2. 処理が終わったら必ず捨てること（残ると数 GB を放置することになる）
//    3. 異常終了で取り残された複製を次回に掃除すること
//

import XCTest

@testable import PhotogrammetryCore

final class InputStagingTests: XCTestCase
{
	private var workDir: URL!
	private var inputFolder: URL!
	private var cacheRoot: URL!

	override func setUpWithError() throws
	{
		workDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("InputStagingTests-\(UUID().uuidString)")
		inputFolder = workDir.appendingPathComponent("photos", isDirectory: true)
		cacheRoot = workDir.appendingPathComponent("Caches", isDirectory: true)
		try FileManager.default.createDirectory(at: inputFolder, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws
	{
		try? FileManager.default.removeItem(at: workDir)
	}

	private func makeFile(_ name: String, bytes: Int = 16) throws
	{
		try Data(repeating: 0x41, count: bytes)
			.write(to: inputFolder.appendingPathComponent(name))
	}

	private func request() -> ReconstructionRequest
	{
		ReconstructionRequest(
			inputFolder: inputFolder,
			outputFile: workDir.appendingPathComponent("model.usdz"))
	}

	// -----------------------------------------------------------------
	// 何を写すか（純ロジック）
	// -----------------------------------------------------------------

	func testSelectPicksImagesOnly()
	{
		let selection = InputStaging.select(names: [
			"a.HEIC", "b.jpg", "c.PNG", "notes.txt", "manifest.json", ".DS_Store",
		])
		XCTAssertEqual(selection.names, ["a.HEIC", "b.jpg", "c.PNG"])
		XCTAssertTrue(selection.pending.isEmpty)
	}

	func testSelectResolvesICloudPlaceholders()
	{
		// 実体が未ダウンロードの写真は `.名前.拡張子.icloud` としてしか見えない。
		// 実体の名前へ直したうえで「ダウンロード待ちが要るもの」として数える。
		let selection = InputStaging.select(names: [".IMG_0002.HEIC.icloud", "IMG_0001.HEIC"])
		XCTAssertEqual(selection.names, ["IMG_0001.HEIC", "IMG_0002.HEIC"])
		XCTAssertEqual(selection.pending, ["IMG_0002.HEIC"])
	}

	func testSelectIgnoresPlaceholderWhenRealFileIsVisible()
	{
		// プレースホルダが消え残っている場合、待つ必要は無い。
		let selection = InputStaging.select(names: [".IMG_0001.HEIC.icloud", "IMG_0001.HEIC"])
		XCTAssertEqual(selection.names, ["IMG_0001.HEIC"])
		XCTAssertTrue(selection.pending.isEmpty)
	}

	func testPlaceholderRealName()
	{
		XCTAssertEqual(InputStaging.placeholderRealName(".a.HEIC.icloud"), "a.HEIC")
		// 画像でないもの・先頭がドットでないものはプレースホルダとして扱わない。
		XCTAssertNil(InputStaging.placeholderRealName(".notes.txt.icloud"))
		XCTAssertNil(InputStaging.placeholderRealName("a.HEIC.icloud"))
		XCTAssertNil(InputStaging.placeholderRealName(".icloud"))
		XCTAssertNil(InputStaging.placeholderRealName("a.HEIC"))
	}

	func testStagedDirectoryNameKeepsSourceName()
	{
		let name = InputStaging.stagedDirectoryName(
			for: URL(fileURLWithPath: "/Users/me/現場/2 階", isDirectory: true), unique: "ABC")
		XCTAssertEqual(name, "2 階-ABC")
		// ルートのように名前が取れない場合でも、成立する名前を返す。
		XCTAssertEqual(
			InputStaging.stagedDirectoryName(for: URL(fileURLWithPath: "/"), unique: "ABC"),
			"input-ABC")
	}

	func testRootIsUnderCachesOfTheBundle()
	{
		let root = InputStaging.root(bundleIdentifier: "com.minnano.photogrammetry")
		XCTAssertEqual(root.lastPathComponent, InputStaging.directoryName)
		XCTAssertEqual(
			root.deletingLastPathComponent().lastPathComponent, "com.minnano.photogrammetry")
		// バンドル ID が無い実行形態（素の CLI）でも場所は決まる。
		XCTAssertEqual(
			InputStaging.root(bundleIdentifier: nil).deletingLastPathComponent()
				.lastPathComponent,
			InputStaging.fallbackBundleDirectoryName)
		// 引数なし（実行中のバンドル）でも場所が決まること。パスを組み立てるだけで
		// ファイルは作らない。
		XCTAssertEqual(InputStaging.root().lastPathComponent, InputStaging.directoryName)
	}

	func testSizeTextIsStable()
	{
		// ログの文言はロケールで揺れない（ByteCountFormatter を使わない理由）。
		XCTAssertEqual(InputStaging.sizeText(512), "512 バイト")
		XCTAssertEqual(InputStaging.sizeText(2048), "2.0 KB")
		XCTAssertEqual(InputStaging.sizeText(3_500_000), "3.5 MB")
		XCTAssertEqual(InputStaging.sizeText(12_000_000_000), "12.0 GB")
	}

	func testNotesMentionWhatIsHappening()
	{
		let note = InputStaging.startNote(
			fileCount: 120, pendingCount: 3, destination: URL(fileURLWithPath: "/tmp/staged"))
		XCTAssertTrue(note.contains("120 枚"))
		XCTAssertTrue(note.contains("/tmp/staged"))
		XCTAssertTrue(note.contains("3 枚"))
		XCTAssertFalse(
			InputStaging.startNote(
				fileCount: 5, pendingCount: 0, destination: URL(fileURLWithPath: "/tmp/staged"))
				.contains("未ダウンロード"))
		XCTAssertTrue(InputStaging.finishNote(fileCount: 7, byteCount: 2048).contains("7 枚"))
		XCTAssertTrue(InputStaging.finishNote(fileCount: 7, byteCount: 2048).contains("2.0 KB"))
	}

	func testIsStale()
	{
		let now = Date(timeIntervalSince1970: 1_000_000)
		XCTAssertFalse(InputStaging.isStale(
			modifiedAt: now.addingTimeInterval(-60), now: now))
		XCTAssertTrue(InputStaging.isStale(
			modifiedAt: now.addingTimeInterval(-InputStaging.staleAge - 1), now: now))
	}

	// -----------------------------------------------------------------
	// 複製の実行
	// -----------------------------------------------------------------

	func testStageCopiesImagesAndRedirectsInput() throws
	{
		try makeFile("a.HEIC", bytes: 10)
		try makeFile("b.jpg", bytes: 20)
		try makeFile("notes.txt", bytes: 5)

		var notes: [String] = []
		let staged = try XCTUnwrap(InputStaging.stage(
			request(),
			root: cacheRoot,
			onEvent:
			{ event in
				if case .note(let message) = event
				{
					notes.append(message)
				}
			}))

		XCTAssertEqual(staged.fileCount, 2)
		XCTAssertEqual(staged.byteCount, 30)
		// 実行に使うリクエストは複製先を指す。他の設定は変わらない。
		XCTAssertEqual(staged.request.inputFolder, staged.directory)
		XCTAssertEqual(staged.request.outputFile, request().outputFile)
		// 複製先は指定したキャッシュの下。
		XCTAssertEqual(staged.directory.deletingLastPathComponent().path, cacheRoot.path)

		let copied = try FileManager.default.contentsOfDirectory(atPath: staged.directory.path)
		XCTAssertEqual(copied.sorted(), ["a.HEIC", "b.jpg"])
		XCTAssertTrue(notes.contains { $0.contains("2 枚をローカルへコピー") })

		// 後始末で消えること（残すとキャッシュが数 GB 単位で膨らむ）。
		InputStaging.discard(staged)
		XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
	}

	func testStageDoesNothingWhenThereAreNoImages() throws
	{
		try makeFile("notes.txt")
		// 写すものが無ければ複製を作らない（元のフォルダのまま実行させる）。
		XCTAssertNil(try InputStaging.stage(request(), root: cacheRoot))
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), [])
	}

	func testStageStopsWhenCancelled() throws
	{
		try makeFile("a.HEIC")
		try makeFile("b.HEIC")

		let cancellation = CancellationFlag()
		cancellation.cancel()
		XCTAssertThrowsError(
			try InputStaging.stage(request(), root: cacheRoot, cancellation: cancellation))
		{ error in
			XCTAssertEqual(error as? InputStagingError, .cancelled)
		}
		// 作りかけの複製を残さない。
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), [])
	}

	func testStageFailsWhenDestinationCannotBeCreated() throws
	{
		try makeFile("a.HEIC")
		// 親がファイルなのでフォルダは作れない。
		let blocked = workDir.appendingPathComponent("blocked")
		try Data().write(to: blocked)

		XCTAssertThrowsError(try InputStaging.stage(request(), root: blocked))
		{ error in
			guard case .destinationUnavailable? = error as? InputStagingError
			else
			{
				return XCTFail("複製先を作れない失敗として返りません: \(error)")
			}
			// 行き詰まったときの逃げ道（切り方）を必ず示す。
			XCTAssertTrue(
				error.localizedDescription.contains("--no-stage-input"))
		}
	}

	func testStageFailsWhenAPhotoCannotBeRead() throws
	{
		try makeFile("a.HEIC")
		// 読めない写真が 1 枚あれば止める。半分だけ写した複製で生成を始めると、
		// 「なぜか写真が減っている」状態で失敗するので原因が分からなくなる。
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o000],
			ofItemAtPath: inputFolder.appendingPathComponent("a.HEIC").path)
		defer
		{
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o644],
				ofItemAtPath: inputFolder.appendingPathComponent("a.HEIC").path)
		}

		XCTAssertThrowsError(try InputStaging.stage(request(), root: cacheRoot))
		{ error in
			guard case .copyFailed(let name, _)? = error as? InputStagingError
			else
			{
				return XCTFail("コピーの失敗として返りません: \(error)")
			}
			XCTAssertEqual(name, "a.HEIC")
		}
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), [])
	}

	func testDiscardIgnoresNothingToDo()
	{
		// 複製を作らなかった（写すものが無かった）ときも呼ばれる経路。
		InputStaging.discard(nil)
	}

	func testPurgeStaleRemovesOnlyOldLeftovers() throws
	{
		let old = cacheRoot.appendingPathComponent("old-1", isDirectory: true)
		let fresh = cacheRoot.appendingPathComponent("fresh-1", isDirectory: true)
		try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
		let now = Date()
		try FileManager.default.setAttributes(
			[.modificationDate: now.addingTimeInterval(-InputStaging.staleAge - 60)],
			ofItemAtPath: old.path)

		XCTAssertEqual(InputStaging.purgeStale(root: cacheRoot, now: now), 1)
		XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
		// 実行中かもしれない新しい複製は触らない。
		XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
	}

	func testStagePurgesLeftoversFromCrashedRuns() throws
	{
		// CorePhotogrammetry が abort() すると後始末は走らない。次回の開始時に
		// 掃除することだけが取り残しへの備えなので、経路ごと固定しておく。
		let leftover = cacheRoot.appendingPathComponent("leftover", isDirectory: true)
		try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
		try FileManager.default.setAttributes(
			[.modificationDate: Date().addingTimeInterval(-InputStaging.staleAge - 60)],
			ofItemAtPath: leftover.path)
		try makeFile("a.HEIC")

		let staged = try XCTUnwrap(InputStaging.stage(request(), root: cacheRoot))
		XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
		InputStaging.discard(staged)
	}

	// -----------------------------------------------------------------
	// 未ダウンロードの写真（クラウド）
	//
	// 実体が無い写真は `.名前.拡張子.icloud` としてしか見えない。ダウンロードを
	// 要求して実体が届くのを待つが、同期が止まっている環境で永久に返らないよう
	// 上限を設けてある。ここではその上限を短くして両方の結末を確かめる。
	// -----------------------------------------------------------------

	func testStageWaitsUntilPlaceholderMaterializes() throws
	{
		try makeFile(".IMG_0001.HEIC.icloud", bytes: 1)
		// 実体は少し遅れて現れる（ダウンロードが完了した状態を再現する）。
		DispatchQueue.global().asyncAfter(deadline: .now() + 0.2)
		{
			try? Data(repeating: 0x41, count: 8)
				.write(to: self.inputFolder.appendingPathComponent("IMG_0001.HEIC"))
		}

		let staged = try XCTUnwrap(InputStaging.stage(
			request(), root: cacheRoot, downloadTimeout: 10))
		XCTAssertEqual(staged.fileCount, 1)
		XCTAssertTrue(FileManager.default.fileExists(
			atPath: staged.directory.appendingPathComponent("IMG_0001.HEIC").path))
		InputStaging.discard(staged)
	}

	func testStageGivesUpWhenTheDownloadNeverArrives() throws
	{
		try makeFile(".IMG_0001.HEIC.icloud", bytes: 1)
		XCTAssertThrowsError(
			try InputStaging.stage(request(), root: cacheRoot, downloadTimeout: 0.3))
		{ error in
			XCTAssertEqual(
				error as? InputStagingError, .downloadTimedOut(name: "IMG_0001.HEIC"))
		}
		// 待ちきれずに終わった複製も残さない。
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), [])
	}

	func testStageStopsWaitingWhenCancelled() throws
	{
		try makeFile(".IMG_0001.HEIC.icloud", bytes: 1)
		let cancellation = CancellationFlag()
		DispatchQueue.global().asyncAfter(deadline: .now() + 0.2)
		{
			cancellation.cancel()
		}
		XCTAssertThrowsError(try InputStaging.stage(
			request(), root: cacheRoot, cancellation: cancellation, downloadTimeout: 30))
		{ error in
			XCTAssertEqual(error as? InputStagingError, .cancelled)
		}
	}

	// -----------------------------------------------------------------
	// withStagedInput（実行の前後で必ず捨てる）
	// -----------------------------------------------------------------

	func testWithStagedInputDiscardsAfterSuccess() async throws
	{
		try makeFile("a.HEIC")
		var used: URL?
		try await InputStaging.withStagedInput(request(), root: cacheRoot, body:
		{ staged in
			used = staged.inputFolder
			XCTAssertTrue(FileManager.default.fileExists(
				atPath: staged.inputFolder.appendingPathComponent("a.HEIC").path))
		})
		let directory = try XCTUnwrap(used)
		XCTAssertNotEqual(directory, inputFolder)
		XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
	}

	func testWithStagedInputDiscardsAfterFailure() async throws
	{
		try makeFile("a.HEIC")
		var used: URL?
		do
		{
			try await InputStaging.withStagedInput(request(), root: cacheRoot, body:
			{ staged in
				used = staged.inputFolder
				throw TestSupportError.unexpectedCommand
			})
			XCTFail("body のエラーが伝わりません")
		}
		catch is TestSupportError
		{
			// 期待どおり。
		}
		// 生成が失敗しても複製は残さない。
		XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(used).path))
	}

	func testWithStagedInputSkipsWhenDisabled() async throws
	{
		try makeFile("a.HEIC")
		var request = self.request()
		request.stageInputLocally = false
		try await InputStaging.withStagedInput(request, root: cacheRoot, body:
		{ staged in
			// 複製せず、元のフォルダをそのまま使う。
			XCTAssertEqual(staged.inputFolder, self.inputFolder)
		})
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), [])
	}

	func testErrorDescriptions()
	{
		XCTAssertEqual(
			InputStagingError.cancelled.errorDescription, "ローカルへのコピーを中断しました。")
		XCTAssertTrue(
			InputStagingError.copyFailed(name: "a.HEIC", reason: "空き容量がありません")
				.errorDescription?.contains("a.HEIC") ?? false)
		XCTAssertTrue(
			InputStagingError.downloadTimedOut(name: "a.HEIC")
				.errorDescription?.contains("ダウンロード") ?? false)
	}
}
