//
//  FeaturePrint.swift
//
//  Vision の画像特徴（feature print）を、**フレームワークの型を持たない値型**へ
//  落としたもの（設計メモ §4.1 の「視覚的類似」、フェーズ 2）。
//
//  Vision を叩くのは FeaturePrinter だけで、この型から先（クラスタリング・
//  グルーピング・共有写真の選定）はすべて純ロジックになる。PhotoInspector が
//  ImageIO を、PhotogrammetryEngine が RealityKit を閉じ込めているのと同じ構造で、
//  こうしておくと**実写真も Vision も無しに** swift test で挙動を固定できる。
//
//  知覚ハッシュ（PerceptualHash）との使い分け:
//
//    知覚ハッシュ  縮小画像の濃淡の大小関係。**ほぼ同一**の検出に強く、構図が
//                  少し変わると急に崩れる。連写の間引きはこちらが安くて確実。
//    feature print 学習された特徴ベクトル。**同じ場所を別の角度から撮った写真**が
//                  近くなる。「同じ部屋か」を見分けられるのはこちらだけ。
//
//  距離は「単位ベクトルに正規化してからのユークリッド距離 ÷ 2」で 0.0〜1.0 に
//  収める。生のベクトルの長さは OS のリビジョンで変わりうるが、向きの違いだけを
//  見れば尺度が揃うため（閾値は結局その現場の分布から決めるので、絶対値の意味を
//  持たせるのではなく**範囲が固定されている**ことのほうが重要）。
//

import Foundation

/// 写真 1 枚ぶんの視覚特徴。要素は単位ベクトルへ正規化済み。
public struct FeaturePrint: Equatable, Sendable
{
	/// 正規化済みの特徴ベクトル。次元は OS のリビジョン依存（2048 など）。
	public private(set) var elements: [Float]

	/// 取りうる最大の距離。次元が食い違う場合など「比べられない」ときの値でもある。
	public static let maximumDistance = 1.0

	/// 特徴ベクトルから作る。空・長さ 0・非有限の値を含むものは受け付けない
	/// （距離が定義できないものを黙って通すと、以降の閾値推定が壊れるため）。
	public init?(elements: [Float])
	{
		guard !elements.isEmpty, elements.allSatisfy({ $0.isFinite })
		else
		{
			return nil
		}
		var squared = 0.0
		for value in elements
		{
			squared += Double(value) * Double(value)
		}
		let length = squared.squareRoot()
		guard length > 0
		else
		{
			return nil
		}
		self.elements = elements.map { Float(Double($0) / length) }
	}

	/// ベクトルの次元。
	public var dimension: Int
	{
		elements.count
	}

	/// 視覚的な距離（0.0〜1.0）。小さいほど同じ場所を写している。
	///
	/// 次元が違うものは比較しない（OS のリビジョンが変わると要素数が変わる）。
	/// 0 を返すと「同一」と誤って扱われるので、**最も遠い**側へ倒す。
	public func distance(to other: FeaturePrint) -> Double
	{
		guard dimension == other.dimension
		else
		{
			return Self.maximumDistance
		}
		var squared = 0.0
		for index in 0 ..< elements.count
		{
			let difference = Double(elements[index]) - Double(other.elements[index])
			squared += difference * difference
		}
		// 単位ベクトル同士の距離は 0〜2。半分にして 0〜1 へ収める。
		return min(1, squared.squareRoot() / 2)
	}
}
