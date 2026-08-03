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
//    stage=imageAlignment  処理段階（OS が返したときだけ）
//    eta=1830          残り時間の見積もり（秒。OS が返したときだけ）
//    note=...          注意情報（スキップされた写真など）
//    output=<パス>     生成されたモデルファイル
//    cancelled         SIGINT / SIGTERM で中断した（終了コード 0）
//    ok                正常終了（終了コード 0）
//  行の書式は PhotogrammetryCore の HelperProtocol が唯一の定義で、GUI は
//  同じ定義でこれを読み戻す（この CLI は GUI のヘルパープロセスでもある）。
//  エラーは stderr へ "error: ..." を出し、終了コード 1。使い方誤りは 2。
//

import Dispatch
import Foundation
import PhotogrammetryCore

@main
struct PhotogrammetryCLI
{
	static let usage = """
		使い方:
		  photogrammetry-cli <入力フォルダ> <出力ファイル.usdz> [オプション]
		  photogrammetry-cli sort <入力フォルダ> <仕分け先フォルダ> [オプション]

		生成（サブコマンド省略時）:
		  <入力フォルダ>            対象物を多方向から撮影した写真が入ったフォルダ
		  <出力ファイル.usdz>       生成する 3D モデルの出力先

		  -d, --detail <値>               preview | reduced | medium | full | raw（既定: medium）
		  -o, --sample-ordering <値>      unordered | sequential（既定: unordered）
		  -s, --feature-sensitivity <値>  normal | high（既定: normal）
		      --subject <値>              object | scene（既定: object）
		                                  建物・部屋などシーン全体の写真は scene を指定
		                                  （オブジェクトマスキングを無効化）

		sort — 大量の写真をグループへ仕分ける:
		  建物 1 棟ぶんの写真は 1 回のセッションでは解けない（枚数の上限を超え、
		  部屋が変わると位置合わせが途切れる）。撮影時刻・位置・見た目などの
		  手がかりから写真を塊に分け、**隣り合う塊に同じ写真を重複させて**
		  出力する。この共有写真が、あとで各モデルを 1 つの座標系へ合成する
		  ときの手がかりになる。

		  写真の見た目からは**同じ場所（部屋・面）を写した写真の集まり**も
		  見分ける（room-01 …）。時刻が離れていても同じ場所ならまとめ、時刻が
		  近くても別の場所なら分ける。部屋を行き来しながら撮った現場で効く。

		      --overlap <n>               隣接グループ間で共有する枚数（既定: 15）
		      --max-per-group <n>         1 グループの上限枚数（既定: 150）
		      --min-per-group <n>         1 グループの下限枚数（既定: 20）
		      --time-gap <秒>             区切りとみなす撮影間隔（既定: 300）
		      --group-threshold <値>      結合スコアの閾値（既定: 分布から自動決定）
		      --min-sharpness <値>        ブレ判定の閾値（既定: 分布から自動決定）
		      --duplicate-distance <n>    ほぼ同一とみなす距離 0〜64（既定: 4）
		      --visual-threshold <値>     同じ場所とみなす視覚特徴の距離 0.0〜1.0
		                                  （既定: 分布から自動決定）
		      --no-visual                 視覚解析を使わない（速いが精度は落ちる）
		      --link <値>                 hardlink | copy | symlink（既定: hardlink）
		      --no-recursive              サブフォルダを走査しない
		      --dry-run                   ファイルを作らず診断だけ出す

		共通:
		  -h, --help                      このヘルプを表示

		例:
		  photogrammetry-cli ~/Pictures/chair ~/Desktop/chair.usdz --detail full
		  photogrammetry-cli ~/Pictures/house ~/Desktop/house.usdz --subject scene
		  photogrammetry-cli sort ~/Pictures/現場 ~/Desktop/現場-仕分け --dry-run
		  photogrammetry-cli ~/Desktop/現場-仕分け/group-01 ~/Desktop/group-01.usdz --subject scene
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

		let command: APICommand
		do
		{
			command = try APICommand.parse(arguments: arguments)
		}
		catch
		{
			fail(error.localizedDescription, code: 2)
		}

		switch command
		{
			case .process(let request):
				await process(request)
			case .sort(let request):
				sort(request)
		}
	}

	/// 仕分け。再構成を伴わないので GPU 要件は無く、Object Capture 非対応の
	/// Mac でも実行できる（現場で撮り直しを判断するための経路）。
	static func sort(_ request: SortRequest) -> Never
	{
		do
		{
			// 上限は「この Mac のハードウェア上限」と設定値の小さいほうで
			// 診断する。上限を知っているのは RealityKit だけなので Core から渡す。
			let sorter = PhotoSorter(hardwareLimit: ReconstructionService.maximumImageCount)
			let cancellation = SortCancellation()
			installSignalHandler { cancellation.cancel() }
			try sorter.run(request, cancellation: cancellation)
			{ event in
				emit(HelperProtocol.encode(event))
			}
			emit(HelperProtocol.finishedLine)
			exit(0)
		}
		catch SortError.cancelled
		{
			// 中断は失敗ではない。生成と同じ約束（cancelled + 終了コード 0）で返す。
			emit(HelperProtocol.encode(.cancelled))
			exit(0)
		}
		catch
		{
			fail(ErrorDetails.describe(error), code: 1)
		}
	}

	/// 3D モデルの生成。
	static func process(_ request: ReconstructionRequest) async
	{
		guard PhotogrammetryEngine.isSupported
		else
		{
			fail("この Mac は Object Capture に対応していません（GPU 要件を満たしていません）。", code: 1)
		}

		do
		{
			let engine = PhotogrammetryEngine()
			installCancelHandler(engine: engine)
			let cancelled = Flag()
			try await engine.process(request)
			{ event in
				if case .cancelled = event
				{
					cancelled.set()
				}
				emit(HelperProtocol.encode(event))
			}
			// 中断で終わったときに ok を出すと、呼び出し側が成功と誤読する。
			if !cancelled.isSet
			{
				emit(HelperProtocol.finishedLine)
			}
		}
		catch
		{
			// domain / code / userInfo まで含めて出す。PhotogrammetrySession の
			// 失敗は localizedDescription だけでは原因が分からないため。
			fail(ErrorDetails.describe(error), code: 1)
		}
	}

	/// SIGINT / SIGTERM をセッションの cancel に振り替える。既定動作（即座に
	/// プロセス終了）だとセッションが後始末されず一時ファイルが残るうえ、
	/// 親プロセス（GUI）からは「異常終了」と区別が付かないため。
	static func installCancelHandler(engine: PhotogrammetryEngine)
	{
		installSignalHandler { engine.cancel() }
	}

	/// SIGINT / SIGTERM を任意の後始末へ振り替える（生成と仕分けで共用）。
	static func installSignalHandler(_ handler: @escaping @Sendable () -> Void)
	{
		for number in [SIGINT, SIGTERM]
		{
			// DispatchSource で扱うので既定ハンドラは無効化する。
			signal(number, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
			source.setEventHandler(handler: handler)
			source.resume()
			// ソースは解放されると監視も止まるので、プロセスが終わるまで保持する。
			signalSources.append(source)
		}
	}

	static var signalSources: [DispatchSourceSignal] = []

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

/// スレッドを跨いで立てられる真偽値。イベントは任意のスレッドから届くので、
/// ローカル変数の書き換えでは扱えない。
final class Flag: @unchecked Sendable
{
	private let lock = NSLock()
	private var value = false

	func set()
	{
		lock.lock()
		value = true
		lock.unlock()
	}

	var isSet: Bool
	{
		lock.lock()
		defer { lock.unlock() }
		return value
	}
}
