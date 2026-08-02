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
	/// 現在の処理段階。割合だけでは足りない長時間処理のために出す。段階が
	/// 分かると失敗の切り分けにも効く（位置合わせまで到達したのか、その前か）。
	case stage(ProcessingStage)
	/// 残り時間の見積もり（秒）。
	///
	/// 段階と残り時間を別のイベントにしてあるのは、OS が片方しか返さないこと
	/// があるうえ、ヘルパープロトコルが 1 イベント = 1 行だから（HelperProtocol）。
	case estimatedRemainingTime(TimeInterval)
	/// 個々の写真のスキップ・無効などの注意情報（処理は続行している）。
	case note(String)
	/// モデルファイルが書き出された。
	case completed(URL)
	/// キャンセルにより中断した。
	case cancelled
}
