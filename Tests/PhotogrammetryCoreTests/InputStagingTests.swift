//
//  InputStagingTests.swift
//
//  写真をアプリのキャッシュへ複製してから処理する動作（InputStaging）を
//  テストする。RealityKit も GPU も要らず、実画像も要らない（複製は中身を
//  見ないので、拡張子だけ揃えたダミーで十分）。
//
//  ここで固定したいのは 3 つ。
//    1. 何を写すか（直下の画像だけ。コピーできない .icloud は数えて警告する）
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

	func testImageNamesPicksImagesOnly()
	{
		// 「オンラインのみ」のファイルも実名で見えていれば普通の写真として選ぶ
		// （コピーの読み取りが取り寄せを起こすので、特別扱いは要らない）。
		XCTAssertEqual(
			InputStaging.imageNames(in: [
				"b.jpg", "a.HEIC", "c.PNG", "notes.txt", "manifest.json", ".DS_Store",
			]),
			["a.HEIC", "b.jpg", "c.PNG"])
	}

	func testPlaceholderCount()
	{
		// 実体が無い旧表現（`.名前.拡張子.icloud`）は実名のパスが存在しないので
		// コピーできない。数えて警告するためだけに見分ける。
		XCTAssertEqual(
			InputStaging.placeholderCount(in: [
				".IMG_0002.HEIC.icloud", ".IMG_0003.HEIC.icloud", "IMG_0001.HEIC", "notes.txt",
			]),
			2)
		XCTAssertEqual(InputStaging.placeholderCount(in: ["IMG_0001.HEIC"]), 0)
		// プレースホルダはコピー対象にもならない。
		XCTAssertEqual(InputStaging.imageNames(in: [".IMG_0002.HEIC.icloud"]), [])
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

	func testRootFallsBackWhenThereIsNoCachesDirectory()
	{
		// キャッシュの場所が取れない環境でも複製先は決まる（決まらないと、
		// 「コピーしてから処理する」という既定の約束が果たせない）。
		let root = InputStaging.root(
			bundleIdentifier: "com.example.app", fileManager: NoCachesFileManager())
		XCTAssertTrue(
			root.path.hasPrefix(FileManager.default.temporaryDirectory.path), root.path)
		XCTAssertEqual(root.lastPathComponent, InputStaging.directoryName)
	}

	func testFileSizeIsZeroWhenUnreadable()
	{
		// 大きさは合計の表示にしか使わないので、読めないこと自体はエラーにしない。
		XCTAssertEqual(
			InputStaging.fileSize(
				of: workDir.appendingPathComponent("missing.HEIC"), fileManager: .default),
			0)
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
			fileCount: 120, destination: URL(fileURLWithPath: "/tmp/staged"))
		XCTAssertTrue(note.contains("120 枚"))
		XCTAssertTrue(note.contains("/tmp/staged"))
		XCTAssertTrue(InputStaging.finishNote(fileCount: 7, byteCount: 2048).contains("7 枚"))
		XCTAssertTrue(InputStaging.finishNote(fileCount: 7, byteCount: 2048).contains("2.0 KB"))
		// 外した枚数と直し方（Finder でダウンロード）を必ず出す。
		let warning = InputStaging.placeholderNote(count: 4)
		XCTAssertTrue(warning.contains("4 個"))
		XCTAssertTrue(warning.contains("今すぐダウンロード"))
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

	func testStageSkipsUnreadableInputFolder() throws
	{
		// 入力フォルダが無い（validate がまだ通っていない・消された）場合は、
		// 複製せずに元のフォルダのまま進める。ここで別のエラーに化けさせない。
		var request = self.request()
		request.inputFolder = workDir.appendingPathComponent("missing", isDirectory: true)
		XCTAssertNil(try InputStaging.stage(request, root: cacheRoot))
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

	func testStageReportsProgressForLargeFolders() throws
	{
		// 数千枚のコピーは数分かかる。途中経過が出ないと「止まった」ように見える
		// ので、一定枚数ごとにログを出す。
		let total = InputStaging.noteInterval + 1
		for index in 0 ..< total
		{
			try makeFile(String(format: "IMG_%04d.HEIC", index), bytes: 1)
		}
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
		XCTAssertEqual(staged.fileCount, total)
		XCTAssertTrue(
			notes.contains("コピー中… \(InputStaging.noteInterval)/\(total) 枚"), "\(notes)")
		InputStaging.discard(staged)
	}

	func testPurgeStaleKeepsGoingWhenSomethingCannotBeRemoved() throws
	{
		let old = cacheRoot.appendingPathComponent("old-1", isDirectory: true)
		try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
		let now = Date()
		try FileManager.default.setAttributes(
			[.modificationDate: now.addingTimeInterval(-InputStaging.staleAge - 60)],
			ofItemAtPath: old.path)
		// 親フォルダを書き込み不可にすると削除できない。掃除は best effort なので、
		// ここで throw せず「消せた件数」を返すこと。
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o500], ofItemAtPath: cacheRoot.path)
		defer
		{
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o755], ofItemAtPath: cacheRoot.path)
		}

		XCTAssertEqual(InputStaging.purgeStale(root: cacheRoot, now: now), 0)
	}

	func testStageIfRequestedSkipsWhenDisabled() throws
	{
		try makeFile("a.HEIC")
		var request = self.request()
		request.stageInputLocally = false
		XCTAssertNil(try InputStaging.stageIfRequested(request, root: cacheRoot))
		request.stageInputLocally = true
		let staged = try XCTUnwrap(InputStaging.stageIfRequested(request, root: cacheRoot))
		InputStaging.discard(staged)
	}

	// -----------------------------------------------------------------
	// クラウド上の入力では複製が必須
	//
	// 処理中に実体を退避されると読めなくなるので、「コピーしない」指定は通さない。
	// ローカルの入力でだけ選べる、という非対称がこの機能の要点。
	// -----------------------------------------------------------------

	func testIsRequiredOnlyForCloudFolders()
	{
		XCTAssertTrue(InputStaging.isRequired(for: URL(
			fileURLWithPath: "/Users/me/Library/CloudStorage/GoogleDrive-me/現場",
			isDirectory: true)))
		XCTAssertTrue(InputStaging.isRequired(for: URL(
			fileURLWithPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/現場",
			isDirectory: true)))
		XCTAssertFalse(InputStaging.isRequired(for: URL(
			fileURLWithPath: "/Users/me/Pictures/現場", isDirectory: true)))
	}

	func testStageIfRequestedOverridesOptOutForCloudFolders() throws
	{
		// クラウドのパスを再現する（判定はパスだけを見る純ロジック）。
		let cloudFolder = workDir
			.appendingPathComponent("Library/CloudStorage/GoogleDrive-me/現場", isDirectory: true)
		try FileManager.default.createDirectory(at: cloudFolder, withIntermediateDirectories: true)
		try Data(repeating: 0x41, count: 8)
			.write(to: cloudFolder.appendingPathComponent("a.HEIC"))

		var request = self.request()
		request.inputFolder = cloudFolder
		request.stageInputLocally = false

		var notes: [String] = []
		let staged = try XCTUnwrap(InputStaging.stageIfRequested(
			request,
			root: cacheRoot,
			onEvent:
			{ event in
				if case .note(let message) = event
				{
					notes.append(message)
				}
			}))

		// 指定を覆した以上、理由を必ず知らせる。
		XCTAssertTrue(notes.contains(InputStaging.requiredNote), "\(notes)")
		XCTAssertEqual(
			try FileManager.default.contentsOfDirectory(atPath: staged.directory.path),
			["a.HEIC"])
		InputStaging.discard(staged)
	}

	func testWithStagedInputAlsoOverridesOptOutForCloudFolders() async throws
	{
		// CLI（--no-stage-input）から来ても結論は同じであること。
		let cloudFolder = workDir
			.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/現場",
				isDirectory: true)
		try FileManager.default.createDirectory(at: cloudFolder, withIntermediateDirectories: true)
		try Data(repeating: 0x41, count: 8)
			.write(to: cloudFolder.appendingPathComponent("a.HEIC"))

		var request = self.request()
		request.inputFolder = cloudFolder
		request.stageInputLocally = false

		try await InputStaging.withStagedInput(request, root: cacheRoot, body:
		{ staged in
			XCTAssertNotEqual(staged.inputFolder, cloudFolder)
		})
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
	// 未ダウンロードの写真（iCloud の旧表現）
	//
	// `.名前.拡張子.icloud` しか見えない状態では実名のパスが存在せず、コピーも
	// 取り寄せもできない。黙って枚数を減らすと原因が分からなくなるので、外した
	// ことを必ず知らせる。
	// -----------------------------------------------------------------

	func testStageWarnsAboutPlaceholdersAndCopiesTheRest() throws
	{
		try makeFile("IMG_0001.HEIC")
		try makeFile(".IMG_0002.HEIC.icloud", bytes: 1)

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

		// 読める写真はコピーされ、プレースホルダは入らない。
		XCTAssertEqual(
			try FileManager.default.contentsOfDirectory(atPath: staged.directory.path),
			["IMG_0001.HEIC"])
		XCTAssertTrue(notes.contains(InputStaging.placeholderNote(count: 1)), "\(notes)")
		InputStaging.discard(staged)
	}

	func testStageWarnsWhenEveryPhotoIsAPlaceholder() throws
	{
		try makeFile(".IMG_0001.HEIC.icloud", bytes: 1)

		var notes: [String] = []
		// 写せるものが 1 枚も無いので複製は作らない（元のフォルダのまま進み、
		// 枚数 0 の警告は InputInspection が出す）。
		XCTAssertNil(try InputStaging.stage(
			request(),
			root: cacheRoot,
			onEvent:
			{ event in
				if case .note(let message) = event
				{
					notes.append(message)
				}
			}))
		XCTAssertTrue(notes.contains(InputStaging.placeholderNote(count: 1)), "\(notes)")
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

	func testWithStagedInputUsesOriginalFolderWhenNothingWasCopied() async throws
	{
		// 写すものが無ければ複製は作られない。body には元のフォルダが渡る。
		try makeFile("notes.txt")
		try await InputStaging.withStagedInput(request(), root: cacheRoot, body:
		{ staged in
			XCTAssertEqual(staged.inputFolder, self.inputFolder)
		})
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
	}
}

/// キャッシュの場所が取れない環境を再現する FileManager。
final class NoCachesFileManager: FileManager
{
	override func urls(
		for directory: FileManager.SearchPathDirectory,
		in domainMask: FileManager.SearchPathDomainMask) -> [URL]
	{
		[]
	}
}
