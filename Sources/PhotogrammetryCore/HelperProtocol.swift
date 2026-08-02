//
//  HelperProtocol.swift
//
//  ヘルパープロセス（photogrammetry-cli）が stdout に出す行の書式。CLI が
//  「機械可読な key=value を出す」ために使い、GUI 側の HelperProcessEngine が
//  同じ定義でそれを読み戻す。両者の対応が崩れると進捗が出なくなるので、
//  書式の定義はこのファイル 1 か所だけに置く。
//
//  文字列だけで完結する純ロジックなので、単体テストで往復を固定できる。
//

import Foundation

/// ヘルパープロセスの 1 行が意味するもの。
public enum HelperMessage: Equatable, Sendable
{
	/// 進捗イベント（progress= / note= / output= / cancelled）。
	case event(ReconstructionEvent)
	/// 正常終了マーカー（ok）。これが来ないまま終わった場合は異常終了。
	case finished
}

public enum HelperProtocol
{
	/// 正常終了を示す最終行。
	public static let finishedLine = "ok"

	/// イベントを 1 行のテキストへ変換する。改行を含みうる note は 1 行に
	/// 潰す（行指向の読み取り側が壊れないようにするため）。
	public static func encode(_ event: ReconstructionEvent) -> String
	{
		switch event
		{
			case .progress(let fraction):
				return String(format: "progress=%.3f", fraction)
			case .note(let message):
				return "note=\(singleLine(message))"
			case .completed(let url):
				return "output=\(singleLine(url.path))"
			case .cancelled:
				return "cancelled"
		}
	}

	/// 1 行をメッセージへ戻す。解釈できない行（RealityKit などが stdout へ
	/// 直接出すログ）は nil を返して**黙って捨てる**。ヘルパーの stdout に
	/// 想定外の出力が混ざっても進捗表示が壊れないようにするため。
	public static func decode(line: String) -> HelperMessage?
	{
		let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty
		{
			return nil
		}
		if trimmed == finishedLine
		{
			return .finished
		}
		if trimmed == "cancelled"
		{
			return .event(.cancelled)
		}
		guard let separator = trimmed.firstIndex(of: "=")
		else
		{
			return nil
		}
		let key = String(trimmed[trimmed.startIndex ..< separator])
		let value = String(trimmed[trimmed.index(after: separator)...])
		switch key
		{
			case "progress":
				guard let fraction = Double(value)
				else
				{
					return nil
				}
				return .event(.progress(fraction))
			case "note":
				return .event(.note(value))
			case "output":
				return .event(.completed(URL(fileURLWithPath: value)))
			default:
				return nil
		}
	}

	private static func singleLine(_ text: String) -> String
	{
		text.replacingOccurrences(of: "\r\n", with: " ")
			.replacingOccurrences(of: "\n", with: " ")
			.replacingOccurrences(of: "\r", with: " ")
	}
}
