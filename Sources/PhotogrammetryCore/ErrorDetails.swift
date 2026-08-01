//
//  ErrorDetails.swift
//
//  エラーの詳細（domain / code / userInfo / underlying の連鎖）を人が読める
//  テキストにする純ロジック。
//
//  PhotogrammetrySession の失敗は localizedDescription だけだと
//  「操作を完了できませんでした。（CoreOC.PhotogrammetrySession.Error エラー 6）」
//  のように内容が分からず、原因調査のたびにログ以上の情報が必要になる。
//  GUI のログと CLI の stderr はこの describe を使い、調査に足る情報を必ず残す。
//

import Foundation

public enum ErrorDetails
{
	/// エラーを複数行のテキストへ展開する。1 行目は localizedDescription、
	/// 以降に NSError としての domain / code / userInfo と underlying エラーの
	/// 連鎖をインデント付きで並べる。
	public static func describe(_ error: Error) -> String
	{
		var lines: [String] = [error.localizedDescription]
		appendDetails(of: error as NSError, to: &lines, depth: 0)
		return lines.joined(separator: "\n")
	}

	private static func appendDetails(of error: NSError, to lines: inout [String], depth: Int)
	{
		// underlying の連鎖が壊れていても出力が際限なく伸びないよう頭打ちにする。
		guard depth < 5
		else
		{
			return
		}
		let indent = String(repeating: "  ", count: depth + 1)
		lines.append("\(indent)domain=\(error.domain) code=\(error.code)")
		for key in error.userInfo.keys.sorted()
		{
			// 説明は 1 行目に、underlying は連鎖として下で出すので重複を省く。
			if key == NSLocalizedDescriptionKey || key == NSUnderlyingErrorKey
			{
				continue
			}
			let value = error.userInfo[key].map { String(describing: $0) } ?? ""
			lines.append("\(indent)\(key)=\(value)")
		}
		if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
		{
			lines.append("\(indent)underlying:")
			appendDetails(of: underlying, to: &lines, depth: depth + 1)
		}
	}
}
