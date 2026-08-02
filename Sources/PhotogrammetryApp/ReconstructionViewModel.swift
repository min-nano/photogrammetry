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
	@Published var inputFolder: URL?
	@Published var outputFile: URL?
	@Published var detail: ReconstructionRequest.Detail = .medium
	@Published var sampleOrdering: ReconstructionRequest.SampleOrdering = .unordered
	@Published var featureSensitivity: ReconstructionRequest.FeatureSensitivity = .normal
	@Published var subject: ReconstructionRequest.SubjectKind = .object

	@Published var isProcessing = false
	@Published var progress: Double = 0
	@Published var statusText = ""
	@Published var logLines: [String] = []

	private var service: ReconstructionService?

	var canStart: Bool
	{
		inputFolder != nil && outputFile != nil && !isProcessing
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
		panel.message = "対象物を多方向から撮影した写真が入ったフォルダを選択してください"
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

	/// URL スキーム（photogrammetry://process?...）からの起動。解釈は Core の
	/// APICommand に委譲し、成功したらフォームへ反映してそのまま実行する。
	func handle(url: URL)
	{
		do
		{
			let request = try APICommand.parse(url: url)
			inputFolder = request.inputFolder
			outputFile = request.outputFile
			detail = request.detail
			sampleOrdering = request.sampleOrdering
			featureSensitivity = request.featureSensitivity
			subject = request.subject
			appendLog("URL コマンドを受信: \(url.absoluteString)")
			run(request)
		}
		catch
		{
			appendLog("URL コマンドを解釈できません: \(error.localizedDescription)")
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
		statusText = "処理中…"
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
			}
			self?.isProcessing = false
			self?.service = nil
		}
	}

	func cancel()
	{
		appendLog("キャンセルを要求しました…")
		service?.cancel()
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
			case .note(let message):
				appendLog(message)
			case .completed(let url):
				appendLog("出力: \(url.path)")
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
