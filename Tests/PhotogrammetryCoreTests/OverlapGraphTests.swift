//
//  OverlapGraphTests.swift
//
//  重なりグラフと予算配分（設計メモ §4.9）のテスト。実画像も Vision も要らない
//  ように、位置合わせの役をスタブへ差し替えて「どの 2 枚が本当に重なっているか」を
//  こちらで決める（`HelperProcessEngine` をシェルスクリプトで差し替えるのと
//  同じ考え方）。
//

import XCTest
@testable import PhotogrammetryCore

/// 「どの 2 枚が本当に重なっているか」を決めておいて位置合わせの代わりにする。
/// **何組を、どの順で確かめに来たか**も記録する — 予算配分そのものがテスト対象
/// なので、答えだけでなく問い方を見る必要がある。
final class OverlapStub: @unchecked Sendable
{
	/// 写真のパス → 添字。
	private let indexByPath: [String: Int]
	/// 本当に重なっているか。nil を返すと「判定できなかった」になる。
	private let truth: @Sendable (Int, Int) -> PhotoOverlap?
	private let lock = NSLock()
	private var asked: [(Int, Int)] = []

	init(urls: [URL], truth: @escaping @Sendable (Int, Int) -> PhotoOverlap?)
	{
		var index: [String: Int] = [:]
		for (position, url) in urls.enumerated()
		{
			index[url.path] = position
		}
		indexByPath = index
		self.truth = truth
	}

	/// 確かめに来た組（順番どおり）。
	var queries: [(Int, Int)]
	{
		lock.lock()
		defer { lock.unlock() }
		return asked
	}

	var count: Int
	{
		queries.count
	}

	func asked(_ a: Int, _ b: Int) -> Bool
	{
		queries.contains { $0 == (min(a, b), max(a, b)) }
	}

	var probe: OverlapSurvey.Probe
	{
		{ [self] batch in
			batch.map
			{ query in
				guard let left = indexByPath[query.a.path], let right = indexByPath[query.b.path]
				else
				{
					return nil
				}
				lock.lock()
				asked.append((min(left, right), max(left, right)))
				lock.unlock()
				return truth(left, right)
			}
		}
	}

	/// 実際に重なっている 2 枚。**判定に効くのはインライア率**（設計メモ §4.9.1）。
	static let overlapping = PhotoOverlap(
		agreement: 0.92, sharedArea: 0.6, inlierRatio: 0.9,
		evaluatedBlocks: 40, coherentBlocks: 36)
	/// 無関係な 2 枚。ブロック単位でもどこも揃わない。
	static let separate = PhotoOverlap(
		agreement: 0.04, sharedArea: 0.5, inlierRatio: 0.02,
		evaluatedBlocks: 40, coherentBlocks: 1)
}

/// 撮影 1 区画ぶんの設計図。
///
/// **見た目（`look`）と実際の場所（`place`）を別々に持てる**のがこの道具の要点。
/// 実データで仕分けが壊れたのはまさにここで、白い壁と同じ建具ばかりの屋内では
/// **別の場所が同じ見た目になる**（設計メモ §4.6.1）。見た目だけを与える合成
/// データでは、フェーズ 2 が現場で失敗した状況を再現できない。
struct SampleScene
{
	var photos: [PhotoMetadata] = []
	/// 添字 → （実際の場所, その場所の中での歩数）。**真実の側**で、
	/// 位置合わせのスタブだけがこれを見る。
	var placement: [(place: Int, step: Int)] = []

	/// 1 区画を足す。
	///
	/// - Parameters:
	///   - look: 見た目。同じ番号なら「似た画が写っている」（EXIF と feature print
	///     から見て区別が付かない）。
	///   - place: 実際の場所。同じ番号を離れた時刻の区画に与えると
	///     「一度離れて戻ってきた撮影」になる。
	///   - startStep: 歩数の起点。見た目の変化と重なりの届く範囲の両方を決める。
	mutating func add(
		count: Int,
		look: Int,
		place: Int,
		startStep: Int = 0,
		startTime: TimeInterval)
	{
		let start = photos.count
		for offset in 0 ..< count
		{
			let step = startStep + offset
			// 1 歩ごとに 1 ビットずつ立てる（サーモメータ符号）。ハミング距離が
			// そのまま歩数の隔たりになる。
			let drift = UInt64(min(step, 47))
			photos.append(SamplePhoto.make(
				index: start + offset,
				secondsFromEpoch: startTime + Double(offset) * 3,
				hash: UInt64(look) << 48 ^ ((1 << drift) &- 1),
				featurePrint: SamplePhoto.featurePrint(room: look, step: step)))
			placement.append((place, step))
		}
	}

