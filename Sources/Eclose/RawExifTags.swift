// 原始 EXIF 标签清点：在原始字节层比较源与产物各有哪些 EXIF 标签，以及 GPS 的分数。
//
// 键空间比对两边都走 ImageIO 的属性视图。ImageIO 在源一侧就读不出的标签（类型写错的
// GPSProcessingMethod、LONG 类型的 LightSource、放错 IFD 的标签、私有标签、国产机型
// 的短 MakerNote……），产物里当然也没有，两边视图里都看不见，比对一声不响。所以这里
// 直接读两边的 TIFF 结构：源里有、产物里没有的标签报「丢失」。
//
// GPS 的坐标同理：源的「秒」常存成分母 1000000 的分数，HEIF 写入器一律存成分母 100；
// ImageIO 的视图在源一侧就已经按 XMP 的 `度,分.分` 形式四舍五入过，只有截断恰好跨过
// 视图的舍入档时才看得见。所以 GPS IFD 里的分数按原始值逐个比。
//
// ImageUniqueID 也按原始值比：ImageIO 只读长度恰好 33 字节的写法，别的长度两边视图里都
// 没有，转换时从源的原始字节补写进产物（见 restorableImageUniqueID），值写对没有只能在
// 这一层核对。

import Foundation
import ImageIO

// MARK: - 读原始条目

/// 标签号的命名空间。IFD0 与 Exif 子 IFD 合成一个：源里放错 IFD 的标签，按 (IFD, 标签号)
/// 比会把「ImageIO 读到后写到规范位置」误报成丢失。GPS、Interop 各自一个（它们的标签号
/// 与前者重叠）。IFD1（缩略图）不在任何一个里：缩略图有意不比。
enum ExifSpace: Hashable {
    case main, gps, interop
}

/// 原始 EXIF 里的一个条目。
struct RawExifEntry {
    let space: ExifSpace
    /// 条目实际所在的 IFD，显示用：`IFD0`、`ExifIFD`、`GPS`、`Interop`。
    let ifd: String
    let tag: Int
    let type: Int
    let count: Int
    /// 值的原始字节；类型不认识或值越界时是 nil（条目在，值读不出）。
    let value: [UInt8]?
    let bigEndian: Bool
}

/// TIFF 结构里 IFD0、Exif 子 IFD、GPS IFD、Interop IFD 的全部条目，按表里的顺序。
/// 指针越界、IFD 互相指向（循环）都不会卡住：每个 IFD 偏移只读一次。
func rawExifEntries(_ tiff: TIFFStructure) -> [RawExifEntry] {
    var result: [RawExifEntry] = []
    var visited = Set<Int>()
    func walk(_ offset: Int?, _ space: ExifSpace, _ name: String, pointers: [Int: (ExifSpace, String)]) {
        guard let offset, visited.insert(offset).inserted else { return }
        let entries = tiff.entries(offset)
        for e in entries {
            result.append(RawExifEntry(space: space, ifd: name, tag: e.tag, type: e.type, count: e.count,
                                       value: tiff.value(of: e), bigEndian: tiff.bigEndian))
        }
        for e in entries {
            guard let (childSpace, childName) = pointers[e.tag], let field = e.field, field.size == 4 else { continue }
            let childPointers: [Int: (ExifSpace, String)] = childName == "ExifIFD" ? [0xA005: (.interop, "Interop")] : [:]
            walk(tiff.u32(field.offset), childSpace, childName, pointers: childPointers)
        }
    }
    walk(tiff.ifd0, .main, "IFD0", pointers: [TIFFStructure.exifIFDPointer: (.main, "ExifIFD"), 0x8825: (.gps, "GPS")])
    return result
}

// MARK: - 标签表

/// 已知标签：名字、规范所在的 IFD、规范允许的类型。显示和「为什么 ImageIO 读不出」
/// 的说明用它；名字还用来找 ImageIO 视图里的同一个字段（见 viewKeys）。
struct ExifTagInfo {
    let name: String
    let home: String
    let types: [Int]
}

private let BYTE = 1, ASCII = 2, SHORT = 3, LONG = 4, RATIONAL = 5, UNDEFINED = 7, SLONG = 9, SRATIONAL = 10, IFD = 13

