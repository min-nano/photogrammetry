//
//  FeaturePrintTests.swift
//
//  視覚特徴の距離を固定する。Vision を叩くのは FeaturePrinter（テスト対象外）
//  だけで、**距離の性質はこの純ロジックが全部持っている**ので、実写真も
//  Vision も無しに確かめられる。
//

import XCTest

@testable import PhotogrammetryCore

final class FeaturePrintTests: XCTestCase
{
	func make(_ elements: [Float]) throws -> FeaturePrint
	{
		try XCTUnwrap(FeaturePrint(elements: elements))
	}

	func testIdenticalPrintsHaveZeroDistance() throws
	{
		let print = try make([1, 2, 3, 4])
		XCTAssertEqual(print.distance(to: print), 0, accuracy: 1e-6)
	}

	func testDistanceIgnoresScale() throws
	{
		// 生のベクトルの長さは OS のリビジョンで変わりうる。**向きだけを見る**
		// ことで尺度を揃えるのが正規化の目的。
		let a = try make([1, 2, 3, 4])
		let b = try make([10, 20, 30, 40])
		XCTAssertEqual(a.distance(to: b), 0, accuracy: 1e-6)
	}

	func testOrthogonalAndOppositeDistances() throws
	{
		let a = try make([1, 0])
		let b = try make([0, 1])
		let opposite = try make([-1, 0])
		// 直交は √2 / 2、真逆は 1.0（＝取りうる最大）。
		XCTAssertEqual(a.distance(to: b), 2.0.squareRoot() / 2, accuracy: 1e-6)
		XCTAssertEqual(a.distance(to: opposite), FeaturePrint.maximumDistance, accuracy: 1e-6)
	}

	func testDistanceIsSymmetricAndBounded() throws
	{
		let a = try make([0.2, -0.5, 0.9])
		let b = try make([-0.7, 0.1, 0.3])
		XCTAssertEqual(a.distance(to: b), b.distance(to: a), accuracy: 1e-9)
		XCTAssertGreaterThanOrEqual(a.distance(to: b), 0)
		XCTAssertLessThanOrEqual(a.distance(to: b), FeaturePrint.maximumDistance)
	}

	func testCloserVectorsGiveSmallerDistance() throws
	{
		let base = try make([1, 0])
		let near = try make([1, 0.1])
		let far = try make([1, 1])
		XCTAssertLessThan(base.distance(to: near), base.distance(to: far))
	}

	func testUnusableVectorsAreRejected()
	{
		// 距離が定義できないものを黙って通すと、閾値の推定ごと壊れる。
		XCTAssertNil(FeaturePrint(elements: []))
		XCTAssertNil(FeaturePrint(elements: [0, 0, 0]))
		XCTAssertNil(FeaturePrint(elements: [1, .nan]))
		XCTAssertNil(FeaturePrint(elements: [1, .infinity]))
	}

	func testMismatchedDimensionsAreTreatedAsFarApart() throws
	{
		// OS のリビジョンが変わると要素数が変わる。0（＝同一）へ倒すと
		// 別物を同じ場所と判定してしまうので、最も遠い側へ倒す。
		let a = try make([1, 0])
		let b = try make([1, 0, 0])
		XCTAssertEqual(a.distance(to: b), FeaturePrint.maximumDistance)
		XCTAssertEqual(a.dimension, 2)
		XCTAssertEqual(b.dimension, 3)
	}

	func testElementsAreNormalized() throws
	{
		let print = try make([3, 4])
		let length = print.elements.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
		XCTAssertEqual(length, 1, accuracy: 1e-6)
	}
}
