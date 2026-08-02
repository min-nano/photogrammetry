//
//  ContentView.swift
//
//  メイン画面。入力フォルダ・出力先・品質を選んで生成を実行する。
//  状態はすべて ReconstructionViewModel が持ち、ここは表示だけ。
//

import PhotogrammetryCore
import PhotogrammetryUpdater
import SwiftUI

struct ContentView: View
{
	@EnvironmentObject private var model: ReconstructionViewModel
	@EnvironmentObject private var updater: UpdaterViewModel

	var body: some View
	{
		VStack(alignment: .leading, spacing: 12)
		{
			if !ReconstructionService.isSupported
			{
				Label(
					"この Mac は Object Capture に対応していません（モデル生成は実行できません）。",
					systemImage: "exclamationmark.triangle")
					.foregroundColor(.orange)
			}

			GroupBox("入力（写真フォルダ）")
			{
				HStack
				{
					Text(model.inputFolder?.path ?? "未選択")
						.lineLimit(1)
						.truncationMode(.middle)
						.foregroundColor(model.inputFolder == nil ? .secondary : .primary)
					Spacer()
					Button("選択…")
					{
						model.chooseInputFolder()
					}
					.disabled(model.isProcessing)
				}
				.padding(4)
			}

			GroupBox("出力（3D モデル .usdz）")
			{
				HStack
				{
					Text(model.outputFile?.path ?? "未選択")
						.lineLimit(1)
						.truncationMode(.middle)
						.foregroundColor(model.outputFile == nil ? .secondary : .primary)
					Spacer()
					Button("選択…")
					{
						model.chooseOutputFile()
					}
					.disabled(model.isProcessing)
				}
				.padding(4)
			}

			GroupBox("品質")
			{
				VStack(alignment: .leading, spacing: 8)
				{
					Picker("対象の種類", selection: $model.subject)
					{
						ForEach(ReconstructionRequest.SubjectKind.allCases, id: \.self)
						{ value in
							Text(Self.label(for: value)).tag(value)
						}
					}
					Picker("詳細度", selection: $model.detail)
					{
						ForEach(ReconstructionRequest.Detail.allCases, id: \.self)
						{ value in
							Text(Self.label(for: value)).tag(value)
						}
					}
					Picker("写真の並び", selection: $model.sampleOrdering)
					{
						ForEach(ReconstructionRequest.SampleOrdering.allCases, id: \.self)
						{ value in
							Text(Self.label(for: value)).tag(value)
						}
					}
					Picker("特徴点検出", selection: $model.featureSensitivity)
					{
						ForEach(ReconstructionRequest.FeatureSensitivity.allCases, id: \.self)
						{ value in
							Text(Self.label(for: value)).tag(value)
						}
					}
				}
				.padding(4)
				.disabled(model.isProcessing)
			}

			HStack(spacing: 12)
			{
				if model.isProcessing
				{
					Button("キャンセル")
					{
						model.cancel()
					}
					ProgressView(value: model.progress)
						.frame(maxWidth: .infinity)
					Text(String(format: "%3.0f%%", model.progress * 100))
						.monospacedDigit()
				}
				else
				{
					Button("3D モデルを生成")
					{
						model.start()
					}
					.keyboardShortcut(.defaultAction)
					.disabled(!model.canStart)
					Spacer()
				}
			}

			if !model.statusText.isEmpty
			{
				Text(model.statusText)
					.font(.callout)
					.foregroundColor(.secondary)
			}

			// ML モデルのキャッシュ破損で落ちたときだけ出す復旧ボタン。
			// この失敗は消せば必ず直るので、ターミナルを使わせない。
			if model.canPurgeModelCache
			{
				Button("ML モデルのキャッシュを削除")
				{
					model.purgeModelCache()
				}
				.disabled(model.isProcessing)
			}

			GroupBox("ログ")
			{
				ScrollView
				{
					VStack(alignment: .leading, spacing: 2)
					{
						ForEach(Array(model.logLines.enumerated()), id: \.offset)
						{ _, line in
							Text(line)
								.font(.system(.caption, design: .monospaced))
								.frame(maxWidth: .infinity, alignment: .leading)
						}
					}
					.padding(4)
				}
				.frame(minHeight: 120, maxHeight: 220)
			}
		}
		.padding()
		.frame(minWidth: 600, minHeight: 520)
		.alert(
			"新しいビルドがあります",
			isPresented: $updater.showUpdateAlert,
			presenting: updater.pendingUpdate,
			actions: { channel in
				Button("アップデート") {
					Task {
						await updater.installUpdate(channel)
					}
				}
				Button("後で", role: .cancel) {}
			},
			message: { channel in
				Text("\(channel.displayName) の最新ビルド \(channel.commit) に更新できます。")
			})
	}

	// 表示ラベル（rawValue は API の語彙なので、日本語表示はここだけの都合）。
	private static func label(for value: ReconstructionRequest.Detail) -> String
	{
		switch value
		{
			case .preview: return "プレビュー"
			case .reduced: return "低"
			case .medium: return "中"
			case .full: return "高"
			case .raw: return "最大（raw）"
		}
	}

	private static func label(for value: ReconstructionRequest.SampleOrdering) -> String
	{
		switch value
		{
			case .unordered: return "順不同"
			case .sequential: return "連続撮影"
		}
	}

	private static func label(for value: ReconstructionRequest.FeatureSensitivity) -> String
	{
		switch value
		{
			case .normal: return "標準"
			case .high: return "高"
		}
	}

	private static func label(for value: ReconstructionRequest.SubjectKind) -> String
	{
		switch value
		{
			case .object: return "物体（単一の対象物）"
			case .scene: return "シーン・建物（マスキング無効）"
		}
	}
}