/// 主命名空间（IFD0 + Exif 子 IFD）里的已知标签。名字尽量取 ImageIO 属性字典里的键名
/// （如 0x8827 是 `ISOSpeedRatings`），对不上时只是少一次去重，不会漏报。
let mainExifTags: [Int: ExifTagInfo] = {
    let ifd0: [(Int, String, [Int])] = [
        (0x0100, "ImageWidth", [SHORT, LONG]), (0x0101, "ImageLength", [SHORT, LONG]),
        (0x0102, "BitsPerSample", [SHORT]), (0x0103, "Compression", [SHORT]),
        (0x0106, "PhotometricInterpretation", [SHORT]), (0x010D, "DocumentName", [ASCII]),
        (0x010E, "ImageDescription", [ASCII]), (0x010F, "Make", [ASCII]), (0x0110, "Model", [ASCII]),
        (0x0112, "Orientation", [SHORT]), (0x0115, "SamplesPerPixel", [SHORT]),
        (0x011A, "XResolution", [RATIONAL]), (0x011B, "YResolution", [RATIONAL]),
        (0x011C, "PlanarConfiguration", [SHORT]), (0x011D, "PageName", [ASCII]),
        (0x0128, "ResolutionUnit", [SHORT]), (0x012D, "TransferFunction", [SHORT]),
        (0x0131, "Software", [ASCII]), (0x0132, "DateTime", [ASCII]), (0x013B, "Artist", [ASCII]),
        (0x013C, "HostComputer", [ASCII]), (0x013E, "WhitePoint", [RATIONAL]),
        (0x013F, "PrimaryChromaticities", [RATIONAL]), (0x0211, "YCbCrCoefficients", [RATIONAL]),
        (0x0212, "YCbCrSubSampling", [SHORT]), (0x0213, "YCbCrPositioning", [SHORT]),
        (0x0214, "ReferenceBlackWhite", [RATIONAL]), (0x4746, "Rating", [SHORT]),
        (0x4749, "RatingPercent", [SHORT]), (0x8298, "Copyright", [ASCII]),
        (0x8769, "ExifIFDPointer", [LONG, IFD]), (0x8825, "GPSInfoIFDPointer", [LONG, IFD]),
        (0x9C9B, "XPTitle", [BYTE]), (0x9C9C, "XPComment", [BYTE]), (0x9C9D, "XPAuthor", [BYTE]),
        (0x9C9E, "XPKeywords", [BYTE]), (0x9C9F, "XPSubject", [BYTE]),
        (0xC4A5, "PrintImageMatching", [UNDEFINED]), (0xEA1C, "Padding", [UNDEFINED]),
    ]
    let exif: [(Int, String, [Int])] = [
        (0x829A, "ExposureTime", [RATIONAL]), (0x829D, "FNumber", [RATIONAL]),
        (0x8822, "ExposureProgram", [SHORT]), (0x8824, "SpectralSensitivity", [ASCII]),
        (0x8827, "ISOSpeedRatings", [SHORT]), (0x8828, "OECF", [UNDEFINED]),
        (0x8830, "SensitivityType", [SHORT]), (0x8831, "StandardOutputSensitivity", [LONG]),
        (0x8832, "RecommendedExposureIndex", [LONG]), (0x8833, "ISOSpeed", [LONG]),
        (0x8834, "ISOSpeedLatitudeyyy", [LONG]), (0x8835, "ISOSpeedLatitudezzz", [LONG]),
        (0x9000, "ExifVersion", [UNDEFINED]), (0x9003, "DateTimeOriginal", [ASCII]),
        (0x9004, "DateTimeDigitized", [ASCII]), (0x9010, "OffsetTime", [ASCII]),
        (0x9011, "OffsetTimeOriginal", [ASCII]), (0x9012, "OffsetTimeDigitized", [ASCII]),
        (0x9101, "ComponentsConfiguration", [UNDEFINED]), (0x9102, "CompressedBitsPerPixel", [RATIONAL]),
        (0x9201, "ShutterSpeedValue", [SRATIONAL]), (0x9202, "ApertureValue", [RATIONAL]),
        (0x9203, "BrightnessValue", [SRATIONAL]), (0x9204, "ExposureBiasValue", [SRATIONAL]),
        (0x9205, "MaxApertureValue", [RATIONAL]), (0x9206, "SubjectDistance", [RATIONAL]),
        (0x9207, "MeteringMode", [SHORT]), (0x9208, "LightSource", [SHORT]), (0x9209, "Flash", [SHORT]),
        (0x920A, "FocalLength", [RATIONAL]), (0x9214, "SubjectArea", [SHORT]),
        (0x927C, "MakerNote", [UNDEFINED]), (0x9286, "UserComment", [UNDEFINED]),
        (0x9290, "SubsecTime", [ASCII]), (0x9291, "SubsecTimeOriginal", [ASCII]),
        (0x9292, "SubsecTimeDigitized", [ASCII]), (0xA000, "FlashPixVersion", [UNDEFINED]),
        (0xA001, "ColorSpace", [SHORT]), (0xA002, "PixelXDimension", [SHORT, LONG]),
        (0xA003, "PixelYDimension", [SHORT, LONG]), (0xA004, "RelatedSoundFile", [ASCII]),
        (0xA005, "InteroperabilityIFDPointer", [LONG, IFD]), (0xA20B, "FlashEnergy", [RATIONAL]),
        (0xA20E, "FocalPlaneXResolution", [RATIONAL]), (0xA20F, "FocalPlaneYResolution", [RATIONAL]),
        (0xA210, "FocalPlaneResolutionUnit", [SHORT]), (0xA214, "SubjectLocation", [SHORT]),
        (0xA215, "ExposureIndex", [RATIONAL]), (0xA217, "SensingMethod", [SHORT]),
        (0xA300, "FileSource", [UNDEFINED]), (0xA301, "SceneType", [UNDEFINED]),
        (0xA302, "CFAPattern", [UNDEFINED]), (0xA401, "CustomRendered", [SHORT]),
        (0xA402, "ExposureMode", [SHORT]), (0xA403, "WhiteBalance", [SHORT]),
        (0xA404, "DigitalZoomRatio", [RATIONAL]), (0xA405, "FocalLenIn35mmFilm", [SHORT]),
        (0xA406, "SceneCaptureType", [SHORT]), (0xA407, "GainControl", [SHORT]),
        (0xA408, "Contrast", [SHORT]), (0xA409, "Saturation", [SHORT]), (0xA40A, "Sharpness", [SHORT]),
        (0xA40B, "DeviceSettingDescription", [UNDEFINED]), (0xA40C, "SubjectDistRange", [SHORT]),
        (0xA420, "ImageUniqueID", [ASCII]), (0xA430, "CameraOwnerName", [ASCII]),
        (0xA431, "BodySerialNumber", [ASCII]), (0xA432, "LensSpecification", [RATIONAL]),
        (0xA433, "LensMake", [ASCII]), (0xA434, "LensModel", [ASCII]), (0xA435, "LensSerialNumber", [ASCII]),
        (0xA460, "CompositeImage", [SHORT]), (0xA500, "Gamma", [RATIONAL]),
        (0xEA1D, "OffsetSchema", [SLONG]),
    ]
    var table: [Int: ExifTagInfo] = [:]
    for (tag, name, types) in ifd0 { table[tag] = ExifTagInfo(name: name, home: "IFD0", types: types) }
    for (tag, name, types) in exif { table[tag] = ExifTagInfo(name: name, home: "ExifIFD", types: types) }
    return table
}()

