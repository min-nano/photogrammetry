//
//  PhotoSorterTests.swift
//
//  仕分けの実行（走査 → 配置 → manifest）を、**実画像を 1 枚も使わずに**
//  確かめる。写真の読み取りは PhotoMetadataReading 越しなので差し替えられる
//  （HelperProcessEngine をシェルスクリプトで差し替えられるようにしてあるのと
//  同じ考え方）。実写真は公開できないという制約（設計メモ §10-10）への答えでもある。
//

import XCTest

@testable import PhotogrammetryCore

/// 相対パスから合成メタデータを返す読み手。実ファイルの中身は見ない。
struct FakePhotoReader: PhotoMetadataReading
{
	var photos: [String: PhotoMetadata]

	func read(_ file: PhotoFile) throws -> PhotoMetadata
	{
		guard var metadata = photos[file.relativePath]
		else
		{
			throw PhotoInspectorError.unreadable(file.relativePath)
		}
		// URL だけは実物に差し替える（配置はこの URL を使う）。
		metadata.url = file.url
		return metadata
	}
}

final class PhotoSorterTests: XCTestCase
{
	var root: URL!
	var input: URL!
	var output: URL!

	override func setUpWithError() throws
	{
		root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("sorter-\(UUID().uuidString)")
		input = root.appendingPathComponent("photos")
		output = root.appendingPathComponent("sorted")
		try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws
	{
		try? FileManager.default.removeItem(at: root)
	}

	/// 2 部屋ぶんの合成メタデータと、それに対応する実ファイル（中身は空）。
	@discardableResult
	func makePhotos() throws -> [PhotoMetadata]
	{
		let photos = SamplePhoto.sequence(start: 1, count: 30, startTime: 0, hashSeed: 0)
			+ SamplePhoto.sequence(
				start: 101, count: 30, startTime: 700, hashSeed: 0xFFFF_FFFF_0000_0000)
		for photo in photos
		{
			try Data("dummy".utf8).write(
				to: input.appendingPathComponent(photo.relativePath))
		}
		return photos
	}

	func makeSorter(_ photos: [PhotoMetadata]) -> PhotoSorter
	{
		PhotoSorter(reader: FakePhotoReader(
			photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.relativePath, $0) })))
	}

	func makeRequest() -> SortRequest
	{
		// 合成写真は 1 枚ごとに 1 ビットしか変わらない（撮影順の隔たりが
		// そのままハミング距離になるようにしてある）ので、既定の「ほぼ同一」
		// 判定だと連続する数枚がまとめて落ちてしまう。ここで見たいのは配置と
		// manifest なので、重複判定は完全一致だけに絞る。
		var request = SortRequest(inputFolder: input, outputFolder: output)
		request.duplicateDistance = 0
		return request
	}

	// -----------------------------------------------------------------

	func testSortCreatesGroupFoldersAndManifest() throws
	{
		let photos = try makePhotos()
		let manifest = try makeSorter(photos).run(makeRequest())

		XCTAssertEqual(manifest.statistics.inputCount, 60)
		XCTAssertEqual(manifest.groups.count, 2)
		XCTAssertEqual(manifest.version, SortManifest.currentVersion)

		let manager = FileManager.default
		for group in manifest.groups
		{
			let folder = output.appendingPathComponent(group.id)
			let contents = try manager.contentsOfDirectory(atPath: folder.path)
			XCTAssertEqual(Set(contents).count, group.photos.count)
		}
		XCTAssertTrue(manager.fileExists(
			atPath: output.appendingPathComponent(SortManifest.fileName).path))
	}

	func testSharedPhotosArePlacedInBothFolders() throws
	{
		// **合成の前提。** 同じファイルが両方のフォルダに実在すること。
		let photos = try makePhotos()
		let manifest = try makeSorter(photos).run(makeRequest())
		let adjacency = try XCTUnwrap(manifest.adjacency.first)
		XCTAssertFalse(adjacency.sharedPhotos.isEmpty)
		for photo in adjacency.sharedPhotos
		{
			let name = SortLayout.flattenedName(for: photo)
			for group in [adjacency.a, adjacency.b]
			{
				XCTAssertTrue(
					FileManager.default.fileExists(
						atPath: output.appendingPathComponent(group)
							.appendingPathComponent(name).path),
					"\(photo) が \(group) にありません")
			}
		}
	}

	func testWrittenManifestCanBeReadBack() throws
	{
		let photos = try makePhotos()
		let manifest = try makeSorter(photos).run(makeRequest())
		let data = try Data(
			contentsOf: output.appendingPathComponent(SortManifest.fileName))
		let restored = try SortManifest.decoded(from: data)
		XCTAssertEqual(restored.groups.map(\.id), manifest.groups.map(\.id))
		XCTAssertEqual(restored.adjacency, manifest.adjacency)
	}

	func testDryRunWritesNothing() throws
	{
		let photos = try makePhotos()
		var request = makeRequest()
		request.dryRun = true
		let manifest = try makeSorter(photos).run(request)
		XCTAssertEqual(manifest.groups.count, 2)
		XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
	}

	func testExcludedPhotosAreKeptWithTheirReason() throws
	{
		var photos = try makePhotos()
		// パノラマを 1 枚混ぜる。
		var panorama = SamplePhoto.make(
			index: 900, secondsFromEpoch: 300, hash: 0x5555, pixelWidth: 12000, pixelHeight: 3000)
		panorama.url = input.appendingPathComponent(panorama.relativePath)
		try Data("dummy".utf8).write(to: panorama.url)
		photos.append(panorama)

		let manifest = try makeSorter(photos).run(makeRequest())
		XCTAssertEqual(manifest.excluded.first?.reason, .panorama)
		// 捨てずに理由別のフォルダへ退避する（判断を後から見直せるように）。
		XCTAssertTrue(FileManager.default.fileExists(
			atPath: output
				.appendingPathComponent(SortLayout.excludedFolder)
				.appendingPathComponent(ExclusionReason.panorama.rawValue)
				.appendingPathComponent("IMG_0900.HEIC").path))
	}

	func testUnreadableFilesAreRecordedNotDropped() throws
	{
		let photos = try makePhotos()
		// メタデータを持たないファイル = 読めないファイル。
		try Data("broken".utf8).write(to: input.appendingPathComponent("BROKEN.JPG"))
		let manifest = try makeSorter(photos).run(makeRequest())
		XCTAssertTrue(manifest.excluded.contains
		{
			$0.photo == "BROKEN.JPG" && $0.reason == .unreadable
		})
	}

	func testSubfoldersAreFlattenedInsideGroups() throws
	{
		// 階ごとにフォルダ分けされた入力。PhotogrammetrySession はフォルダ
		// 直下しか見ないので、グループ内では平らに並べる必要がある。
		let photos = SamplePhoto.sequence(
			start: 1, count: 25, startTime: 0, hashSeed: 0, folder: "1F")
			+ SamplePhoto.sequence(
				start: 1, count: 25, startTime: 700, hashSeed: 0xFFFF_FFFF_0000_0000,
				folder: "2F")
		for folder in ["1F", "2F"]
		{
			try FileManager.default.createDirectory(
				at: input.appendingPathComponent(folder), withIntermediateDirectories: true)
		}
		for photo in photos
		{
			try Data("dummy".utf8).write(to: input.appendingPathComponent(photo.relativePath))
		}

		let manifest = try makeSorter(photos).run(makeRequest())
		XCTAssertEqual(manifest.groups.count, 2)
		// 同名 IMG_0001.HEIC が 1F/2F 両方にあるが衝突しない。
		XCTAssertEqual(SortLayout.flattenedName(for: "1F/IMG_0001.HEIC"), "1F_IMG_0001.HEIC")
		let names = try FileManager.default.contentsOfDirectory(
			atPath: output.appendingPathComponent("group-01").path)
		XCTAssertTrue(names.allSatisfy { $0.hasPrefix("1F_") || $0.hasPrefix("2F_") })
	}

	func testCancellationStopsBeforeWritingAnything() throws
	{
		// 数千枚のデコードは数分かかる。フォルダを選び間違えたときに待たされ
		// ないための逃げ道で、**途中まで作ったフォルダを残さない**ことが要点
		// （残すと次回「仕分け先が空でない」で止まる）。
		let photos = try makePhotos()
		let cancellation = SortCancellation()
		cancellation.cancel()
		XCTAssertThrowsError(
			try makeSorter(photos).run(makeRequest(), cancellation: cancellation))
		{ error in
			XCTAssertEqual(error as? SortError, .cancelled)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
	}

	func testEmptyInputIsAnError() throws
	{
		XCTAssertThrowsError(try makeSorter([]).run(makeRequest()))
		{ error in
			XCTAssertEqual(error as? SortError, .noImages(input.path))
		}
	}

	func testProgressAndDiagnosticsAreEmitted() throws
	{
		let photos = try makePhotos()
		let log = EventLog()
		try makeSorter(photos).run(makeRequest())
		{ event in
			log.append(event)
		}
		let events = log.all
		XCTAssertTrue(events.contains { if case .progress = $0 { return true }; return false })
		XCTAssertTrue(events.contains { if case .note = $0 { return true }; return false })
		XCTAssertTrue(events.contains { if case .completed = $0 { return true }; return false })
	}

	func testCopyStrategyDuplicatesTheFile() throws
	{
		let photos = try makePhotos()
		var request = makeRequest()
		request.link = .copy
		let manifest = try makeSorter(photos).run(request)
		let group = try XCTUnwrap(manifest.groups.first)
		let name = SortLayout.flattenedName(for: try XCTUnwrap(group.photos.first))
		let placed = output.appendingPathComponent(group.id).appendingPathComponent(name)
		XCTAssertEqual(try Data(contentsOf: placed), Data("dummy".utf8))
	}

	func testOutputInsideInputDoesNotReimportPreviousResults() throws
	{
		let photos = try makePhotos()
		var request = makeRequest()
		request.outputFolder = input.appendingPathComponent("sorted")
		let manifest = try makeSorter(photos).run(request)
		XCTAssertEqual(manifest.statistics.inputCount, 60)
	}

	func testSymlinkStrategyPointsAtTheOriginal() throws
	{
		let photos = try makePhotos()
		var request = makeRequest()
		request.link = .symlink
		let manifest = try makeSorter(photos).run(request)
		let group = try XCTUnwrap(manifest.groups.first)
		let name = SortLayout.flattenedName(for: try XCTUnwrap(group.photos.first))
		let placed = output.appendingPathComponent(group.id).appendingPathComponent(name)
		let destination = try FileManager.default.destinationOfSymbolicLink(atPath: placed.path)
		XCTAssertTrue(destination.hasPrefix(input.path))
	}

	func testPlacingOverAnExistingFileReplacesIt() throws
	{
		// 同じ写真が複数のグループへ入る（共有写真）ので、同名の残骸があっても
		// 黙って上書きできる必要がある。
		let source = input.appendingPathComponent("A.JPG")
		let destination = root.appendingPathComponent("dest.JPG")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try Data("new".utf8).write(to: source)
		try Data("old".utf8).write(to: destination)
		try PhotoSorter.place(
			source, at: destination, strategy: .copy, fileManager: .default)
		XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
	}

	func testDiagnosticSeverityIsVisibleInTheLogLine()
	{
		// 深刻度が一目で分かること。ログは失敗の切り分けに使う。
		let sorter = PhotoSorter()
		XCTAssertEqual(
			sorter.message(for: SortDiagnostic(severity: .info, code: "a", message: "普通")),
			"普通")
		XCTAssertEqual(
			sorter.message(for: SortDiagnostic(severity: .warning, code: "b", message: "注意")),
			"警告: 注意")
		XCTAssertEqual(
			sorter.message(for: SortDiagnostic(severity: .error, code: "c", message: "駄目")),
			"問題: 駄目")
	}

	func testSortErrorDescriptions()
	{
		XCTAssertEqual(
			SortError.noImages("/tmp/x").errorDescription,
			"画像ファイルが見つかりません: /tmp/x")
		XCTAssertEqual(SortError.cancelled.errorDescription, "仕分けを中断しました。")
	}
}