	/// 「同じ場所で、歩数の隔たりが `reach` 以内なら重なる」を真実にする。
	func stub(reach: Int = 4) -> OverlapStub
	{
		let placement = placement
		return OverlapStub(urls: photos.map(\.url))
		{ left, right in
			let a = placement[left]
			let b = placement[right]
			guard a.place == b.place, abs(a.step - b.step) <= reach
			else
			{
				return OverlapStub.separate
			}
			return OverlapStub.overlapping
		}
	}
}

final class OverlapGraphTests: XCTestCase
{
	// -----------------------------------------------------------------
	// 値型としてのグラフ
	// -----------------------------------------------------------------

	/// **「重なっていない」と「判定できなかった」を混ぜない。** 前者はグループを
	/// 切る根拠になり、後者は何も言えない。
	func testVerdictDistinguishesSeparateFromUndecided()
	{
		let criteria = OverlapCriteria()
		XCTAssertEqual(criteria.judge(nil), .undecided)
		XCTAssertEqual(criteria.judge(OverlapStub.separate), .separate(OverlapStub.separate))
		// 局所的には揃っているが**帯のように少ししか重なっていない**組は対応点に
		// ならない。
		let narrow = PhotoOverlap(
			agreement: 0.9, sharedArea: 0.05, inlierRatio: 0.9, evaluatedBlocks: 8, coherentBlocks: 7)
		XCTAssertEqual(criteria.judge(narrow), .separate(narrow))
		// **全体の相関が低くても、局所が揃っていれば重なっている。** 視差のある
		// 2 枚がこれで、当初の測り方ではここを取りこぼしていた（§4.9.1）。
		let parallax = PhotoOverlap(
			agreement: 0.22, sharedArea: 0.6, inlierRatio: 0.55, evaluatedBlocks: 30, coherentBlocks: 17)
		XCTAssertTrue(criteria.judge(parallax).isOverlapping)
		XCTAssertTrue(criteria.judge(OverlapStub.overlapping).isOverlapping)
	}

	/// 重なっていない組も**スコア 0 のエッジとして残す**。切れ目の判定では
	/// 「そこは本当に切れている」という最も強い証拠になるため。
	func testEdgesKeepRejectedPairsAsZero()
	{
		var graph = OverlapGraph(photoCount: 4)
		graph.verdicts[OverlapGraph.key(0, 1, photoCount: 4)] = .overlapping(OverlapStub.overlapping)
		graph.verdicts[OverlapGraph.key(1, 2, photoCount: 4)] = .separate(OverlapStub.separate)
		graph.verdicts[OverlapGraph.key(2, 3, photoCount: 4)] = .undecided

		let edges = graph.edges()
		XCTAssertEqual(edges.count, 2, "判定できなかった組はエッジにしない")
		XCTAssertEqual(edges[0].i, 0)
		XCTAssertEqual(edges[0].score, 0.9, accuracy: 1e-9)
		XCTAssertEqual(edges[1].i, 1)
		XCTAssertEqual(edges[1].score, 0)
	}

	/// 予算外だっただけの写真を「重なっていない」と言わない。
	func testPhotosWithoutOverlapOnlyCountsAttemptedPhotos()
	{
		var graph = OverlapGraph(photoCount: 4)
		graph.verdicts[OverlapGraph.key(0, 1, photoCount: 4)] = .overlapping(OverlapStub.overlapping)
		graph.verdicts[OverlapGraph.key(1, 2, photoCount: 4)] = .separate(OverlapStub.separate)
		// 3 は 1 度も確かめていない。2 は確かめたうえで重ならなかった。
		XCTAssertEqual(graph.photosWithoutOverlap(), [2])
	}

	func testUsableRequiresAtLeastOneDecidedPair()
	{
		var graph = OverlapGraph(photoCount: 3)
		graph.verdicts[OverlapGraph.key(0, 1, photoCount: 3)] = .undecided
		XCTAssertFalse(graph.isUsable)
		graph.verdicts[OverlapGraph.key(1, 2, photoCount: 3)] = .separate(OverlapStub.separate)
		XCTAssertTrue(graph.isUsable, "「重なっていない」も判定のうち")
	}

	// -----------------------------------------------------------------
	// 予算の配り方
	// -----------------------------------------------------------------

	/// 骨格は**距離 1 の全組を先に**確かめる。予算が尽きても隣り合う 2 枚だけは
	/// 全体に行き渡らせたいため。
	func testChainPairsGoNearestFirst()
	{
		let pairs = OverlapSurvey.chainPairs(count: 5, window: 2)
		XCTAssertEqual(
			pairs.map { [$0.0, $0.1] },
			[[0, 1], [1, 2], [2, 3], [3, 4], [0, 2], [1, 3], [2, 4]])
	}

