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
					Button(model.startButtonTitle)
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
		// どちらのフォームも項目が多い（生成は出力が 2 つ、仕分けは設定が多い）。
		.frame(minWidth: 620, minHeight: 700)
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
		// モデルも点群も任意の出力で、少なくとも一方を選べば実行できる
		// （規則は Core の ReconstructionRequest.validate が持つ）。モデルを
		// 解除すれば「点群だけ」になる。
		GroupBox("出力（3D モデル .usdz）")
		{
			HStack
			{
				Text(model.outputFile?.path ?? "書き出さない")
					.lineLimit(1)
					.truncationMode(.middle)
					.foregroundColor(model.outputFile == nil ? .secondary : .primary)
				Spacer()
				if model.outputFile != nil
				{
					Button("解除")
					{
						model.clearOutputFile()
					}
				}
				Button("選択…")
				{
					model.chooseOutputFile()
				}
			}
			.padding(4)
			.disabled(model.isProcessing)
		}

		// 点群はメッシュとは別の任意の出力。保存先を選ぶことが「書き出す」の
		// 指示そのものになるので、ON/OFF のフラグは別に持たない。
		GroupBox("出力（点群 .ply・任意）")
		{
			VStack(alignment: .leading, spacing: 4)
			{
				HStack
				{
					Text(model.pointCloudFile?.path ?? "書き出さない")
						.lineLimit(1)
						.truncationMode(.middle)
						.foregroundColor(model.pointCloudFile == nil ? .secondary : .primary)
					Spacer()
					if model.pointCloudFile != nil
					{
						Button("解除")
						{
							model.clearPointCloudFile()
						}
					}
					Button("選択…")
					{
						model.choosePointCloudFile()
					}
				}
				Text("位置合わせで得られた色つきの 3D 点を PLY で保存します"
					+ "（CloudCompare・MeshLab・CAD などで読めます）。")
					.font(.caption)
					.foregroundColor(.secondary)
				if model.outputFile == nil, model.pointCloudFile != nil
				{
					Text("3D モデルは書き出しません。メッシュ化・テクスチャ貼りの"
						+ "段階が省かれるぶん、点群だけの生成は速く終わります。")
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}
			.padding(4)
			.disabled(model.isProcessing)
		}

		// クラウド（iCloud Drive・Google ドライブなど）に置いたままの写真は、処理中に
		// 実体が退避されると読めなくなる。ローカルの入力では「切りたい人のための
		// 逃げ道」として選べるが、クラウド上の入力では ON 固定にする（判断は Core の
		// InputStaging.isRequired が持ち、ここは映すだけ）。
		GroupBox("写真の扱い")
		{
			VStack(alignment: .leading, spacing: 4)
			{
				Toggle(
					"写真をローカル（アプリのキャッシュ）へコピーしてから処理する",
					isOn: Binding(
						get: { model.stageInputLocallyEffective },
						set: { model.stageInputLocally = $0 }))
					.disabled(model.mustStageInput)
				if model.mustStageInput
				{
					Text("入力フォルダはクラウド上（iCloud Drive・Google ドライブなど）に"
						+ "あるため、コピーは必須です。")
						.font(.caption)
						.foregroundColor(.secondary)
				}
				Text("クラウド上の写真でも確実に読めます。"
					+ "コピーは処理が終わると自動的に削除されます。")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.padding(4)
			.disabled(model.isProcessing)
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
				// 詳細度はメッシュにしか効かない（点群のリクエストは詳細度を
				// 受け取らない）。点群だけを頼んでいるときは触らせない。
				Picker("詳細度", selection: $model.detail)
				{
					ForEach(ReconstructionRequest.Detail.allCases, id: \.self)
					{ value in
						Text(Self.label(for: value)).tag(value)
					}
				}
				.disabled(model.outputFile == nil)
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
