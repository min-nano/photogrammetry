//
//  PointCloudFileTests.swift
//
//  点群の PLY 書き出しをテストする。バイト列の組み立ては純ロジックなので
//  RealityKit も GPU も要らない —— ここで形式を固定しておけば、実機でしか
//  動かないエンジン側は「RealityKit の点を写して渡す」だけになる。
//

import XCTest

@testable import PhotogrammetryCore

final class PointCloudFileTests: XCTestCase
{
	private var workDir: URL!

	override func setUpWithError() throws
	{
		workDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("PointCloudFileTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws
	{
		try? FileManager.default.removeItem(at: workDir)
	}

	// -----------------------------------------------------------------
	// ヘッダ
	// -----------------------------------------------------------------

	func testHeaderDeclaresBinaryLittleEndianAndCount()
	{
		let header = PointCloudFile.header(pointCount: 3)
		let lines = header.split(separator: "\n", omittingEmptySubsequences: false)
			.map(String.init)
		XCTAssertEqual(lines.first, "ply")
		XCTAssertTrue(lines.contains("format binary_little_endian 1.0"))
		XCTAssertTrue(lines.contains("element vertex 3"))
		// property の並びは 1 点 16 バイトの内訳と対。順序を変えるなら
		// body 側も同時に変える必要がある。
		XCTAssertEqual(
			lines.filter { $0.hasPrefix("property") },
			[
				"property float x",
				"property float y",
				"property float z",
				"property uchar red",
				"property uchar green",
				"property uchar blue",
				"property uchar alpha",
			])
		// end_header の直後（改行のあと）からバイナリ本体が始まる。
		XCTAssertTrue(header.hasSuffix("end_header\n"))
	}

	// -----------------------------------------------------------------
	// バイナリ本体
	// -----------------------------------------------------------------

	func testBodyLayoutIsLittleEndian()
	{
		// 1.0 は IEEE754 で 0x3F800000。リトルエンディアンなので 00 00 80 3F。
		let point = PointCloudPoint(
			x: 1, y: -2, z: 0, red: 10, green: 20, blue: 30, alpha: 40)
		let body = PointCloudFile.body([point][...])
		XCTAssertEqual(body.count, PointCloudFile.bytesPerPoint)
		XCTAssertEqual(Array(body[0 ..< 4]), [0x00, 0x00, 0x80, 0x3F])
		// -2.0 は 0xC0000000。
		XCTAssertEqual(Array(body[4 ..< 8]), [0x00, 0x00, 0x00, 0xC0])
		XCTAssertEqual(Array(body[8 ..< 12]), [0x00, 0x00, 0x00, 0x00])
		XCTAssertEqual(Array(body[12 ..< 16]), [10, 20, 30, 40])
	}

	func testAlphaDefaultsToOpaque()
	{
		let point = PointCloudPoint(x: 0, y: 0, z: 0, red: 1, green: 2, blue: 3)
		XCTAssertEqual(point.alpha, 255)
	}

	func testDataIsHeaderPlusBody()
	{
		let points = [
			PointCloudPoint(x: 0, y: 0, z: 0, red: 0, green: 0, blue: 0),
			PointCloudPoint(x: 1, y: 1, z: 1, red: 255, green: 255, blue: 255),
		]
		let data = PointCloudFile.data(points: points)
		let header = Data(PointCloudFile.header(pointCount: 2).utf8)
		XCTAssertEqual(data.prefix(header.count), header)
		XCTAssertEqual(data.count, header.count + 2 * PointCloudFile.bytesPerPoint)
	}

	// -----------------------------------------------------------------
	// ファイルへの書き出し
	// -----------------------------------------------------------------

	func testWriteProducesSameBytesAsData() throws
	{
		let points = (0 ..< 10).map
		{ index in
			PointCloudPoint(
				x: Float(index), y: Float(index) * 0.5, z: -Float(index),
				red: UInt8(index), green: 0, blue: 0)
		}
		let url = workDir.appendingPathComponent("cloud.ply")
		try PointCloudFile.write(points: points, to: url)
		XCTAssertEqual(try Data(contentsOf: url), PointCloudFile.data(points: points))
	}

	func testWriteCreatesMissingParentDirectory() throws
	{
		// 利用者が手で組み立てたパス（CLI / URL スキーム）では親フォルダが
		// 無いことがある。ここで作らないと生成の最後で失敗する。
		let url = workDir
			.appendingPathComponent("nested/deeper")
			.appendingPathComponent("cloud.ply")
		try PointCloudFile.write(points: [], to: url)
		XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
	}

	func testWriteEmptyCloudIsHeaderOnly() throws
	{
		let url = workDir.appendingPathComponent("empty.ply")
		try PointCloudFile.write(points: [], to: url)
		XCTAssertEqual(
			try Data(contentsOf: url), Data(PointCloudFile.header(pointCount: 0).utf8))
	}

	func testWriteReplacesExistingFile() throws
	{
		let url = workDir.appendingPathComponent("cloud.ply")
		try Data(repeating: 0xFF, count: 4096).write(to: url)
		try PointCloudFile.write(points: [], to: url)
		XCTAssertEqual(
			try Data(contentsOf: url).count, PointCloudFile.header(pointCount: 0).utf8.count)
	}

	func testWriteSpansMultipleChunks() throws
	{
		// 分割して書き出す経路（数百万点でメモリを食わないための工夫）が、
		// 1 度に書いた場合と同じ結果になることを確かめる。
		let count = PointCloudFile.chunkSize + 7
		let points = (0 ..< count).map
		{ index in
			PointCloudPoint(
				x: Float(index), y: 0, z: 0,
				red: UInt8(truncatingIfNeeded: index), green: 0, blue: 0)
		}
		let url = workDir.appendingPathComponent("large.ply")
		try PointCloudFile.write(points: points, to: url)
		let written = try Data(contentsOf: url)
		let header = Data(PointCloudFile.header(pointCount: count).utf8)
		XCTAssertEqual(
			written.count, header.count + count * PointCloudFile.bytesPerPoint)
		XCTAssertEqual(written, PointCloudFile.data(points: points))
	}

	func testWriteFailsWhenPathIsADirectory()
	{
		// 出力先にフォルダを指定された場合。createFile が失敗するので、
		// 何が起きたか分かるエラーへ翻訳する。
		let url = workDir.appendingPathComponent("cloud.ply", isDirectory: true)
		XCTAssertNoThrow(
			try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true))
		XCTAssertThrowsError(try PointCloudFile.write(points: [], to: url))
		{ error in
			XCTAssertEqual(error as? PointCloudError, .cannotWrite(url.path))
		}
	}

	func testErrorDescription()
	{
		XCTAssertEqual(
			PointCloudError.cannotWrite("/tmp/a.ply").errorDescription,
			"点群ファイルを作成できません: /tmp/a.ply")
	}
}
