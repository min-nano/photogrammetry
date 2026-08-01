//
//  ErrorDetailsTests.swift
//
//  エラー詳細の整形（domain / code / userInfo / underlying の展開）をテストする。
//  実際の PhotogrammetrySession の失敗（CoreOC ドメインのエラー）を模した
//  NSError で、調査に必要な情報が確実にログへ出ることを確かめる。
//

import XCTest

@testable import PhotogrammetryCore

final class ErrorDetailsTests: XCTestCase
{
	func testDescribeIncludesDomainAndCode()
	{
		// 実際に観測された「エラー 6」の形。
		let error = NSError(
			domain: "CoreOC.PhotogrammetrySession.Error",
			code: 6,
			userInfo: [NSLocalizedDescriptionKey: "操作を完了できませんでした。"])
		let text = ErrorDetails.describe(error)
		XCTAssertTrue(text.contains("操作を完了できませんでした。"), text)
		XCTAssertTrue(text.contains("domain=CoreOC.PhotogrammetrySession.Error"), text)
		XCTAssertTrue(text.contains("code=6"), text)
	}

	func testDescribeIncludesUserInfoAndUnderlyingChain()
	{
		let underlying = NSError(domain: "Inner", code: -42, userInfo: [:])
		let error = NSError(
			domain: "Outer",
			code: 1,
			userInfo: [
				"Reason": "alignment failed",
				NSUnderlyingErrorKey: underlying,
			])
		let text = ErrorDetails.describe(error)
		XCTAssertTrue(text.contains("Reason=alignment failed"), text)
		XCTAssertTrue(text.contains("underlying:"), text)
		XCTAssertTrue(text.contains("domain=Inner code=-42"), text)
	}

	func testDescribeDoesNotDuplicateLocalizedDescription()
	{
		let error = NSError(
			domain: "X", code: 0,
			userInfo: [NSLocalizedDescriptionKey: "一度だけ出るべきメッセージ"])
		let text = ErrorDetails.describe(error)
		let occurrences = text.components(separatedBy: "一度だけ出るべきメッセージ").count - 1
		XCTAssertEqual(occurrences, 1, text)
	}

	func testDescribeSwiftError()
	{
		// Swift のエラーも NSError ブリッジ経由で domain / code が出る。
		let text = ErrorDetails.describe(RequestError.outputExtensionInvalid("/x.obj"))
		XCTAssertTrue(text.contains(".usdz"), text)
		XCTAssertTrue(text.contains("domain="), text)
	}
}
