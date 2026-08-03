//
//  APICommand.swift
//
//  外部連携 API の唯一の定義。GUI アプリの URL スキーム（photogrammetry://）と
//  CLI の引数列を、同じ規則でリクエストへ変換する純ロジック。
//
//  連携の入口は 3 つあるが、パラメータの名前と意味はここで 1 回だけ定義する
//  （入口ごとに解釈を散らさない）:
//
//    1. Swift ライブラリ  ReconstructionRequest / SortRequest を直接組み立てる
//    2. CLI              photogrammetry-cli <input> <output> [--detail ...]
//                        photogrammetry-cli sort <input> <output> [--overlap ...]
//    3. URL スキーム      photogrammetry://process?input=...&output=...&detail=...
//                        photogrammetry://sort?input=...&output=...&overlap=...
//
//  コマンドは 2 つある（生成と仕分け）。CLI はサブコマンド名が無ければ従来
//  どおり process として扱うので、**既存の呼び出しの後方互換は壊れない**。
//
//  ここはファイルシステムにもネットワークにも触れない（存在チェックは各
//  Request の validate の仕事）。したがって単体テストは文字列だけで書ける。
//

import Foundation

/// 外部から受け取った 1 つの指示。
public enum APICommand: Equatable, Sendable
{
	/// 写真フォルダ 1 つから 3D モデルを生成する。
	case process(ReconstructionRequest)
	/// 大量の写真をグループへ仕分ける（建築規模の入力を分割する前処理）。
	case sort(SortRequest)

	/// GUI アプリが Info.plist（CFBundleURLTypes）で宣言する URL スキーム。
	public static let urlScheme = "photogrammetry"
	/// photogrammetry://process?... のホスト部 / CLI のサブコマンド名。
	public static let processCommand = "process"
	/// photogrammetry://sort?... のホスト部 / CLI のサブコマンド名。
	public static let sortCommand = "sort"

	/// CLI が受け付けるサブコマンド名。
	public static let commandNames = [processCommand, sortCommand]

