//
//  QualityFilterTests.swift
//
//  品質フィルタ（設計メモ §4.2）を固定する。**「落とすべきものを落とす」より
//  「落としてはいけないものを落とさない」ほうが重要**なので、閾値の自動決定が
//  暴走しないことに重点を置く。現場写真は撮り直しが利かない。
//

import XCTest

@testable import PhotogrammetryCore

final class QualityFilterTests: XCTestCase
{
	/// 鮮鋭度だけを変えた n 枚。指紋は互いに大きく離す（ここで見たいのはブレの
	/// 判定であって、ほぼ同一の除去ではないため）。
	func photos(sharpness values: [Double]) -> [PhotoMetadata]
	{
		values.enumerated().map
		{ index, value in
			SamplePhoto.make(
				index: index,
				secondsFromEpoch: Double(index) * 5,
				hash: UInt64(index) &* 0x9E37_79B9_7F4A_7C15,
				sharpness: value)
		}
	}

	// -----------------------------------------------------------------
	// ブレ
	// -----------------------------------------------------------------

	func testBlurredPhotosAreExcludedWhenDistributionIsBimodal()
	{
		// はっきり 2 つの山（ブレた 3 枚と、まともな 12 枚）。
		let values = [Double](repeating: 5, count: 3) + [Double](repeating: 100, count: 12)
		let outcome = QualityFilter.apply(to: photos(sharpness: values))
		XCTAssertEqual(outcome.excluded.filter { $0.reason == .blur }.count, 3)
		XCTAssertEqual(outcome.kept.count, 12)
		XCTAssertFalse(outcome.blurFilterSuppressed)
	}

	func testNothingIsExcludedWhenAllPhotosAreSharp()
	{
		// 山が 1 つ。**ここで良品を捨てないことが要点。**
		let values = (0 ..< 20).map { 100 + Double($0 % 5) * 4 }
		let outcome = QualityFilter.apply(to: photos(sharpness: values))
		XCTAssertTrue(outcome.excluded.filter { $0.reason == .blur }.isEmpty)
		XCTAssertEqual(outcome.kept.count, 20)
	}

	func testBlurFilterIsSuppressedWhenItWouldRemoveTooMuch()
	{
		// 半分が低い側に寄った分布。谷は見つかるが、そこで切ると半数が落ちる。
		// 安全弁が働いて判定ごと見送る。
		let values = [Double](repeating: 1, count: 9) + [Double](repeating: 10, count: 9)
		let outcome = QualityFilter.apply(to: photos(sharpness: values))
		XCTAssertTrue(outcome.blurFilterSuppressed)
		XCTAssertNil(outcome.sharpnessThreshold)
		XCTAssertTrue(outcome.excluded.filter { $0.reason == .blur }.isEmpty)
	}

	func testExplicitThresholdOverridesAutomaticEstimate()
	{
		let values = (0 ..< 12).map { 100 + Double($0) }
		var settings = QualityFilter.Settings()
		settings.minimumSharpness = 105
		let outcome = QualityFilter.apply(to: photos(sharpness: values), settings: settings)
		XCTAssertEqual(outcome.sharpnessThreshold, 105)
		XCTAssertEqual(outcome.excluded.filter { $0.reason == .blur }.count, 5)
	}

	func testSharpnessThresholdNeverExceedsSafetyCeiling()
	{
		// 自動決定は「中央値の 60%」を超えない。
		let values = [Double](repeating: 10, count: 4) + [Double](repeating: 100, count: 10)
		let threshold = QualityFilter.estimateSharpnessThreshold(values: values)
		XCTAssertNotNil(threshold)
		let median = ThresholdEstimator.median(values) ?? 0
		XCTAssertLessThanOrEqual(threshold ?? .infinity, median * QualityFilter.maximumCutFactor)
	}

	func testSharpnessThresholdNeedsEnoughSamples()
	{
		// 数枚しか無ければ分布を推定できない。切らない。
		XCTAssertNil(QualityFilter.estimateSharpnessThreshold(values: [1, 2, 100]))
	}

	// -----------------------------------------------------------------
	// 形と露出
	// -----------------------------------------------------------------

	func testPanoramaAndTinyImagesAreExcluded()
	{
		let input = [
			SamplePhoto.make(index: 1, hash: 1, pixelWidth: 12000, pixelHeight: 3000),
			SamplePhoto.make(index: 2, hash: 2, pixelWidth: 320, pixelHeight: 240),
			SamplePhoto.make(index: 3, hash: 4),
		]
		let outcome = QualityFilter.apply(to: input)
		XCTAssertEqual(outcome.excluded.first { $0.reason == .panorama }?.photo, "IMG_0001.HEIC")
		XCTAssertEqual(outcome.excluded.first { $0.reason == .tooSmall }?.photo, "IMG_0002.HEIC")
		XCTAssertEqual(outcome.kept.map(\.relativePath), ["IMG_0003.HEIC"])
	}

	func testClippedPhotosAreExcluded()
	{
		// 小屋裏のフラッシュ（白飛び）と床下の暗所（黒つぶれ）。
		let input = [
			SamplePhoto.make(index: 1, hash: 1, clippedHighlights: 0.8),
			SamplePhoto.make(index: 2, hash: 2, clippedShadows: 0.9),
			SamplePhoto.make(index: 3, hash: 4, clippedHighlights: 0.2),
		]
		let outcome = QualityFilter.apply(to: input)
		XCTAssertEqual(outcome.excluded.first { $0.reason == .overexposed }?.photo, "IMG_0001.HEIC")
		XCTAssertEqual(outcome.excluded.first { $0.reason == .underexposed }?.photo, "IMG_0002.HEIC")
		XCTAssertEqual(outcome.kept.count, 1)
	}

