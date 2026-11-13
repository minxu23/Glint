// 一张图的信息：格式、像素尺寸、拍摄时间、相机、位置、备注。
//
// 只依赖 Foundation 与 ImageIO，不依赖 AppKit，由 Tests/guimodel 直接测。
// 读取（PhotoInfo.read）会碰磁盘，只在后台队列上调用（函数开头有 dispatchPrecondition）；
// 这里的其余部分都是纯函数。

import Eclose
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 格式

/// 界面上说的「格式」。按扩展名定：列文件那一步要快，不打开文件。JPEG 与 RAW 的扩展名用 Eclose 的
/// SourceKind.extensions（与命令行扫目录同一份清单）。转不转仍由 Eclose 按内容判定：内容与扩展名
/// 不符的（改了扩展名的 HEIC、小到被 ImageIO 当成 TIFF 的 DNG）转换时跳过并说明原因。
///
/// 相机 RAW 统一叫「RAW」，不分 CR3、NEF、ARW：副标题、汇总、排序都按格式归类，相机的 RAW 是
/// 同一类东西（都能转、都不删）；具体是哪家的 RAW 看文件名的扩展名就知道。
enum ImageFormat: Hashable {
    case jpeg, raw, heif
    case other(String)

    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        if SourceKind.jpeg.extensions.contains(ext) {
            self = .jpeg
        } else if SourceKind.raw.extensions.contains(ext) {
            self = .raw
        } else if ["heic", "heif", "hif"].contains(ext) {
            self = .heif
        } else {
            let names = ["tif": "TIFF", "jpf": "JPEG 2000", "jp2": "JPEG 2000"]
            self = .other(names[ext] ?? (ext.isEmpty ? "图片" : ext.uppercased()))
        }
    }

    var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .raw: return "RAW"
        case .heif: return "HEIF"
        case .other(let name): return name
        }
    }

    /// 能转的源是哪一种；不能转的格式是 nil。
    var sourceKind: SourceKind? {
        switch self {
        case .jpeg: return .jpeg
        case .raw: return .raw
        default: return nil
        }
    }

    /// 排序用的先后：能转的 JPEG、RAW 在前，然后 HEIF，其余按名字。
    var sortKey: String {
        switch self {
        case .jpeg: return "0"
        case .raw: return "1"
        case .heif: return "2"
        case .other(let name): return "3" + name
        }
    }

    /// 扫描时只收这些：扩展名对应的 UTType 符合 public.image。
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

// MARK: - 缩略图的取法

/// `src` 是不是相机 RAW：按内容，CGImageSourceGetType 给的类型符合 public.camera-raw-image
/// （与 Eclose 判定 RAW 是同一条）。
func isCameraRAW(_ src: CGImageSource) -> Bool {
    guard let type = CGImageSourceGetType(src) as String?, let t = UTType(type) else { return false }
    return t.conforms(to: .rawImage)
}

/// 生成缩略图时交给 CGImageSourceCreateThumbnailAtIndex 的选项：长边不超过 `maxPixels`，按 EXIF
/// 方向转正。`fromPreview` 为真时文件里有内嵌的缩略图或预览就用它（FromImageIfAbsent），否则从全图
/// 缩（FromImageAlways）。
func thumbnailOptions(fromPreview: Bool, maxPixels: Int) -> [CFString: Any] {
    [
        fromPreview ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        kCGImageSourceShouldCacheImmediately: true,
    ]
}

/// 生成一张缩略图：长边不超过 `maxPixels`，按 EXIF 方向转正。会读文件，只在后台调用。
/// - JPEG 等：从全图缩。文件里自带的 EXIF 缩略图常常只有 160×120，放大了是糊的。
/// - 相机 RAW：先用内嵌的预览。RAW 的「全图」要整幅显影，又慢又吃内存（手写的 6000×4000 DNG
///   实测：从预览出 336 px 的缩略图 73 ms、峰值内存 19 MB；整幅显影 217 ms、259 MB），网格里一屏
///   几十张会把缩略图队列和内存都占满。预览的长边不到要的一半（只带了一张小缩略图）时才整幅显影，
///   免得网格里一片糊。
func makeThumbnail(_ src: CGImageSource, maxPixels: Int) -> CGImage? {
    if isCameraRAW(src),
       let preview = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbnailOptions(fromPreview: true, maxPixels: maxPixels) as CFDictionary),
       max(preview.width, preview.height) * 2 >= maxPixels {
        return preview
    }
    return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbnailOptions(fromPreview: false, maxPixels: maxPixels) as CFDictionary)
}

// MARK: - 拍摄时间

/// EXIF 的拍摄时间原样的年月日时分秒，不带时区：照片上写的是拍摄地的钟点，
/// 换算成本机时区反而会把「晚上 8 点拍的」显示成别的钟点。
struct CaptureTime: Comparable, Hashable {
    var year, month, day, hour, minute, second: Int