	// -----------------------------------------------------------------
	// URL スキーム
	//   photogrammetry://process?input=<パス>&output=<パス>
	//                   [&detail=medium][&ordering=sequential][&sensitivity=high]
	//                   [&subject=scene]
	//   photogrammetry://sort?input=<パス>&output=<パス>
	//                   [&overlap=15][&maxPerGroup=150][&minPerGroup=20]
	//                   [&timeGap=300][&groupThreshold=0.4][&minSharpness=12]
	//                   [&duplicateDistance=4][&visual=true][&visualThreshold=0.4]
	//                   [&overlapCheck=true][&overlapInliers=0.3]
	//                   [&overlapGrouping=true][&overlapBudget=20000]
	//                   [&link=hardlink][&recursive=true][&dryRun=false]
	// パスはパーセントエンコード済みの絶対パス。
	// -----------------------------------------------------------------
	public static func parse(url: URL) throws -> APICommand
	{
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			components.scheme == urlScheme
		else
		{
			throw APICommandError.unsupportedCommand(url.absoluteString)
		}
		let command = components.host ?? ""
		// コマンド名を先に確かめる。パラメータの不足より「そもそも知らない
		// コマンド」のほうが呼び出し側にとって有用な情報なので順序を保つ。
		guard commandNames.contains(command)
		else
		{
			throw APICommandError.unsupportedCommand(command)
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
		let inputFolder = URL(fileURLWithPath: input, isDirectory: true)

		switch command
		{
			case processCommand:
				var request = ReconstructionRequest(
					inputFolder: inputFolder,
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
				return .process(request)

			case sortCommand:
				var request = SortRequest(
					inputFolder: inputFolder,
					outputFolder: URL(fileURLWithPath: output, isDirectory: true))
				if let raw = parameters["overlap"]
				{
					request.overlap = try intValue(raw, parameter: "overlap")
				}
				if let raw = parameters["maxPerGroup"]
				{
					request.maxPerGroup = try intValue(raw, parameter: "maxPerGroup")
				}
				if let raw = parameters["minPerGroup"]
				{
					request.minPerGroup = try intValue(raw, parameter: "minPerGroup")
				}
				if let raw = parameters["timeGap"]
				{
					request.timeGap = try doubleValue(raw, parameter: "timeGap")
				}
				if let raw = parameters["groupThreshold"]
				{
					request.groupThreshold = try doubleValue(raw, parameter: "groupThreshold")
				}
				if let raw = parameters["minSharpness"]
				{
					request.minimumSharpness = try doubleValue(raw, parameter: "minSharpness")
				}
				if let raw = parameters["duplicateDistance"]
				{
					request.duplicateDistance = try intValue(raw, parameter: "duplicateDistance")
				}
				if let raw = parameters["visual"]
				{
					request.visualEvidence = try boolValue(raw, parameter: "visual")
				}
				if let raw = parameters["visualThreshold"]
				{
					request.visualThreshold = try doubleValue(raw, parameter: "visualThreshold")
				}
				if let raw = parameters["overlapCheck"]
				{
					request.overlapCheck = try boolValue(raw, parameter: "overlapCheck")
				}
				if let raw = parameters["overlapInliers"]
				{
					request.overlapInliers = try doubleValue(raw, parameter: "overlapInliers")
				}
				if let raw = parameters["overlapGrouping"]
				{
					request.overlapGrouping = try boolValue(raw, parameter: "overlapGrouping")
				}
				if let raw = parameters["overlapBudget"]
				{
					request.overlapBudget = try intValue(raw, parameter: "overlapBudget")
				}
				if let raw = parameters["link"]
				{
					request.link = try enumValue(raw, parameter: "link")
				}
				if let raw = parameters["recursive"]
				{
					request.recursive = try boolValue(raw, parameter: "recursive")
				}
				if let raw = parameters["dryRun"]
				{
					request.dryRun = try boolValue(raw, parameter: "dryRun")
				}
				return .sort(request)

			default:
				throw APICommandError.unsupportedCommand(command)
		}
	}

	// -----------------------------------------------------------------
	// CLI 引数
	//   <input-folder> <output-file> [--detail d] [--sample-ordering o]
	//                                [--feature-sensitivity s] [--subject k]
	//   sort <input-folder> <output-folder> [--overlap n] [--max-per-group n] …
	//
	// 生成の語彙は Apple の HelloPhotogrammetry と同じにしてある（移行しやすさ
	// 優先）。サブコマンド名が無ければ生成として解釈するので、既存のスクリプトは
	// そのまま動く。
	// -----------------------------------------------------------------
	public static func parse(arguments: [String]) throws -> APICommand
	{
		guard let first = arguments.first, commandNames.contains(first)
		else
		{
			return .process(try parseProcess(arguments: arguments))
		}
		let rest = Array(arguments.dropFirst())
		switch first
		{
			case sortCommand:
				return .sort(try parseSort(arguments: rest))
			default:
				return .process(try parseProcess(arguments: rest))
		}
	}

	static func parseProcess(arguments: [String]) throws -> ReconstructionRequest
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

	static func parseSort(arguments: [String]) throws -> SortRequest
	{
		var positionals: [String] = []
		var request = SortRequest(
			inputFolder: URL(fileURLWithPath: "/", isDirectory: true),
			outputFolder: URL(fileURLWithPath: "/", isDirectory: true))

		var index = 0
		while index < arguments.count
		{
			let argument = arguments[index]
			switch argument
			{
				case "--overlap":
					request.overlap = try intValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--max-per-group":
					request.maxPerGroup = try intValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--min-per-group":
					request.minPerGroup = try intValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--time-gap":
					request.timeGap = try doubleValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--group-threshold":
					request.groupThreshold = try doubleValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--min-sharpness":
					request.minimumSharpness = try doubleValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--duplicate-distance":
					request.duplicateDistance = try intValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--visual-threshold":
					request.visualThreshold = try doubleValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--no-visual":
					request.visualEvidence = false
					index += 1
				case "--overlap-inliers":
					request.overlapInliers = try doubleValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--no-overlap-check":
					request.overlapCheck = false
					index += 1
				case "--no-overlap-grouping":
					request.overlapGrouping = false
					index += 1
				case "--overlap-budget":
					request.overlapBudget = try intValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--link":
					request.link = try enumValue(
						optionValue(arguments, at: index, name: argument), parameter: argument)
					index += 2
				case "--no-recursive":
					request.recursive = false
					index += 1
				case "--dry-run":
					request.dryRun = true
					index += 1
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
			throw APICommandError.missingSortArguments
		}
		request.inputFolder = URL(fileURLWithPath: positionals[0], isDirectory: true)
		request.outputFolder = URL(fileURLWithPath: positionals[1], isDirectory: true)
		return request
	}

	/// Request を CLI の引数列へ戻す（parse(arguments:) の逆）。GUI が
	/// ヘルパープロセス（photogrammetry-cli）を起動するときに使う。語彙を
	/// 1 か所に保つため、組み立てもここに置く（往復はテストで固定している）。
	public static func arguments(for request: ReconstructionRequest) -> [String]
	{
		[
			request.inputFolder.path,
			request.outputFile.path,
			"--detail", request.detail.rawValue,
			"--sample-ordering", request.sampleOrdering.rawValue,
			"--feature-sensitivity", request.featureSensitivity.rawValue,
			"--subject", request.subject.rawValue,
		]
	}

	/// SortRequest を CLI の引数列へ戻す。自動決定に任せる項目（閾値）は
	/// 指定が無ければ出さない — 出すと「自動」という選択そのものが失われる。
	public static func arguments(for request: SortRequest) -> [String]
	{
		var result = [
			sortCommand,
			request.inputFolder.path,
			request.outputFolder.path,
			"--overlap", String(request.overlap),
			"--max-per-group", String(request.maxPerGroup),
			"--min-per-group", String(request.minPerGroup),
			"--time-gap", String(Int(request.timeGap.rounded())),
			"--duplicate-distance", String(request.duplicateDistance),
			"--link", request.link.rawValue,
		]
		if let threshold = request.groupThreshold
		{
			result += ["--group-threshold", String(threshold)]
		}
		if let sharpness = request.minimumSharpness
		{
			result += ["--min-sharpness", String(sharpness)]
		}
		if let threshold = request.visualThreshold
		{
			result += ["--visual-threshold", String(threshold)]
		}
		if let inliers = request.overlapInliers
		{
			result += ["--overlap-inliers", String(inliers)]
		}
		if !request.visualEvidence
		{
			result.append("--no-visual")
		}
		if !request.overlapCheck
		{
			result.append("--no-overlap-check")
		}
		if !request.overlapGrouping
		{
			result.append("--no-overlap-grouping")
		}
		if let budget = request.overlapBudget
		{
			result += ["--overlap-budget", String(budget)]
		}
		if !request.recursive
		{
			result.append("--no-recursive")
		}
		if request.dryRun
		{
			result.append("--dry-run")
		}
		return result
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

	private static func intValue(_ raw: String, parameter: String) throws -> Int
	{
		guard let value = Int(raw)
		else
		{
			throw APICommandError.invalidValue(parameter: parameter, value: raw)
		}
		return value
	}

	private static func doubleValue(_ raw: String, parameter: String) throws -> Double
	{
		guard let value = Double(raw), value.isFinite
		else
		{
			throw APICommandError.invalidValue(parameter: parameter, value: raw)
		}
		return value
	}

	/// 真偽値は URL スキームでしか出てこない（CLI はフラグ形式）。
	/// true / false / 1 / 0 / yes / no を受ける。
	private static func boolValue(_ raw: String, parameter: String) throws -> Bool
	{
		switch raw.lowercased()
		{
			case "true", "1", "yes":
				return true
			case "false", "0", "no":
				return false
			default:
				throw APICommandError.invalidValue(parameter: parameter, value: raw)
		}
	}
}

public enum APICommandError: Error, LocalizedError, Equatable
{
	case unsupportedCommand(String)
	case missingParameter(String)
	case invalidValue(parameter: String, value: String)
	case unknownOption(String)
	case missingArguments
	case missingSortArguments

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
			case .missingSortArguments:
				return "引数が不足しています（sort <入力フォルダ> <仕分け先フォルダ> が必要です）。"
		}
	}
}
