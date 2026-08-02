//
//  ModelCacheTests.swift
//
//  ML モデルのコンパイル済みキャッシュの見分け・場所・削除をテストする。
//  実機で 49% クラッシュの原因になった失敗の署名を、実際に観測した出力
//  そのままで固定しておく（見分けが崩れると、また一般論しか出せなくなる）。
//

import XCTest

@testable import PhotogrammetryCore

final class ModelCacheTests: XCTestCase
{
	/// 実機（macOS 26.5.2 / M1 Pro）で観測したヘルパーの出力。
	private let observedOutput = """
		2026-08-02 17:27:11.408 photogrammetry-cli[32168:1984423] \
		ファイル“manifest.plist”は存在しないため、開けませんでした。
		Assert: in line 521
		E5RT encountered an STL exception. msg = MILCompilerForANE error: \
		failed to compile ANE model using ANEF. Error=_ANECompiler : ANECCompile() FAILED.
		Unable to load MPSGraphExecutable from path /Users/me/Library/Caches/\
		com.minnano.photogrammetry/com.apple.e5rt.e5bundlecache/25F84/…
		"""

	private var workDir: URL!

	override func setUpWithError() throws
	{
		workDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("ModelCacheTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws
	{
		try? FileManager.default.removeItem(at: workDir)
	}

	// -----------------------------------------------------------------
	// 見分け
	// -----------------------------------------------------------------

	func testRecognizesObservedFailure()
	{
		XCTAssertTrue(ModelCache.isCompilationFailure(observedOutput))
	}

	func testRecognizesEachLayerOfTheFailure()
	{
		// 3 行のうちどれが取れても同じ結論になること（GUI のログには
		// 先頭 2 行しか届かない場合があった）。
		XCTAssertTrue(ModelCache.isCompilationFailure(
			"ファイル“manifest.plist”は存在しないため、開けませんでした。"))
		XCTAssertTrue(ModelCache.isCompilationFailure("Assert: in line 521\nANECCompile() FAILED."))
		XCTAssertTrue(ModelCache.isCompilationFailure("… com.apple.e5rt.e5bundlecache/25F84 …"))
		XCTAssertTrue(ModelCache.isCompilationFailure("Unable to load MPSGraphExecutable"))
	}

	func testDoesNotRecognizeUnrelatedFailures()
	{
		XCTAssertFalse(ModelCache.isCompilationFailure(""))
		XCTAssertFalse(ModelCache.isCompilationFailure(
			"error: 入力フォルダが見つかりません（フォルダを指定してください）: /tmp/x"))
	}

	// -----------------------------------------------------------------
	// 場所
	// -----------------------------------------------------------------

	func testDirectoryLayout()
	{
		let directory = ModelCache.directory(bundleIdentifier: "com.minnano.photogrammetry")
		XCTAssertEqual(directory?.lastPathComponent, ModelCache.bundleCacheDirectoryName)
		XCTAssertEqual(
			directory?.deletingLastPathComponent().lastPathComponent,
			"com.minnano.photogrammetry")
		XCTAssertTrue(directory?.path.contains("/Library/Caches/") ?? false, "\(directory as Any)")
	}

	func testDirectoryIsUnknownWithoutBundleIdentifier()
	{
		// 素の CLI として動いている場合はバンドル ID が無い。
		XCTAssertNil(ModelCache.directory(bundleIdentifier: nil))
		XCTAssertNil(ModelCache.directory(bundleIdentifier: ""))
	}

	// -----------------------------------------------------------------
	// 説明
	// -----------------------------------------------------------------

	func testRecoveryAdviceNamesThePath()
	{
		let directory = URL(fileURLWithPath: "/Users/me/Library/Caches/app/\(ModelCache.bundleCacheDirectoryName)")
		let advice = ModelCache.recoveryAdvice(directory: directory).joined(separator: "\n")
		XCTAssertTrue(advice.contains(directory.path), advice)
		XCTAssertTrue(advice.contains("写真や設定は関係ありません"), advice)
	}

	func testRecoveryAdviceFallsBackToPlaceholder()
	{
		let advice = ModelCache.recoveryAdvice(directory: nil).joined(separator: "\n")
		XCTAssertTrue(advice.contains(ModelCache.placeholderPath), advice)
	}

	// -----------------------------------------------------------------
	// 削除
	// -----------------------------------------------------------------

	func testPurgeRemovesDirectory() throws
	{
		let directory = workDir.appendingPathComponent(ModelCache.bundleCacheDirectoryName)
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("25F84/bundle"),
			withIntermediateDirectories: true)

		XCTAssertTrue(try ModelCache.purge(directory: directory))
		XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
		// もう無いので 2 回目は false（エラーにはしない）。
		XCTAssertFalse(try ModelCache.purge(directory: directory))
	}

	func testPurgeRefusesUnexpectedDirectory() throws
	{
		// 取り違えで無関係なフォルダを消さないこと。
		let directory = workDir.appendingPathComponent("Pictures")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

		XCTAssertThrowsError(try ModelCache.purge(directory: directory))
		{ error in
			XCTAssertEqual(error as? ModelCacheError, .unexpectedDirectory(directory.path))
		}
		XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
	}

	func testPurgeWithoutDirectoryThrows()
	{
		XCTAssertThrowsError(try ModelCache.purge(directory: nil))
		{ error in
			XCTAssertEqual(error as? ModelCacheError, .directoryUnavailable)
			XCTAssertNotNil((error as? ModelCacheError)?.errorDescription)
		}
	}

	func testErrorDescriptions()
	{
		XCTAssertNotNil(ModelCacheError.unexpectedDirectory("/tmp/x").errorDescription)
	}

	// -----------------------------------------------------------------
	// クラッシュのエラー文面との接続
	// -----------------------------------------------------------------

	func testCrashErrorGivesCachePathInsteadOfGeneralAdvice()
	{
		let error = HelperProcessError.crashed(
			signal: SIGABRT,
			lastProgress: 0.49,
			message: observedOutput)
		XCTAssertTrue(error.isModelCacheFailure)

		let message = error.localizedDescription
		XCTAssertTrue(message.contains(ModelCache.bundleCacheDirectoryName), message)
		// 効かない一般論（詳細度を下げる等）は出さない。
		XCTAssertFalse(message.contains("詳細度を下げる"), message)
	}

	func testUnknownCrashKeepsGeneralAdvice()
	{
		let error = HelperProcessError.crashed(signal: SIGABRT, lastProgress: nil, message: "")
		XCTAssertFalse(error.isModelCacheFailure)
		XCTAssertTrue(error.localizedDescription.contains("詳細度を下げる"))
	}

	func testNonCrashErrorsAreNotModelCacheFailures()
	{
		XCTAssertFalse(HelperProcessError.failed(exitCode: 1, message: "manifest.plist")
			.isModelCacheFailure)
	}
}
