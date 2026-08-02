//
//  PhotoMetadata.swift
//
//  写真 1 枚から取り出した「事実」だけを持つ値型。ImageIO / 画素統計に触るのは
//  PhotoInspector だけで、この型から先（品質フィルタ・グルーピング・計画・診断）は
//  すべて純ロジックになる。PhotogrammetryEngine が RealityKit を閉じ込めているのと
//  同じ構造で、こうしておくと仕分けの判断を GPU も写真も無しに swift test で回せる。
//
//  取れる項目は撮影機材と経路で大きく変わる（iPhone の HEIC は EXIF が豊富だが、
//  転送アプリを経由すると剥がされる）。したがってほぼ全項目が Optional で、
//  「無いものは証拠として使わない」がグルーピング側の原則になる（PhotoGrouping）。
//

import Foundation

/// 知覚ハッシュ（difference hash）。写真の縮小グレースケールから作る 64 bit の
/// 指紋で、**Vision を使わずに常時利用できる視覚的な手がかり**として使う。
///
/// フェーズ 2 で Vision の feature print を導入したあとも、ほぼ同一の重複検出
/// （連写・立ち止まったままのシャッター連打）はこちらのほうが安く確実なので残す。
public struct PerceptualHash: Equatable, Hashable, Sendable
{
	/// 上位ビットから行優先で並んだ比較結果。
	public var bits: UInt64

	/// ハッシュの総ビット数。距離の正規化に使う。
	public static let bitCount = 64

	public init(bits: UInt64)
	{
		self.bits = bits
	}

	/// ハミング距離（0〜64）。小さいほど見た目が似ている。
	public func distance(to other: PerceptualHash) -> Int
	{
		(bits ^ other.bits).nonzeroBitCount
	}

	/// ハミング距離を 0.0〜1.0 へ正規化したもの。閾値をビット数に依存させない
	/// ため、外へ出す距離はこちらを使う。
	public func normalizedDistance(to other: PerceptualHash) -> Double
	{
		Double(distance(to: other)) / Double(Self.bitCount)
	}
}

/// EXIF から読んだ撮影位置。緯度経度だけでなく**確からしさ**（水平誤差・測位時刻）
/// も持つ。屋内（床下・小屋裏）では iPhone が直前の屋外での測位をそのまま書き込む
/// ことがあり、これを信じると別の部屋を同じ場所と判定してしまうため。
public struct GeoLocation: Equatable, Sendable
{
	public var latitude: Double
	public var longitude: Double
	/// 海抜高度（m）。iPhone は気圧計を融合させるので階の分離に効くことがある。
	public var altitude: Double?
	/// EXIF `GPSHPositioningError`（m）。屋内では数十〜数百 m になる。
	public var horizontalAccuracy: Double?
	/// 測位時刻（UTC）。撮影時刻との差が大きいものは「古い測位」。
	public var timestamp: Date?

	public init(
		latitude: Double,
		longitude: Double,
		altitude: Double? = nil,
		horizontalAccuracy: Double? = nil,
		timestamp: Date? = nil)
	{
		self.latitude = latitude
		self.longitude = longitude
		self.altitude = altitude
		self.horizontalAccuracy = horizontalAccuracy
		self.timestamp = timestamp
	}

	/// 2 点間の水平距離（m）。建物 1 棟の範囲しか扱わないので、地球を球とみなす
	/// ハバーサイン公式で十分（誤差は数 cm 未満）。
	public func horizontalDistance(to other: GeoLocation) -> Double
	{
		let earthRadius = 6_371_000.0
		let toRadians = Double.pi / 180
		let lat1 = latitude * toRadians
		let lat2 = other.latitude * toRadians
		let deltaLatitude = (other.latitude - latitude) * toRadians
		let deltaLongitude = (other.longitude - longitude) * toRadians
		let a =
			sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
			+ cos(lat1) * cos(lat2) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
		return 2 * earthRadius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
	}

	/// 高度差（m）。どちらかに高度が無ければ nil。
	public func verticalDistance(to other: GeoLocation) -> Double?
	{
		guard let a = altitude, let b = other.altitude
		else
		{
			return nil
		}
		return abs(a - b)
	}
}

/// 画素から測った品質。閾値はここでは決めない（現場ごとに分布が違うので、
/// QualityFilter が分布から自動決定する）。
public struct PhotoQuality: Equatable, Sendable
{
	/// ラプラシアン分散（生値）。大きいほどエッジが立っている＝ブレていない。
	/// 絶対値の意味は被写体依存なので、判定は必ず分布との相対で行う。
	public var sharpness: Double
	/// 白飛びしている画素の割合（0.0〜1.0）。小屋裏のフラッシュ撮影で出やすい。
	public var clippedHighlights: Double
	/// 黒つぶれしている画素の割合（0.0〜1.0）。床下の暗所で出やすい。
	public var clippedShadows: Double
	/// 平均輝度（0.0〜1.0）。
	public var meanLuminance: Double

	public init(
		sharpness: Double,
		clippedHighlights: Double,
		clippedShadows: Double,
		meanLuminance: Double)
	{
		self.sharpness = sharpness
		self.clippedHighlights = clippedHighlights
		self.clippedShadows = clippedShadows
		self.meanLuminance = meanLuminance
	}
}

