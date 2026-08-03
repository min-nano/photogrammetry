//
//  PhotoOverlap.swift
//
//  「2 枚が実際に重なって写っているか」の値型と、その測り方（純ロジック）。
//  設計メモ §4.6.1。Vision を叩くのは ImageRegistrar の仕事で、ここは受け取った
//  画素と位置合わせの答えだけを扱う。
//
//  **なぜ要るか。** 共有写真は合成の対応点なので、両側に**重なって写っている**
//  ことがすべてで、「同じ頃に撮った」「見た目が似ている」では 1 枚も意味を
//  持たない。ところが実データ（1424 枚）では feature print の距離が狭い帯に
//  潰れており（同じ壁の連続撮影で 0.2 前後、別の部屋で 0.3 前後）、距離の絶対値
//  でも中央値を基準にした相対値でも判定しきれなかった。700 枚離れた別の場所の
//  写真が共有写真として残る、という形で表に出た（設計メモ §4.6.1）。
//
//  したがって最後は**実際に位置合わせしてみる**（設計メモ §4.1 の表にある
//  「実際の重なり」）。表に「強（ただし高コスト）／候補ペアにのみ適用」と
//  あるとおりで、共有写真の選定は候補ペアが数十組しかない場面なので、コストの
//  心配が要らない唯一の適用先になる。
//
//  **位置合わせが成立したことを「重なっている」の根拠にはしない。** ci-debug で
//  実測したところ、Vision の位置合わせは無関係な 2 枚に対しても信頼度 1.0 の
//  まま大きな平行移動を返す（run 30778945459）。判定材料になるのは
//  「**その変換で本当に画素が一致するか**」だけなので、重なった範囲の
//  正規化相互相関をここで測る。実測値（run 30779080396 / 30779188029）:
//
//  | 2 枚の関係 | 一致度 |
//  | --- | --- |
//  | 同じ写真 | 1.00 |
//  | 平行移動（重なり 85%） | 1.00 |
//  | 拡大 1.15 倍・回転 8 度 | 0.65〜0.69 |
//  | **無関係** | **0.04 以下** |
//
//  無関係な組が 0.05 を超えないのがこの方法の値打ちで、閾値の置き場所に幅がある。
//

import Foundation

/// 解析用のグレースケール画像。ImageIO / CoreGraphics に触れるのは PhotoInspector
/// だけなので、画素はこの値型に詰め替えてから純ロジックへ渡す。
public struct GrayImage: Equatable, Sendable
{
	public var pixels: [UInt8]
	public var width: Int
	public var height: Int

	public init(pixels: [UInt8], width: Int, height: Int)
	{
		self.pixels = pixels
		self.width = width
		self.height = height
	}
}

/// 2 枚を位置合わせした結果の事実。**判断は含まない** — 「重なっていると
/// 言えるか」の閾値は `SortPlanner.Settings` が持つ。
public struct PhotoOverlap: Equatable, Sendable
{
	/// 重なった範囲で画素がどれだけ一致したか（-1.0〜1.0。正規化相互相関）。
	/// 明るさの差では下がらない（平均と分散で正規化してある）ので、露出が
	/// 違う 2 枚でも「同じものが写っている」なら高い。
	public var agreement: Double
	/// 重なりの広さ。**基準画像の面積に対する割合**（0.0〜1.0）。
	public var sharedArea: Double

	public init(agreement: Double, sharedArea: Double)
	{
		self.agreement = agreement
		self.sharedArea = sharedArea
	}

	/// 位置合わせは走ったが重なりが見つからなかった、という結果。
	/// **「判定できなかった」（nil）とは意味が違う** — こちらは積極的な「無い」。
	public static let none = PhotoOverlap(agreement: 0, sharedArea: 0)
}

/// 重なりを確かめたい 1 組。ファイルの読み出しは実装（ラッパー）の仕事なので、
/// 純ロジックからは URL だけを渡す。
public struct OverlapQuery: Equatable, Sendable
{
	public var a: URL
	public var b: URL

	public init(a: URL, b: URL)
	{
		self.a = a
		self.b = b
	}
}


/// 平面の射影変換（3×3・行優先）。**両側とも左上を原点とする画素座標**で、
/// (x', y', w) = M ·(x, y, 1) と読む。
///
/// Vision の座標系（左下原点）との差はラッパー（`ImageRegistrar`）が吸収して
/// から渡す — 上下の食い違いは実測で確認済みで（run 30779080396）、
/// 知っているのはフレームワークを叩く側だけでよい。
public struct ProjectiveTransform: Equatable, Sendable
{
	/// m00, m01, m02, m10, m11, m12, m20, m21, m22 の順。
	public var elements: [Double]

	public init(elements: [Double])
	{
		// 9 要素でなければ恒等に倒す（変換が壊れていることを重なりの有無に
		// すり替えないため。**ここで落ちるより「重なっていない」と言うほうが
		// 害が小さい**）。
		self.elements = elements.count == 9 ? elements : Self.identity.elements
	}

	public static let identity = ProjectiveTransform(elements: [1, 0, 0, 0, 1, 0, 0, 0, 1])

