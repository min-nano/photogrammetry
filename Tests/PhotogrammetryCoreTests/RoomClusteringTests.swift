//
//  RoomClusteringTests.swift
//
//  視覚クラスタリング（フェーズ 2）を合成ベクトルで固定する。
//
//  ここで確かめたいのは 2 つ。
//
//    1. **別の場所は別のクラスタになる**（時刻や位置がまったく無くても）
//    2. **一続きの場所は割らない**（ブレ判定と同じで、山が 1 つなら切らない）
//
//  2 が効かないと、白い壁ばかりの部屋を撮り歩いただけで場所が刻まれ、
//  グルーピングが逆に悪くなる。
//

import XCTest

@testable import PhotogrammetryCore

final class RoomClusteringTests: XCTestCase
{
	/// 部屋 `room` を `count` 枚撮った区画ぶんの視覚特徴。
	func prints(room: Int, count: Int, from step: Int = 0) -> [FeaturePrint?]
	{
		(0 ..< count).map { SamplePhoto.featurePrint(room: room, step: step + $0) }
	}

	func testTwoRoomsBecomeTwoClusters()
	{
		let result = RoomClustering.cluster(prints: prints(room: 0, count: 20)
			+ prints(room: 3, count: 20))
		XCTAssertEqual(result.clusters.count, 2)
		XCTAssertEqual(result.clusters.map { $0.members.count }, [20, 20])
		XCTAssertEqual(result.clusters.map(\.id), ["room-01", "room-02"])
		XCTAssertEqual(result.labels[0], 0)
		XCTAssertEqual(result.labels[39], 1)
	}

	func testContinuousWalkIsNotSplit()
	{
		// 一続きの場所を撮り歩いただけ。**谷が無いので切らない。**
		let result = RoomClustering.cluster(prints: prints(room: 1, count: 40))
		XCTAssertEqual(result.clusters.count, 1)
		XCTAssertEqual(result.clusters.first?.members.count, 40)
	}

	func testReturningToTheSameRoomLandsInTheSameCluster() throws
	{
		// **フェーズ 2 の狙いそのもの。** 部屋 A → 部屋 B → 部屋 A と撮った
		// とき、時刻はまったく助けにならないが、見た目は同じ場所だと言える。
		let result = RoomClustering.cluster(prints: prints(room: 0, count: 15)
			+ prints(room: 5, count: 15)
			+ prints(room: 0, count: 15, from: 3))
		XCTAssertEqual(result.clusters.count, 2)
		XCTAssertEqual(result.labels[0], result.labels[35])
		XCTAssertNotEqual(result.labels[0], result.labels[20])
		let label = try XCTUnwrap(result.labels[0])
		XCTAssertEqual(result.clusters[label].members.count, 30)
	}

	func testPhotosWithoutFeaturePrintsAreLeftUnlabelled()
	{
		var input = prints(room: 0, count: 10)
		input.insert(nil, at: 4)
		let result = RoomClustering.cluster(prints: input)
		XCTAssertNil(result.labels[4])
		XCTAssertEqual(result.coverage, 10.0 / 11.0, accuracy: 1e-9)
		XCTAssertFalse(result.clusters.contains { $0.members.contains(4) })
	}

	func testTinyClusterIsAbsorbedIntoTheNearestOne()
	{
		// 1 枚だけ離れた写真は「部屋」として扱わない（判断材料にならない）。
		// 最も近いクラスタへ寄せる。
		var input = prints(room: 0, count: 20)
		input.append(SamplePhoto.featurePrint(room: 7, step: 0))
		let result = RoomClustering.cluster(prints: input)
		XCTAssertEqual(result.clusters.count, 1)
		XCTAssertEqual(result.clusters.first?.members.count, 21)
	}

	func testSeveralTinyClustersAreAllAbsorbed()
	{
		// 小さすぎるクラスタが 2 つ以上あるときは、撮影順（添字の小さいほう）から
		// 順に寄せる。**どれから処理するかを決めておかないと結果が実行ごとに
		// 変わる**（辞書の走査順は保証されないため）。
		let input = prints(room: 0, count: 20)
			+ [SamplePhoto.featurePrint(room: 3, step: 0),
				SamplePhoto.featurePrint(room: 3, step: 1)]
			+ [SamplePhoto.featurePrint(room: 5, step: 0),
				SamplePhoto.featurePrint(room: 5, step: 1)]
		let result = RoomClustering.cluster(prints: input)
		XCTAssertEqual(result.clusters.count, 1)
		XCTAssertEqual(result.clusters.first?.members.count, 24)
	}

	func testExplicitThresholdIsUsedAndRecorded()
	{
		let settings = RoomClustering.Settings(threshold: 0.4)
		let result = RoomClustering.cluster(
			prints: prints(room: 0, count: 20) + prints(room: 3, count: 20),
			settings: settings)
		XCTAssertEqual(result.threshold, 0.4)
		XCTAssertFalse(result.thresholdWasAutomatic)
		XCTAssertEqual(result.clusters.count, 2)
	}

	func testAutomaticThresholdStaysInRange()
	{
		let result = RoomClustering.cluster(prints: prints(room: 0, count: 20)
			+ prints(room: 3, count: 20))
		XCTAssertTrue(result.thresholdWasAutomatic)
		XCTAssertGreaterThanOrEqual(result.threshold, RoomClustering.Settings().minimumThreshold)
		XCTAssertLessThanOrEqual(result.threshold, RoomClustering.Settings().maximumThreshold)
	}