/// GPS IFD 的已知标签。`view` 是 ImageIO 属性字典 {GPS} 里的键名（直接取常量），显示名
/// 是 EXIF 规范的名字。
let gpsExifTags: [Int: (info: ExifTagInfo, view: String)] = {
    let list: [(Int, String, CFString, [Int])] = [
        (0x0000, "GPSVersionID", kCGImagePropertyGPSVersion, [BYTE]),
        (0x0001, "GPSLatitudeRef", kCGImagePropertyGPSLatitudeRef, [ASCII]),
        (0x0002, "GPSLatitude", kCGImagePropertyGPSLatitude, [RATIONAL]),
        (0x0003, "GPSLongitudeRef", kCGImagePropertyGPSLongitudeRef, [ASCII]),
        (0x0004, "GPSLongitude", kCGImagePropertyGPSLongitude, [RATIONAL]),
        (0x0005, "GPSAltitudeRef", kCGImagePropertyGPSAltitudeRef, [BYTE]),
        (0x0006, "GPSAltitude", kCGImagePropertyGPSAltitude, [RATIONAL]),
        (0x0007, "GPSTimeStamp", kCGImagePropertyGPSTimeStamp, [RATIONAL]),
        (0x0008, "GPSSatellites", kCGImagePropertyGPSSatellites, [ASCII]),
        (0x0009, "GPSStatus", kCGImagePropertyGPSStatus, [ASCII]),
        (0x000A, "GPSMeasureMode", kCGImagePropertyGPSMeasureMode, [ASCII]),
        (0x000B, "GPSDOP", kCGImagePropertyGPSDOP, [RATIONAL]),
        (0x000C, "GPSSpeedRef", kCGImagePropertyGPSSpeedRef, [ASCII]),
        (0x000D, "GPSSpeed", kCGImagePropertyGPSSpeed, [RATIONAL]),
        (0x000E, "GPSTrackRef", kCGImagePropertyGPSTrackRef, [ASCII]),
        (0x000F, "GPSTrack", kCGImagePropertyGPSTrack, [RATIONAL]),
        (0x0010, "GPSImgDirectionRef", kCGImagePropertyGPSImgDirectionRef, [ASCII]),
        (0x0011, "GPSImgDirection", kCGImagePropertyGPSImgDirection, [RATIONAL]),
        (0x0012, "GPSMapDatum", kCGImagePropertyGPSMapDatum, [ASCII]),
        (0x0013, "GPSDestLatitudeRef", kCGImagePropertyGPSDestLatitudeRef, [ASCII]),
        (0x0014, "GPSDestLatitude", kCGImagePropertyGPSDestLatitude, [RATIONAL]),
        (0x0015, "GPSDestLongitudeRef", kCGImagePropertyGPSDestLongitudeRef, [ASCII]),
        (0x0016, "GPSDestLongitude", kCGImagePropertyGPSDestLongitude, [RATIONAL]),
        (0x0017, "GPSDestBearingRef", kCGImagePropertyGPSDestBearingRef, [ASCII]),
        (0x0018, "GPSDestBearing", kCGImagePropertyGPSDestBearing, [RATIONAL]),
        (0x0019, "GPSDestDistanceRef", kCGImagePropertyGPSDestDistanceRef, [ASCII]),
        (0x001A, "GPSDestDistance", kCGImagePropertyGPSDestDistance, [RATIONAL]),
        (0x001B, "GPSProcessingMethod", kCGImagePropertyGPSProcessingMethod, [UNDEFINED]),
        (0x001C, "GPSAreaInformation", kCGImagePropertyGPSAreaInformation, [UNDEFINED]),
        (0x001D, "GPSDateStamp", kCGImagePropertyGPSDateStamp, [ASCII]),
        (0x001E, "GPSDifferential", kCGImagePropertyGPSDifferental, [SHORT]),
        (0x001F, "GPSHPositioningError", kCGImagePropertyGPSHPositioningError, [RATIONAL]),
    ]
    var table: [Int: (info: ExifTagInfo, view: String)] = [:]
    for (tag, name, view, types) in list { table[tag] = (ExifTagInfo(name: name, home: "GPS", types: types), view as String) }
    return table
}()