    /// EXIF 写法 `2026:04:27 20:28:41`；读不出是 nil。
    init?(exif: String) {
        let digits = exif.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count >= 5, digits[0] > 0, (1...12).contains(digits[1]), (1...31).contains(digits[2]),
              (0...23).contains(digits[3]), (0...59).contains(digits[4])
        else { return nil }
        self.init(year: digits[0], month: digits[1], day: digits[2], hour: digits[3], minute: digits[4],
                  second: digits.count > 5 ? digits[5] : 0)
    }

    init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        (self.year, self.month, self.day, self.hour, self.minute, self.second) = (year, month, day, hour, minute, second)
    }

    /// 本机时区下的钟点。文件的修改时间用它显示，也给没有拍摄时间的图排序用。
    init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                  hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }

    /// `2026 年 4 月 27 日 20:28`
    var display: String {
        String(format: "%d 年 %d 月 %d 日 %02d:%02d", year, month, day, hour, minute)
    }

    /// 列表里的短写法：`2026-04-27 20:28`
    var compact: String {
        String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
    }

    private var tuple: [Int] { [year, month, day, hour, minute, second] }
    static func < (a: CaptureTime, b: CaptureTime) -> Bool { a.tuple.lexicographicallyPrecedes(b.tuple) }
}

// MARK: - 位置

struct GeoPoint: Equatable {
    var latitude: Double
    var longitude: Double

    /// `51.0530° N，13.7343° E`
    var display: String {
        String(format: "%.4f° %@，%.4f° %@", abs(latitude), latitude >= 0 ? "N" : "S",
               abs(longitude), longitude >= 0 ? "E" : "W")
    }

    /// 「在地图中打开」用的链接。
    var mapsURL: URL? {
        URL(string: String(format: "maps://?ll=%.6f,%.6f&q=%.6f,%.6f", latitude, longitude, latitude, longitude))
    }
}

// MARK: - 备注

/// 备注从哪读到的。
enum NoteOrigin: CaseIterable, Equatable {
    /// 「照片」App 的说明：扩展属性 com.apple.assetsd.description。
    case photos
    /// 访达备注：扩展属性 com.apple.metadata:kMDItemFinderComment。
    case finder
    /// 文件里的说明：XMP dc:description、IPTC Caption/Abstract、TIFF ImageDescription。
    case fileDescription
    /// EXIF UserComment。
    case exifComment

    var isInFile: Bool { self == .fileDescription || self == .exifComment }
}

/// 信息栏里的一条备注：一段文字，和它在哪些地方出现过。
struct Note: Equatable {
    let text: String
    var origins: [NoteOrigin]

    enum Place: Equatable {
        /// 只在文件之外（扩展属性）：换设备、传网盘容易丢。
        case outside
        /// 只在文件里；`exifOnly` 是只在 EXIF 备注里。
        case inFile(exifOnly: Bool)
        /// 文件里外各有一份。
        case both
    }

    var place: Place {
        let inside = origins.filter(\.isInFile)
        if inside.isEmpty { return .outside }
        if inside.count == origins.count { return .inFile(exifOnly: inside.allSatisfy { $0 == .exifComment }) }
        return .both
    }

    /// 备注下面那行小字。
    var placeText: String {
        switch place {
        case .outside: return "存在文件之外，换设备或传网盘容易丢"
        case .inFile(let exifOnly): return exifOnly ? "存在文件里（EXIF 备注）" : "存在文件里"
        case .both: return "文件里外各有一份"
        }
    }

    /// 小字前面要不要放橙色三角：只有只存在文件之外的那种。
    var isAtRisk: Bool { place == .outside }
}

/// 把各处读到的文字并成信息栏里的那几条：去掉首尾空白，空的不要；
/// 同一段文字（去掉首尾空白后相同）只留一条，记下它出现过的每一处。顺序按第一次出现。
func mergeNotes(_ found: [(NoteOrigin, String)]) -> [Note] {
    var notes: [Note] = []
    for (origin, raw) in found {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        if let i = notes.firstIndex(where: { $0.text == text }) {
            if !notes[i].origins.contains(origin) { notes[i].origins.append(origin) }
        } else {
            notes.append(Note(text: text, origins: [origin]))
        }
    }
    return notes
}

// MARK: - 一张图的信息

struct PhotoInfo: Equatable {
    /// 按 EXIF 方向转正之后的宽高。
    var pixelWidth: Int?
    var pixelHeight: Int?
    var captured: CaptureTime?
    var make: String?
    var model: String?
    var lens: String?
    var fNumber: Double?
    var exposureTime: Double?
    var iso: Int?
    var focalLength: Double?
    var location: GeoPoint?
    var notes: [Note] = []
    /// 「照片」的说明在、而文件里没有说明字段——勾「把备注写进文件」能写进去的那种
    /// （判定用 Eclose 的 captionCanBeEmbedded，与转换时同一把尺子）。它只对 JPEG 说「能」：RAW 的
    /// 这一项总是 false，面板上「这批里有几张的备注存在文件之外」不数 RAW。
    var captionOutsideOnly = false
    /// 色彩模型是 CMYK（判定用 Eclose 的 isCMYK，与转换时同一把尺子）。这种 JPEG 转换时默认跳过。
    var isCMYK = false

