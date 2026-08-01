//
//  SettingsView.swift
//
//  設定画面（メニュー「Photogrammetry > 設定…」）。自動アップデートの
//  チャンネル（＝ブランチ）選択と手動確認を提供する。
//

import PhotogrammetryUpdater
import SwiftUI

struct SettingsView: View
{
	@EnvironmentObject private var updater: UpdaterViewModel

	var body: some View
	{
		Form
		{
			Section("アップデート")
			{
				Picker("使用するバージョン（ブランチ）", selection: $updater.selectedBranch)
				{
					ForEach(updater.branchChoices, id: \.self)
					{ branch in
						Text(updater.displayName(for: branch)).tag(branch)
					}
				}
				Toggle("起動時に更新を自動確認する", isOn: $updater.autoCheck)

				HStack
				{
					Button("一覧を更新")
					{
						Task
						{
							await updater.refreshChannels()
						}
					}
					Button("今すぐ更新を確認")
					{
						Task
						{
							await updater.checkNow()
						}
					}
					if updater.isBusy
					{
						ProgressView()
							.controlSize(.small)
					}
				}

				if !updater.statusText.isEmpty
				{
					Text(updater.statusText)
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}

			Section("このビルド")
			{
				LabeledContent("コミット", value: updater.installedCommitText)
				LabeledContent("ブランチ", value: updater.installedBranchText)
				LabeledContent("チャンネル", value: updater.installedChannelText)
			}
		}
		.formStyle(.grouped)
		.frame(width: 480)
		.task
		{
			// 設定を開いたときにブランチ一覧を最新化する（失敗は statusText に出る）。
			await updater.refreshChannels()
		}
	}
}
