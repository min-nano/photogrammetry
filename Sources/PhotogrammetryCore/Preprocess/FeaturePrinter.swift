//
//  FeaturePrinter.swift
//
//  Vision を叩く唯一の層（フェーズ 2）。PhotoInspector が ImageIO を、
//  PhotogrammetryEngine が RealityKit を閉じ込めているのと同じ扱いで、
//  **Vision の型をここから外へ漏らさない**（外へ出るのは値型 FeaturePrint だけ）。
//  したがってこのファイルは自動テストの対象外で、挙動確認は実機か ci-debug の
//  run-cli で行う（CLAUDE.md「テスト方針」）。判定そのものは FeaturePrint から
//  先の純ロジック（RoomClustering / PhotoGrouping）が持つ。
//
//  `VNGenerateImageFeaturePrintRequest` は「同じ場所を別の角度から撮った写真」が
//  近くなる特徴を返す。知覚ハッシュ（dHash）は構図が変わると急に崩れるので、
//  **視覚的に同一の部屋を見つける**にはこちらが要る。逆にほぼ同一の重複検出は
//  dHash のほうが安く確実なので、両方を残して使い分ける（設計メモ §4.1）。
//
//  リビジョンは固定しない。OS が新しい表現を持っているならそれを使うほうが
//  精度が上がるし、距離は**同じ 1 回の実行の中でしか比較しない**（閾値もその場の
//  分布から決める）ので、実行をまたいだ互換性は要らない。次元が食い違う組み合わせは
//  FeaturePrint.distance が「最も遠い」として扱う。
//

import CoreGraphics
import Foundation
import Vision

/// 画像から視覚特徴を取り出す役。実装は Vision だが、返すのは値型だけ。
public protocol ImageFeaturePrinting: Sendable
{
	func featurePrint(of image: CGImage) -> FeaturePrint?
}

public struct FeaturePrinter: ImageFeaturePrinting
{
	public init() {}

	/// 1 枚ぶんの特徴を取り出す。取れなければ nil（**失敗を例外にしない**のは、
	/// 数千枚のうち数枚が読めなくても仕分けは続けるべきだから。証拠の
	/// カバレッジが下がれば PhotoGrouping が自動でこの手がかりを使わなくなる）。
	public func featurePrint(of image: CGImage) -> FeaturePrint?
	{
		let request = VNGenerateImageFeaturePrintRequest()
		let handler = VNImageRequestHandler(cgImage: image, options: [:])
		do
		{
			try handler.perform([request])
		}
		catch
		{
			return nil
		}
		guard let observation = request.results?.first
		else
		{
			return nil
		}
		return Self.elements(of: observation).flatMap(FeaturePrint.init(elements:))
	}

	/// 観測結果のバイト列を Float の配列へ広げる。要素型は OS のリビジョンで
	/// float / double のどちらもありうるので両方を受ける。
	static func elements(of observation: VNFeaturePrintObservation) -> [Float]?
	{
		let count = observation.elementCount
		guard count > 0
		else
		{
			return nil
		}
		let data = observation.data
		// Data の先頭が Float / Double の境界に載っている保証は無いので、
		// ポインタを束ね直さず 1 要素ずつ非整列読み出しで取り出す。
		switch observation.elementType
		{
			case .float:
				let stride = MemoryLayout<Float>.size
				guard data.count >= count * stride
				else
				{
					return nil
				}
				return data.withUnsafeBytes
				{ buffer in
					(0 ..< count).map
					{ index in
						buffer.loadUnaligned(fromByteOffset: index * stride, as: Float.self)
					}
				}
			case .double:
				let stride = MemoryLayout<Double>.size
				guard data.count >= count * stride
				else
				{
					return nil
				}
				return data.withUnsafeBytes
				{ buffer in
					(0 ..< count).map
					{ index in
						Float(buffer.loadUnaligned(fromByteOffset: index * stride, as: Double.self))
					}
				}
			default:
				// 未知の要素型は捨てる（無理に解釈すると意味の無い距離になる）。
				return nil
		}
	}
}
