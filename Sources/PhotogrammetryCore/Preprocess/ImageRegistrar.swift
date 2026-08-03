//
//  ImageRegistrar.swift
//
//  Vision の画像レジストレーションを叩く唯一の層（設計メモ §4.6.1）。
//  `FeaturePrinter` が feature print を、`PhotoInspector` が ImageIO を、
//  `PhotogrammetryEngine` が RealityKit を閉じ込めているのと同じ扱いで、
//  **Vision の型をここから外へ漏らさない**（外へ出るのは値型 `PhotoOverlap` だけ）。
//  したがってこのファイルは自動テストの対象外で（CLAUDE.md「テスト方針」）、
//  判断はすべて `OverlapMeasurement` から先の純ロジックが持つ。
//
//  **このファイルに残っているのは 3 つだけ:**
//
//    1. Vision に位置合わせを頼み、変換を取り出す
//    2. Vision の座標系（左下原点）を画素座標（左上原点）へ直す
//    3. 候補の組をまとめて処理する（デコードは 1 枚 1 回）
//
//  「重なっていると言えるか」は 1 つも判断しない。
//
//  ### 実測して決めたこと（ci-debug）
//
//  - **信頼度は使えない。** 無関係な 2 枚でも `confidence` は 1.0 で返る
//    （run 30778945459）。したがって「位置合わせが成立した」ことを重なりの
//    根拠にはできず、**その変換で画素が本当に一致するか**を測るしかない。
//  - **平行移動と射影の 2 つを使う。** 平行移動の推定は横に振った撮影で正確
//    （一致度 1.00）だが、寄り引き・回転が入ると外れる。射影はその逆で、
//    拡大 1.15 倍・回転 8 度で 0.65〜0.69 を出す一方、純粋な平行移動では
//    外すことがある（run 30779188029）。**安いほうを先に試し、駄目なら
//    もう一方**という順にして、無駄な推論を避ける。
//  - **上下が逆。** Vision の座標系は左下原点なので、画素座標（左上原点）へ
//    直してから純ロジックへ渡す（run 30779080396 で実測）。
//

import CoreGraphics
import Foundation
import Vision
import simd

/// 2 枚が実際に重なって写っているかを確かめる役。実装は Vision だが、返すのは
/// 値型だけ。テストではこれを差し替えて、実画像なしに仕分けの判断を確かめる
/// （`PhotoMetadataReading` と同じ考え方）。
public protocol PhotoOverlapVerifying: Sendable
{
	/// 1 組ぶん。**判定できなければ nil**（「重なっていない」ではない）。
	func overlap(between a: URL, and b: URL) -> PhotoOverlap?

	/// まとめて確かめる。**並行にするかどうかは実装の都合**なので、呼び出し側
	/// （純ロジック）が実装の種類で分岐しなくて済むようにここに置く。
	///
	/// - Returns: `queries` と同じ並び・同じ長さ。
	func overlaps(for queries: [OverlapQuery], isCancelled: @Sendable () -> Bool) -> [PhotoOverlap?]
}

public extension PhotoOverlapVerifying
{
	/// 既定の実装は 1 組ずつ順に確かめる素朴なもの。並行化が要るのは実画像を
	/// デコードする `ImageRegistrar` だけなので、そちらで差し替える。
	func overlaps(for queries: [OverlapQuery], isCancelled: @Sendable () -> Bool) -> [PhotoOverlap?]
	{
		queries.map
		{ query in
			isCancelled() ? nil : overlap(between: query.a, and: query.b)
		}
	}
}

public struct ImageRegistrar: PhotoOverlapVerifying
{
	/// 位置合わせに使う画像の最大辺（画素）。解析用の縮小（320）より大きいのは、
	/// 特徴の対応付けに使える模様を残すため。原寸を渡してもコストが増えるだけで
	/// 判定は変わらない。
	public static let imageSize = 480

	/// 画像を読む役。ImageIO に触れるのは PhotoInspector だけ、という約束を
	/// 守るためにこちらへ委ねる。
	public var inspector: PhotoInspector