	func testDistanceHistogramIsProduced()
	{
		// 写真そのものを含まない統計だけで閾値を検討できるようにするため（§10-10）。
		let result = RoomClustering.cluster(prints: prints(room: 0, count: 20))
		XCTAssertEqual(result.distanceHistogram.count, RoomClustering.histogramBins)
		XCTAssertGreaterThan(result.distanceHistogram.reduce(0, +), 0)
	}

	func testEmptyAndSingleInput()
	{
		let empty = RoomClustering.cluster(prints: [])
		XCTAssertTrue(empty.clusters.isEmpty)
		XCTAssertEqual(empty.coverage, 0)

		let single = RoomClustering.cluster(prints: prints(room: 0, count: 1))
		XCTAssertEqual(single.clusters.count, 1)
		XCTAssertEqual(single.labels[0], 0)

		// 特徴が 1 枚も取れなければクラスタは作られない（分ける材料が無い）。
		let none = RoomClustering.cluster(prints: [nil, nil, nil])
		XCTAssertTrue(none.clusters.isEmpty)
		XCTAssertEqual(none.coverage, 0)
	}

	func testNeighboursAreSortedAndReusable()
	{
		// 近傍は候補ペアの選定にそのまま使い回すので、順序と件数を固定する。
		let settings = RoomClustering.Settings(neighbors: 4)
		let result = RoomClustering.cluster(prints: prints(room: 0, count: 20), settings: settings)
		for neighbors in result.neighbors
		{
			XCTAssertEqual(neighbors.count, 4)
			XCTAssertEqual(neighbors.map(\.distance), neighbors.map(\.distance).sorted())
		}
		// 撮影順で隣り合う写真が最も近い。
		XCTAssertTrue(result.neighbors[10].prefix(2).contains { $0.index == 9 || $0.index == 11 })
	}

	func testIdenticalPhotosFormOneRoom()
	{
		// まったく同じ写真ばかり（分布に山も谷も無い）。切る材料が無いので
		// 1 か所にまとめる。
		let sample = SamplePhoto.featurePrint(room: 0, step: 0)
		let result = RoomClustering.cluster(prints: [FeaturePrint?](repeating: sample, count: 10))
		XCTAssertEqual(result.clusters.count, 1)
		XCTAssertEqual(result.separability, 0)
	}

	func testAutomaticThresholdFallsBackWhenThereAreNoDistances()
	{
		// 近傍が 1 つも無いときは「最も緩い閾値」を返す（切らない側へ倒す）。
		let settings = RoomClustering.Settings()
		XCTAssertEqual(
			RoomClustering.automaticThreshold(distances: [], estimate: nil, settings: settings),
			settings.maximumThreshold)
	}

	func testAutomaticThresholdIgnoresAValleyBelowTheMedian()
	{
		// 判別分析が山の裾で谷を見つけることがある。そのまま採ると近傍の
		// 大半を切ってしまい、1 つの部屋が刻まれる（実際に起きた）。中央値より
		// 下の谷は信用せず、ほぼ全ての近傍を残す側（95 パーセンタイル）へ倒す。
		let distances = [0.01, 0.02, 0.30, 0.31, 0.32, 0.33]
		let low = ThresholdEstimator.Estimate(
			threshold: 0.05, separability: 0.9, lowerFraction: 0.33)
		let settings = RoomClustering.Settings()
		XCTAssertEqual(
			RoomClustering.automaticThreshold(distances: distances, estimate: low, settings: settings),
			ThresholdEstimator.percentile(distances, settings.fallbackPercentile) ?? 0,
			accuracy: 1e-9)

		// 中央値より上の谷ははっきりした切れ目なので採る。
		let high = ThresholdEstimator.Estimate(
			threshold: 0.6, separability: 0.9, lowerFraction: 0.6)
		XCTAssertEqual(
			RoomClustering.automaticThreshold(distances: distances, estimate: high, settings: settings),
			0.6,
			accuracy: 1e-9)
	}

	func testNearestSkipsPhotosWithoutFeaturePrints()
	{
		let base = SamplePhoto.featurePrint(room: 0, step: 0)
		let other = SamplePhoto.featurePrint(room: 0, step: 5)
		// 起点に特徴が無ければ近傍は作れない。
		XCTAssertTrue(RoomClustering.nearest(
			0, among: [0, 1], prints: [nil, other], k: 2).isEmpty)
		// 相手に無い場合は飛ばす（見つかるのは特徴のあるものだけ）。
		let found = RoomClustering.nearest(
			0, among: [0, 1, 2], prints: [base, nil, other], k: 2)
		XCTAssertEqual(found.map(\.index), [2])
	}

	func testIdentifierFormat()
	{
		XCTAssertEqual(RoomClustering.identifier(0), "room-01")
		XCTAssertEqual(RoomClustering.identifier(11), "room-12")
	}

	func testIdentifierLookupForPhoto()
	{
		let result = RoomClustering.cluster(prints: prints(room: 0, count: 20)
			+ prints(room: 3, count: 20))
		XCTAssertEqual(result.identifier(forPhoto: 0), "room-01")
		XCTAssertEqual(result.identifier(forPhoto: 39), "room-02")
		XCTAssertNil(result.identifier(forPhoto: 999))
	}
}
