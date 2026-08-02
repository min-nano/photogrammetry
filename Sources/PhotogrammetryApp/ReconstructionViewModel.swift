//
//  ReconstructionViewModel.swift
//
//  生成画面の状態管理。ReconstructionService の進捗イベントをメインアクターへ
//  持ち上げて UI へ反映するのが仕事で、生成ロジック自体は一切持たない。
//

import AppKit
import Foundation
import PhotogrammetryCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ReconstructionViewModel: ObservableObject
{
	/// 画面のモード。生成と仕分けは出力も設定も別物なので、フォームごと切り替える
	/// （入力の写真フォルダだけは共通）。
	enum Mode: String, CaseIterable, Identifiable
	{
		/// 写真フォルダ 1 つ → 3D モデル。
		case reconstruct
		/// 大量の写真 → グループへ仕分け。
		case sort

		var id: String { rawValue }

		var displayName: String
		{
			switch self
			{
				case .reconstruct:
					return "3D モデルを生成"
				case .sort:
					return "写真を仕分ける"
			}
		}
	}

	@Published var mode: Mode = .reconstruct

	@Published var inputFolder: URL?
	@Published var outputFile: URL?
	@Published var detail: ReconstructionRequest.Detail = .medium
	@Published var sampleOrdering: ReconstructionRequest.SampleOrdering = .unordered
	@Published var featureSensitivity: ReconstructionRequest.FeatureSensitivity = .normal
	@Published var subject: ReconstructionRequest.SubjectKind = .object

	// 仕分け（sort）のフォーム。既定値は SortRequest と揃える（食い違うと
	// GUI と CLI で結果が変わってしまう）。閾値は既定の「分布から自動決定」の
	// ままにしてあり、上書きは CLI / URL スキームの逃げ道に任せる。
	@Published var sortOutputFolder: URL?
	@Published var overlap = 15
	@Published var maxPerGroup = 150
	@Published var minPerGroup = 20
	@Published var timeGap: Double = 300
	@Published var linkStrategy: LinkStrategy = .hardlink
	@Published var sortRecursive = true
	@Published var sortDryRun = false

	@Published var isProcessing = false
	@Published var progress: Double = 0
	@Published var statusText = ""
	@Published var logLines: [String] = []
	/// ML モデルのキャッシュ破損で失敗した直後だけ true（復旧ボタンの表示）。
	/// 判断そのものは Core（HelperProcessError.isModelCacheFailure）が持つ。
	@Published var canPurgeModelCache = false

	/// 現在の処理段階と残り時間の見積もり。OS が返さないことがあるので Optional。
	@Published var processingStage: ProcessingStage?
	@Published var estimatedRemainingTime: TimeInterval?

	/// 直前に書き出したもの（モデルファイル / manifest.json）。仕分けの結果は
	/// フォルダを開いて中身を見に行くことになるので、そこまで案内する。
	@Published var lastOutput: URL?

	private var service: ReconstructionService?
	/// 実行中の仕分けの中断フラグ。
	private var sortCancellation: SortCancellation?
	/// ログへ出した最後の段階。段階が変わったときだけ 1 行残すために持つ
	/// （進捗イベントは頻繁に来るので、毎回書くとログが埋まる）。
	private var loggedStage: ProcessingStage?

	/// プログレスバーの下に出す 1 行（「画像の位置合わせ中 — 残り約 30 分」）。
	/// 文言の組み立ては Core にあり、ここは受け渡すだけ。
	var progressDetailText: String?
	{
		ProcessingStage.progressText(stage: processingStage, remaining: estimatedRemainingTime)
	}

	var canStart: Bool
	{
		inputFolder != nil && outputFile != nil && !isProcessing
	}

	var canStartSort: Bool
	{
		inputFolder != nil && sortOutputFolder != nil && !isProcessing
	}

	// -----------------------------------------------------------------
	// ファイル選択
	// -----------------------------------------------------------------

	func chooseInputFolder()
	{
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.message = mode == .sort
			? "仕分けたい写真が入ったフォルダを選択してください"
			: "対象物を多方向から撮影した写真が入ったフォルダを選択してください"
		panel.prompt = "選択"
		if panel.runModal() == .OK
		{
			inputFolder = panel.url
		}
	}

	func chooseOutputFile()
	{
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.usdz]
		panel.canCreateDirectories = true
		panel.nameFieldStringValue = "model.usdz"
		panel.message = "生成する 3D モデルの保存先を選択してください"
		if panel.runModal() == .OK
		{
			outputFile = panel.url
		}
	}

	func chooseSortOutputFolder()
	{
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.canCreateDirectories = true
		panel.allowsMultipleSelection = false
		panel.message = "仕分け結果（group-01 … と manifest.json）を作るフォルダを選択してください"
		panel.prompt = "選択"
		if panel.runModal() == .OK
		{
			sortOutputFolder = panel.url
		}
	}

	/// 直前の出力を Finder で表示する。仕分けの結果はフォルダを開いて
	/// group-NN を見に行くことになるので、そこまで繋いでおく。
	func revealLastOutput()
	{
		guard let url = lastOutput
		else
		{
			return
		}
		NSWorkspace.shared.activateFileViewerSelecting([url])
	}

	// -----------------------------------------------------------------
	// 実行
	// -----------------------------------------------------------------

	func start()
	{
		guard let input = inputFolder, let output = outputFile
		else
		{
			return
		}
		run(ReconstructionRequest(
			inputFolder: input,
			outputFile: output,
			detail: detail,
			sampleOrdering: sampleOrdering,
			featureSensitivity: featureSensitivity,
			subject: subject))
	}

	/// フォームの内容で仕分けを実行する。組み立てるのは SortRequest 1 つだけで、
	/// 妥当性の判断も各段の設定への翻訳も Core（SortRequest）が持つ。
	func startSort()
	{
		guard let input = inputFolder, let output = sortOutputFolder
		else
		{
			return
		}
		runSort(SortRequest(
			inputFolder: input,
			outputFolder: output,
			overlap: overlap,
			maxPerGroup: maxPerGroup,
			minPerGroup: minPerGroup,
			timeGap: timeGap,
			link: linkStrategy,
			recursive: sortRecursive,
			dryRun: sortDryRun))
	}

	/// URL スキーム（photogrammetry://process?... / photogrammetry://sort?...）
	/// からの起動。解釈は Core の APICommand に委譲し、成功したらフォームへ
	/// 反映してそのまま実行する。
	func handle(url: URL)
	{
		do
		{
			let command = try APICommand.parse(url: url)
			appendLog("URL コマンドを受信: \(url.absoluteString)")
			switch command
			{
				case .process(let request):
					inputFolder = request.inputFolder
					outputFile = request.outputFile
					detail = request.detail
					sampleOrdering = request.sampleOrdering
					featureSensitivity = request.featureSensitivity
					subject = request.subject
					run(request)
				case .sort(let request):
					// フォームにも反映する（何が実行されたのか画面で分かるように）。
					mode = .sort
					inputFolder = request.inputFolder
					sortOutputFolder = request.outputFolder
					overlap = request.overlap
					maxPerGroup = request.maxPerGroup
					minPerGroup = request.minPerGroup
					timeGap = request.timeGap
					linkStrategy = request.link
					sortRecursive = request.recursive
					sortDryRun = request.dryRun
					runSort(request)
			}
		}
		catch
		{
			appendLog("URL コマンドを解釈できません: \(error.localizedDescription)")
		}
	}

	/// 写真の仕分け。再構成と違って RealityKit を使わないため
	/// `CorePhotogrammetry` の異常終了に巻き込まれる恐れがなく、別プロセスに
	/// する必要がない（別プロセス化が要るのは生成だけ。CLAUDE.md 参照）。
	/// 判断はすべて Core の PhotoSorter にあり、ここは進捗を映すだけ。
	func runSort(_ request: SortRequest)
	{
		guard !isProcessing
		else
		{
			appendLog("すでに処理中です。")
			return
		}

		isProcessing = true
		progress = 0
		processingStage = nil
		estimatedRemainingTime = nil
		loggedStage = nil
		canPurgeModelCache = false
		lastOutput = nil
		statusText = "写真を仕分けています…"
		appendLog("仕分け開始: \(request.inputFolder.path) → \(request.outputFolder.path)")

		let sink: @Sendable (ReconstructionEvent) -> Void =
		{ [weak self] event in
			Task
			{ @MainActor in
				self?.handle(event: event)
			}
		}
		let sorter = PhotoSorter(hardwareLimit: ReconstructionService.maximumImageCount)
		let cancellation = SortCancellation()
		sortCancellation = cancellation

		// 解析は数百〜数千枚のデコードで数分かかる。メインアクターを塞がない
		// ように裏で走らせる。
		Task.detached(priority: .userInitiated)
		{
			let failure: Error?
			do
			{
				try sorter.run(request, cancellation: cancellation, progress: sink)
				failure = nil
			}
			catch
			{
				failure = error
			}
			await MainActor.run
			{ [weak self] in
				guard let self
				else
				{
					return
				}
				switch failure
				{
					case .none:
						self.statusText = request.dryRun
							? "仕分けの確認が完了しました（ファイルは作成していません）"
							: "仕分け完了"
						self.appendLog("仕分け完了")
					case .some(let error) where (error as? SortError) == .cancelled:
						// 中断は失敗ではない。生成と同じ表現に揃える。
						self.statusText = "キャンセルされました"
						self.appendLog("キャンセルされました")
					case .some(let error):
						self.statusText = "エラー: \(Self.summary(of: error))"
						self.appendLog("エラー: \(ErrorDetails.describe(error))")
				}
				self.isProcessing = false
				self.sortCancellation = nil
			}
		}
	}

	func run(_ request: ReconstructionRequest)
	{
		guard !isProcessing
		else
		{
			appendLog("すでに処理中です。")
			return
		}
		guard ReconstructionService.isSupported
		else
		{
			statusText = "この Mac は Object Capture に対応していません。"
			return
		}

		isProcessing = true
		progress = 0
		processingStage = nil
		estimatedRemainingTime = nil
		loggedStage = nil
		statusText = "処理中…"
		canPurgeModelCache = false
		lastOutput = nil
		appendLog("開始: \(request.inputFolder.path) → \(request.outputFile.path)")

		// 実行方式（別プロセス / 同一プロセス）の判断は Core の
		// ReconstructionService が持つ。ここは結果を表示するだけ。
		let service = ReconstructionService()
		self.service = service

		// イベントはエンジンのスレッド（別プロセス実行なら読み取りスレッド）から
		// 届くので、メインアクターへ持ち上げてから UI に反映する。self の弱参照は
		// このクロージャで 1 回だけ捕らえる（入れ子で捕らえ直さない）。
		let sink: @Sendable (ReconstructionEvent) -> Void =
		{ [weak self] event in
			Task
			{ @MainActor in
				self?.handle(event: event)
			}
		}

		// self は @MainActor なので、この Task の本体はメインアクター上で走る。
		// process の await 中だけ裏へ hop する。
		Task
		{ [weak self] in
			do
			{
				try await service.process(request, onEvent: sink)
				self?.statusText = "完了"
				self?.appendLog("完了")
			}
			catch
			{
				// ログには domain / code / userInfo まで残す（「エラー 6」のような
				// 表示だけでは原因調査ができないため）。
				self?.statusText = "エラー: \(Self.summary(of: error))"
				self?.appendLog("エラー: \(ErrorDetails.describe(error))")
				self?.canPurgeModelCache =
					(error as? HelperProcessError)?.isModelCacheFailure ?? false
			}
			self?.isProcessing = false
			self?.service = nil
		}
	}

	func cancel()
	{
		appendLog("キャンセルを要求しました…")
		// 走っているのは生成か仕分けのどちらか一方（isProcessing で排他）。
		service?.cancel()
		sortCancellation?.cancel()
	}

	/// 壊れた ML モデルのキャッシュを削除する（OS が次回作り直す）。
	/// 削除する場所と可否の判断は Core の ModelCache が持つ。
	func purgeModelCache()
	{
		do
		{
			let path = ModelCache.directory()?.path ?? ""
			if try ModelCache.purge()
			{
				appendLog("ML モデルのキャッシュを削除しました: \(path)")
				statusText = "キャッシュを削除しました。もう一度「3D モデルを生成」を実行してください。"
			}
			else
			{
				appendLog("ML モデルのキャッシュはありませんでした: \(path)")
				statusText = "削除するキャッシュはありませんでした。"
			}
			canPurgeModelCache = false
		}
		catch
		{
			appendLog("ML モデルのキャッシュを削除できません: \(ErrorDetails.describe(error))")
			statusText = "エラー: \(Self.summary(of: error))"
		}
	}

	/// ステータス行は 1 行なので、複数行のエラー（ヘルパーの異常終了は対処方法
	/// まで含む）は先頭行だけを出す。全文はログ欄に残る。
	static func summary(of error: Error) -> String
	{
		error.localizedDescription
			.split(separator: "\n", omittingEmptySubsequences: false)
			.first
			.map(String.init) ?? ""
	}

	// -----------------------------------------------------------------
	// イベント・ログ
	// -----------------------------------------------------------------

	private func handle(event: ReconstructionEvent)
	{
		switch event
		{
			case .progress(let fraction):
				progress = fraction
			case .stage(let stage):
				processingStage = stage
				// 段階の変わり目だけログに残す。失敗したときに「どの段階まで
				// 進んだか」が分かると原因の切り分けができる。
				if stage != loggedStage
				{
					loggedStage = stage
					appendLog("段階: \(stage.displayName)")
				}
			case .estimatedRemainingTime(let remaining):
				estimatedRemainingTime = remaining
			case .note(let message):
				appendLog(message)
			case .completed(let url):
				appendLog("出力: \(url.path)")
				lastOutput = url
			case .cancelled:
				statusText = "キャンセルされました"
				appendLog("キャンセルされました")
		}
	}

	private func appendLog(_ line: String)
	{
		logLines.append(line)
		// ログは画面表示用なので溜め込みすぎない。
		if logLines.count > 500
		{
			logLines.removeFirst(logLines.count - 500)
		}
	}
}
