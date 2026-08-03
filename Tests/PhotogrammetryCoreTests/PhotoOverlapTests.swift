//
//  PhotoOverlapTests.swift
//
//  「2 枚が実際に重なって写っているか」の測り方を固定する（設計メモ §4.6.1）。
//  ここが崩れると共有写真の選定が壊れ、合成の対応点が当てにならなくなる。
//
//  実画像も Vision も要らない — 測定は画素の配列と変換だけを見る純ロジックで、
//  Vision が返した変換の解釈は ImageRegistrar（ラッパー）の担当。
//

import XCTest

@testable import PhotogrammetryCore

final class PhotoOverlapTests: XCTestCase
{
	/// 決まった模様のグレースケール画像。`shiftX` / `shiftY` だけ内容をずらして
	/// 作れるので、「同じ場所を少し動いて撮った 2 枚」を合成できる。
	func makeImage(
		width: Int = 120,
		height: Int = 90,
		shiftX: Int = 0,
		shiftY: Int = 0,
		seed: UInt64 = 1) -> GrayImage
	{
		var pixels = [UInt8](repeating: 0, count: width * height)
		for y in 0 ..< height
		{
			for x in 0 ..< width
			{
				// 撮影内容の座標（ずらすぶんを引く）から決まる模様。周期の異なる
				// 波を混ぜて、平行移動に対して一意に決まる模様にする。**種を変えると
				// 周期ごと変わる**（位相だけずらすと「別の写真」にならない）。
				let u = Double(x + shiftX)
				let v = Double(y + shiftY)
				let scale = 1 + Double(seed) * 0.37
				let value = 128
					+ 60 * sin(u * 0.21 * scale + v * 0.07 / scale)
					+ 40 * cos(u * 0.05 / scale - v * 0.17 * scale)
					+ 20 * sin((u + v) * 0.4 * scale)
				pixels[y * width + x] = UInt8(min(255, max(0, value)))
			}
		}
		return GrayImage(pixels: pixels, width: width, height: height)
	}

	/// 一面の壁のように模様が無い画像。
	func makeFlatImage(width: Int = 120, height: Int = 90, value: UInt8 = 200) -> GrayImage
	{
		GrayImage(
			pixels: [UInt8](repeating: value, count: width * height),
			width: width,
			height: height)
	}

	func testSamePhotoAgreesCompletely()
	{
		let image = makeImage()
		let overlap = OverlapMeasurement.measure(
			base: image, other: image, transform: .identity)
		XCTAssertEqual(overlap?.agreement ?? 0, 1, accuracy: 0.001)
		XCTAssertEqual(overlap?.sharedArea ?? 0, 1, accuracy: 0.001)
	}

	func testShiftedPhotoAgreesWhenTheTransformMatches()
	{
		// 相手は模様が右へ 24 画素ずれて写っている（撮る位置を横へ動かした）。
		// 基準の (x, y) と同じものは相手の (x + 24, y) にある。
		let base = makeImage()
		let other = makeImage(shiftX: -24)
		let overlap = OverlapMeasurement.measure(
			base: base, other: other, transform: .translation(x: 24, y: 0))
		XCTAssertGreaterThan(overlap?.agreement ?? 0, 0.95)
		// 重なりは横 (120-24)/120 = 0.8。
		XCTAssertEqual(overlap?.sharedArea ?? 0, 0.8, accuracy: 0.05)
	}

	/// **これが検証の値打ち。** 位置合わせが「答え」を返しても、その変換で画素が
	/// 一致しないなら重なっていない。実データで 700 枚離れた写真が共有写真に
	/// 混ざったのは、ここを見ていなかったため。
	func testWrongAlignmentDoesNotAgree()
	{
		let base = makeImage()
		let other = makeImage(shiftX: -24)
		// 正解は -24。まったく違うずらし方をすれば一致しない。
		let overlap = OverlapMeasurement.measure(
			base: base, other: other, transform: .translation(x: 13, y: 21))
		XCTAssertLessThan(overlap?.agreement ?? 1, 0.5)
	}

	func testDifferentPhotosDoNotAgree()
	{
		let overlap = OverlapMeasurement.measure(
			base: makeImage(seed: 1), other: makeImage(seed: 40), transform: .identity)
		XCTAssertLessThan(overlap?.agreement ?? 1, 0.5)
		// 枠としては重なっている（＝広さだけでは判定できない）。
		XCTAssertEqual(overlap?.sharedArea ?? 0, 1, accuracy: 0.001)
	}

	func testNoOverlapWhenTheFramesDoNotMeet()
	{
		let overlap = OverlapMeasurement.measure(
			base: makeImage(), other: makeImage(), transform: .translation(x: 500, y: 0))
		XCTAssertEqual(overlap, PhotoOverlap(agreement: 0, sharedArea: 0))
	}

