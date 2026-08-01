//
//  UpdateFeed.swift
//
//  GitHub Releases API の応答（JSON）を「アップデートチャンネル一覧」へ解釈する
//  純ロジック。ネットワークにも AppKit にも依存しないので、JSON フィクスチャを
//  使って CI 上で単体テストできる（UpdaterService がネットワーク側の薄いグルー）。
//
//  リリースの構成は CI（.github/workflows/build.yml）と対になっている:
//
//    tag "stable"        main へのマージごとに作り直されるローリングリリース
//    tag "dev-<slug>"    ブランチ（PR）ごとのプレリリース。push のたびに作り直される
//
//  どちらもリリース本文（notes）に channel= / branch= / commit= / built= の
//  key=value 行を持ち、target_commitish にビルド元コミットが入る。
//  「チャンネル = ブランチ」であり、設定画面のブランチ選択はこの一覧から作る。
//

import Foundation

/// 1 つのアップデートチャンネル（= 1 ブランチの最新ビルド）。
public struct UpdateChannel: Equatable, Sendable
{
	/// ビルド元ブランチ。"main" が安定版、それ以外は開発版。
	public let branch: String
	/// リリースのタグ（"stable" または "dev-<slug>"）。
	public let tag: String
	/// GitHub 上でプレリリース扱いか（dev-* は true）。
	public let isPrerelease: Bool
	/// ビルド元コミット（7 桁短縮）。インストール済みビルドとの比較に使う。
	public let commit: String
	/// Photogrammetry.app.zip のダウンロード URL。
	public let assetURL: URL
	/// リリースのタイトル（表示用）。
	public let title: String
	/// ビルド時刻（notes の built= 行。無ければ nil）。
	public let builtAt: String?

	/// 設定画面のブランチ選択に出す表示名。
	public var displayName: String
	{
		branch == "main" ? "main（安定版）" : "\(branch)（開発版）"
	}

	public init(
		branch: String, tag: String, isPrerelease: Bool, commit: String,
		assetURL: URL, title: String, builtAt: String?)
	{
		self.branch = branch
		self.tag = tag
		self.isPrerelease = isPrerelease
		self.commit = commit
		self.assetURL = assetURL
		self.title = title
		self.builtAt = builtAt
	}
}

public enum UpdateFeed
{
	/// リリースに添付される GUI アプリのアセット名（build.yml と一致させる）。
	public static let appAssetName = "Photogrammetry.app.zip"

	/// releases API（GET /repos/{owner}/{repo}/releases）の JSON からチャンネル
	/// 一覧を作る。stable / dev-* 以外のタグ、アプリのアセットが無いリリースは
	/// 黙って除外する（更新先として提示できないため）。結果は stable を先頭に、
	/// 開発版はブランチ名順 — 入力順（API の返却順）に依存しない決定的な並びにする。
	public static func channels(fromReleasesJSON data: Data) throws -> [UpdateChannel]
	{
		let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
		var result: [UpdateChannel] = []
		for release in releases
		{
			let isStable = release.tagName == "stable"
			let isDev = release.tagName.hasPrefix("dev-")
			guard isStable || isDev
			else
			{
				continue
			}

			let body = release.body ?? ""
			var branch = value(of: "branch", in: body)
			if branch.isEmpty
			{
				// notes が欠けていてもタグから推定できるようにしておく
				// （dev-<slug> の slug はブランチ名を記号置換したもの）。
				branch = isStable ? "main" : String(release.tagName.dropFirst("dev-".count))
			}

			var commit = value(of: "commit", in: body)
			if commit.isEmpty
			{
				commit = release.targetCommitish ?? ""
			}
			commit = String(commit.prefix(7))

			guard
				let asset = release.assets.first(where: { $0.name == appAssetName }),
				let assetURL = URL(string: asset.browserDownloadURL)
			else
			{
				continue
			}

			let builtAt = value(of: "built", in: body)
			result.append(UpdateChannel(
				branch: branch,
				tag: release.tagName,
				isPrerelease: release.prerelease,
				commit: commit,
				assetURL: assetURL,
				title: release.name ?? release.tagName,
				builtAt: builtAt.isEmpty ? nil : builtAt))
		}
		result.sort
		{ a, b in
			if a.tag == "stable"
			{
				return true
			}
			if b.tag == "stable"
			{
				return false
			}
			return a.branch < b.branch
		}
		return result
	}

	/// インストール済みコミットとチャンネルの最新コミットを比べ、更新すべきか
	/// 判定する。リリースはローリング（削除して作り直し）なので「より新しいか」
	/// ではなく「異なるか」で判定する。インストール情報が無い（開発実行や
	/// スタンプ無しビルド）場合は常に更新を提案する。
	public static func updateAvailable(installed: String?, channel: UpdateChannel) -> Bool
	{
		guard let installed, !installed.isEmpty, installed != "unknown"
		else
		{
			return true
		}
		return String(installed.prefix(7)) != String(channel.commit.prefix(7))
	}

	/// ブランチ名でチャンネルを引く（設定画面の選択値 → チャンネル解決）。
	public static func channel(named branch: String, in channels: [UpdateChannel])
		-> UpdateChannel?
	{
		channels.first { $0.branch == branch }
	}

	/// リリース本文の "key=value" 行から値を取り出す（無ければ ""）。
	/// CI が書き出す notes.txt（channel= / branch= / commit= / built=）用。
	static func value(of key: String, in body: String) -> String
	{
		let needle = key + "="
		for line in body.split(separator: "\n", omittingEmptySubsequences: false)
		{
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.hasPrefix(needle)
			{
				return String(trimmed.dropFirst(needle.count))
					.trimmingCharacters(in: .whitespacesAndNewlines)
			}
		}
		return ""
	}
}

// GitHub Releases API の必要フィールドだけを写した Decodable。
// （自動 snake_case 変換に頼らず明示の CodingKeys にしてある）
struct GitHubRelease: Decodable
{
	struct Asset: Decodable
	{
		let name: String
		let browserDownloadURL: String

		enum CodingKeys: String, CodingKey
		{
			case name
			case browserDownloadURL = "browser_download_url"
		}
	}

	let tagName: String
	let name: String?
	let prerelease: Bool
	let targetCommitish: String?
	let body: String?
	let assets: [Asset]

	enum CodingKeys: String, CodingKey
	{
		case tagName = "tag_name"
		case name
		case prerelease
		case targetCommitish = "target_commitish"
		case body
		case assets
	}
}