	// -----------------------------------------------------------------
	// ほぼ同一
	// -----------------------------------------------------------------

	func testNearDuplicateRunKeepsTheSharpestPhoto()
	{
		// 立ち止まったままの連写。同じ指紋が 3 枚続く。
		let input = [
			SamplePhoto.make(index: 1, secondsFromEpoch: 0, hash: 0xFF00, sharpness: 80),
			SamplePhoto.make(index: 2, secondsFromEpoch: 1, hash: 0xFF00, sharpness: 120),
			SamplePhoto.make(index: 3, secondsFromEpoch: 2, hash: 0xFF00, sharpness: 90),
			SamplePhoto.make(index: 4, secondsFromEpoch: 60, hash: 0x00FF, sharpness: 100),
		]
		let outcome = QualityFilter.apply(to: input)
		XCTAssertEqual(outcome.kept.map(\.relativePath), ["IMG_0002.HEIC", "IMG_0004.HEIC"])
		XCTAssertEqual(outcome.excluded.filter { $0.reason == .duplicate }.count, 2)
	}

	func testPhotosWithoutFingerprintAreNeverTreatedAsDuplicates()
	{
		// 指紋が取れない写真を「同じ」と決めつけない（消さない側に倒す）。
		let input = (1 ... 4).map
		{ index in
			SamplePhoto.make(index: index, secondsFromEpoch: Double(index), hash: nil)
		}
		let outcome = QualityFilter.apply(to: input)
		XCTAssertEqual(outcome.kept.count, 4)
	}

	// -----------------------------------------------------------------
	// 並び順
	// -----------------------------------------------------------------

	func testOrderingPrefersCaptureDateThenSequenceNumber()
	{
		let a = SamplePhoto.make(index: 5, secondsFromEpoch: 100, hash: 1)
		let b = SamplePhoto.make(index: 3, secondsFromEpoch: 50, hash: 2)
		XCTAssertEqual(PhotoOrdering.sorted([a, b]).map(\.relativePath),
			["IMG_0003.HEIC", "IMG_0005.HEIC"])

		// 時刻が無ければ連番。EXIF が剥がされた写真でも撮影順を復元する。
		let c = SamplePhoto.make(index: 12, hash: 1)
		let d = SamplePhoto.make(index: 7, hash: 2)
		XCTAssertEqual(PhotoOrdering.sorted([c, d]).map(\.relativePath),
			["IMG_0007.HEIC", "IMG_0012.HEIC"])
	}

	func testPhotosWithoutMeasuredQualityAreNotDropped()
	{
		// 画素を読めなかった写真（サムネイルが作れない等）は品質が nil になる。
		// 測れないことを理由に落とさない。
		let input = (1 ... 6).map
		{ index in
			PhotoMetadata(
				url: URL(fileURLWithPath: "/tmp/IMG_\(index).HEIC"),
				relativePath: "IMG_\(index).HEIC",
				captureDate: SamplePhoto.epoch.addingTimeInterval(Double(index)),
				pixelWidth: 4032,
				pixelHeight: 3024,
				fingerprint: PerceptualHash(bits: 0xAAAA),
				quality: nil)
		}
		let outcome = QualityFilter.apply(to: input)
		// 指紋が同じなので「ほぼ同一」の塊にはなるが、鮮鋭度で選べないので
		// 先頭が残る。落ちるのは重複としてだけ。
		XCTAssertEqual(outcome.kept.map(\.relativePath), ["IMG_1.HEIC"])
		XCTAssertTrue(outcome.excluded.allSatisfy { $0.reason == .duplicate })
		XCTAssertNil(outcome.sharpnessThreshold)
		XCTAssertNil(outcome.sharpnessMedian)
	}

	func testHammingDistanceNeedsBothFingerprints()
	{
		let withHash = SamplePhoto.make(index: 1, hash: 0b1011)
		let other = SamplePhoto.make(index: 2, hash: 0b1000)
		let without = SamplePhoto.make(index: 3, hash: nil)
		XCTAssertEqual(QualityFilter.hammingDistance(withHash, other), 2)
		XCTAssertEqual(QualityFilter.hammingDistance(withHash, without), 0)
	}

	func testSharpnessOfPhotoWithoutQualityIsZero()
	{
		XCTAssertEqual(QualityFilter.sharpness(of: SamplePhoto.make(index: 1, hash: 1)), 100)
		let measured = PhotoMetadata(
			url: URL(fileURLWithPath: "/tmp/a.HEIC"), relativePath: "a.HEIC")
		XCTAssertEqual(QualityFilter.sharpness(of: measured), 0)
	}

	func testEveryExclusionReasonHasADisplayName()
	{
		// 診断レポートに出る語彙。1 つでも欠けると「除外の内訳」が読めなくなる。
		for reason in ExclusionReason.allCases
		{
			XCTAssertFalse(reason.displayName.isEmpty, "\(reason.rawValue) の表示名が空です")
			XCTAssertNotEqual(reason.displayName, reason.rawValue)
		}
		XCTAssertEqual(ExclusionReason.unreadable.displayName, "読み取り失敗")
	}

	func testSequenceNumberParsing()
	{
		XCTAssertEqual(PhotoMetadata.sequenceNumber(fromName: "IMG_0123.HEIC"), 123)
		XCTAssertEqual(PhotoMetadata.sequenceNumber(fromName: "DSC01234.JPG"), 1234)
		XCTAssertEqual(PhotoMetadata.sequenceNumber(fromName: "photo.jpg"), nil)
		// 日時をそのまま名前にしたものは連番ではない（桁が多すぎる）。
		XCTAssertEqual(PhotoMetadata.sequenceNumber(fromName: "20260802134512999.jpg"), nil)
	}
}
