//
//  TestSupport.swift
//
//  別プロセス実行のテストで使う道具。ヘルパー（photogrammetry-cli）を
//  シェルスクリプトへ差し替えられるので、GPU も本物のセッションも要らずに
//  「進捗を出す / 異常終了する / 中断する」を再現できる。
//

import Foundation

@testable import PhotogrammetryCore

enum FakeHelper
{
	/// ヘルパーの代わりに走らせるシェルスクリプトを作る。引数の並びは
	/// APICommand.arguments に従うので、$1 = 入力フォルダ、$2 = 出力ファイル。
	static func make(in directory: URL, body: String) throws -> URL
	{
		let url = directory.appendingPathComponent("helper-\(UUID().uuidString).sh")
		try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o755],
			ofItemAtPath: url.path)
		return url
	}

	/// 進捗を 1 つ出してから SIGINT を待ち、受け取ったら中断して終了する
	/// スクリプト（本物の CLI と同じ振る舞い）。
	static let cancellableBody = """
		trap 'echo "cancelled"; exit 0' INT
		echo "progress=0.100"
		i=0
		while [ $i -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
		echo "ok"
		"""
}

/// イベントは任意のスレッドから届くので、配列はロックで守る。
final class EventLog: @unchecked Sendable
{
	private let lock = NSLock()
	private var events: [ReconstructionEvent] = []

	func append(_ event: ReconstructionEvent)
	{
		lock.lock()
		events.append(event)
		lock.unlock()
	}

	var all: [ReconstructionEvent]
	{
		lock.lock()
		defer { lock.unlock() }
		return events
	}

	/// 指定のイベントが届くまで待つ（届かなければ false）。
	func wait(for event: ReconstructionEvent, timeout: TimeInterval = 5) async -> Bool
	{
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline
		{
			if all.contains(event)
			{
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return false
	}
}
