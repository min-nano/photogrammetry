//
//  ModelCache.swift
//
//  Object Capture が使う機械学習モデルのコンパイル済みキャッシュ（E5RT の
//  バンドルキャッシュ）の扱い。
//
//  CorePhotogrammetry は再構成の途中で Apple Neural Engine 用の ML モデルを
//  使う。そのモデルは初回に ANE 向けへコンパイルされ、
//  ~/Library/Caches/<バンドル ID>/com.apple.e5rt.e5bundlecache/… へ保存される。
//  このコンパイルが失敗するとバンドルが不完全なまま残り（目録の
//  manifest.plist が無い状態）、以降は**毎回まったく同じ進捗で**内部アサート →
//  abort() に至る。実機で報告された 49% のクラッシュはこれだった。
//
//  写真にもフォルダにも原因が無い（＝詳細度や枚数をいくら変えても直らない）
//  一方、壊れたキャッシュを消せば OS が作り直すので確実に復旧する。したがって
//  「この失敗を見分けて、消すべき場所を名指しする」ことに価値がある。
//

import Foundation

public enum ModelCache
{
	/// コンパイル済みモデルが入るディレクトリ名（E5RT が決めている名前）。
	public static let bundleCacheDirectoryName = "com.apple.e5rt.e5bundlecache"

	/// このアプリのコンパイル済みモデルキャッシュの場所。キャッシュは
	/// バンドル ID ごとに分かれるので、バンドル ID が無い実行形態
	/// （素の CLI など）では nil を返す。
	public static func directory(
		bundleIdentifier: String? = Bundle.main.bundleIdentifier,
		fileManager: FileManager = .default) -> URL?
	{
		guard let bundleIdentifier, !bundleIdentifier.isEmpty,
			let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
		else
		{
			return nil
		}
		return caches
			.appendingPathComponent(bundleIdentifier, isDirectory: true)
			.appendingPathComponent(bundleCacheDirectoryName, isDirectory: true)
	}

	/// ヘルパーの出力がモデルのコンパイル失敗を示しているか。実機で観測した
	/// 3 行（順に manifest.plist が無い / 内部アサート / E5RT の例外）は
	/// 1 つの因果の連なりで、どれが取れても同じ結論になる。
	public static func isCompilationFailure(_ message: String) -> Bool
	{
		failureMarkers.contains { message.contains($0) }
	}

	/// 復旧手順の説明。消す場所を具体的に示さないと手の打ちようがないので、
	/// 実際のパスを埋めて返す。
	public static func recoveryAdvice(directory: URL?) -> [String]
	{
		[
			"原因は Apple Neural Engine 用の機械学習モデルのキャッシュが壊れていることです"
				+ "（ANE へのコンパイルに失敗しています）。写真や設定は関係ありません。",
			"次のフォルダを削除してから、もう一度実行してください（OS が作り直します）:",
			"  \(directory?.path ?? placeholderPath)",
			"アプリのエラー表示に出る「ML モデルのキャッシュを削除」ボタンからも削除できます。",
		]
	}

	/// コンパイル済みモデルのキャッシュを削除する。消したら true、
	/// もともと無ければ false。
	@discardableResult
	public static func purge(
		directory: URL? = ModelCache.directory(),
		fileManager: FileManager = .default) throws -> Bool
	{
		guard let directory
		else
		{
			throw ModelCacheError.directoryUnavailable
		}
		// 呼び出し側の取り違えで無関係なフォルダを消さないための歯止め。
		guard directory.lastPathComponent == bundleCacheDirectoryName
		else
		{
			throw ModelCacheError.unexpectedDirectory(directory.path)
		}
		guard fileManager.fileExists(atPath: directory.path)
		else
		{
			return false
		}
		try fileManager.removeItem(at: directory)
		return true
	}

	/// バンドル ID が分からないときに説明へ埋める代替表記。
	static let placeholderPath = "~/Library/Caches/<アプリのバンドル ID>/\(bundleCacheDirectoryName)"

	/// 失敗を示す手掛かり。ANE コンパイラ・E5RT・MPSGraph のいずれの層の
	/// メッセージでも拾えるようにしてある。
	static let failureMarkers = [
		"ANECCompile",
		"MILCompilerForANE",
		bundleCacheDirectoryName,
		"MPSGraphExecutable",
		"manifest.plist",
	]
}

public enum ModelCacheError: Error, LocalizedError, Equatable
{
	case directoryUnavailable
	case unexpectedDirectory(String)

	public var errorDescription: String?
	{
		switch self
		{
			case .directoryUnavailable:
				return "モデルキャッシュの場所を特定できません（アプリのバンドル ID が不明です）。"
			case .unexpectedDirectory(let path):
				return "モデルキャッシュとして扱えない場所です: \(path)"
		}
	}
}