let interopExifTags: [Int: ExifTagInfo] = [
    0x0001: ExifTagInfo(name: "InteroperabilityIndex", home: "Interop", types: [ASCII]),
    0x0002: ExifTagInfo(name: "InteroperabilityVersion", home: "Interop", types: [UNDEFINED]),
]

func exifTagInfo(_ space: ExifSpace, _ tag: Int) -> ExifTagInfo? {
    switch space {
    case .main: return mainExifTags[tag]
    case .gps: return gpsExifTags[tag]?.info
    case .interop: return interopExifTags[tag]
    }
}

/// 这个标签在 ImageIO 属性视图与 XMP 里对应的键（去掉了数组下标）。键空间比对已经为
/// 其中某个键报了丢失时，原始清点不再为同一个标签另报一行。
func viewKeys(_ space: ExifSpace, _ tag: Int) -> [String] {
    switch space {
    case .main:
        guard let name = mainExifTags[tag]?.name else { return [] }
        return [metadataKey(kCGImagePropertyTIFFDictionary, name as CFString), exifKey(name as CFString),
                xmpKey("tiff:\(name)"), xmpKey("exif:\(name)")]
    case .gps:
        guard let view = gpsExifTags[tag]?.view else { return [] }
        return [metadataKey(kCGImagePropertyGPSDictionary, view as CFString), xmpKey("exif:GPS\(view)")]
    case .interop:
        return []
    }
}

// MARK: - 不报的条目

/// 描述文件结构或编码方式、而不描述照片的标签，产物里没有不算丢失。每一条的理由：
///   ImageWidth/ImageLength、PixelX/YDimension  像素尺寸，由编码结果决定（与键空间的
///                                              PixelWidth/PixelHeight 同为易变键）
///   BitsPerSample、Compression、PhotometricInterpretation、SamplesPerPixel、
///   PlanarConfiguration                        像素的存储方式，换了编码就变
///   YCbCrCoefficients/SubSampling/Positioning   JPEG 的色度编码参数，HEIF 有自己的
///   ComponentsConfiguration                    分量排列，同上（键空间里也是易变键）
///   0x8769/0x8825/0xA005 各 IFD 指针           结构本身，指向的内容另行逐条比
///   InteroperabilityIndex/Version              说明 EXIF 文件按哪套互通规则存放，属于
///                                              容器格式（HEIF 产物里 ImageIO 不写 Interop IFD）
///   Padding（0xEA1C）、OffsetSchema（0xEA1D）    Windows 写入时留的填充块与偏移修正值，
///                                              只为日后原地改写 EXIF 时不挪数据
let structuralExifTags: [ExifSpace: Set<Int>] = [
    .main: [0x0100, 0x0101, 0x0102, 0x0103, 0x0106, 0x0115, 0x011C, 0x0211, 0x0212, 0x0213,
            0x8769, 0x8825, 0xA005, 0xA002, 0xA003, 0x9101, 0xEA1C, 0xEA1D],
    .interop: [0x0001, 0x0002],
]

