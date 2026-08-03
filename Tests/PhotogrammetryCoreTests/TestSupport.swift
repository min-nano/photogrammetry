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

// -----------------------------------------------------------------
// APICommand の取り出し
//
// APICommand はコマンドの enum（process / sort）なので、既存の「Request を
// 期待する」テストは 1 段はがす必要がある。エラーはそのまま伝播させるので、
// 例外を確かめるテストは書き換えずに済む。
// -----------------------------------------------------------------

extension APICommand
{
	var processRequest: ReconstructionRequest?
	{
		guard case .process(let request) = self
		else
		{
			return nil
		}
		return request
	}

	var sortRequest: SortRequest?
	{
		guard case .sort(let request) = self
		else
		{
			return nil
		}
		return request
	}
}

enum TestSupportError: Error
{
	case unexpectedCommand
}

func parseProcess(url: URL) throws -> ReconstructionRequest
{
	guard let request = try APICommand.parse(url: url).processRequest
	else
	{
		throw TestSupportError.unexpectedCommand
	}
	return request
}

func parseProcess(arguments: [String]) throws -> ReconstructionRequest
{
	guard let request = try APICommand.parse(arguments: arguments).processRequest
	else
	{
		throw TestSupportError.unexpectedCommand
	}
	return request
}

func parseSort(url: URL) throws -> SortRequest
{
	guard let request = try APICommand.parse(url: url).sortRequest
	else
	{
		throw TestSupportError.unexpectedCommand
	}
	return request
}

func parseSort(arguments: [String]) throws -> SortRequest
{
	guard let request = try APICommand.parse(arguments: arguments).sortRequest
	else
	{
		throw TestSupportError.unexpectedCommand
	}
	return request
}

/// 合成のメタデータを作る道具。実写真は公開できない（設計メモ §10-10）ので、
/// 仕分けのテストはすべてこの合成データで書く。
enum SamplePhoto
{
	/// 起点の時刻（固定値。テストを時計に依存させない）。
	static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

	/// 合成の視覚特徴。**同じ `room` の写真どうしは近く、違う部屋とはほぼ直交する。**
	///
	/// 本物の feature print は 2048 次元だが、ここで使うのは距離の性質だけなので、
	/// 部屋ごとに 2 軸だけ与えて「撮り進むにつれ向きが少しずつ変わる」を円運動で
	/// 表す。こうすると隣り合う写真ほど近く、離れるほど遠い（同じ部屋の中では
	/// 単調）という、実写真と同じ性質になる。
	static func featurePrint(room: Int, step: Int) -> FeaturePrint?
	{
		let dimension = 32
		var elements = [Float](repeating: 0, count: dimension)
		let axis = (room * 2) % dimension
		let angle = Double(step) * 0.02
		elements[axis] = Float(cos(angle))
		elements[(axis + 1) % dimension] = Float(sin(angle))
		return FeaturePrint(elements: elements)
	}

	/// 1 枚分のメタデータ。指定しない項目は「その手がかりが無い写真」になる。
	static func make(
		index: Int,
		folder: String = "",
		secondsFromEpoch: TimeInterval? = nil,
		latitude: Double? = nil,
		longitude: Double? = nil,
		altitude: Double? = nil,
		accuracy: Double? = nil,
		heading: Double? = nil,
		focalLength35mm: Double? = nil,
		cameraModel: String? = nil,
		exposureValue: Double? = nil,
		hash: UInt64? = nil,
		featurePrint: FeaturePrint? = nil,
		sharpness: Double = 100,
		clippedHighlights: Double = 0,
		clippedShadows: Double = 0,
		pixelWidth: Int = 4032,
		pixelHeight: Int = 3024) -> PhotoMetadata
	{
		let name = String(format: "IMG_%04d.HEIC", index)
		let relativePath = folder.isEmpty ? name : "\(folder)/\(name)"
		var location: GeoLocation?
		if let latitude, let longitude
		{
			location = GeoLocation(
				latitude: latitude,
				longitude: longitude,
				altitude: altitude,
				horizontalAccuracy: accuracy,
				timestamp: nil)
		}
		return PhotoMetadata(
			url: URL(fileURLWithPath: "/tmp/photos/\(relativePath)"),
			relativePath: relativePath,
			sourceFolder: folder,
			captureDate: secondsFromEpoch.map { epoch.addingTimeInterval($0) },
			location: location,
			heading: heading,
			focalLength35mm: focalLength35mm,
			cameraModel: cameraModel,
			pixelWidth: pixelWidth,
			pixelHeight: pixelHeight,
			exposureValue: exposureValue,
			fingerprint: hash.map(PerceptualHash.init(bits:)),
			featurePrint: featurePrint,
			quality: PhotoQuality(
				sharpness: sharpness,
				clippedHighlights: clippedHighlights,
				clippedShadows: clippedShadows,
				meanLuminance: 0.5),
			sequenceNumber: PhotoMetadata.sequenceNumber(fromName: name))
	}