/// 進捗の間引き。並行読みから届く報告を直列化して流す部品なので、単体で
/// 「刻みを飛ばさない・後戻りしない」を固定しておく。
final class ProgressThrottleTests: XCTestCase
{
	func testEmitsOnlyWhenTheRoundedFractionAdvances()
	{
		let log = ValueLog()
		let throttle = ProgressThrottle(scale: 1) { log.append($0) }
		// 同じ刻みの中では 1 回だけ。
		throttle.record(0.001)
		throttle.record(0.005)
		throttle.record(0.02)
		throttle.record(0.021)
		XCTAssertEqual(log.all, [0.0, 0.02])
	}

	func testDoesNotGoBackwards()
	{
		let log = ValueLog()
		let throttle = ProgressThrottle(scale: 1) { log.append($0) }
		throttle.record(0.5)
		throttle.record(0.1)
		XCTAssertEqual(log.all, [0.5])
	}

	func testScaleMapsIntoTheGivenRange()
	{
		// 読み取りは全体の前半 50% を占める。
		let log = ValueLog()
		let throttle = ProgressThrottle(scale: 0.5) { log.append($0) }
		throttle.record(1.0)
		XCTAssertEqual(log.all, [0.5])
	}
}

/// スレッドを跨いで届く値を溜める。
final class ValueLog: @unchecked Sendable
{
	private let lock = NSLock()
	private var values: [Double] = []

	func append(_ value: Double)
	{
		lock.lock()
		values.append(value)
		lock.unlock()
	}

	var all: [Double]
	{
		lock.lock()
		defer { lock.unlock() }
		return values
	}
}