/// 已经由别的规则负责的标签：Windows XP 标签和评级由「等价字段带着同一个值」管
/// （WindowsTags.swift），时间字段由源侧原始时间那条规则管（RawTimes.swift）。
let exifTagsCoveredElsewhere: Set<Int> = Set(windowsTags.map(\.tag))
    .union([0x0132, 0x9003, 0x9004, 0x9010, 0x9011, 0x9012])

/// EXIF 规定的 UserComment 字符集头（8 字节）。
private let userCommentHeaders: [[UInt8]] = [
    Array("ASCII\0\0\0".utf8), Array("UNICODE\0".utf8), Array("JIS\0\0\0\0\0".utf8), [UInt8](repeating: 0, count: 8),
]

/// 条目里有没有数据。没有的：个数 0；ASCII/UNDEFINED 的值只含 NUL 和空格；
/// UserComment 带着合规的字符集头、去掉头之后只含 NUL 和空格。数值型的 0 **算**数据
/// （LightSource 0 是「未知光源」）。值读不出（类型不认识、越界）的条目算有数据：
/// 它声称有值，读不出不等于没有。
func exifEntryHasData(_ e: RawExifEntry) -> Bool {
    guard e.count > 0 else { return false }
    guard let value = e.value else { return true }
    guard e.type == ASCII || e.type == UNDEFINED else { return true }
    var body = value[...]
    if e.space == .main, e.tag == 0x9286, value.count >= 8, userCommentHeaders.contains(Array(value[0..<8])) {
        body = value[8...]
    }
    return body.contains { $0 != 0 && $0 != 0x20 }
}

// MARK: - ImageUniqueID

/// ImageUniqueID（ExifIFD 0xA420）。规范是定长 ASCII，33 字节（32 个字符加 NUL）。ImageIO 只认
/// 恰好 33 字节的写法，与内容无关：别的长度在源一侧读不出，产物一侧同样读不出。HEIC 写入器
/// 却什么长度都照写（值的 UTF-8 字节加一个 NUL），所以转换时补写，校验时按原始字节核对。
let imageUniqueIDTag = 0xA420

/// ImageUniqueID 条目的值：取到第一个 NUL 为止，没有 NUL 就取满。值读不出是 nil。
/// 补写与核对都按这一条取值。
func imageUniqueIDValue(_ e: RawExifEntry) -> [UInt8]? {
    e.value.map { Array($0.prefix { $0 != 0 }) }
}

/// 源里的 ImageUniqueID 能原样补写进产物时，要放进属性字典的字符串；不能就是 nil，
/// 交给原始清点照报丢失。能补写要同时满足：
///   主命名空间里恰好一个 0xA420 条目   同号的不止一个时不知道该写哪个
///   在 Exif 子 IFD、ASCII 类型          放错 IFD、类型不合规范的写法不替它改正
///   有数据、取出的值非空                没有数据的条目原始清点本来也不报
///   取出的字节是合法 UTF-8              写入器存的是字符串的 UTF-8，别的字节写不回原样
/// 这里不看 ImageIO 视图：视图里已经有它（33 字节的写法）时不补，由调用方判断。
func restorableImageUniqueID(_ entries: [RawExifEntry]) -> String? {
    let found = entries.filter { $0.space == .main && $0.tag == imageUniqueIDTag }
    guard found.count == 1, let e = found.first, e.ifd == "ExifIFD", e.type == ASCII, exifEntryHasData(e),
          let bytes = imageUniqueIDValue(e), !bytes.isEmpty else { return nil }
    let text = String(decoding: bytes, as: UTF8.self)
    return Array(text.utf8) == bytes ? text : nil
}

/// ImageUniqueID 的变化行。两边的值照文本显示（不去尾部空格，空格的差别也看得见）；
/// 不是合法 UTF-8 的写字节数。显示截断后两边一样时，注明原始字节从哪里开始不同。
private func imageUniqueIDChangeLine(_ a: [UInt8]?, _ b: [UInt8]?) -> String {
    func show(_ v: [UInt8]?) -> String {
        guard let v else { return "值读不出" }
        let text = String(decoding: v, as: UTF8.self)
        return Array(text.utf8) == v ? "\"\(truncate(text))\"" : "\(v.count) 字节（不是合法的 UTF-8）"
    }
    var line = "变化 EXIF 标签 ImageUniqueID：\(show(a)) → \(show(b))"
    if show(a) == show(b), let a, let b {
        let at = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        line += "（显示相同，原始字节从第 \(at + 1) 个起不同）"
    }
    return line
}