	public init(inspector: PhotoInspector = PhotoInspector(thumbnailSize: ImageRegistrar.imageSize))
	{
		self.inspector = inspector
	}

	public func overlap(between a: URL, and b: URL) -> PhotoOverlap?
	{
		guard let base = inspector.registrationImage(at: a),
			let other = inspector.registrationImage(at: b)
		else
		{
			return nil
		}
		return overlap(base: base, other: other)
	}

	public func overlaps(for queries: [OverlapQuery], isCancelled: @Sendable () -> Bool)
		-> [PhotoOverlap?]
	{
		guard !queries.isEmpty
		else
		{
			return []
		}
		// 同じ写真が複数の組に現れる（隣接 1 本の候補は同じ数枚の周りに集まる）。
		// デコードが処理時間の大半なので、1 枚 1 回に抑える。
		var urls: [URL] = []
		var seen = Set<String>()
		for query in queries
		{
			for url in [query.a, query.b] where seen.insert(url.path).inserted
			{
				urls.append(url)
			}
		}
		let cache = RegistrationImageCache()
		let inspector = self.inspector
		DispatchQueue.concurrentPerform(iterations: urls.count)
		{ index in
			guard !isCancelled()
			else
			{
				return
			}
			let url = urls[index]
			guard let loaded = inspector.registrationImage(at: url)
			else
			{
				return
			}
			cache.store(loaded, for: url)
		}

		let results = RegistrationResults(count: queries.count)
		let registrar = self
		DispatchQueue.concurrentPerform(iterations: queries.count)
		{ index in
			guard !isCancelled()
			else
			{
				return
			}
			let query = queries[index]
			guard let base = cache.image(for: query.a), let other = cache.image(for: query.b)
			else
			{
				return
			}
			results.store(registrar.overlap(base: base, other: other), at: index)
		}
		return results.finish()
	}

	// -----------------------------------------------------------------
	// Vision
	// -----------------------------------------------------------------

	/// 読み込み済みの 2 枚から重なりを測る。
	///
	/// **平行移動 → 射影の順**に試し、先に閾値を超えたほうを採る…のではなく
	/// **両方の一致度のうち高いほう**を返す。どちらのモデルが当たるかは撮り方
	/// （横に振ったか・寄ったか）で変わり、外したモデルの答えは一致度が低い
	/// ままなので、高いほうを採れば取り違えない。射影は平行移動より高価なので、
	/// 平行移動でよく一致したときは省く。
	func overlap(
		base: (image: CGImage, gray: GrayImage),
		other: (image: CGImage, gray: GrayImage)) -> PhotoOverlap?
	{
		var best: PhotoOverlap?
		if let translation = Self.translation(base: base.image, other: other.image)
		{
			best = OverlapMeasurement.measure(
				base: base.gray, other: other.gray, transform: translation)
		}
		// 平行移動でほぼ一致したなら射影を求める意味が無い（時間だけかかる）。
		if let best, best.agreement >= Self.sufficientAgreement
		{
			return best
		}
		guard let homography = Self.homography(
			base: base.image, other: other.image,
			baseHeight: base.gray.height, otherHeight: other.gray.height)
		else
		{
			return best
		}
		let projective = OverlapMeasurement.measure(
			base: base.gray, other: other.gray, transform: homography)
		guard let projective
		else
		{
			return best
		}
		guard let best
		else
		{
			return projective
		}
		return projective.agreement > best.agreement ? projective : best
	}

	/// これ以上の一致度なら射影の推定を省く。
	static let sufficientAgreement = 0.8

	/// 平行移動の位置合わせ。`tx` はそのまま画素の横ずれ、`ty` は**符号が逆**
	/// （Vision は左下原点、画素配列は左上原点）。
	static func translation(base: CGImage, other: CGImage) -> ProjectiveTransform?
	{
		let request = VNTranslationalImageRegistrationRequest(targetedCGImage: base, options: [:])
		guard perform(request, on: other),
			let observation = request.results?.first as? VNImageTranslationAlignmentObservation
		else
		{
			return nil
		}
		let transform = observation.alignmentTransform
		guard transform.tx.isFinite, transform.ty.isFinite
		else
		{
			return nil
		}
		return ProjectiveTransform.translation(
			x: Double(transform.tx), y: -Double(transform.ty))
	}

