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
			// 生成と仕分けはどちらも「写真フォルダを渡す」ところから始まるので
			// 1 つの画面で切り替える。仕分けは Object Capture 非対応の Mac でも
			// 動くため、警告は生成のときだけ出す。
			Picker("", selection: $model.mode)
			{
				ForEach(ReconstructionViewModel.Mode.allCases)
				{ value in
					Text(value.displayName).tag(value)
				}
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.disabled(model.isProcessing)

			if model.mode == .reconstruct, !ReconstructionService.isSupported
			{
				Label(
					"この Mac は Object Capture に対応していません（モデル生成は実行できません）。"
						+ "写真の仕分けは実行できます。",
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

			if model.mode == .reconstruct
			{
				reconstructionForm
			}
			else
			{
				sortForm
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
				else if model.mode == .reconstruct
				{
					Button("3D モデルを生成")
					{
						model.start()
					}
					.keyboardShortcut(.defaultAction)
					.disabled(!model.canStart)
					Spacer()
				}
				else
				{
					Button(model.sortDryRun ? "仕分けを確認" : "写真を仕分ける")
					{
						model.startSort()
					}
					.keyboardShortcut(.defaultAction)
					.disabled(!model.canStartSort)
					Spacer()
				}
			}

			// 段階・残り時間はプログレスバーの下に出す。建築規模では 1 回の
			// 生成に数時間かかるので、割合だけでは進んでいるのか分からない。
			if model.isProcessing, let detail = model.progressDetailText
			{
				Text(detail)
					.font(.callout)
					.foregroundColor(.secondary)
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

			// 仕分けの結果は group-01 … を開いて中身を見に行くことになるので、
			// Finder まで繋いでおく（ログのパスを手で辿らせない）。
			if !model.isProcessing, model.lastOutput != nil
			{
				Button("Finder で表示")
				{
					model.revealLastOutput()
				}
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
		// 仕分けのフォームは項目が多いので、生成のときより高さが要る。
		.frame(minWidth: 620, minHeight: 620)
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

	// -----------------------------------------------------------------
	// 生成のフォーム
	// -----------------------------------------------------------------

	@ViewBuilder
	private var reconstructionForm: some View
	{
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
	}

	// -----------------------------------------------------------------
	// 仕分けのフォーム
	//
	// 出しているのは「現場で意味が変わる」設定だけ。ブレや結合スコアの閾値は
	// **その現場の分布から自動決定する**のが設計の核なので、GUI には出さない
	// （上書きは CLI / URL スキームの逃げ道に任せる）。
	// -----------------------------------------------------------------

	@ViewBuilder
	private var sortForm: some View
	{
		GroupBox("仕分け先（フォルダ）")
		{
			VStack(alignment: .leading, spacing: 4)
			{
				HStack
				{
					Text(model.sortOutputFolder?.path ?? "未選択")
						.lineLimit(1)
						.truncationMode(.middle)
						.foregroundColor(model.sortOutputFolder == nil ? .secondary : .primary)
					Spacer()
					Button("選択…")
					{
						model.chooseSortOutputFolder()
					}
					.disabled(model.isProcessing)
				}
				Text("group-01 … と manifest.json を作ります（空のフォルダを指定してください）。")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.padding(4)
		}

		GroupBox("仕分けの設定")
		{
			VStack(alignment: .leading, spacing: 8)
			{
				Stepper(
					"隣接グループで共有する枚数: \(model.overlap)",
					value: $model.overlap,
					in: 0 ... 60)
				Text("あとで複数のモデルを 1 つの座標系へ合成するための手がかりです。多いほど安定します。")
					.font(.caption)
					.foregroundColor(.secondary)

				Stepper(
					"1 グループの上限: \(model.maxPerGroup) 枚",
					value: $model.maxPerGroup,
					in: 20 ... 400,
					step: 10)
				Stepper(
					"1 グループの下限: \(model.minPerGroup) 枚",
					value: $model.minPerGroup,
					in: 1 ... 100)
				Stepper(
					"区切りとみなす撮影間隔: \(Int(model.timeGap)) 秒",
					value: $model.timeGap,
					in: 30 ... 1800,
					step: 30)

				Picker("配置方法", selection: $model.linkStrategy)
				{
					ForEach(LinkStrategy.allCases, id: \.self)
					{ value in
						Text(Self.label(for: value)).tag(value)
					}
				}
				Toggle("見た目から同じ場所を見分ける", isOn: $model.visualEvidence)
				Text("同じ部屋・同じ面を写した写真をまとめます。部屋を行き来しながら"
					+ "撮った写真ほど効きます（1 枚あたりの解析は少し遅くなります）。")
					.font(.caption)
					.foregroundColor(.secondary)

				Toggle("サブフォルダも対象にする", isOn: $model.sortRecursive)
				Toggle("確認のみ（ファイルを作らず診断だけ）", isOn: $model.sortDryRun)
				Text("撮り直しが要るかはここで分かります。仕分けは数分ですが、再構成は数時間かかります。")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.padding(4)
			.disabled(model.isProcessing)
		}
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

	private static func label(for value: LinkStrategy) -> String
	{
		switch value
		{
			case .hardlink: return "ハードリンク（容量を増やさない）"
			case .copy: return "コピー（元と切り離す）"
			case .symlink: return "シンボリックリンク（元を消すと壊れる）"
		}
	}
}