// MARK: - 显示

func tiffTypeName(_ type: Int) -> String {
    let names = [1: "BYTE", 2: "ASCII", 3: "SHORT", 4: "LONG", 5: "RATIONAL", 6: "SBYTE", 7: "UNDEFINED",
                 8: "SSHORT", 9: "SLONG", 10: "SRATIONAL", 11: "FLOAT", 12: "DOUBLE", 13: "IFD"]
    return names[type] ?? "类型 \(type)"
}

/// 一个条目值的整数（BYTE/SHORT/LONG 及有符号版本、IFD）或分数分量，按字节序解出。
private func integers(_ e: RawExifEntry, width: Int, signed: Bool) -> [Int] {
    guard let value = e.value else { return [] }
    return stride(from: 0, to: value.count - width + 1, by: width).map { at in
        let bytes = Array(value[at..<(at + width)])
        let v = (e.bigEndian ? bytes : bytes.reversed()).reduce(0) { $0 << 8 | Int($1) }
        return signed && v >= 1 << (width * 8 - 1) ? v - (1 << (width * 8)) : v
    }
}

/// RATIONAL / SRATIONAL 条目的各个分数；别的类型是 nil。
func exifRationals(_ e: RawExifEntry) -> [(n: Int, d: Int)]? {
    guard e.type == RATIONAL || e.type == SRATIONAL, e.value != nil else { return nil }
    let parts = integers(e, width: 4, signed: e.type == SRATIONAL)
    return stride(from: 0, to: parts.count - 1, by: 2).map { (parts[$0], parts[$0 + 1]) }
}

/// 分数写成人看得懂的样子：分母只含因子 2 和 5（有限小数）就写成精确的小数，
/// 否则写成 `n/d` 并附上近似值。`53743286/1000000` → `53.743286`，`5374/100` → `53.74`，
/// `624988/49999` → `624988/49999（≈12.5000100002）`。
func describeRational(_ n: Int, _ d: Int) -> String {
    guard d != 0 else { return "\(n)/0" }
    var digits = 0, rest = d
    while rest % 10 == 0 { rest /= 10; digits += 1 }
    while rest % 2 == 0 { rest /= 2; digits += 1 }
    while rest % 5 == 0 { rest /= 5; digits += 1 }
    guard rest == 1, digits <= 12 else { return "\(n)/\(d)（≈\(String(format: "%.12g", Double(n) / Double(d)))）" }
    var scale = 1
    for _ in 0..<digits { scale *= 10 }
    let scaled = n * (scale / d)      // d 整除 10^digits
    let sign = scaled < 0 ? "-" : ""
    let whole = abs(scaled) / scale, fraction = abs(scaled) % scale
    guard fraction != 0 else { return "\(sign)\(whole)" }
    var text = String(fraction)
    text = String(repeating: "0", count: digits - text.count) + text
    while text.hasSuffix("0") { text.removeLast() }
    return "\(sign)\(whole).\(text)"
}

/// 条目值的简短显示：文本加引号，数值逗号分隔，长的截断。
func describeExifValue(_ e: RawExifEntry) -> String {
    guard let value = e.value else { return "值读不出" }
    func text(_ bytes: ArraySlice<UInt8>) -> String {
        let s = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        return "\"\(truncate(trimPadding(s), max: 40))\""
    }
    func list(_ items: [String]) -> String {
        items.count <= 8 ? items.joined(separator: ", ") : items.prefix(8).joined(separator: ", ") + ", …"
    }
    switch e.type {
    case ASCII:
        return text(value[...])
    case UNDEFINED:
        if e.space == .main, e.tag == 0x9286, value.count >= 8, userCommentHeaders.contains(Array(value[0..<8])) {
            return text(value[8...])
        }
        // 可读的文本（允许结尾的 NUL 填充）照文本显示，否则只写字节数。
        let body = value.reversed().drop { $0 == 0 }.reversed()
        if !body.isEmpty, let s = String(bytes: body, encoding: .utf8),
           s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
            return text(value[...])
        }
        return "\(value.count) 字节"
    case 1, 6:
        return value.count <= 8 ? list(integers(e, width: 1, signed: e.type == 6).map(String.init)) : "\(value.count) 字节"
    case SHORT, 8:
        return list(integers(e, width: 2, signed: e.type == 8).map(String.init))
    case LONG, SLONG, IFD:
        return list(integers(e, width: 4, signed: e.type == SLONG).map(String.init))
    case RATIONAL, SRATIONAL:
        return list((exifRationals(e) ?? []).map { describeRational($0.n, $0.d) })
    default:
        return "\(value.count) 字节"
    }
}

