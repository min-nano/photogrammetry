//
//  CLI.swift
//
//  photogrammetry-cli — コマンドラインから 3D モデル生成を実行するフロント
//  エンド。Apple 公式サンプル HelloPhotogrammetry に相当する。引数の解釈は
//  PhotogrammetryCore の APICommand（GUI の URL スキームと同じ規則）に委譲し、
//  ここは入出力の整形だけを行う。
//
//  stdout には機械可読な key=value 行を出す（他アプリ・スクリプトからの連携用）:
//    progress=0.123    進捗（0.0〜1.0）
//    note=...          注意情報（スキップされた写真など）
//    output=<パス>     生成されたモデルファイル
//    ok                正常終了（終了コード 0）
//  エラーは stderr へ "error: ..." を出し、終了コード 1。使い方誤りは 2。
//

import Foundation
import PhotogrammetryCore

@main
struct PhotogrammetryCLI
{
	static let usage = """
		使い方: photogrammetry-cli <入力フォルダ> <出力ファイル.usdz> [オプション]

		  <入力フォルダ>            対象物を多方向から撮影した写真が入ったフォルダ
		  <出力ファイル.usdz>       生成する 3D モデルの出力先

		オプション:
		  -d, --detail <値>               preview | reduced | medium | full | raw（既定: medium）
		  -o, --sample-ordering <値>      unordered | sequential（既定: unordered）
		  -s, --feature-sensitivity <値>  normal | high（既定: normal）
		      --subject <値>              object | scene（既定: object）
		                                  建物・部屋などシーン全体の写真は scene を指定
		                                  （オブジェクトマスキングを無効化）
		  -h, --help                      このヘルプを表示

		例:
		  photogrammetry-cli ~/Pictures/chair ~/Desktop/chair.usdz --detail full
		  photogrammetry-cli ~/Pictures/house ~/Desktop/house.usdz --subject scene
		"""

	static func main() async
	{
		let arguments = Array(CommandLine.arguments.dropFirst())

		if arguments.isEmpty
		{
			print(usage)
			exit(2)
		}
		if arguments.contains("-h") || arguments.contains("--help")
		{
			print(usage)
			exit(0)
		}

		let request: ReconstructionRequest
		do
		{
			request = try APICommand.parse(arguments: arguments)
		}
		catch
		{
			fail(error.localizedDescription, code: 2)
		}

		guard PhotogrammetryEngine.isSupported
		else
		{
			fail("この Mac は Object Capture に対応していません（GPU 要件を満たしていません）。", code: 1)
		}

		do
		{
			let engine = PhotogrammetryEngine()
			try await engine.process(request)
			{ event in
				switch event
				{
					case .progress(let fraction):
						emit(String(format: "progress=%.3f", fraction))
					case .note(let message):
						emit("note=\(message)")
					case .completed(let url):
						emit("output=\(url.path)")
					case .cancelled:
						emit("cancelled")
				}
			}
			emit("ok")
		}
		catch
		{
			// domain / code / userInfo まで含めて出す。PhotogrammetrySession の
			// 失敗は localizedDescription だけでは原因が分からないため。
			fail(ErrorDetails.describe(error), code: 1)
		}
	}

	/// 1 行出して即 flush する。パイプ越しの連携（進捗の逐次読み取り）のため
	/// 行バッファリングに頼らない。
	static func emit(_ line: String)
	{
		print(line)
		fflush(stdout)
	}

	static func fail(_ message: String, code: Int32) -> Never
	{
		FileHandle.standardError.write(Data("error: \(message)\n".utf8))
		exit(code)
	}
}