/// 写真 1 枚分のメタデータ。
public struct PhotoMetadata: Equatable, Sendable
{
	/// 実ファイルの位置。
	public var url: URL
	/// 入力フォルダからの相対パス。manifest に載る識別子であり、サブフォルダ
	/// 走査時にファイル名の衝突を避ける鍵でもある。
	public var relativePath: String
	/// 相対パスの親フォルダ（直下なら空文字）。撮影者が階・部屋ごとに分けて
	/// くれている場合、これ自体が最も信頼できる区切りの証拠になる。
	public var sourceFolder: String
	/// 撮影時刻（EXIF DateTimeOriginal + SubsecTimeOriginal）。
	public var captureDate: Date?
	/// 撮影位置。
	public var location: GeoLocation?
	/// カメラの方位（真北 0 度・時計回り）。外壁のどの面を撮ったかの判定に使う。
	public var heading: Double?
	/// 35mm 換算焦点距離。iPhone は寄ると自動で超広角へ切り替わることがあり、
	/// レンズが混在したセッションは Object Capture が不安定になるので検出する。
	public var focalLength35mm: Double?
	/// レンズ名（EXIF LensModel）。
	public var lensModel: String?
	/// カメラの機種名（EXIF TIFF Model）。機材混在の検出に使う。
	public var cameraModel: String?
	/// 画素数。
	public var pixelWidth: Int
	public var pixelHeight: Int
	/// 露出値 EV（ISO 100 換算）。屋外 → 床下のような環境の切り替わりが
	/// 数段の差になって現れるので、時刻も GPS も無いときの区切りの手がかりになる。
	public var exposureValue: Double?
	/// 知覚ハッシュ。
	public var fingerprint: PerceptualHash?
	/// 画素から測った品質。
	public var quality: PhotoQuality?
	/// ファイル名に含まれる連番（IMG_0123 → 123）。EXIF が剥がされた写真でも
	/// 撮影順を復元できることがある。
	public var sequenceNumber: Int?

	public init(
		url: URL,
		relativePath: String,
		sourceFolder: String = "",
		captureDate: Date? = nil,
		location: GeoLocation? = nil,
		heading: Double? = nil,
		focalLength35mm: Double? = nil,
		lensModel: String? = nil,
		cameraModel: String? = nil,
		pixelWidth: Int = 0,
		pixelHeight: Int = 0,
		exposureValue: Double? = nil,
		fingerprint: PerceptualHash? = nil,
		quality: PhotoQuality? = nil,
		sequenceNumber: Int? = nil)
	{
		self.url = url
		self.relativePath = relativePath
		self.sourceFolder = sourceFolder
		self.captureDate = captureDate
		self.location = location
		self.heading = heading
		self.focalLength35mm = focalLength35mm
		self.lensModel = lensModel
		self.cameraModel = cameraModel
		self.pixelWidth = pixelWidth
		self.pixelHeight = pixelHeight
		self.exposureValue = exposureValue
		self.fingerprint = fingerprint
		self.quality = quality
		self.sequenceNumber = sequenceNumber
	}

	/// 画像の縦横比（常に 1.0 以上）。パノラマの検出に使う。
	public var aspectRatio: Double
	{
		guard pixelWidth > 0, pixelHeight > 0
		else
		{
			return 1
		}
		let longer = Double(max(pixelWidth, pixelHeight))
		let shorter = Double(min(pixelWidth, pixelHeight))
		return longer / shorter
	}

	/// 位置情報を証拠として使ってよいか。
	///
	/// 屋内で撮ると iPhone は最後の測位をそのまま書き込むことがある。**位置が
	/// 付いていること自体は信用の根拠にならない**ので、水平誤差と測位時刻の
	/// 古さで足切りする。撮影時刻の UTC が確定できない場合（タイムゾーン
	/// オフセットが EXIF に無い）は古さの判定を行わず、誤差だけで判断する。
	public func hasTrustworthyLocation(
		maximumAccuracy: Double,
		maximumAge: TimeInterval) -> Bool
	{
		guard let location
		else
		{
			return false
		}
		if let accuracy = location.horizontalAccuracy, accuracy > maximumAccuracy
		{
			return false
		}
		if let fix = location.timestamp, let captured = captureDate
		{
			if abs(fix.timeIntervalSince(captured)) > maximumAge
			{
				return false
			}
		}
		return true
	}

	/// ファイル名末尾の数字列を連番として取り出す（IMG_0123.HEIC → 123）。
	/// 桁が多すぎるもの（日時をそのまま名前にしたもの）は連番ではないので捨てる。
	public static func sequenceNumber(fromName name: String) -> Int?
	{
		let stem = (name as NSString).deletingPathExtension
		var digits: [Character] = []
		for character in stem.reversed()
		{
			if character.isNumber
			{
				digits.append(character)
			}
			else if digits.isEmpty
			{
				continue
			}
			else
			{
				break
			}
		}
		guard !digits.isEmpty, digits.count <= 8
		else
		{
			return nil
		}
		return Int(String(digits.reversed()))
	}
}