	/// 平行移動だけの変換。基準の (x, y) が相手の (x + offsetX, y + offsetY) に対応する。
	public static func translation(x: Double, y: Double) -> ProjectiveTransform
	{
		ProjectiveTransform(elements: [1, 0, x, 0, 1, y, 0, 0, 1])
	}

	/// 1 点を写す。w が 0 に潰れる（無限遠へ飛ぶ）点は nil。
	public func apply(x: Double, y: Double) -> (x: Double, y: Double)?
	{
		let w = elements[6] * x + elements[7] * y + elements[8]
		guard w.isFinite, abs(w) > 1e-9
		else
		{
			return nil
		}
		let mappedX = (elements[0] * x + elements[1] * y + elements[2]) / w
		let mappedY = (elements[3] * x + elements[4] * y + elements[5]) / w
		guard mappedX.isFinite, mappedY.isFinite
		else
		{
			return nil
		}
		return (mappedX, mappedY)
	}
}

/// 位置合わせの答え（変換）から重なりを測る。
public enum OverlapMeasurement
{
	/// 相関を信用するのに必要な標本数。狭い帯だけが重なった状態では、相関は
	/// 偶然に大きく振れる。
	public static let minimumSamples = 256
	/// 相関を信用するのに必要な画素値の分散。**白い壁だけが重なった**ような
	/// 場合、分母がほぼ 0 になって相関が意味を失う（8bit の分散 16 = 標準偏差 4）。
	public static let minimumVariance = 16.0
	/// 相関に使う標本数の上限。全画素を舐めても答えは変わらないので、大きな
	/// 画像では間引いて時間を一定に保つ。
	public static let maximumSamples = 40000

	/// 位置合わせ後の重なりを測る。
	///
	/// 基準画像の画素を格子状に拾い、変換で相手の画素へ写して**同じものが
	/// 写っているか**（正規化相互相関）を測る。相関は平均と分散で正規化して
	/// あるので、露出やホワイトバランスが違う 2 枚でも下がらない。
	///
	/// - Parameters:
	///   - base: 基準画像。重なりの割合はこの画像の面積に対する比で返す。
	///   - other: 相手の画像。
	///   - transform: 基準の画素座標から相手の画素座標への変換。
	/// - Returns: 測れた重なり。**判定材料が足りなければ nil**（模様が無さすぎて
	///   相関が意味を持たない）。nil は「重なっていない」ではないので、呼び出し側は
	///   候補を落とす理由に使わないこと。
	public static func measure(
		base: GrayImage,
		other: GrayImage,
		transform: ProjectiveTransform) -> PhotoOverlap?
	{
		guard base.width > 0, base.height > 0, other.width > 0, other.height > 0,
			base.pixels.count >= base.width * base.height,
			other.pixels.count >= other.width * other.height
		else
		{
			return nil
		}
		// 標本数を上限で抑える（答えは変わらず、時間だけが変わる）。
		let step = max(1, Int(
			(Double(base.width * base.height) / Double(maximumSamples)).squareRoot().rounded(.up)))

		var sumBase = 0.0
		var sumOther = 0.0
		var sumBaseSquared = 0.0
		var sumOtherSquared = 0.0
		var sumProduct = 0.0
		var inside = 0.0
		var sampled = 0.0

		for y in stride(from: 0, to: base.height, by: step)
		{
			for x in stride(from: 0, to: base.width, by: step)
			{
				sampled += 1
				guard let mapped = transform.apply(x: Double(x), y: Double(y))
				else
				{
					continue
				}
				let column = Int(mapped.x.rounded())
				let row = Int(mapped.y.rounded())
				guard column >= 0, column < other.width, row >= 0, row < other.height
				else
				{
					continue
				}
				let left = Double(base.pixels[y * base.width + x])
				let right = Double(other.pixels[row * other.width + column])
				sumBase += left
				sumOther += right
				sumBaseSquared += left * left
				sumOtherSquared += right * right
				sumProduct += left * right
				inside += 1
			}
		}

		guard sampled > 0
		else
		{
			return nil
		}
		let sharedArea = inside / sampled
		guard inside >= Double(minimumSamples)
		else
		{
			// 重なりが狭すぎて相関が偶然に左右される。**広さは分かっている**ので、
			// 一致度 0 の重なりとして返す（呼び出し側の閾値で落ちる）。
			return PhotoOverlap(agreement: 0, sharedArea: sharedArea)
		}

		let varianceBase = (sumBaseSquared - sumBase * sumBase / inside) / inside
		let varianceOther = (sumOtherSquared - sumOther * sumOther / inside) / inside
		guard varianceBase >= minimumVariance, varianceOther >= minimumVariance
		else
		{
			// 模様が無い（白い壁・白飛び）。**一致していると言えないのと同じくらい、
			// していないとも言えない**ので判定を返さない。
			return nil
		}
		let covariance = (sumProduct - sumBase * sumOther / inside) / inside
		let agreement = covariance / (varianceBase * varianceOther).squareRoot()
		return PhotoOverlap(
			agreement: min(1, max(-1, agreement)),
			sharedArea: min(1, sharedArea))
	}
}