	/// 模様が無い（白い壁だけの）2 枚は**判定しない**。一致しているとも、
	/// していないとも言えないため。
	func testFlatImagesAreNotJudged()
	{
		XCTAssertNil(OverlapMeasurement.measure(
			base: makeFlatImage(), other: makeFlatImage(), transform: .identity))
		// 片側だけが平らでも同じ。
		XCTAssertNil(OverlapMeasurement.measure(
			base: makeImage(), other: makeFlatImage(), transform: .identity))
	}

	func testEmptyImagesAreNotJudged()
	{
		let empty = GrayImage(pixels: [], width: 0, height: 0)
		XCTAssertNil(OverlapMeasurement.measure(
			base: empty, other: makeImage(), transform: .identity))
		XCTAssertNil(OverlapMeasurement.measure(
			base: makeImage(), other: empty, transform: .identity))
		// 画素が寸法に足りない（壊れた入力）ときも判定しない。
		let broken = GrayImage(pixels: [1, 2, 3], width: 100, height: 100)
		XCTAssertNil(OverlapMeasurement.measure(
			base: broken, other: makeImage(), transform: .identity))
		XCTAssertNil(OverlapMeasurement.measure(
			base: makeImage(), other: broken, transform: .identity))
	}

	/// 重なりが狭すぎるときは相関を信用しない（広さだけを返す）。
	func testNarrowOverlapReportsAreaWithoutAgreement()
	{
		let base = makeImage(width: 120, height: 90)
		let other = makeImage(width: 120, height: 90)
		let overlap = OverlapMeasurement.measure(
			base: base, other: other, transform: .translation(x: -118, y: 0))
		XCTAssertEqual(overlap?.agreement ?? 1, 0)
		XCTAssertGreaterThan(overlap?.sharedArea ?? 0, 0)
		XCTAssertLessThan(overlap?.sharedArea ?? 1, 0.05)
	}

	/// 明るさが違っても「同じものが写っている」なら一致する（露出が変わる
	/// 屋外 ⇄ 屋内の境目で効く）。
	func testAgreementIgnoresBrightness()
	{
		let base = makeImage()
		var darker = base
		darker.pixels = base.pixels.map { UInt8(Double($0) * 0.5) }
		let overlap = OverlapMeasurement.measure(
			base: base, other: darker, transform: .identity)
		XCTAssertGreaterThan(overlap?.agreement ?? 0, 0.95)
	}

	// -----------------------------------------------------------------
	// 変換
	// -----------------------------------------------------------------

	func testTranslationTransform()
	{
		let point = ProjectiveTransform.translation(x: 3, y: -4).apply(x: 10, y: 10)
		XCTAssertEqual(point?.x ?? 0, 13, accuracy: 1e-9)
		XCTAssertEqual(point?.y ?? 0, 6, accuracy: 1e-9)
	}

	func testProjectiveTransformDividesByW()
	{
		// 遠近のある変換（最終行が 0 でない）。
		let transform = ProjectiveTransform(elements: [2, 0, 0, 0, 2, 0, 0, 0, 2])
		let point = transform.apply(x: 4, y: 6)
		XCTAssertEqual(point?.x ?? 0, 4, accuracy: 1e-9)
		XCTAssertEqual(point?.y ?? 0, 6, accuracy: 1e-9)
	}

	func testDegenerateTransformMapsNothing()
	{
		// w が 0 に潰れる点は写せない（無限遠）。
		let transform = ProjectiveTransform(elements: [1, 0, 0, 0, 1, 0, 0, 0, 0])
		XCTAssertNil(transform.apply(x: 1, y: 1))
		// 変換ごと壊れているなら重なりも見つからない。
		let overlap = OverlapMeasurement.measure(
			base: makeImage(), other: makeImage(), transform: transform)
		XCTAssertEqual(overlap, PhotoOverlap(agreement: 0, sharedArea: 0))
	}

	func testMalformedTransformFallsBackToIdentity()
	{
		// 9 要素でない指定は恒等に倒す（壊れた変換を「重なり」にすり替えない）。
		XCTAssertEqual(ProjectiveTransform(elements: [1, 2, 3]), .identity)
	}

	func testNonFiniteTransformMapsNothing()
	{
		let transform = ProjectiveTransform(
			elements: [1, 0, .infinity, 0, 1, 0, 0, 0, 1])
		XCTAssertNil(transform.apply(x: 1, y: 1))
	}

	func testNoneMeansJudgedAbsent()
	{
		// nil（判定できない）と none（重なっていない）は違う、という約束。
		XCTAssertEqual(PhotoOverlap.none.agreement, 0)
		XCTAssertEqual(PhotoOverlap.none.sharedArea, 0)
	}
}