	/// 予算を超えて確かめない。超えたことは伝える。
	func testSurveyStopsAtBudgetAndSaysSo()
	{
		var scene = SampleScene()
		scene.add(count: 30, look: 0, place: 0, startTime: 0)
		let stub = scene.stub()
		let graph = OverlapSurvey.survey(
			urls: scene.photos.map(\.url),
			prior: [],
			settings: OverlapSurvey.Settings(budget: 10, batchSize: 4),
			probe: stub.probe)

		XCTAssertEqual(graph.checked, 10)
		XCTAssertEqual(stub.count, 10)
		XCTAssertTrue(graph.budgetExhausted)
	}

	/// 骨格が切れた位置の周りだけ広げて確かめる。**1 枚だけ被写体が変わったのか、
	/// 本当に場所が変わったのか**はこれで分かる。
	func testSeamProbeWidensOnlyAroundBreaks()
	{
		var scene = SampleScene()
		scene.add(count: 10, look: 0, place: 0, startTime: 0)
		scene.add(count: 10, look: 1, place: 1, startTime: 1000)
		let stub = scene.stub()
		_ = OverlapSurvey.survey(
			urls: scene.photos.map(\.url),
			prior: [],
			settings: OverlapSurvey.Settings(chainWindow: 2, seamProbeWindow: 5),
			probe: stub.probe)

		// 切れ目（9 と 10 の間）をまたぐ、骨格より広い組は確かめている。
		XCTAssertTrue(stub.asked(7, 11), "切れ目の周りは広げて確かめる")
		// 部屋の内側は骨格で繋がっているので広げない。
		XCTAssertFalse(stub.asked(0, 5), "繋がっている位置に予算を使わない")
	}

	/// **答えが変わらない組に予算を使わない。** 既に同じ連結成分にいる 2 枚は
	/// 確かめても仕分けが変わらない。
	func testInformativeBatchSkipsPairsAlreadyConnected()
	{
		var graph = OverlapGraph(photoCount: 4)
		graph.verdicts[OverlapGraph.key(0, 1, photoCount: 4)] = .overlapping(OverlapStub.overlapping)
		var remaining = [
			PairScore(i: 0, j: 1, score: 0.9),
			PairScore(i: 0, j: 2, score: 0.8),
			PairScore(i: 1, j: 2, score: 0.7),
			PairScore(i: 2, j: 3, score: 0.6),
		]
		var used = [Int](repeating: 0, count: 4)
		let batch = OverlapSurvey.informativeBatch(
			remaining: &remaining,
			used: &used,
			graph: graph,
			settings: OverlapSurvey.Settings(),
			budget: 100)

		// (0,1) は既に繋がっているので落ちる。(0,2) は成分を跨ぐので採る。
		// (1,2) は同じ束の (0,2) が同じ 2 成分を橋渡しするので**見送り**（次の周へ）。
		XCTAssertEqual(batch.map { [$0.0, $0.1] }, [[0, 2], [2, 3]])
		XCTAssertEqual(remaining.map(\.j), [2], "見送った組は候補に残す")
		XCTAssertEqual(remaining.map(\.i), [1])
	}

	// -----------------------------------------------------------------
	// グループ分けへの効き方（ここが §4.9 の本題）
	// -----------------------------------------------------------------

	/// **見た目が同じでも、実際に重なっていない場所は分かれる。**
	///
	/// 白い壁と同じ建具ばかりの屋内で、隣り合う 2 部屋を続けて撮った状況
	/// （設計メモ §4.6.1 の実データそのもの）。時刻も連番も見た目も連続している
	/// ので合算スコアでは 1 つの塊になるが、実際には重なっていないので分かれる。
	func testAdjacentRoomsShotBackToBackAreSeparatedByOverlap()
	{
		var scene = SampleScene()
		scene.add(count: 20, look: 0, place: 0, startStep: 0, startTime: 0)
		// 見た目は同じ（look 0・歩数も続く）が、実際には別の部屋。
		scene.add(count: 20, look: 0, place: 1, startStep: 20, startTime: 60)
		let settings = GroupingSettings(maxPerGroup: 150, minPerGroup: 5)

		// フェーズ 2 まで（合算スコア）: 時刻が続いているので 1 つになる。
		let withoutOverlap = PhotoGrouping.group(photos: scene.photos, settings: settings)
		XCTAssertEqual(withoutOverlap.groups.count, 1)

		// フェーズ 2.6（実際の重なり）: 部屋ごとに分かれる。
		let stub = scene.stub()
		let withOverlap = PhotoGrouping.group(
			photos: scene.photos, settings: settings, verifyOverlap: stub.probe)
		XCTAssertEqual(withOverlap.groups.count, 2)
		XCTAssertEqual(withOverlap.groups[0].members, Array(0 ..< 20))
		XCTAssertEqual(withOverlap.groups[1].members, Array(20 ..< 40))
		XCTAssertTrue(withOverlap.usedEvidence.contains(.overlap))
		XCTAssertFalse(withOverlap.thresholdWasAutomatic, "一致度の目盛りは現場に依存しない")
		XCTAssertEqual(withOverlap.threshold, OverlapCriteria().minimumInlierRatio, accuracy: 1e-9)
	}

