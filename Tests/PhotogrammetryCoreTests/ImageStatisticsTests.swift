//
//  ImageStatisticsTests.swift
//
//  画素統計の性質を固定する。実写真は公開できない（設計メモ §10-10）ので、
//  合成した画素で「ブレていない画像のほうが分散が大きい」「明るさを変えても
//  ハッシュは変わらない」といった**性質**を確かめる。
//

import XCTest

@testable import PhotogrammetryCore

final class ImageStatisticsTests: XCTestCase
{
	/// 市松模様（エッジだらけ）と一様な灰色（エッジ無し）。
	func makeCheckerboard(width: Int, height: Int, cell: Int) -> [UInt8]
	{
		(0 ..< (width * height)).map
		{ index in
			let x = index % width
			let y = index / width
			return ((x / cell) + (y / cell)) % 2 == 0 ? 255 : 0
		}
	}

	/// 横方向に滑らかな階調（ブレた写真に近い）。
	func makeGradient(width: Int, height: Int) -> [UInt8]
	{
		(0 ..< (width * height)).map
		{ index in
			UInt8(min(255, index % width * 255 / max(1, width - 1)))
		}
	}

	// -----------------------------------------------------------------
	// ラプラシアン分散
	// -----------------------------------------------------------------

	func testSharpImageHasLargerLaplacianVariance()
	{
		let sharp = makeCheckerboard(width: 32, height: 32, cell: 2)
		let blurred = makeGradient(width: 32, height: 32)
		let sharpValue = ImageStatistics.laplacianVariance(gray: sharp, width: 32, height: 32)
		let blurredValue = ImageStatistics.laplacianVariance(gray: blurred, width: 32, height: 32)
		XCTAssertGreaterThan(sharpValue, blurredValue)
	}

	func testFlatImageHasZeroLaplacianVariance()
	{
		let flat = [UInt8](repeating: 128, count: 16 * 16)
		XCTAssertEqual(
			ImageStatistics.laplacianVariance(gray: flat, width: 16, height: 16), 0, accuracy: 1e-9)
	}

	func testLaplacianVarianceRejectsTooSmallImages()
	{
		// 3x3 未満は内側の画素が無い。0 を返して落ちないこと。
		XCTAssertEqual(
			ImageStatistics.laplacianVariance(gray: [1, 2, 3, 4], width: 2, height: 2), 0)
		XCTAssertEqual(ImageStatistics.laplacianVariance(gray: [], width: 0, height: 0), 0)
	}

	// -----------------------------------------------------------------
	// 輝度
	// -----------------------------------------------------------------

	func testLuminanceProfileCountsClipping()
	{
		// 半分が真っ白、残りが真っ黒。
		var pixels = [UInt8](repeating: 255, count: 50)
		pixels.append(contentsOf: [UInt8](repeating: 0, count: 50))
		let profile = ImageStatistics.luminanceProfile(gray: pixels)
		XCTAssertEqual(profile.clippedHighlights, 0.5, accuracy: 1e-9)
		XCTAssertEqual(profile.clippedShadows, 0.5, accuracy: 1e-9)
		XCTAssertEqual(profile.mean, 0.5, accuracy: 0.01)
	}

	func testLuminanceProfileOfMidGrayHasNoClipping()
	{
		let profile = ImageStatistics.luminanceProfile(gray: [UInt8](repeating: 128, count: 100))
		XCTAssertEqual(profile.clippedHighlights, 0)
		XCTAssertEqual(profile.clippedShadows, 0)
	}

	// -----------------------------------------------------------------
	// 知覚ハッシュ
	// -----------------------------------------------------------------

	func testDifferenceHashIsStableUnderBrightnessChange()
	{
		// dHash は隣り合う画素の大小関係しか見ないので、全体を暗くしても
		// 変わらない。露出が違う同じ構図を「同じ」と判定できることが要点。
		let bright = makeCheckerboard(width: 32, height: 32, cell: 4)
		let dark = bright.map { UInt8(Double($0) * 0.4) }
		let a = ImageStatistics.differenceHash(gray: bright, width: 32, height: 32)
		let b = ImageStatistics.differenceHash(gray: dark, width: 32, height: 32)
		XCTAssertNotNil(a)
		XCTAssertEqual(a, b)
	}

	func testDifferenceHashDiffersForDifferentImages()
	{
		let checkerboard = makeCheckerboard(width: 32, height: 32, cell: 4)
		let gradient = makeGradient(width: 32, height: 32)
		let a = try? XCTUnwrap(ImageStatistics.differenceHash(gray: checkerboard, width: 32, height: 32))
		let b = try? XCTUnwrap(ImageStatistics.differenceHash(gray: gradient, width: 32, height: 32))
		guard let a, let b
		else
		{
			return XCTFail("ハッシュを計算できませんでした")
		}
		XCTAssertGreaterThan(a.distance(to: b), 8)
	}

	func testDifferenceHashRejectsEmptyInput()
	{
		XCTAssertNil(ImageStatistics.differenceHash(gray: [], width: 0, height: 0))
	}

	func testPerceptualHashDistance()
	{
		let a = PerceptualHash(bits: 0b1011)
		let b = PerceptualHash(bits: 0b1000)
		XCTAssertEqual(a.distance(to: b), 2)
		XCTAssertEqual(a.distance(to: a), 0)
		XCTAssertEqual(a.normalizedDistance(to: b), 2.0 / 64, accuracy: 1e-9)
	}

	// -----------------------------------------------------------------
	// 縮小
	// -----------------------------------------------------------------

	func testBoxDownsampleAveragesBlocks()
	{
		// 4x4 を 2x2 へ。左上ブロックは全部 100、右上は全部 200。
		let pixels: [UInt8] = [
			100, 100, 200, 200,
			100, 100, 200, 200,
			0, 0, 50, 50,
			0, 0, 50, 50,
		]
		let small = ImageStatistics.boxDownsample(
			gray: pixels, width: 4, height: 4, toWidth: 2, toHeight: 2)
		XCTAssertEqual(small, [100, 200, 0, 50])
	}

	func testBoxDownsampleHandlesUpscaleRequestWithoutCrashing()
	{
		// 縮小先が元より大きいケース（端数で 0 幅ブロックが出ないこと）。
		let small = ImageStatistics.boxDownsample(
			gray: [10, 20, 30, 40], width: 2, height: 2, toWidth: 4, toHeight: 4)
		XCTAssertEqual(small.count, 16)
	}
}
