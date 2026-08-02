//
//  ThresholdEstimator.swift
//
//  「値の並びから 2 つの山の谷を探す」純ロジック（大津の二値化と同じ判別分析）。
//
//  設計メモ §10-5 のとおり、この処理系には**万能な固定閾値が無い**。ブレの
//  ラプラシアン分散は被写体の模様で桁が変わるし、写真同士の結合スコアの分布は
//  現場（屋外の外周・狭い床下）でまるで違う。固定値を置くと、暗い床下の写真が
//  全滅したり、逆に全部 1 グループになったりする。
//
//  そこで閾値は**その現場の分布から決める**。加えて重要なのは、
//  **分布が 1 つの山しか持たないときに無理やり切らないこと**。ブレた写真が
//  1 枚も無い現場で判別分析を回すと、必ずどこかで切って良品を捨ててしまう。
//  separability（クラス間分散比 η）を返しているのはそのためで、呼び出し側は
//  これが低いときは「切らない」を選べる。
//

import Foundation

public enum ThresholdEstimator
{
	/// 判別分析の結果。
	public struct Estimate: Equatable, Sendable
	{
		/// 求まった閾値（この値**以下**を下位クラスとみなす）。
		public var threshold: Double
		/// クラス間分散 / 全分散（0.0〜1.0）。1 に近いほど 2 つの山がはっきり
		/// 分かれている。低いときは「山が 1 つ」＝切るべきでない。
		public var separability: Double
		/// 閾値以下に入った値の割合。
		public var lowerFraction: Double

		public init(threshold: Double, separability: Double, lowerFraction: Double)
		{
			self.threshold = threshold
			self.separability = separability
			self.lowerFraction = lowerFraction
		}
	}

	/// 判別分析（大津の二値化）で分布の谷を探す。
	///
	/// - Parameters:
	///   - values: 対象の値（順不同）。
	///   - binCount: ヒストグラムの分割数。値域を等分する。
	/// - Returns: 値が 2 種類未満なら nil（切る意味が無い）。
	public static func otsu(values: [Double], binCount: Int = 64) -> Estimate?
	{
		guard values.count >= 2, binCount >= 2
		else
		{
			return nil
		}
		let minimum = values.min() ?? 0
		let maximum = values.max() ?? 0
		guard maximum > minimum
		else
		{
			return nil
		}

		let width = (maximum - minimum) / Double(binCount)
		var histogram = [Int](repeating: 0, count: binCount)
		for value in values
		{
			let index = min(binCount - 1, max(0, Int((value - minimum) / width)))
			histogram[index] += 1
		}

		let total = Double(values.count)
		// ビンの代表値は中央。閾値をビン境界に取ると片側が空になりやすい。
		func center(_ index: Int) -> Double
		{
			minimum + (Double(index) + 0.5) * width
		}

		var grandMean = 0.0
		for index in 0 ..< binCount
		{
			grandMean += center(index) * Double(histogram[index])
		}
		grandMean /= total

		var variance = 0.0
		for index in 0 ..< binCount
		{
			let difference = center(index) - grandMean
			variance += difference * difference * Double(histogram[index])
		}
		variance /= total
		guard variance > 0
		else
		{
			return nil
		}

		var lowerWeight = 0.0
		var lowerSum = 0.0
		var best = (betweenVariance: -1.0, index: 0, fraction: 0.0)
		for index in 0 ..< (binCount - 1)
		{
			lowerWeight += Double(histogram[index]) / total
			lowerSum += center(index) * Double(histogram[index]) / total
			let upperWeight = 1 - lowerWeight
			guard lowerWeight > 0, upperWeight > 0
			else
			{
				continue
			}
			let lowerMean = lowerSum / lowerWeight
			let upperMean = (grandMean - lowerSum) / upperWeight
			let difference = lowerMean - upperMean
			let betweenVariance = lowerWeight * upperWeight * difference * difference
			if betweenVariance > best.betweenVariance
			{
				best = (betweenVariance, index, lowerWeight)
			}
		}
		guard best.betweenVariance >= 0
		else
		{
			return nil
		}
		return Estimate(
			threshold: minimum + Double(best.index + 1) * width,
			separability: min(1, best.betweenVariance / variance),
			lowerFraction: best.fraction)
	}

	/// 昇順に並べた値の p 分位点（0.0〜1.0）。分布の裾を掴むのに使う。
	public static func percentile(_ values: [Double], _ p: Double) -> Double?
	{
		guard !values.isEmpty
		else
		{
			return nil
		}
		let sorted = values.sorted()
		let position = min(Double(sorted.count - 1), max(0, p * Double(sorted.count - 1)))
		let lower = Int(position.rounded(.down))
		let upper = min(sorted.count - 1, lower + 1)
		let fraction = position - Double(lower)
		return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
	}

	/// 中央値。
	public static func median(_ values: [Double]) -> Double?
	{
		percentile(values, 0.5)
	}

	/// ヒストグラム（診断レポート用）。写真そのものを含まない統計だけを
	/// 出力するという方針（設計メモ §10-10）に沿って、閾値調整はこの形の
	/// 統計だけで回せるようにしてある。
	public static func histogram(values: [Double], bins: Int, lower: Double, upper: Double)
		-> [Int]
	{
		guard bins > 0
		else
		{
			return []
		}
		var result = [Int](repeating: 0, count: bins)
		guard upper > lower
		else
		{
			return result
		}
		let width = (upper - lower) / Double(bins)
		for value in values
		{
			let index = min(bins - 1, max(0, Int((value - lower) / width)))
			result[index] += 1
		}
		return result
	}
}