	/// 「時刻が連続し、少しずつ見た目が変わっていく」1 区画ぶんの写真。
	/// 現場を歩きながら撮った状況を模す。
	///
	/// - Parameters:
	///   - start: 先頭の添字（ファイル名になる）。
	///   - count: 枚数。
	///   - startTime: 先頭の時刻（epoch からの秒）。
	///   - interval: 1 枚あたりの間隔（秒）。
	///   - hashSeed: 見た目の起点。区画ごとに大きく離すと別の場所になる。
	///   - room: 視覚特徴を付ける場合の部屋番号。**同じ番号を離れた時刻の
	///     区画に与えると「一度離れて戻ってきた撮影」になる**（フェーズ 2 が
	///     解こうとしている状況そのもの）。nil なら視覚特徴を持たない写真になる。
	static func sequence(
		start: Int,
		count: Int,
		startTime: TimeInterval,
		interval: TimeInterval = 3,
		hashSeed: UInt64,
		folder: String = "",
		heading: Double? = nil,
		exposureValue: Double? = nil,
		room: Int? = nil) -> [PhotoMetadata]
	{
		(0 ..< count).map
		{ offset in
			// 1 枚ごとに 1 ビットずつ立てる（サーモメータ符号）。ハミング距離が
			// そのまま撮影順の隔たりになるので、「隣は近く、離れるほど遠い」が
			// 単調に成立する。剰余で折り返すと遠い写真が同一指紋になってしまう。
			let drift = UInt64(min(offset, 63))
			return make(
				index: start + offset,
				folder: folder,
				secondsFromEpoch: startTime + Double(offset) * interval,
				heading: heading.map { $0 + Double(offset) * 4 },
				exposureValue: exposureValue,
				hash: hashSeed ^ ((1 << drift) &- 1),
				featurePrint: room.flatMap { featurePrint(room: $0, step: offset) },
				sharpness: 100 + Double(offset % 5))
		}
	}
}

/// グループ分けと場所の割り当てを直接指定した `GroupingResult` を作る。
/// 実写真もクラスタリングも通さずに、その先（計画・診断）だけを固定したいときに使う。
func manualGrouping(groups: [[Int]], labels: [Int]) -> GroupingResult
{
	let photos = labels.indices.map { SamplePhoto.make(index: $0) }
	let clusterCount = (labels.max() ?? -1) + 1
	let clusters = (0 ..< clusterCount).map
	{ label in
		RoomCluster(
			id: RoomClustering.identifier(label),
			members: labels.indices.filter { labels[$0] == label })
	}
	let rooms = RoomClusteringResult(
		clusters: clusters,
		labels: labels.map { Optional($0) },
		neighbors: [[SceneNeighbor]](repeating: [], count: labels.count),
		threshold: 0.3,
		thresholdWasAutomatic: true,
		separability: 0.6,
		distanceHistogram: [],
		coverage: 1)
	return GroupingResult(
		photos: photos,
		groups: groups.enumerated().map
		{
			PhotoGroup(id: PhotoGrouping.identifier($0.offset), members: $0.element)
		},
		links: [],
		unassigned: [],
		rooms: rooms,
		usedEvidence: [.time, .scene, .room],
		evidenceCoverage: [.scene: 1, .room: 1],
		threshold: 0.5,
		thresholdWasAutomatic: true,
		scoreHistogram: [])
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
