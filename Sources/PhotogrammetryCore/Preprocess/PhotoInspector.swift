//
//  PhotoInspector.swift
//
//  写真ファイルから事実を読み出す唯一の層。ImageIO / CoreGraphics に触れるのは
//  ここだけで、PhotogrammetryEngine が RealityKit を閉じ込めているのと同じ扱い
//  （フレームワークの型を外へ漏らさない）。したがってこのファイルは
//  PhotogrammetryEngine と同様に自動テストの対象外で、挙動確認は実機か
//  ci-debug の run-cli で行う。判定そのものは PhotoMetadata から先の純ロジックが
//  持っているので、テストできないのは「読み取り」だけになる。
//
//  iPhone で撮ることを強く想定している。EXIF から取れるものは可能な限り取り、
//  かつ**そのまま信用しない**:
//
//    - 撮影時刻はサブ秒とタイムゾーンオフセットまで読む（連写は秒が同じになる）
//    - GPS は水平誤差と測位時刻を併せて読む。屋内では直前の屋外の測位がそのまま
//      書き込まれるので、「付いていること」を信用の根拠にしない
//    - 焦点距離（35mm 換算）を読む。iPhone は寄ると超広角へ自動で切り替わり、
//      混在したセッションはアライメントが不安定になる
//    - 露出（EV）を APEX から計算する。屋外から床下へ潜ると数段変わるので、
//      時刻も位置も無いときの環境の切れ目として使える
//

import CoreGraphics
import Foundation
import ImageIO

/// 走査で見つかった 1 ファイル。
public struct PhotoFile: Equatable, Sendable
{
	public var url: URL
	/// 入力フォルダからの相対パス。
	public var relativePath: String

	public init(url: URL, relativePath: String)
	{
		self.url = url
		self.relativePath = relativePath
	}

	/// 相対パスの親フォルダ（直下なら空文字）。
	public var folder: String
	{
		let components = relativePath.split(separator: "/")
		guard components.count > 1
		else
		{
			return ""
		}
		return components.dropLast().joined(separator: "/")
	}
}

/// 写真からメタデータを読む役。テストで差し替えられるようにプロトコルにして
/// ある（PhotoSorter は実ファイルを読まずに検証できる）。
public protocol PhotoMetadataReading: Sendable
{
	func read(_ file: PhotoFile) throws -> PhotoMetadata
}

public struct PhotoInspector: PhotoMetadataReading, Sendable
{
	/// 解析に使う縮小画像の最大辺（画素）。品質指標と知覚ハッシュはこの縮小
	/// 画像から求める。原寸で計算しても判定は変わらないうえ、数千枚では
	/// 時間が桁で変わるため。
	public var thumbnailSize: Int

	public init(thumbnailSize: Int = 256)
	{
		self.thumbnailSize = thumbnailSize
	}

