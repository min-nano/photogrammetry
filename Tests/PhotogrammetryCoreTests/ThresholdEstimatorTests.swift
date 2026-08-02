//
//  ThresholdEstimatorTests.swift
//
//  閾値の自動決定（設計メモ §10-5「固定の既定値を持たない」）を固定する。
//  重要なのは 2 つ:
//
//    1. 山が 2 つある分布では、その谷を当てる
//    2. 山が 1 つしか無い分布では **separability が低くなる**（＝呼び出し側が
//       「切らない」を選べる）
//
//  2 が無いと、ブレた写真が 1 枚も無い現場で良品を捨ててしまう。
//

import XCTest

@testable import PhotogrammetryCore

final class ThresholdEstimatorTests: XCTestCase
{
	func testOtsuFindsValleyOfBimodalDistribution()
	{
		// 10 付近の山と 100 付近の山。
		var values = [Double](repeating: 10, count: 30)
		values.append(contentsOf: [Double](repeating: 100, count: 70))
		let estimate = ThresholdEstimator.otsu(values: values)
		XCTAssertNotNil(estimate)
		guard let estimate
		else
		{
			return
		}
		XCTAssertGreaterThan(estimate.threshold, 10)
		XCTAssertLessThan(estimate.threshold, 100)
		XCTAssertGreaterThan(estimate.separability, 0.9)
		XCTAssertEqual(estimate.lowerFraction, 0.3, accuracy: 0.01)
	}

	func testOtsuReportsLowSeparabilityForSingleMode()
	{
		// 正規分布に近い 1 つの山（0.0〜1.0 の中央付近に集中）。
		let values = (0 ..< 200).map
		{ index -> Double in
			let position = Double(index % 20) - 9.5
			return 50 + position * position * (position < 0 ? -0.1 : 0.1)
		}
		let estimate = ThresholdEstimator.otsu(values: values)
		XCTAssertNotNil(estimate)
		// 谷が無いので分離度は 1 から遠い。
		XCTAssertLessThan(estimate?.separability ?? 1, 0.9)
	}

	func testOtsuNeedsVariation()
	{
		XCTAssertNil(ThresholdEstimator.otsu(values: [5, 5, 5, 5]))
		XCTAssertNil(ThresholdEstimator.otsu(values: [1]))
		XCTAssertNil(ThresholdEstimator.otsu(values: []))
	}

	func testPercentileAndMedian()
	{
		let values: [Double] = [1, 2, 3, 4, 5]
		XCTAssertEqual(ThresholdEstimator.median(values), 3)
		XCTAssertEqual(ThresholdEstimator.percentile(values, 0), 1)
		XCTAssertEqual(ThresholdEstimator.percentile(values, 1), 5)
		XCTAssertEqual(ThresholdEstimator.percentile(values, 0.25) ?? 0, 2, accuracy: 1e-9)
		XCTAssertNil(ThresholdEstimator.percentile([], 0.5))
	}

	func testHistogramCountsIntoBins()
	{
		let values: [Double] = [0.05, 0.15, 0.15, 0.95]
		let histogram = ThresholdEstimator.histogram(values: values, bins: 10, lower: 0, upper: 1)
		XCTAssertEqual(histogram.count, 10)
		XCTAssertEqual(histogram[0], 1)
		XCTAssertEqual(histogram[1], 2)
		XCTAssertEqual(histogram[9], 1)
	}

	func testHistogramClampsOutOfRangeValues()
	{
		// 範囲外の値は端のビンへ落ちる（例外にしない。統計の破綻より
		// 「診断が出ない」ほうが困るため）。
		let histogram = ThresholdEstimator.histogram(
			values: [-5, 42], bins: 4, lower: 0, upper: 1)
		XCTAssertEqual(histogram[0], 1)
		XCTAssertEqual(histogram[3], 1)
	}
}
