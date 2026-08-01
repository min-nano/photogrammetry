//
//  ReconstructionViewModel.swift
//
//  生成画面の状態管理。PhotogrammetryEngine の進捗イベントをメインアクターへ
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

	private var engine: PhotogrammetryEngine?

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
		guard PhotogrammetryEngine.isSupported
		else
		{
			statusText = "この Mac は Object Capture に対応していません。"
			return
		}

		isProcessing = true
		progress = 0
		statusText = "処理中…"
		appendLog("開始: \(request.inputFolder.path) → \(request.outputFile.path)")

		let engine = PhotogrammetryEngine()
		self.engine = engine

		// self は @MainActor なので、この Task の本体はメインアクター上で走る。
		// engine.process の await 中だけ裏へ hop し、イベントは Task { @MainActor }
		// で持ち上げる。
		Task
		{ [weak self] in
			do
			{
				try await engine.process(request)
				{ event in
					Task
					{ @MainActor [weak self] in
						self?.handle(event: event)
					}
				}
				self?.statusText = "完了"
				self?.appendLog("完了")
			}
			catch
			{
				// ログには domain / code / userInfo まで残す（「エラー 6」のような
				// 表示だけでは原因調査ができないため）。
				self?.statusText = "エラー: \(error.localizedDescription)"
				self?.appendLog("エラー: \(ErrorDetails.describe(error))")
			}
			self?.isProcessing = false
			self?.engine = nil
		}
	}

	func cancel()
	{
		appendLog("キャンセルを要求しました…")
		engine?.cancel()
	}

	// -----------------------------------------------------------------
	// イベント・ログ
	// -----------------------------------------------------------------

	private func handle(event: PhotogrammetryEngine.Event)
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