	public func read(_ file: PhotoFile) throws -> PhotoMetadata
	{
		guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
			CGImageSourceGetCount(source) > 0
		else
		{
			throw PhotoInspectorError.unreadable(file.relativePath)
		}
		let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
		let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
		let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
		let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

		let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
		let captureDate = Self.captureDate(exif: exif, offset: offset)

		var metadata = PhotoMetadata(
			url: file.url,
			relativePath: file.relativePath,
			sourceFolder: file.folder,
			captureDate: captureDate,
			location: Self.location(gps: gps, canCompareTime: offset != nil),
			heading: gps[kCGImagePropertyGPSImgDirection] as? Double,
			focalLength35mm: (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue,
			lensModel: exif[kCGImagePropertyExifLensModel] as? String,
			cameraModel: tiff[kCGImagePropertyTIFFModel] as? String,
			pixelWidth: (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
			pixelHeight: (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0,
			exposureValue: Self.exposureValue(exif: exif),
			sequenceNumber: PhotoMetadata.sequenceNumber(
				fromName: (file.relativePath as NSString).lastPathComponent))

		if let gray = grayscale(source: source)
		{
			let profile = ImageStatistics.luminanceProfile(gray: gray.pixels)
			metadata.quality = PhotoQuality(
				sharpness: ImageStatistics.laplacianVariance(
					gray: gray.pixels, width: gray.width, height: gray.height),
				clippedHighlights: profile.clippedHighlights,
				clippedShadows: profile.clippedShadows,
				meanLuminance: profile.mean)
			metadata.fingerprint = ImageStatistics.differenceHash(
				gray: gray.pixels, width: gray.width, height: gray.height)
		}
		return metadata
	}

	/// 複数ファイルを並行して読む。数百〜数千枚を扱うので、1 枚ずつ読むと
	/// 待ち時間が実用外になる（デコードが支配的なのでコア数だけ効く）。
	///
	/// - Returns: 読めた写真と、読めなかったファイルの相対パス。
	public func inspectAll(
		_ files: [PhotoFile],
		progress: (@Sendable (Int, Int) -> Void)? = nil)
		-> (photos: [PhotoMetadata], unreadable: [String])
	{
		guard !files.isEmpty
		else
		{
			return ([], [])
		}
		let collector = InspectionCollector(total: files.count, progress: progress)
		let inspector = self
		DispatchQueue.concurrentPerform(iterations: files.count)
		{ index in
			let file = files[index]
			if let metadata = try? inspector.read(file)
			{
				collector.add(metadata)
			}
			else
			{
				collector.addFailure(file.relativePath)
			}
		}
		return collector.finish()
	}

	// -----------------------------------------------------------------
	// フォルダ走査
	// -----------------------------------------------------------------

	/// 入力フォルダの画像を列挙する。隠しファイルと、仕分け結果の予約フォルダ
	/// （`group-NN` / `_excluded` / `_unassigned`）は除く — 仕分け先を誤って
	/// 入力に指定したときに二重取り込みを起こさないため。
	public static func imageFiles(
		in folder: URL,
		recursive: Bool = true,
		fileManager: FileManager = .default) -> [PhotoFile]
	{
		var result: [PhotoFile] = []
		let root = folder.standardizedFileURL

		func scan(_ directory: URL, prefix: String)
		{
			let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
			for name in names.sorted()
			{
				if name.hasPrefix(".")
				{
					continue
				}
				let child = directory.appendingPathComponent(name)
				var isDirectory: ObjCBool = false
				guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory)
				else
				{
					continue
				}
				let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
				if isDirectory.boolValue
				{
					guard recursive, !isReservedFolderName(name)
					else
					{
						continue
					}
					scan(child, prefix: relative)
				}
				else if ReconstructionRequest.imageExtensions
					.contains((name as NSString).pathExtension.lowercased())
				{
					result.append(PhotoFile(url: child, relativePath: relative))
				}
			}
		}

		scan(root, prefix: "")
		return result
	}

	/// 仕分け結果として作られるフォルダ名か。
	public static func isReservedFolderName(_ name: String) -> Bool
	{
		name == SortLayout.excludedFolder || name == SortLayout.unassignedFolder
			|| name.hasPrefix("group-")
	}

	// -----------------------------------------------------------------
	// EXIF の解釈
	// -----------------------------------------------------------------

	/// 撮影時刻。サブ秒まで読むのは、連写だと秒が同じになって順序が崩れるため。
	/// タイムゾーンオフセットがあれば絶対時刻として正しく解釈する。
	static func captureDate(exif: [CFString: Any], offset: String?) -> Date?
	{
		guard let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
		else
		{
			return nil
		}
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
		formatter.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? TimeZone.current
		guard let date = formatter.date(from: text)
		else
		{
			return nil
		}
		guard let subsecond = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
			let fraction = Double("0.\(subsecond)")
		else
		{
			return date
		}
		return date.addingTimeInterval(fraction)
	}

	/// "+09:00" 形式のオフセットを TimeZone にする。
	static func timeZone(fromOffset text: String) -> TimeZone?
	{
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		guard trimmed.count >= 3, let sign = trimmed.first, sign == "+" || sign == "-"
		else
		{
			return nil
		}
		let digits = trimmed.dropFirst().split(separator: ":")
		guard let hours = Int(digits.first ?? "")
		else
		{
			return nil
		}
		let minutes = digits.count > 1 ? Int(digits[1]) ?? 0 : 0
		let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
		return TimeZone(secondsFromGMT: seconds)
	}

	/// GPS 辞書から位置を組み立てる。
	///
	/// - Parameter canCompareTime: 撮影時刻を UTC として確定できたか。できて
	///   いないときに測位時刻を入れると、タイムゾーンのずれを「古い測位」と
	///   誤判定して位置情報を丸ごと捨ててしまう。判定材料が無いときは黙って
	///   持たせない（水平誤差だけで判断させる）。
	static func location(gps: [CFString: Any], canCompareTime: Bool) -> GeoLocation?
	{
		guard let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
			let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
		else
		{
			return nil
		}
		let latitudeRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
		let longitudeRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"

		var altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue
		if let reference = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue,
			reference == 1, let value = altitude
		{
			// AltitudeRef = 1 は海面下。
			altitude = -value
		}

		return GeoLocation(
			latitude: latitudeRef.uppercased() == "S" ? -latitude : latitude,
			longitude: longitudeRef.uppercased() == "W" ? -longitude : longitude,
			altitude: altitude,
			horizontalAccuracy: (gps[kCGImagePropertyGPSHPositioningError] as? NSNumber)?.doubleValue,
			timestamp: canCompareTime ? fixTimestamp(gps: gps) : nil)
	}

	/// GPS の測位時刻（UTC）。日付と時刻が別のタグに入っている。
	static func fixTimestamp(gps: [CFString: Any]) -> Date?
	{
		guard let day = gps[kCGImagePropertyGPSDateStamp] as? String,
			let time = gps[kCGImagePropertyGPSTimeStamp] as? String
		else
		{
			return nil
		}
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
		// 秒に小数が付くことがある（"04:45:12.00"）ので落とす。
		let seconds = time.split(separator: ".").first.map(String.init) ?? time
		return formatter.date(from: "\(day) \(seconds)")
	}

	/// 露出値 EV（ISO 100 換算）。APEX の定義そのまま。絞りとシャッター速度が
	/// 無ければ EXIF の BrightnessValue で代用する。
	static func exposureValue(exif: [CFString: Any]) -> Double?
	{
		let aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
		let time = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
		let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
		if let aperture, aperture > 0, let time, time > 0
		{
			var value = log2(aperture * aperture / time)
			if let iso = speeds?.first?.doubleValue, iso > 0
			{
				value -= log2(iso / 100)
			}
			return value
		}
		return (exif[kCGImagePropertyExifBrightnessValue] as? NSNumber)?.doubleValue
	}

	// -----------------------------------------------------------------
	// 画素
	// -----------------------------------------------------------------

	/// 縮小したグレースケール画素を取り出す。回転（Orientation）は ImageIO に
	/// 正規化させる — 縦位置で撮った写真の指紋が横位置と食い違わないようにするため。
	func grayscale(source: CGImageSource) -> (pixels: [UInt8], width: Int, height: Int)?
	{
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
		]
		guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
		else
		{
			return nil
		}
		let width = image.width
		let height = image.height
		guard width > 0, height > 0,
			let context = CGContext(
				data: nil,
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: width,
				space: CGColorSpaceCreateDeviceGray(),
				bitmapInfo: CGImageAlphaInfo.none.rawValue)
		else
		{
			return nil
		}
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		guard let data = context.data
		else
		{
			return nil
		}
		let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
		var pixels = [UInt8]()
		pixels.reserveCapacity(width * height)
		for row in 0 ..< height
		{
			pixels.append(contentsOf: UnsafeBufferPointer(
				start: bytes + row * context.bytesPerRow, count: width))
		}
		return (pixels, width, height)
	}
}

public enum PhotoInspectorError: Error, LocalizedError, Equatable
{
	case unreadable(String)