// MARK: - 比对

/// 源与产物原始 EXIF 的比对结果：差异行，以及这些行已经替键空间比对说过的视图键
/// （键空间比对跳过它们，免得一处变化报两行）。`lostMainTags` 是报了「丢失 EXIF 标签」的
/// 主命名空间（IFD0 / Exif 子 IFD）标签号，备注原文核对据此让位。
struct RawExifComparison {
    var issues: [String] = []
    var coveredViewKeys: Set<String> = []
    var lostMainTags: Set<Int> = []
}

/// 比较源与产物的原始 EXIF 条目。纯函数，单测直接喂条目。
///
/// - `dest` 为 nil：产物的 EXIF 读不出（见 heifExif），报一行「无法核对」，不当作没有差异。
/// - `viewLosses`：键空间比对报了「丢失」的键（去掉了数组下标）。原始清点里的标签对应
///   的视图键（viewKeys）在其中时，那一行已经有了，不再重复。
/// - `makerNoteReported`：键空间比对已经出了 MakerNote 汇总行（佳能、松下那种被
///   ImageIO 解析成 {MakerCanon} 等伪字典的），原始清点不再报 0x927C。
/// - `sourceViewHasImageUniqueID`：源的 ImageIO 视图里有 `{Exif}/ImageUniqueID`。有的话
///   它的值由键空间比对管；没有的话两边都有 0xA420 时在这里按原始字节比值。
func compareRawExif(source: [RawExifEntry], dest: [RawExifEntry]?, viewLosses: Set<String>,
                    makerNoteReported: Bool, sourceViewHasImageUniqueID: Bool) -> RawExifComparison {
    var result = RawExifComparison()
    let candidates = source.filter { e in
        exifEntryHasData(e)
            && !(structuralExifTags[e.space]?.contains(e.tag) ?? false)
            && !(e.space == .main && exifTagsCoveredElsewhere.contains(e.tag))
    }
    guard !candidates.isEmpty else { return result }
    guard let dest else {
        result.issues.append("无法核对原始 EXIF 标签：产物里的 EXIF 读不出，源里有 \(candidates.count) 个标签没法确认带过去了")
        return result
    }
    struct Key: Hashable { let space: ExifSpace; let tag: Int }
    let present = Set(dest.map { Key(space: $0.space, tag: $0.tag) })

    // 丢失：按 (命名空间, 标签号) 归组，一组一行。
    var groups: [Key: [RawExifEntry]] = [:]
    var order: [Key] = []
    for e in candidates {
        let key = Key(space: e.space, tag: e.tag)
        guard !present.contains(key) else { continue }
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(e)
    }
    for key in order {
        if key.space == .main, key.tag == 0x927C, makerNoteReported { continue }
        if viewKeys(key.space, key.tag).contains(where: viewLosses.contains) { continue }
        result.issues.append(lostTagLine(groups[key]!))
        if key.space == .main { result.lostMainTags.insert(key.tag) }
    }

    // ImageUniqueID：源的视图里没有它时，产物里的值只可能来自转换时按原始字节的补写，两边
    // 视图都看不见（33 字节以外的写法 ImageIO 读不出），只能在这里比。只比这一个标签：别的
    // 标签源一侧读不出就不会写进产物，而原始值的写法（分数的分母、补齐长度、整数宽度）
    // 重新写一遍本来就会变，逐值比只会刷出噪声。取值规则同补写；同号条目各取第一个。
    func isImageUniqueID(_ e: RawExifEntry) -> Bool { e.space == .main && e.tag == imageUniqueIDTag }
    if !sourceViewHasImageUniqueID, let s = candidates.first(where: isImageUniqueID),
       let d = dest.first(where: isImageUniqueID), imageUniqueIDValue(s) != imageUniqueIDValue(d) {
        result.issues.append(imageUniqueIDChangeLine(imageUniqueIDValue(s), imageUniqueIDValue(d)))
    }

    // GPS 的分数：两边都有、都是分数的标签逐个比原始值，不加容差。同号条目各取第一个。
    var compared = Set<Int>()
    for s in source where s.space == .gps && compared.insert(s.tag).inserted {
        guard let a = exifRationals(s), let d = dest.first(where: { $0.space == .gps && $0.tag == s.tag }),
              let b = exifRationals(d), !sameRationals(a, b) else { continue }
        result.issues.append(gpsChangeLine(s.tag, a, b))
        result.coveredViewKeys.formUnion(viewKeys(.gps, s.tag))
    }
    return result
}

