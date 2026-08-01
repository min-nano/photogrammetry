//
//  UpdateFeedTests.swift
//
//  GitHub Releases JSON → チャンネル一覧の解釈と、更新要否の判定をテストする。
//  フィクスチャは build.yml が実際に作るリリースの形（rolling の stable +
//  ブランチごとの dev-* プレリリース、notes は key=value 行）を模している。
//

import XCTest

@testable import PhotogrammetryUpdater

final class UpdateFeedTests: XCTestCase
{
	/// stable + dev 2 本 + 無関係のタグ + アセット欠落、を含む一覧。
	private let fixture = """
		[
		  {
		    "tag_name": "dev-feature-roof",
		    "name": "Dev: feature/roof (1234567)",
		    "prerelease": true,
		    "target_commitish": "1234567890abcdef1234567890abcdef12345678",
		    "body": "channel=dev\\nbranch=feature/roof\\ncommit=1234567890abcdef1234567890abcdef12345678\\nbuilt=2026-08-01T00:00:00Z\\n",
		    "assets": [
		      {
		        "name": "Photogrammetry.app.zip",
		        "browser_download_url": "https://example.com/dev-feature-roof/Photogrammetry.app.zip"
		      },
		      {
		        "name": "photogrammetry-cli.zip",
		        "browser_download_url": "https://example.com/dev-feature-roof/photogrammetry-cli.zip"
		      }
		    ]
		  },
		  {
		    "tag_name": "stable",
		    "name": "Stable (abc1234)",
		    "prerelease": false,
		    "target_commitish": "abc1234567890abcdef1234567890abcdef12345",
		    "body": "channel=stable\\nbranch=main\\ncommit=abc1234567890abcdef1234567890abcdef12345\\nbuilt=2026-08-01T01:00:00Z\\n",
		    "assets": [
		      {
		        "name": "Photogrammetry.app.zip",
		        "browser_download_url": "https://example.com/stable/Photogrammetry.app.zip"
		      }
		    ]
		  },
		  {
		    "tag_name": "dev-another-branch",
		    "name": "Dev: another-branch (9999999)",
		    "prerelease": true,
		    "target_commitish": "9999999999999999999999999999999999999999",
		    "body": "channel=dev\\nbranch=another-branch\\ncommit=9999999999999999999999999999999999999999\\n",
		    "assets": [
		      {
		        "name": "Photogrammetry.app.zip",
		        "browser_download_url": "https://example.com/dev-another-branch/Photogrammetry.app.zip"
		      }
		    ]
		  },
		  {
		    "tag_name": "v1.0.0-manual",
		    "name": "手動で作った無関係のリリース",
		    "prerelease": false,
		    "target_commitish": "main",
		    "body": "",
		    "assets": []
		  },
		  {
		    "tag_name": "dev-no-asset",
		    "name": "Dev: no-asset (build failed halfway)",
		    "prerelease": true,
		    "target_commitish": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		    "body": "channel=dev\\nbranch=no-asset\\ncommit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n",
		    "assets": []
		  }
		]
		"""

	private func channels() throws -> [UpdateChannel]
	{
		try UpdateFeed.channels(fromReleasesJSON: Data(fixture.utf8))
	}

	func testChannelsFilterAndOrder() throws
	{
		let list = try channels()
		// 無関係のタグと、アセットの無い dev-no-asset は除外される。
		XCTAssertEqual(list.count, 3)
		// stable が先頭、開発版はブランチ名順（API の返却順に依存しない）。
		XCTAssertEqual(list[0].tag, "stable")
		XCTAssertEqual(list[1].branch, "another-branch")
		XCTAssertEqual(list[2].branch, "feature/roof")
	}

	func testStableChannelFields() throws
	{
		let list = try channels()
		let stable = list[0]
		XCTAssertEqual(stable.branch, "main")
		XCTAssertFalse(stable.isPrerelease)
		XCTAssertEqual(stable.commit, "abc1234")
		XCTAssertEqual(
			stable.assetURL.absoluteString,
			"https://example.com/stable/Photogrammetry.app.zip")
		XCTAssertEqual(stable.builtAt, "2026-08-01T01:00:00Z")
		XCTAssertEqual(stable.displayName, "main（安定版）")
	}

	func testDevChannelUsesBranchFromNotes() throws
	{
		let list = try channels()
		// スラッシュ入りブランチ名はタグ（dev-feature-roof）からは復元できない
		// ので、notes の branch= 行が使われることを確かめる。
		let dev = try XCTUnwrap(UpdateFeed.channel(named: "feature/roof", in: list))
		XCTAssertTrue(dev.isPrerelease)
		XCTAssertEqual(dev.commit, "1234567")
		XCTAssertEqual(dev.displayName, "feature/roof（開発版）")
	}

	func testBranchFallsBackToTagWhenNotesMissing() throws
	{
		let json = """
			[
			  {
			    "tag_name": "dev-fallback",
			    "name": null,
			    "prerelease": true,
			    "target_commitish": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			    "body": null,
			    "assets": [
			      {
			        "name": "Photogrammetry.app.zip",
			        "browser_download_url": "https://example.com/x/Photogrammetry.app.zip"
			      }
			    ]
			  }
			]
			"""
		let list = try UpdateFeed.channels(fromReleasesJSON: Data(json.utf8))
		XCTAssertEqual(list.count, 1)
		XCTAssertEqual(list[0].branch, "fallback")
		// notes が無ければ target_commitish から短縮コミットを取る。
		XCTAssertEqual(list[0].commit, "bbbbbbb")
		// name が無ければタグをタイトルにする。
		XCTAssertEqual(list[0].title, "dev-fallback")
	}

	func testUpdateAvailable() throws
	{
		let list = try channels()
		let stable = list[0]
		// 同じコミット → 更新不要。
		XCTAssertFalse(UpdateFeed.updateAvailable(installed: "abc1234", channel: stable))
		// 異なるコミット → 更新あり（ローリングリリースなので新旧は問わない）。
		XCTAssertTrue(UpdateFeed.updateAvailable(installed: "0000000", channel: stable))
		// スタンプが無い（開発実行など）→ 常に更新を提案。
		XCTAssertTrue(UpdateFeed.updateAvailable(installed: nil, channel: stable))
		XCTAssertTrue(UpdateFeed.updateAvailable(installed: "", channel: stable))
		XCTAssertTrue(UpdateFeed.updateAvailable(installed: "unknown", channel: stable))
	}

	func testChannelNamedLookup() throws
	{
		let list = try channels()
		XCTAssertEqual(UpdateFeed.channel(named: "main", in: list)?.tag, "stable")
		XCTAssertNil(UpdateFeed.channel(named: "no-such-branch", in: list))
	}

	func testValueOfParsesKeyValueLines()
	{
		let body = "channel=dev\nbranch=feature/x\ncommit=  abcdef1  \n"
		XCTAssertEqual(UpdateFeed.value(of: "branch", in: body), "feature/x")
		XCTAssertEqual(UpdateFeed.value(of: "commit", in: body), "abcdef1")
		XCTAssertEqual(UpdateFeed.value(of: "missing", in: body), "")
	}
}