	/// **一度離れて戻ってきた撮影は、時刻が離れていても 1 つになる。** これが
	/// 合成でいうループ閉じ込みで、予算配分の第 3 段が拾う経路。
	func testReturningToTheSameRoomIsReconnected()
	{
		var scene = SampleScene()
		scene.add(count: 15, look: 0, place: 0, startStep: 0, startTime: 0)
		scene.add(count: 15, look: 1, place: 1, startStep: 0, startTime: 600)
		// 部屋 0 の入口付近へ戻ってくる（歩数は 0 から＝最初の区画と同じ立ち位置）。
		scene.add(count: 10, look: 0, place: 0, startStep: 0, startTime: 1200)

		let stub = scene.stub()
		let grouping = PhotoGrouping.group(
			photos: scene.photos,
			settings: GroupingSettings(maxPerGroup: 150, minPerGroup: 5),
			verifyOverlap: stub.probe)

		XCTAssertEqual(grouping.groups.count, 2)
		let first = Set(grouping.groups[0].members)
		XCTAssertTrue(first.isSuperset(of: Set(0 ..< 15)))
		XCTAssertTrue(first.isSuperset(of: Set(30 ..< 40)), "戻ってきた区画が同じグループへ")
		XCTAssertEqual(grouping.groups[1].members, Array(15 ..< 30))

		// **撮影順が途切れたことを伝えなければならない。** このグループに
		// --sample-ordering sequential を与えると、隣り合わない 2 枚を隣だと
		// 言うことになる（設計メモ §4.9）。
		let plan = SortPlanner.plan(grouping: grouping, settings: SortPlanner.Settings())
		XCTAssertFalse(plan.groups[0].sequential, "戻ってきた区画を含むので一続きではない")
		XCTAssertTrue(plan.groups[1].sequential)
	}

	/// **1 組も判定できなければ合算スコアへ丸ごと戻る。** 確認が答えを出せない
	/// 現場で歯止めまで失うと、確認前より悪くなる（§4.6.1 と同じ判断）。
	func testFallsBackToCombinedScoreWhenNothingCanBeJudged() throws
	{
		var scene = SampleScene()
		scene.add(count: 20, look: 0, place: 0, startStep: 0, startTime: 0)
		scene.add(count: 20, look: 0, place: 1, startStep: 20, startTime: 60)
		let settings = GroupingSettings(maxPerGroup: 150, minPerGroup: 5)
		// 白飛びした白い壁ばかりで、位置合わせが 1 組も答えを出せない現場。
		let blind = OverlapStub(urls: scene.photos.map(\.url)) { _, _ in nil }

		let grouping = PhotoGrouping.group(
			photos: scene.photos, settings: settings, verifyOverlap: blind.probe)

		XCTAssertFalse(grouping.usedEvidence.contains(.overlap))
		XCTAssertEqual(
			grouping.groups.map(\.members),
			PhotoGrouping.group(photos: scene.photos, settings: settings).groups.map(\.members),
			"フェーズ 2 とまったく同じ結果に戻る")
		XCTAssertNotNil(grouping.overlap, "測った事実そのものは捨てない（診断と再利用のため）")
		// **空振りに予算を使い切らない。** 骨格が 1 組も判定できなければそこで止める。
		let graph = try XCTUnwrap(grouping.overlap)
		XCTAssertLessThan(graph.checked, graph.budget)
		XCTAssertFalse(graph.budgetExhausted)
	}