/// 两组分数的值是否逐个相等（约分后比较；分母为 0 的按原样比）。
func sameRationals(_ a: [(n: Int, d: Int)], _ b: [(n: Int, d: Int)]) -> Bool {
    func reduced(_ r: (n: Int, d: Int)) -> [Int] {
        guard r.d != 0 else { return [r.n, 0] }
        var x = abs(r.n), y = abs(r.d)
        while y != 0 { (x, y) = (y, x % y) }
        let g = max(x, 1), sign = (r.n < 0) != (r.d < 0) ? -1 : 1
        return [sign * abs(r.n) / g, abs(r.d) / g]
    }
    return a.count == b.count && zip(a, b).allSatisfy { reduced($0) == reduced($1) }
}

private func lostTagLine(_ group: [RawExifEntry]) -> String {
    let first = group[0]
    let info = exifTagInfo(first.space, first.tag)
    let name = info?.name ?? "未知标签"
    let location = "\(first.ifd) 0x\(String(format: "%04X", first.tag))"
    var values: [String] = []
    for e in group {
        let v = describeExifValue(e)
        if !values.contains(v) { values.append(v) }
    }
    let shown = values.count <= 3 ? values.joined(separator: "、") : values.prefix(3).joined(separator: "、") + "…"
    let repeated = group.count > 1 ? "，同号条目 \(group.count) 个" : ""
    let why: String
    if let info {
        if !info.types.contains(first.type) {
            why = "类型不合规范（规范是 \(info.types.map(tiffTypeName).joined(separator: "/"))），ImageIO 读不出这种写法"
        } else if first.ifd != info.home {
            why = "放错了 IFD（规范在 \(info.home)），ImageIO 读不出"
        } else if first.value == nil {
            why = "值越界，ImageIO 读不出"
        } else {
            why = "ImageIO 没有把它写进产物"
        }
    } else {
        why = "ImageIO 不认识这个标签，不搬"
    }
    return "丢失 EXIF 标签 \(name)（\(location)，\(tiffTypeName(first.type))，\(shown)\(repeated)）——\(why)"
}

/// GPS 分数标签的中文名，差异行用。
private let gpsGloss: [Int: String] = [
    0x0002: "纬度", 0x0004: "经度", 0x0006: "海拔", 0x0007: "时间戳", 0x000B: "精度因子",
    0x000D: "速度", 0x000F: "航向", 0x0011: "拍摄方向", 0x0014: "目的地纬度", 0x0016: "目的地经度",
    0x0018: "目的地方位", 0x001A: "目的地距离", 0x001F: "水平定位误差",
]

private func gpsChangeLine(_ tag: Int, _ a: [(n: Int, d: Int)], _ b: [(n: Int, d: Int)]) -> String {
    let angle: Set<Int> = [0x0002, 0x0004, 0x0014, 0x0016]
    func show(_ r: [(n: Int, d: Int)]) -> String {
        let parts = r.map { describeRational($0.n, $0.d) }
        if angle.contains(tag), parts.count == 3 { return "\(parts[0])°\(parts[1])′\(parts[2])″" }
        if tag == 0x0007, parts.count == 3 { return parts.joined(separator: ":") }
        return parts.joined(separator: ", ")
    }
    // 度、分相同而产物的秒是分母 100：变化就是写入器把秒截到了 1/100。
    let truncated = angle.contains(tag) && a.count == 3 && b.count == 3
        && sameRationals(Array(a.prefix(2)), Array(b.prefix(2))) && b[2].d == 100
    let name = gpsGloss[tag] ?? gpsExifTags[tag]?.info.name ?? String(format: "0x%04X", tag)
    return "变化 GPS \(name)：\(show(a)) → \(show(b))" + (truncated ? "（HEIF 写入器只保留到 1/100 秒）" : "")
}

// MARK: - 接到文件上

/// 读两边的原始 EXIF 并比对。源不是带 EXIF 的 JPEG 时没有可清点的东西。
func rawExifDiff(source: SourceJPEG, dest destBytes: [UInt8], viewLosses: Set<String>,
                 makerNoteReported: Bool, sourceViewHasImageUniqueID: Bool) -> RawExifComparison {
    guard let sourceTIFF = source.exif else { return RawExifComparison() }
    let dest: [RawExifEntry]?
    switch heifExif(destBytes) {
    case .absent: dest = []
    case .unreadable: dest = nil
    case .tiff(let tiff): dest = rawExifEntries(tiff)
    }
    return compareRawExif(source: rawExifEntries(sourceTIFF), dest: dest, viewLosses: viewLosses,
                          makerNoteReported: makerNoteReported, sourceViewHasImageUniqueID: sourceViewHasImageUniqueID)
}
