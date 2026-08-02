//
//  ReconstructionEvent.swift
//
//  生成処理中にフロントエンドへ流す進捗イベント。同一プロセスで実行する
//  PhotogrammetryEngine と、別プロセスで実行する HelperProcessEngine の
//  どちらも同じイベントを流すので、型はエンジンから独立させてある。
//
//  UI スレッドへの hop は受け取り側の責任（エンジンはスレッドを知らない）。
//

import Foundation

/// 生成 1 回分の進行状況。
public enum ReconstructionEvent: Equatable, Sendable
{
	/// リクエスト全体の進捗（0.0〜1.0）。
	case progress(Double)
	/// 個々の写真のスキップ・無効などの注意情報（処理は続行している）。
	case note(String)
	/// モデルファイルが書き出された。
	case completed(URL)
	/// キャンセルにより中断した。
	case cancelled
}
