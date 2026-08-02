//
//  ProcessingStage.swift
//
//  再構成が「いまどの段階を処理しているか」。RealityKit の
//  PhotogrammetrySession.Output.ProcessingStage に対応する自前 enum で、
//  RealityKit の型を PhotogrammetryEngine の外へ漏らさないためにここで定義する
//  （変換表はエンジン側に 1 つだけ置く。Detail / SampleOrdering と同じ扱い）。
//
//  rawValue は CLI の `stage=` 行の語彙そのもの（他アプリとの約束）なので
//  変更しない。表示用の日本語は displayName 側に分ける。
//

import Foundation

/// 再構成の処理段階。段階が見えること自体に診断価値がある — 例えば README の
/// 「エラー 6」（写真群の位置合わせ失敗）は `imageAlignment` で起きるので、
/// 段階が分かれば「アライメントまで到達したのか、その前で落ちたのか」を
/// 切り分けられる。
public enum ProcessingStage: String, CaseIterable, Equatable, Sendable
{
	/// 写真の前処理（読み込み・品質判定）。
	case preProcessing
	/// 写真同士の位置合わせ。失敗するとアライメントエラーになる段階。
	case imageAlignment
	/// 点群の生成。
	case pointCloudGeneration
	/// メッシュの生成。
	case meshGeneration
	/// テクスチャの貼り付け。
	case textureMapping
	/// 最適化（軽量化・整理）。
	case optimization

	/// 画面・ログに出す日本語名。rawValue は外部連携の語彙なので表示には使わない。
	public var displayName: String
	{
		switch self
		{
			case .preProcessing:
				return "写真の前処理中"
			case .imageAlignment:
				return "画像の位置合わせ中"
			case .pointCloudGeneration:
				return "点群の生成中"
			case .meshGeneration:
				return "メッシュの生成中"
			case .textureMapping:
				return "テクスチャの貼り付け中"
			case .optimization:
				return "最適化中"
		}
	}
}

public extension ProcessingStage
{
	/// 「画像の位置合わせ中 — 残り約 30 分」のような 1 行の進捗説明を組み立てる。
	///
	/// 段階も残り時間も OS が返さないことがあるので、**あるものだけ**で文を作り、
	/// 両方欠けていれば nil を返す（表示側が欠落で崩れないようにするため）。
	/// 文言を 1 か所に集めているのは、GUI とログで同じ表現を使うため。
	static func progressText(stage: ProcessingStage?, remaining: TimeInterval?) -> String?
	{
		let parts = [stage?.displayName, remaining.map(remainingText)].compactMap { $0 }
		guard !parts.isEmpty
		else
		{
			return nil
		}
		return parts.joined(separator: " — ")
	}

	/// 残り時間の文字列。秒単位の精度は意味を持たない（OS の見積もり自体が
	/// 揺れる）ので、分・時間へ丸めて「約」を付ける。
	static func remainingText(_ remaining: TimeInterval) -> String
	{
		// 見積もりが 0 や負になることがある（終盤・OS の揺れ）。
		let seconds = max(0, remaining)
		guard seconds >= 60
		else
		{
			return "残り 1 分未満"
		}

		let minutesTotal = Int((seconds / 60).rounded())
		guard minutesTotal >= 60
		else
		{
			return "残り約 \(minutesTotal) 分"
		}

		let hours = minutesTotal / 60
		let minutes = minutesTotal % 60
		guard minutes > 0
		else
		{
			return "残り約 \(hours) 時間"
		}
		return "残り約 \(hours) 時間 \(minutes) 分"
	}
}