	/// 射影（ホモグラフィ）の位置合わせ。Vision の左下原点を上下反転で挟んで
	/// 画素座標へ直す（`F(other)⁻¹ · M · F(base)`。反転行列は自分自身が逆行列）。
	static func homography(
		base: CGImage,
		other: CGImage,
		baseHeight: Int,
		otherHeight: Int) -> ProjectiveTransform?
	{
		let request = VNHomographicImageRegistrationRequest(targetedCGImage: base, options: [:])
		guard perform(request, on: other),
			let observation = request.results?.first as? VNImageHomographicAlignmentObservation
		else
		{
			return nil
		}
		let matrix = observation.warpTransform
		// simd は列優先。行優先（純ロジック側の約束）へ並べ替える。
		let rows = [
			Double(matrix.columns.0.x), Double(matrix.columns.1.x), Double(matrix.columns.2.x),
			Double(matrix.columns.0.y), Double(matrix.columns.1.y), Double(matrix.columns.2.y),
			Double(matrix.columns.0.z), Double(matrix.columns.1.z), Double(matrix.columns.2.z),
		]
		guard rows.allSatisfy({ $0.isFinite })
		else
		{
			return nil
		}
		return ProjectiveTransform(elements: multiply(
			flip(height: otherHeight),
			multiply(rows, flip(height: baseHeight))))
	}

	/// 上下反転の 3×3（y' = height - 1 - y）。
	static func flip(height: Int) -> [Double]
	{
		[1, 0, 0, 0, -1, Double(height - 1), 0, 0, 1]
	}

	/// 3×3 の行優先どうしの積。
	static func multiply(_ left: [Double], _ right: [Double]) -> [Double]
	{
		var result = [Double](repeating: 0, count: 9)
		for row in 0 ..< 3
		{
			for column in 0 ..< 3
			{
				var sum = 0.0
				for index in 0 ..< 3
				{
					sum += left[row * 3 + index] * right[index * 3 + column]
				}
				result[row * 3 + column] = sum
			}
		}
		return result
	}

	/// 位置合わせの実行。**失敗を例外にしない** — 数千枚のうち数組が解けなくても
	/// 仕分けは続けるべきで、解けなかったことは呼び出し側が nil として扱う。
	static func perform(_ request: VNImageRegistrationRequest, on image: CGImage) -> Bool
	{
		do
		{
			try VNSequenceRequestHandler().perform([request], on: image)
			return true
		}
		catch
		{
			return false
		}
	}
}

/// デコード済みの画像を組の間で使い回すための入れ物。CGImage は Sendable では
/// ないので、並行アクセスはロックで直列化する（`InspectionCollector` と同じ）。
final class RegistrationImageCache: @unchecked Sendable
{
	private let lock = NSLock()
	private var images: [String: (image: CGImage, gray: GrayImage)] = [:]

	func store(_ loaded: (image: CGImage, gray: GrayImage), for url: URL)
	{
		lock.lock()
		images[url.path] = loaded
		lock.unlock()
	}

	func image(for url: URL) -> (image: CGImage, gray: GrayImage)?
	{
		lock.lock()
		defer { lock.unlock() }
		return images[url.path]
	}
}

/// 並行に求めた重なりを添字どおりに集める。
final class RegistrationResults: @unchecked Sendable
{
	private let lock = NSLock()
	private var values: [PhotoOverlap?]

	init(count: Int)
	{
		values = [PhotoOverlap?](repeating: nil, count: count)
	}

	func store(_ overlap: PhotoOverlap?, at index: Int)
	{
		lock.lock()
		values[index] = overlap
		lock.unlock()
	}

	func finish() -> [PhotoOverlap?]
	{
		lock.lock()
		defer { lock.unlock() }
		return values
	}
}
