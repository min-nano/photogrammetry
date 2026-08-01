//
//  UpdaterViewModel.swift
//
//  自動アップデートの状態管理。チャンネル一覧・選択ブランチ・確認結果を UI へ
//  公開し、実際の取得・差し替えは PhotogrammetryUpdater の UpdaterService へ
//  委譲する。
//
//  「チャンネル = ブランチ」: 設定画面でブランチを選ぶと、そのブランチの最新の
//  リリース（main → stable）またはプレリリース（それ以外 → dev-<slug>）へ
//  アップデートする。
//

import AppKit
import Foundation
import PhotogrammetryUpdater
import SwiftUI

@MainActor
final class UpdaterViewModel: ObservableObject
{
	private static let branchKey = "updateBranch"
	private static let autoCheckKey = "autoCheckUpdates"

	private let service = UpdaterService()
	private let defaults = UserDefaults.standard

	/// 使用するバージョン（ブランチ）。既定はこのビルドの出自ブランチ、
	/// それも無ければ main。
	@Published var selectedBranch: String
	{
		didSet
		{
			defaults.set(selectedBranch, forKey: Self.branchKey)
		}
	}

	/// 起動時に自動で更新を確認するか。
	@Published var autoCheck: Bool
	{
		didSet
		{
			defaults.set(autoCheck, forKey: Self.autoCheckKey)
		}
	}

	@Published var channels: [UpdateChannel] = []
	@Published var statusText = ""
	@Published var pendingUpdate: UpdateChannel?
	@Published var showUpdateAlert = false
	@Published var isBusy = false

	init()
	{
		let defaults = UserDefaults.standard
		// service（stored property）へは全プロパティ初期化前に触れないので、
		// ブランチスタンプはここで直接読む。
		let stamped = Bundle.main.object(forInfoDictionaryKey: "GitBranch") as? String
		let installedBranch = (stamped?.isEmpty == false && stamped != "unknown") ? stamped : nil
		self.selectedBranch = defaults.string(forKey: Self.branchKey) ?? installedBranch ?? "main"
		self.autoCheck = defaults.object(forKey: Self.autoCheckKey) == nil
			? true
			: defaults.bool(forKey: Self.autoCheckKey)
	}

	// -----------------------------------------------------------------
	// 表示用
	// -----------------------------------------------------------------

	var installedCommitText: String { service.installedCommit ?? "（開発実行）" }
	var installedBranchText: String { service.installedBranch ?? "（開発実行）" }
	var installedChannelText: String { service.installedChannel ?? "（開発実行）" }

	/// 設定画面のブランチ Picker の選択肢。チャンネル一覧が未取得でも現在の
	/// 選択値は必ず含める（Picker の selection が選択肢に無いと表示が壊れる）。
	var branchChoices: [String]
	{
		var list = channels.map(\.branch)
		if !list.contains(selectedBranch)
		{
			list.insert(selectedBranch, at: 0)
		}
		return list
	}

	func displayName(for branch: String) -> String
	{
		UpdateFeed.channel(named: branch, in: channels)?.displayName ?? branch
	}

	// -----------------------------------------------------------------
	// 確認・更新
	// -----------------------------------------------------------------

	func refreshChannels() async
	{
		statusText = "チャンネル一覧を取得中…"
		do
		{
			channels = try await service.fetchChannels()
			statusText = "チャンネル \(channels.count) 件を取得しました。"
		}
		catch
		{
			statusText = "取得に失敗しました: \(error.localizedDescription)"
		}
	}

	/// 選択中ブランチの最新ビルドとインストール済みコミットを比較する。
	func checkNow() async
	{
		await refreshChannels()
		guard let channel = UpdateFeed.channel(named: selectedBranch, in: channels)
		else
		{
			statusText = "ブランチ \(selectedBranch) のビルドが見つかりません。"
			return
		}
		if UpdateFeed.updateAvailable(installed: service.installedCommit, channel: channel)
		{
			statusText = "新しいビルドがあります（\(channel.commit)）。"
			offerUpdate(channel)
		}
		else
		{
			statusText = "最新です（\(channel.commit)）。"
		}
	}

	/// 起動時の自動確認。オフライン等の失敗は黙って無視する。
	func autoCheckOnLaunch() async
	{
		guard autoCheck
		else
		{
			return
		}
		guard let fetched = try? await service.fetchChannels()
		else
		{
			return
		}
		channels = fetched
		guard let channel = UpdateFeed.channel(named: selectedBranch, in: fetched)
		else
		{
			return
		}
		if UpdateFeed.updateAvailable(installed: service.installedCommit, channel: channel)
		{
			offerUpdate(channel)
		}
	}

	private func offerUpdate(_ channel: UpdateChannel)
	{
		pendingUpdate = channel
		showUpdateAlert = true
	}

	/// ダウンロード → 差し替えスクリプト起動 → アプリ終了。スクリプト側が
	/// 終了を待って置き換え、新しいビルドを再起動する。
	func installUpdate(_ channel: UpdateChannel) async
	{
		isBusy = true
		statusText = "ダウンロード中…"
		do
		{
			let staged = try await service.downloadAndStage(channel)
			try service.launchInstaller(staged)
			statusText = "更新を適用するため再起動します…"
			// スクリプトの起動が確実に済むよう一拍おいてから終了する。
			try? await Task.sleep(nanoseconds: 300_000_000)
			NSApplication.shared.terminate(nil)
		}
		catch
		{
			statusText = "更新に失敗しました: \(error.localizedDescription)"
		}
		isBusy = false
	}
}
