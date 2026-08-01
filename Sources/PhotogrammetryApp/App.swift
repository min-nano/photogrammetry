//
//  App.swift
//
//  GUI アプリのエントリポイント。GUI はロジックを持たない薄いシェルで、
//  実処理は PhotogrammetryCore（生成）と PhotogrammetryUpdater（更新）に委譲する。
//
//  外部アプリ連携: Info.plist の CFBundleURLTypes で photogrammetry:// を宣言して
//  おり、onOpenURL 経由で APICommand（Core）が解釈する。つまり
//    open "photogrammetry://process?input=%2Fpath%2Fphotos&output=%2Fpath%2Fmodel.usdz"
//  だけで他アプリからモデル生成を起動できる。
//

import PhotogrammetryCore
import SwiftUI

@main
struct PhotogrammetryMainApp: App
{
	@StateObject private var model = ReconstructionViewModel()
	@StateObject private var updater = UpdaterViewModel()

	var body: some Scene
	{
		WindowGroup
		{
			ContentView()
				.environmentObject(model)
				.environmentObject(updater)
				.onOpenURL
				{ url in
					model.handle(url: url)
				}
				.task
				{
					// 起動時の自動更新確認（設定でオフにできる）。失敗しても黙る
					// — オフライン時に起動のたびエラーを見せない。
					await updater.autoCheckOnLaunch()
				}
		}

		Settings
		{
			SettingsView()
				.environmentObject(updater)
		}
	}
}
