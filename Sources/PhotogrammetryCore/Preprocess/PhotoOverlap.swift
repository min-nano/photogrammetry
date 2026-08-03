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
/// 言えるか」の閾値は `OverlapCriteria` が持つ。
public struct PhotoOverlap: Equatable, Sendable
{
	/// 重なった範囲**全体**で画素がどれだけ一致したか（-1.0〜1.0。正規化相互相関）。
	/// 明るさの差では下がらない（平均と分散で正規化してある）。
	///
	/// **これは判定には使わない。** 1 枚の射影変換は平面しか記述できないので、
	/// 奥行きのある場面を別の立ち位置から撮った 2 枚では、本当に重なっていても
	/// この値は落ちる（実データ 1424 枚で分布に谷が出ず、隣り合う写真の 45% しか
	/// 拾えなかった。設計メモ §4.9.1）。閾値の見直しのために統計として残している。
	public var agreement: Double
	/// 重なりの広さ。**基準画像の面積に対する割合**（0.0〜1.0）。
	public var sharedArea: Double
	/// **判定に使うのはこれ。** 重なり範囲を格子に割り、ブロックごとに局所探索して
	/// 一致を探したとき、**一致し、かつずれ方が揃っていたブロックの割合**
	/// （0.0〜1.0）。実質的にインライア率で、視差があっても局所的には合うので
	/// 落ちない一方、無関係な 2 枚では 1 ブロックも揃わない。
	public var inlierRatio: Double
	/// 判定に使えたブロック数（重なりの中にあって、かつ模様のあるブロック）。
	/// 少なすぎるときは測定側が nil（判定できなかった）を返すので、ここに 0 が
	/// 入った値が外へ出ることはない。
	public var evaluatedBlocks: Int

	public init(
		agreement: Double,
		sharedArea: Double,
		inlierRatio: Double = 0,
		evaluatedBlocks: Int = 0)
	{
		self.agreement = agreement
		self.sharedArea = sharedArea
		self.inlierRatio = inlierRatio
		self.evaluatedBlocks = evaluatedBlocks
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

	// -----------------------------------------------------------------
	// ブロックごとの局所一致（設計メモ §4.9.1）
	// -----------------------------------------------------------------

	/// 重なり範囲を割る格子。細かくするほど判定は鋭くなるが、1 ブロックの
	/// 画素数が減って相関が偶然に振れる。
	public static let gridColumns = 8
	public static let gridRows = 6
	/// 1 ブロックから拾う標本数の目安。相関を信用できて、かつ探索を回しても
	/// 軽い量。
	public static let samplesPerBlock = 144
	/// 局所探索の半径（画像の長辺に対する割合）。**視差の逃げ幅**で、これが
	/// 足りないと奥行きのある場面で本当の重なりを取りこぼす。
	public static let searchFraction = 0.08
	/// 粗い探索の刻み（画素）。この後 ±`refineRadius` を 1 画素刻みで詰める。
	public static let coarseStride = 4
	public static let refineRadius = 3
	/// 判定に足るブロック数。これを下回ると「判定できなかった」（nil）。
	public static let minimumEvaluatedBlocks = 6
	/// 隣り合うブロックのずれが「揃っている」と認める距離（探索半径に対する割合）。
	///
	/// **中央値との比較ではなく、格子の隣どうしで比べる。** 視差は「1 つのずれ」に
	/// 収束しない — 手前のものと奥のものではずれ方が違うのが視差そのものなので、
	/// 全体の中央値から測ると**本当に重なっている組ほど落ちる**（実際、手前 16 px・
	/// 奥 26 px の 2 枚で半分が落ちた）。一方、奥行きは連続しているので**隣り合う
	/// ブロックのずれは近い**。無関係な 2 枚が偶然合ったときのずれにはこの性質が
	/// 無いので、ここで切り分けられる。
	public static let neighbourTolerance = 0.5

	/// 位置合わせ後の重なりを測る。
	///
	/// 2 つを測る。
	///
	/// 1. **全体の相関**（`agreement`）— 変換 1 つで全画素を突き合わせた値。
	///    平面しか記述できないので奥行きのある場面では落ちる。統計として残すだけ。
	/// 2. **ブロックごとの局所一致**（`inlierRatio`）— 重なり範囲を格子に割り、
	///    ブロックごとに変換の周りを少し探して一致を探す。**視差はブロック単位の
	///    小さなずれとして現れる**ので、探せば見つかる。そのうえで「ずれ方が
	///    揃っているか」を見て、偶然合っただけのブロックを落とす。
	///
	/// 相関は平均と分散で正規化してあるので、露出やホワイトバランスが違う 2 枚
	/// でも下がらない。
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
		guard let global = globalAgreement(base: base, other: other, transform: transform)
		else
		{
			return nil
		}
		let blocks = blockMatches(base: base, other: other, transform: transform)
		guard blocks.inside > 0
		else
		{
			// どのブロックの中心も相手の外だった（重なりが無いか、帯のように
			// 狭い）。**積極的な「重なっていない」**。広さは画素で測ったほうを返す
			// — ブロックより細かいので、狭い重なりもそのまま伝わる。
			return PhotoOverlap(agreement: 0, sharedArea: min(1, global.sharedArea))
		}
		guard blocks.evaluated >= minimumEvaluatedBlocks
		else
		{
			// 重なってはいるが模様が無い（白い壁・白飛び）。一致しているとも
			// していないとも言えないので判定を返さない。
			return nil
		}
		return PhotoOverlap(
			agreement: global.agreement,
			sharedArea: min(1, global.sharedArea),
			inlierRatio: Double(blocks.coherent) / Double(blocks.evaluated),
			evaluatedBlocks: blocks.evaluated)
	}