    var hasNotes: Bool { !notes.isEmpty }

    /// 信息栏「相机」那一行：型号；没有型号时用厂商。
    var cameraName: String? {
        if let model, !model.isEmpty { return model }
        if let make, !make.isEmpty { return make }
        return nil
    }

    /// `f/1.4，1/50 秒，ISO 640，24 mm`，有几项写几项；一项都没有是 nil。
    var exposureLine: String? {
        var parts: [String] = []
        if let f = fNumber, f > 0 { parts.append("f/" + trimmedNumber(f, decimals: 1)) }
        if let t = exposureTime, t > 0 {
            parts.append(t < 1 ? "1/\(Int((1 / t).rounded())) 秒" : trimmedNumber(t, decimals: 1) + " 秒")
        }
        if let iso, iso > 0 { parts.append("ISO \(iso)") }
        if let mm = focalLength, mm > 0 { parts.append(trimmedNumber(mm, decimals: 1) + " mm") }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    var dimensions: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return "\(w) × \(h)"
    }
}

/// 去掉多余的 0：1.4 → "1.4"，2.0 → "2"。
func trimmedNumber(_ v: Double, decimals: Int) -> String {
    let s = String(format: "%.\(decimals)f", v)
    guard s.contains(".") else { return s }
    var t = s
    while t.hasSuffix("0") { t.removeLast() }
    if t.hasSuffix(".") { t.removeLast() }
    return t
}

/// 界面上的文件大小：`3.3 MB`、`989 KB`、`612 MB`。十以下留一位小数，其余取整；
/// 进位与 Eclose 的 humanSize 相同（1024）。
func shortSize(_ bytes: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(bytes), i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    if i == 0 { return "\(bytes) B" }
    let rounded = v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    return rounded + " " + units[i]
}

// MARK: - 从文件读

extension PhotoInfo {
    /// 读一张图的信息。会打开文件，只能在后台调用。读不出图像时只有扩展属性里的备注。
    static func read(_ url: URL) -> PhotoInfo {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var info = PhotoInfo()
        var found: [(NoteOrigin, String)] = []
        if let s = photosCaption(of: url) { found.append((.photos, s)) }
        if let s = finderComment(of: url) { found.append((.finder, s)) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, options), CGImageSourceGetCount(src) > 0 else {
            info.notes = mergeNotes(found)
            return info
        }
        let props = imageProperties(src)
        let index = (CGImageSourceCopyPropertiesAtIndex(src, 0, options) as? [CFString: Any]) ?? [:]
        let exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        let iptc = (props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        let gps = (props[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]
        let aux = (props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]) ?? [:]

        if let w = (index[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (index[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            let orientation = (index[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            (info.pixelWidth, info.pixelHeight) = orientation >= 5 ? (h, w) : (w, h)
        }
        info.isCMYK = Eclose.isCMYK(index)
        let taken = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        info.captured = taken.flatMap(CaptureTime.init(exif:))

        func text(_ v: Any?) -> String? {
            guard let s = v as? String else { return nil }
            let t = trimPadding(s).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func number(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let a = v as? [Any] { return number(a.first) }
            return nil
        }
        info.make = text(tiff[kCGImagePropertyTIFFMake])
        info.model = text(tiff[kCGImagePropertyTIFFModel])
        info.lens = text(exif[kCGImagePropertyExifLensModel]) ?? text(aux[kCGImagePropertyExifAuxLensModel])
        info.fNumber = number(exif[kCGImagePropertyExifFNumber])
        info.exposureTime = number(exif[kCGImagePropertyExifExposureTime])
        info.iso = number(exif[kCGImagePropertyExifISOSpeedRatings]).map { Int($0) }
        info.focalLength = number(exif[kCGImagePropertyExifFocalLength])
        if let lat = number(gps[kCGImagePropertyGPSLatitude]), let lon = number(gps[kCGImagePropertyGPSLongitude]) {
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
            info.location = GeoPoint(latitude: south ? -lat : lat, longitude: west ? -lon : lon)
        }

        let xmp = CGImageSourceCopyMetadataAtIndex(src, 0, nil)
        let xmpText = xmp.flatMap {
            CGImageMetadataCopyStringValueWithPath($0, nil, "dc:description[x-default]" as CFString) as String?
        } ?? xmpDescription(xmp)
        for value in [xmpText, text(iptc[kCGImagePropertyIPTCCaptionAbstract]),
                      text(tiff[kCGImagePropertyTIFFImageDescription])] {
            if let value { found.append((.fileDescription, value)) }
        }
        if let comment = displayedExifComment(of: url, image: src) { found.append((.exifComment, comment)) }
        info.notes = mergeNotes(found)
        info.captionOutsideOnly = captionCanBeEmbedded(url, image: src)
        return info
    }
}
