//
//  CancellationFlag.swift
//
//  「各段の切れ目で見る中断フラグ」。RealityKit のセッションのように中断 API を
//  持たない処理（写真の仕分け・ローカルへのコピー）で、待たされ続けないための
//  逃げ道として使う。
//
//  スレッドを跨いで立てられる（GUI のボタン・シグナルハンドラ → 処理スレッド）
//  ので、ロックで守った真偽値ひとつにしてある。生成（PhotogrammetryEngine.cancel）
//  はセッション自身が中断機構を持つので、これは使わない。
//

import Foundation

public final class CancellationFlag: @unchecked Sendable
{
	private let lock = NSLock()
	private var cancelled = false

	public init() {}

	public func cancel()
	{
		lock.lock()
		cancelled = true
		lock.unlock()
	}

	public var isCancelled: Bool
	{
		lock.lock()
		defer { lock.unlock() }
		return cancelled
	}
}

/// 仕分けの中断フラグ。中身は `CancellationFlag` そのもので、呼び出し側
/// （`PhotoSorter.run(_:cancellation:)`）の語彙を保つための別名。
public typealias SortCancellation = CancellationFlag