	/// 変換 1 つで全画素を突き合わせた相関と、重なりの広さ。
	/// **判定には使わない**（`measure` のドキュメント参照）。
	static func globalAgreement(
		base: GrayImage,
		other: GrayImage,
		transform: ProjectiveTransform) -> (agreement: Double, sharedArea: Double)?
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
			// 重なりが狭すぎて相関が偶然に左右される。**広さは分かっている**。
			return (0, sharedArea)
		}

		let varianceBase = (sumBaseSquared - sumBase * sumBase / inside) / inside
		let varianceOther = (sumOtherSquared - sumOther * sumOther / inside) / inside
		guard varianceBase >= minimumVariance, varianceOther >= minimumVariance
		else
		{
			// 模様が無い。相関は意味を持たないが、広さは分かっている。
			return (0, sharedArea)
		}
		let covariance = (sumProduct - sumBase * sumOther / inside) / inside
		let agreement = covariance / (varianceBase * varianceOther).squareRoot()
		return (min(1, max(-1, agreement)), sharedArea)
	}

	/// ブロックごとに局所探索して一致を数える。
	///
	/// - Returns: 重なりの中に入ったブロック数・判定に使えたブロック数・
	///   一致したうえでずれ方が揃っていたブロック数。
	static func blockMatches(
		base: GrayImage,
		other: GrayImage,
		transform: ProjectiveTransform)
		-> (inside: Int, evaluated: Int, coherent: Int)
	{
		guard base.width >= gridColumns, base.height >= gridRows,
			base.pixels.count >= base.width * base.height,
			other.pixels.count >= other.width * other.height
		else
		{
			return (0, 0, 0)
		}
		let blockWidth = base.width / gridColumns
		let blockHeight = base.height / gridRows
		// 1 ブロックからおよそ `samplesPerBlock` 枚拾う刻み。
		let stride = max(
			1,
			Int((Double(blockWidth * blockHeight) / Double(samplesPerBlock)).squareRoot().rounded()))
		let radius = max(
			coarseStride,
			Int((Double(max(other.width, other.height)) * searchFraction).rounded()))
		let tolerance = max(3.0, Double(radius) * neighbourTolerance)

		var inside = 0
		var evaluated = 0
		// 格子の並びのまま持つ（隣どうしを比べるため）。
		var offsets = [(x: Int, y: Int)?](repeating: nil, count: gridRows * gridColumns)

		for row in 0 ..< gridRows
		{
			for column in 0 ..< gridColumns
			{
				let originX = column * blockWidth
				let originY = row * blockHeight
				// 基準側の標本と、変換で写した先の座標をまとめて作る。
				var values: [Double] = []
				var targets: [(x: Double, y: Double)] = []
				values.reserveCapacity(samplesPerBlock)
				targets.reserveCapacity(samplesPerBlock)
				for y in Swift.stride(from: originY, to: originY + blockHeight, by: stride)
				{
					for x in Swift.stride(from: originX, to: originX + blockWidth, by: stride)
					{
						guard let mapped = transform.apply(x: Double(x), y: Double(y))
						else
						{
							continue
						}
						values.append(Double(base.pixels[y * base.width + x]))
						targets.append(mapped)
					}
				}
				guard values.count >= minimumBlockSamples
				else
				{
					continue
				}
				// ブロックの中心が相手の画像の中に落ちるか（＝重なりの中にあるか）。
				let centre = targets[targets.count / 2]
				guard centre.x >= 0, centre.x < Double(other.width),
					centre.y >= 0, centre.y < Double(other.height)
				else
				{
					continue
				}
				inside += 1
				guard variance(of: values) >= minimumVariance
				else
				{
					// 基準側が真っ平ら。**この組の判定材料にならない**ので数えない
					// （一致しなかった、とは違う）。
					continue
				}
				guard let best = bestMatch(
					values: values,
					targets: targets,
					other: other,
					radius: radius)
				else
				{
					// 相手側が真っ平ら／範囲外。同上。
					continue
				}
				evaluated += 1
				if best.agreement >= minimumBlockAgreement
				{
					offsets[row * gridColumns + column] = (best.x, best.y)
				}
			}
		}

		guard evaluated > 0
		else
		{
			return (inside, evaluated, 0)
		}
		return (inside, evaluated, coherentBlocks(offsets: offsets, tolerance: tolerance))
	}

	/// **隣り合うブロックとずれ方が揃っているものだけを数える。**
	///
	/// 合ったブロックのうち、格子の隣（上下左右）にも合ったブロックがあり、その
	/// ずれが `tolerance` 以内のものを採る。奥行きは連続しているので、本当に
	/// 重なっていれば隣どうしは必ず近い（視差で全体がばらけていても）。偶然合った
	/// だけのブロックにはこの性質が無く、孤立するので落ちる。
	static func coherentBlocks(offsets: [(x: Int, y: Int)?], tolerance: Double) -> Int
	{
		var count = 0
		for row in 0 ..< gridRows
		{
			for column in 0 ..< gridColumns
			{
				guard let here = offsets[row * gridColumns + column]
				else
				{
					continue
				}
				let neighbours = [(row - 1, column), (row + 1, column),
					(row, column - 1), (row, column + 1)]
				let agrees = neighbours.contains
				{ neighbourRow, neighbourColumn in
					guard neighbourRow >= 0, neighbourRow < gridRows,
						neighbourColumn >= 0, neighbourColumn < gridColumns,
						let there = offsets[neighbourRow * gridColumns + neighbourColumn]
					else
					{
						return false
					}
					let dx = Double(here.x - there.x)
					let dy = Double(here.y - there.y)
					return (dx * dx + dy * dy).squareRoot() <= tolerance
				}
				if agrees
				{
					count += 1
				}
			}
		}
		return count
	}

	/// 1 ブロックが認められる最低の一致度。全体の相関より高く取れるのは、
	/// 局所では視差の影響がほとんど無いため。
	public static let minimumBlockAgreement = 0.6
	/// **その一致が「そこだけ」で起きていることを求める。** 探索の中で最もよく
	/// 合ったずれが、離れた別のずれより**これだけ上回っている**ことを要求する。
	///
	/// これが無いと、大きな平らな面（同じ色の壁・床）を持つ 2 枚が「どこでも
	/// 合う」せいで重なっていることになってしまう。合成サンプルの 2 部屋
	/// （色の違う矩形の並び）が 1 グループに融合して発覚した。特徴点照合の
	/// 比率テストと同じ考え方で、**曖昧な一致は証拠にしない。**
	public static let minimumPeakMargin = 0.15
	/// 「離れた別のずれ」と認める距離（探索半径に対する割合）。
	public static let peakSeparation = 0.5
	/// 1 ブロックの相関に必要な標本数。
	static let minimumBlockSamples = 24

	/// 変換の周りを探して、最もよく一致するずれを見つける。粗く探してから
	/// 1 画素刻みで詰める（全部を 1 画素刻みで探すと探索が 16 倍になる）。
	static func bestMatch(
		values: [Double],
		targets: [(x: Double, y: Double)],
		other: GrayImage,
		radius: Int) -> (x: Int, y: Int, agreement: Double)?
	{
		// 粗い探索の答えは全部覚えておく。**最良のずれだけでなく「離れた別の
		// ずれがどれだけ合ったか」も要る**（曖昧な一致を落とすため）。
		var coarseScores: [(x: Int, y: Int, agreement: Double)] = []
		var offset = -radius
		while offset <= radius
		{
			var vertical = -radius
			while vertical <= radius
			{
				if let score = correlation(
					values: values, targets: targets, other: other,
					offsetX: offset, offsetY: vertical)
				{
					coarseScores.append((offset, vertical, score))
				}
				vertical += coarseStride
			}
			offset += coarseStride
		}
		guard let coarse = coarseScores.max(by: { $0.agreement < $1.agreement })
		else
		{
			return nil
		}

		// **離れた別のずれでも同じくらい合うなら、その一致は「そこだけ」で起きて
		// いない。** 大きな平らな面はどこでも合うので、これで落ちる。
		let separation = max(4.0, Double(radius) * peakSeparation)
		let rival = coarseScores.filter
		{
			let dx = Double($0.x - coarse.x)
			let dy = Double($0.y - coarse.y)
			return (dx * dx + dy * dy).squareRoot() > separation
		}.map(\.agreement).max()
		if let rival, coarse.agreement - rival < minimumPeakMargin
		{
			return nil
		}

		var best = coarse
		for dx in (coarse.x - refineRadius) ... (coarse.x + refineRadius)
		{
			for dy in (coarse.y - refineRadius) ... (coarse.y + refineRadius)
			{
				guard let score = correlation(
					values: values, targets: targets, other: other, offsetX: dx, offsetY: dy),
					score > best.agreement
				else
				{
					continue
				}
				best = (dx, dy, score)
			}
		}
		return best
	}

	/// 1 ブロックぶんの正規化相互相関。相手側の分散が足りなければ nil。
	static func correlation(
		values: [Double],
		targets: [(x: Double, y: Double)],
		other: GrayImage,
		offsetX: Int,
		offsetY: Int) -> Double?
	{
		var sumBase = 0.0
		var sumOther = 0.0
		var sumBaseSquared = 0.0
		var sumOtherSquared = 0.0
		var sumProduct = 0.0
		var count = 0.0
		for index in 0 ..< values.count
		{
			let column = Int(targets[index].x.rounded()) + offsetX
			let row = Int(targets[index].y.rounded()) + offsetY
			guard column >= 0, column < other.width, row >= 0, row < other.height
			else
			{
				continue
			}
			let left = values[index]
			let right = Double(other.pixels[row * other.width + column])
			sumBase += left
			sumOther += right
			sumBaseSquared += left * left
			sumOtherSquared += right * right
			sumProduct += left * right
			count += 1
		}
		guard count >= Double(minimumBlockSamples)
		else
		{
			return nil
		}
		let varianceBase = (sumBaseSquared - sumBase * sumBase / count) / count
		let varianceOther = (sumOtherSquared - sumOther * sumOther / count) / count
		guard varianceBase >= minimumVariance, varianceOther >= minimumVariance
		else
		{
			return nil
		}
		let covariance = (sumProduct - sumBase * sumOther / count) / count
		return min(1, max(-1, covariance / (varianceBase * varianceOther).squareRoot()))
	}

	/// 標本の分散。
	static func variance(of values: [Double]) -> Double
	{
		guard !values.isEmpty
		else
		{
			return 0
		}
		let count = Double(values.count)
		let sum = values.reduce(0, +)
		let sumSquared = values.reduce(0) { $0 + $1 * $1 }
		return (sumSquared - sum * sum / count) / count
	}
}