	public var errorDescription: String?
	{
		switch self
		{
			case .unreadable(let path):
				return "画像として読み取れませんでした: \(path)"
		}
	}
}

/// 並行読み取りの結果をまとめる。イベントと同じくスレッドを跨ぐのでロックで守る。
final class InspectionCollector: @unchecked Sendable
{
	private let lock = NSLock()
	private var photos: [PhotoMetadata] = []
	private var failures: [String] = []
	private var done = 0
	private let total: Int
	private let progress: (@Sendable (Int, Int) -> Void)?

	init(total: Int, progress: (@Sendable (Int, Int) -> Void)?)
	{
		self.total = total
		self.progress = progress
		photos.reserveCapacity(total)
	}

	func add(_ metadata: PhotoMetadata)
	{
		lock.lock()
		photos.append(metadata)
		done += 1
		let current = done
		lock.unlock()
		progress?(current, total)
	}

	func addFailure(_ path: String)
	{
		lock.lock()
		failures.append(path)
		done += 1
		let current = done
		lock.unlock()
		progress?(current, total)
	}

	/// 並行に集めたので順序は不定。相対パスで安定した順序へ戻す
	/// （以降の処理を決定的にするため）。
	func finish() -> (photos: [PhotoMetadata], unreadable: [String])
	{
		lock.lock()
		defer { lock.unlock() }
		return (photos.sorted { $0.relativePath < $1.relativePath }, failures.sorted())
	}
}