	/// 中断は**確認のたびに効く**。効かないキャンセルボタンを出さないため。
	func testSurveyStopsWhenCancelled()
	{
		var scene = SampleScene()
		scene.add(count: 40, look: 0, place: 0, startTime: 0)
		let stub = scene.stub()
		var calls = 0
		let graph = OverlapSurvey.survey(
			urls: scene.photos.map(\.url),
			prior: [],
			settings: OverlapSurvey.Settings(batchSize: 8),
			isCancelled:
			{
				calls += 1
				// 1 束ぶん確かめたところで中断する（前後で 2 回見るので 3 回目）。
				return calls > 2
			},
			probe: stub.probe)

		XCTAssertEqual(graph.checked, 8)
		XCTAssertFalse(
			graph.verdicts.values.contains(.undecided),
			"中断を「判定できなかった」にすり替えない")
	}

	// -----------------------------------------------------------------
	// 共有写真の選定との噛み合わせ
	// -----------------------------------------------------------------

	/// **グループ分けで測った組は測り直さない。** 隣接の候補は切れ目をまたぐ
	/// エッジなので、その多くは骨格で測り終えている。
	func testSharedPhotoSelectionReusesMeasuredPairs()
	{
		// ひと続きの場所を 60 枚。上限枚数で割られるので、切れ目をまたぐ組
		// （＝隣接の候補）はすべて骨格で測り終えている。
		var scene = SampleScene()
		scene.add(count: 60, look: 0, place: 0, startTime: 0)
		let stub = scene.stub()
		let grouping = PhotoGrouping.group(
			photos: scene.photos,
			settings: GroupingSettings(maxPerGroup: 25, minPerGroup: 5),
			verifyOverlap: stub.probe)
		XCTAssertGreaterThan(grouping.groups.count, 1)
		XCTAssertFalse(grouping.links.isEmpty)
		let measured = stub.count

		// 計画の段には**確かめる役を渡さない**。既に測った結果だけで判断できる。
		let plan = SortPlanner.plan(grouping: grouping, settings: SortPlanner.Settings(overlap: 5))
		XCTAssertEqual(stub.count, measured, "同じ組にもう一度払わない")
		XCTAssertNotNil(plan.overlapSummary, "測ってあるなら集計は出る")
		XCTAssertFalse(plan.adjacency.isEmpty)
		XCTAssertTrue(
			plan.adjacency.allSatisfy(\.overlapVerified),
			"骨格で測った結果がそのまま「確かめた」になる")
	}

	/// **測る手が無い組は落とさず保留にする。** 分からないことを理由に候補を
	/// 捨てると、視覚特徴が取れない現場で隣接が 1 本も作れなくなる。
	func testUnknownPairsAreHeldWhenThereIsNothingLeftToMeasureWith()
	{
		var scene = SampleScene()
		scene.add(count: 4, look: 0, place: 0, startTime: 0)
		var graph = OverlapGraph(photoCount: 4)
		graph.verdicts[OverlapGraph.key(0, 1, photoCount: 4)] = .overlapping(OverlapStub.overlapping)

		let result = SortPlanner.verifiedCandidates(
			ranked: [PairScore(i: 0, j: 1, score: 0.9), PairScore(i: 2, j: 3, score: 0.8)],
			photos: scene.photos,
			settings: SortPlanner.Settings(),
			known: graph)

		XCTAssertEqual(result.verified, 1)
		XCTAssertEqual(result.rejected, 0)
		XCTAssertEqual(result.undecided, 1, "測っていない組は「重なっていない」ではない")
		XCTAssertEqual(result.candidates.count, 2)
	}

	/// **証明済みに重なっていない組は隣接の候補にしない。** 重なっていない隣接は
	/// 合成にとって無いのと同じどころか、無関係な写真を持ち込むぶん有害。
	func testProvenSeparatePairsNeverBecomeLinks()
	{
		var scene = SampleScene()
		scene.add(count: 20, look: 0, place: 0, startStep: 0, startTime: 0)
		scene.add(count: 20, look: 0, place: 1, startStep: 20, startTime: 60)
		let stub = scene.stub()
		let grouping = PhotoGrouping.group(
			photos: scene.photos,
			settings: GroupingSettings(maxPerGroup: 150, minPerGroup: 5),
			verifyOverlap: stub.probe)

		XCTAssertEqual(grouping.groups.count, 2)
		// **隣接の候補には未測定の組も残る**（絞ると共有写真が枯れる。§4.9.1）。
		// 落とすのは確認を通してからで、そこで初めて隣接が消える。
		let plan = SortPlanner.plan(
			grouping: grouping,
			settings: SortPlanner.Settings(),
			verifyOverlap: stub.probe)
		XCTAssertTrue(plan.adjacency.isEmpty, "確かめれば 1 組も重なっていない")
		XCTAssertGreaterThan(plan.overlapSummary?.rejected ?? 0, 0)
	}
}
