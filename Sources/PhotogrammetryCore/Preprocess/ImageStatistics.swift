//
//  ImageStatistics.swift
//
//  グレースケール画素の配列から品質指標と知覚ハッシュを求める純ロジック。
//
//  画像を「読む」のは PhotoInspector（ImageIO）の仕事で、ここは受け取った
//  バイト列を数値にするだけ。こう分けてあるので、ブレ判定・白飛び判定・
//  ハッシュの性質を**写真ファイルを 1 枚も用意せずに** swift test で固定できる
//  （実写真は公開できないという制約が設計メモ §10-10 にある）。
//
//  入力はいずれも行優先・1 画素 1 バイトのグレースケール。
//

import Foundation

public enum ImageStatistics
{
	/// ラプラシアン分散。ブレ・ピンボケの標準的な指標で、値が小さいほど
	/// エッジが失われている＝ブレている。
	///
	/// 絶対値は被写体依存（のっぺりした白壁は元々小さい）なので、**判定は
	/// 必ず分布との相対で行う**こと（QualityFilter）。ここでは生値を返す。
	public static func laplacianVariance(gray: [UInt8], width: Int, height: Int) -> Double
	{
		guard width > 2, height > 2, gray.count >= width * height
		else
		{
			return 0
		}
		var sum = 0.0
		var sumOfSquares = 0.0
		var count = 0
		for y in 1 ..< (height - 1)
		{
			let row = y * width
			let above = row - width
			let below = row + width
			for x in 1 ..< (width - 1)
			{
				// 4 近傍ラプラシアン。カーネルは [[0,1,0],[1,-4,1],[0,1,0]]。
				let value =
					Double(gray[above + x]) + Double(gray[below + x])
					+ Double(gray[row + x - 1]) + Double(gray[row + x + 1])
					- 4 * Double(gray[row + x])
				sum += value
				sumOfSquares += value * value
				count += 1
			}
		}
		guard count > 0
		else
		{
			return 0
		}
		let mean = sum / Double(count)
		return max(0, sumOfSquares / Double(count) - mean * mean)
	}

	/// 輝度の分布から平均・白飛び率・黒つぶれ率を求める。
	///
	/// - Parameters:
	///   - highlightLevel: これ以上を白飛びとみなす輝度（既定 250）。
	///   - shadowLevel: これ以下を黒つぶれとみなす輝度（既定 5）。
	public static func luminanceProfile(
		gray: [UInt8],
		highlightLevel: UInt8 = 250,
		shadowLevel: UInt8 = 5)
		-> (mean: Double, clippedHighlights: Double, clippedShadows: Double)
	{
		guard !gray.isEmpty
		else
		{
			return (0, 0, 0)
		}
		var total = 0.0
		var highlights = 0
		var shadows = 0
		for value in gray
		{
			total += Double(value)
			if value >= highlightLevel
			{
				highlights += 1
			}
			else if value <= shadowLevel
			{
				shadows += 1
			}
		}
		let count = Double(gray.count)
		return (
			mean: total / count / 255,
			clippedHighlights: Double(highlights) / count,
			clippedShadows: Double(shadows) / count)
	}

	/// difference hash（dHash）。9×8 へ縮小し、横に隣り合う画素の大小関係を
	/// 64 bit へ詰める。明るさの変化に強く（大小関係しか見ない）、構図が変わると
	/// すぐ崩れるので「ほぼ同一かどうか」の判定に向く。
	public static func differenceHash(gray: [UInt8], width: Int, height: Int) -> PerceptualHash?
	{
		guard width > 0, height > 0, gray.count >= width * height
		else
		{
			return nil
		}
		let small = boxDownsample(gray: gray, width: width, height: height, toWidth: 9, toHeight: 8)
		var bits: UInt64 = 0
		for y in 0 ..< 8
		{
			for x in 0 ..< 8
			{
				bits <<= 1
				if small[y * 9 + x] > small[y * 9 + x + 1]
				{
					bits |= 1
				}
			}
		}
		return PerceptualHash(bits: bits)
	}

	/// 面積平均による縮小。縮小先の 1 画素が対応する元の矩形をすべて平均する
	/// ので、間引き（最近傍）と違ってノイズや細かい模様に振られにくい。
	public static func boxDownsample(
		gray: [UInt8],
		width: Int,
		height: Int,
		toWidth: Int,
		toHeight: Int) -> [UInt8]
	{
		guard width > 0, height > 0, toWidth > 0, toHeight > 0, gray.count >= width * height
		else
		{
			return [UInt8](repeating: 0, count: max(0, toWidth * toHeight))
		}
		var result = [UInt8](repeating: 0, count: toWidth * toHeight)
		for targetY in 0 ..< toHeight
		{
			// 端数を切り上げ・切り捨てで挟み、必ず 1 画素以上を含むようにする。
			let startY = targetY * height / toHeight
			let endY = max(startY + 1, (targetY + 1) * height / toHeight)
			for targetX in 0 ..< toWidth
			{
				let startX = targetX * width / toWidth
				let endX = max(startX + 1, (targetX + 1) * width / toWidth)
				var total = 0
				var count = 0
				for y in startY ..< min(endY, height)
				{
					let row = y * width
					for x in startX ..< min(endX, width)
					{
						total += Int(gray[row + x])
						count += 1
					}
				}
				result[targetY * toWidth + targetX] = count > 0 ? UInt8(total / count) : 0
			}
		}
		return result
	}
}
