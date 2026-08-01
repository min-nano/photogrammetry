//
//  APICommand.swift
//
//  外部連携 API の唯一の定義。GUI アプリの URL スキーム（photogrammetry://）と
//  CLI の引数列を、同じ規則で ReconstructionRequest へ変換する純ロジック。
//
//  連携の入口は 3 つあるが、パラメータの名前と意味はここで 1 回だけ定義する
//  （入口ごとに解釈を散らさない）:
//
//    1. Swift ライブラリ  ReconstructionRequest を直接組み立てる
//    2. CLI              photogrammetry-cli <input> <output> [--detail ...]
//    3. URL スキーム      photogrammetry://process?input=...&output=...&detail=...
//
//  ここはファイルシステムにもネットワークにも触れない（存在チェックは
//  ReconstructionRequest.validate の仕事）。したがって単体テストは文字列だけで書ける。
//

import Foundation

public enum APICommand
{
	/// GUI アプリが Info.plist（CFBundleURLTypes）で宣言する URL スキーム。
	public static let urlScheme = "photogrammetry"
	/// 現状サポートする唯一のコマンド。photogrammetry://process?... のホスト部。
	public static let processCommand = "process"

	// -----------------------------------------------------------------
	// URL スキーム: photogrammetry://process?input=<パス>&output=<パス>
	//               [&detail=medium][&ordering=sequential][&sensitivity=high]
	//               [&subject=scene]
	// パスはパーセントエンコード済みの絶対パス。
	// -----------------------------------------------------------------
	public static func parse(url: URL) throws -> ReconstructionRequest
	{
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			components.scheme == urlScheme
		else
		{
			throw APICommandError.unsupportedCommand(url.absoluteString)
		}
		guard (components.host ?? "") == processCommand
		else
		{
			throw APICommandError.unsupportedCommand(components.host ?? "")
		}

		var parameters: [String: String] = [:]
		for item in components.queryItems ?? []
		{
			parameters[item.name] = item.value ?? ""
		}

		guard let input = parameters["input"], !input.isEmpty
		else
		{
			throw APICommandError.missingParameter("input")
		}
		guard let output = parameters["output"], !output.isEmpty
		else
		{
			throw APICommandError.missingParameter("output")
		}

		var request = ReconstructionRequest(
			inputFolder: URL(fileURLWithPath: input, isDirectory: true),
			outputFile: URL(fileURLWithPath: output))
		if let raw = parameters["detail"]
		{
			request.detail = try enumValue(raw, parameter: "detail")
		}
		if let raw = parameters["ordering"]
		{
			request.sampleOrdering = try enumValue(raw, parameter: "ordering")
		}
		if let raw = parameters["sensitivity"]
		{
			request.featureSensitivity = try enumValue(raw, parameter: "sensitivity")
		}
		if let raw = parameters["subject"]
		{
			request.subject = try enumValue(raw, parameter: "subject")
		}
		return request
	}

	// -----------------------------------------------------------------
	// CLI 引数: <input-folder> <output-file>
	//           [--detail d] [--sample-ordering o] [--feature-sensitivity s]
	//           [--subject k]
	// Apple の HelloPhotogrammetry と同じ語彙にしてある（移行しやすさ優先）。
	// --subject は本アプリの拡張（マスキングの有効/無効）。
	// -----------------------------------------------------------------
	public static func parse(arguments: [String]) throws -> ReconstructionRequest
	{
		var positionals: [String] = []
		var detailRaw: String?
		var orderingRaw: String?
		var sensitivityRaw: String?
		var subjectRaw: String?

		var index = 0
		while index < arguments.count
		{
			let argument = arguments[index]
			switch argument
			{
				case "--detail", "-d":
					detailRaw = try optionValue(arguments, at: index, name: argument)
					index += 2
				case "--sample-ordering", "-o":
					orderingRaw = try optionValue(arguments, at: index, name: argument)
					index += 2
				case "--feature-sensitivity", "-s":
					sensitivityRaw = try optionValue(arguments, at: index, name: argument)
					index += 2
				case "--subject":
					subjectRaw = try optionValue(arguments, at: index, name: argument)
					index += 2
				default:
					if argument.hasPrefix("-")
					{
						throw APICommandError.unknownOption(argument)
					}
					positionals.append(argument)
					index += 1
			}
		}

		guard positionals.count == 2
		else
		{
			throw APICommandError.missingArguments
		}

		var request = ReconstructionRequest(
			inputFolder: URL(fileURLWithPath: positionals[0], isDirectory: true),
			outputFile: URL(fileURLWithPath: positionals[1]))
		if let raw = detailRaw
		{
			request.detail = try enumValue(raw, parameter: "--detail")
		}
		if let raw = orderingRaw
		{
			request.sampleOrdering = try enumValue(raw, parameter: "--sample-ordering")
		}
		if let raw = sensitivityRaw
		{
			request.featureSensitivity = try enumValue(raw, parameter: "--feature-sensitivity")
		}
		if let raw = subjectRaw
		{
			request.subject = try enumValue(raw, parameter: "--subject")
		}
		return request
	}

	// -----------------------------------------------------------------
	// 内部ヘルパー
	// -----------------------------------------------------------------

	private static func optionValue(_ arguments: [String], at index: Int, name: String) throws
		-> String
	{
		guard index + 1 < arguments.count
		else
		{
			throw APICommandError.missingParameter(name)
		}
		return arguments[index + 1]
	}

	private static func enumValue<T: RawRepresentable>(_ raw: String, parameter: String) throws -> T
		where T.RawValue == String
	{
		guard let value = T(rawValue: raw)
		else
		{
			throw APICommandError.invalidValue(parameter: parameter, value: raw)
		}
		return value
	}
}

public enum APICommandError: Error, LocalizedError, Equatable
{
	case unsupportedCommand(String)
	case missingParameter(String)
	case invalidValue(parameter: String, value: String)
	case unknownOption(String)
	case missingArguments

	public var errorDescription: String?
	{
		switch self
		{
			case .unsupportedCommand(let what):
				return "サポートされていないコマンドです: \(what)"
			case .missingParameter(let name):
				return "パラメータ \(name) が指定されていません。"
			case .invalidValue(let parameter, let value):
				return "\(parameter) の値が不正です: \(value)"
			case .unknownOption(let option):
				return "不明なオプションです: \(option)"
			case .missingArguments:
				return "引数が不足しています（<入力フォルダ> <出力ファイル.usdz> が必要です）。"
		}
	}
}
