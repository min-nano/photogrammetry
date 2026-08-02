//
//  InputInspection.swift
//
//  入力フォルダの事前チェック。生成を始める前に「失敗・クラッシュの典型原因」を
//  ログへ出しておくためのもので、処理そのものは止めない（上限や実体の要不要を
//  ここで確実に断定はできず、止めると使える組み合わせまで塞いでしまうため）。
//
//  判定は数値と文字列だけで行い（inspect が集めた事実を notes が文章にする）、
//  ファイルシステムを見る部分と分けてある。こうしておくと文章のルールを
//  単体テストで固定できる。
//

import Foundation

public enum InputInspection
{
	/// 入力フォルダについて事前に分かる事実。
	public struct Summary: Equatable, Sendable
	{
		/// 画像として数えられたファイル数。
		public var imageCount: Int
		/// iCloud Drive 上で実体が未ダウンロードのプレースホルダ（`.icloud`）の数。
		public var placeholderCount: Int
		/// フォルダがクラウド同期領域（iCloud Drive）にあるか。
		public var isCloudStorage: Bool
		/// この Mac のハードウェア上限（PhotogrammetrySession.limits）。
		public var maximumImageCount: Int

		public init(
			imageCount: Int,
			placeholderCount: Int = 0,
			isCloudStorage: Bool = false,
			maximumImageCount: Int)
		{
			self.imageCount = imageCount
			self.placeholderCount = placeholderCount
			self.isCloudStorage = isCloudStorage
			self.maximumImageCount = maximumImageCount
		}
	}

	/// 実体が未ダウンロードの iCloud ファイルは `.名前.拡張子.icloud` という
	/// 隠しプレースホルダとして見える。この名前を数えるだけで「まだ落ちてきて
	/// いない写真がある」ことが分かる。
	public static let placeholderExtension = "icloud"

	/// パスがクラウド同期領域（iCloud Drive）かどうか。iCloud Drive の実体は
	/// `~/Library/Mobile Documents/com~apple~CloudDocs/…` に置かれる。
	public static func isCloudStoragePath(_ path: String) -> Bool
	{
		path.contains("/Library/Mobile Documents/")
	}

	/// 入力フォルダを走査して Summary を作る（ファイルシステムを見るのはここだけ）。
	public static func inspect(
		folder: URL,
		maximumImageCount: Int,
		fileManager: FileManager = .default) -> Summary
	{
		let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
		var images = 0
		var placeholders = 0
		for name in names
		{
			let extensionName = (name as NSString).pathExtension.lowercased()
			if extensionName == placeholderExtension
			{
				placeholders += 1
			}
			else if ReconstructionRequest.imageExtensions.contains(extensionName)
			{
				images += 1
			}
		}
		return Summary(
			imageCount: images,
			placeholderCount: placeholders,
			isCloudStorage: isCloudStoragePath(folder.path),
			maximumImageCount: maximumImageCount)
	}

	/// Summary をログ行（note）へ変換する。1 行目は必ず枚数の事実で、以降に
	/// 当てはまる警告が続く。
	public static func notes(for summary: Summary) -> [String]
	{
		var notes: [String] = []

		if summary.imageCount > summary.maximumImageCount
		{
			// 上限超えはアライメント失敗（CoreOC エラー 6）の典型原因。
			notes.append(
				"警告: 入力画像 \(summary.imageCount) 枚はこの Mac の上限 "
					+ "\(summary.maximumImageCount) 枚を超えています。"
					+ "失敗する場合は写真を \(summary.maximumImageCount) 枚以下に減らしてください。")
		}
		else
		{
			notes.append(
				"入力画像: \(summary.imageCount) 枚（この Mac の上限: "
					+ "\(summary.maximumImageCount) 枚）")
		}

		if summary.imageCount == 0
		{
			notes.append(
				"警告: 画像ファイルが 1 枚も見つかりません。写真が直下にあるフォルダを"
					+ "選んでください（サブフォルダの中は対象外です）。")
		}

		if summary.placeholderCount > 0
		{
			// 実体が無いまま読ませると、処理途中で読み取りに失敗して
			// CorePhotogrammetry 側が異常終了することがある。
			notes.append(
				"警告: iCloud の未ダウンロードファイル（.icloud）が "
					+ "\(summary.placeholderCount) 個あります。Finder でフォルダを"
					+ "「今すぐダウンロード」するか、ローカル（例: ~/Pictures）へコピーしてから"
					+ "実行してください。")
		}
		else if summary.isCloudStorage
		{
			notes.append(
				"注意: 入力フォルダは iCloud Drive 上にあります。処理中にファイルの実体が"
					+ "退避されると読み取りに失敗するため、ローカル（例: ~/Pictures）へ"
					+ "コピーしてから実行するのが確実です。")
		}

		return notes
	}
}
