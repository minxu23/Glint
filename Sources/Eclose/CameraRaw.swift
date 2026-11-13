// 相机 RAW 源专有的规则：写入前整理版本号、产物必须是 10 位。
//
// （本项目里别的「Raw」——RawExifCarry、RawExifTags、RawTimes——说的是 EXIF 的原始字节，
// 和相机 RAW 无关。）

import Foundation
import ImageIO

// MARK: - 版本号

/// RAW 源的属性字典里三个版本号字段，整理成 HEIC 写入器能正确往返的形式。不需要整理时原样返回
/// 同一个字典。只对 RAW 做（convert 里按源类型分派）。
///
/// 写入器认的形式（拿手写 DNG 当源，AddImageFromSource 时覆盖这个字段，再读回产物，实测）：
/// - ExifVersion、FlashPixVersion：一串整数，第一个是两位的主版本，后面每个是一位，写成 4 个
///   ASCII 数字、不够补 0：`[2,3,1]` → "0231"，`[2,3]` → "0230"，`[1,0]` → "0100"。读回时 ImageIO
///   去掉末尾的 0，但至少留两个：`[1,0,0]` 读回 `[1,0]`。
/// - GPSVersion：4 个整数原样写：`[2,3,0,0]`；只给两个时补 0。
/// - 浮点数一律写不进去：`[2.0,3.0,1.0]`、`[2.0,3.0,0.0,0.0]` 在产物里整个字段都没有了。
/// - 字符码被当成数字写：`[48,50,51,49]` 写成 "4801"，读回 `[48,0,1]`；`[48,49,48,48]` 读回 `[48,9,8]`。
///
/// ImageIO 读 CR3 时 ExifVersion、FlashPixVersion 给的正是字符码（主会话实测 `[48,50,51,49]`），
/// GPSVersion `[2,3,0,0]` 写不进去——和浮点数的表现一样，推测是浮点数（待用真 CR3 确认）。所以：
/// - ExifVersion、FlashPixVersion 是恰好 4 个 ASCII 数字的字符码时，换成上面那种整数形式
///   （versionDigits）；
/// - 三个字段里的数都是整数值、但有浮点类型的，换成整数。
/// 别的形状原样不动，写坏了由校验如实报（校验按源的原值比，见 canonicalVersion）。
func versionFieldsForHEIFWriter(_ properties: [CFString: Any]) -> [CFString: Any] {
    var result = properties
    var changed = false
    let fields: [(dictionary: CFString, key: CFString, characterCodes: Bool)] = [
        (kCGImagePropertyExifDictionary, kCGImagePropertyExifVersion, true),
        (kCGImagePropertyExifDictionary, kCGImagePropertyExifFlashPixVersion, true),
        (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSVersion, false),
    ]
    for field in fields {
        guard var dictionary = result[field.dictionary] as? [CFString: Any],
              let value = dictionary[field.key],
              let written = writableVersion(value, characterCodes: field.characterCodes) else { continue }
        dictionary[field.key] = written.map { NSNumber(value: $0) }
        result[field.dictionary] = dictionary
        changed = true
    }
    return changed ? result : properties
}

/// 一个版本号字段要换成的整数数组；不用换是 nil。规则见 versionFieldsForHEIFWriter。
func writableVersion(_ value: Any, characterCodes: Bool) -> [Int]? {
    guard let numbers = value as? [NSNumber], !numbers.isEmpty else { return nil }
    var integers: [Int] = []
    for n in numbers {
        let d = n.doubleValue
        guard d == d.rounded(), abs(d) < 2_147_483_648 else { return nil }
        integers.append(Int(d))
    }
    if characterCodes, integers.count == 4, integers.allSatisfy({ (48...57).contains($0) }) {
        return versionDigits(String(decoding: integers.map { UInt8($0) }, as: UTF8.self))
    }
    return numbers.contains(where: { CFNumberIsFloatType($0) }) ? integers : nil
}

/// 4 个 ASCII 数字的版本号（"0231"）→ ImageIO 读正常文件时给的整数数组：前两位是一个数，后面每位
/// 一个数，末尾的 0 去掉但至少留两个。"0231" → [2,3,1]，"0230" → [2,3]，"0100" → [1,0]。
func versionDigits(_ text: String) -> [Int]? {
    let chars = Array(text)
    guard chars.count == 4, isAllDigits(chars), let major = Int(String(chars[0..<2])) else { return nil }
    var rest = chars[2...].compactMap { $0.wholeNumberValue }
    while rest.count > 1, rest.last == 0 { rest.removeLast() }
    return [major] + rest
}

/// 版本号字段在视图里的值（展开后的各个元素，按下标顺序）→ 比较用的规范写法，两边同一把尺子，
/// 按源的原值比：
/// - ExifVersion、FlashPixVersion（`characterCodes`）：4 个 ASCII 数字的字符码照字符读；否则第一个
///   数写两位、后面每个数写一位，不够 4 位补 0。`[48,50,51,49]` 与 `[2,3,1]` 都是 "0231"，
///   `[2,3]` 是 "0230"，写坏的 `[48,0,1]` 是 "4801"。
/// - GPSVersion：各个数用点连起来，不够 4 个补 0：`[2,3,0,0]` 与 `[2,3]` 都是 "2.3.0.0"。
/// 有不是整数的元素、或数超出一位（第一个超出两位）时是 nil，照原样逐个元素比。
func canonicalVersion(_ elements: [String], characterCodes: Bool) -> String? {
    var integers: [Int] = []
    for e in elements {
        guard let d = Double(e), d == d.rounded(), d >= 0, d < 1000 else { return nil }
        integers.append(Int(d))
    }
    guard !integers.isEmpty else { return nil }
    guard characterCodes else {
        guard integers.count <= 4, integers.allSatisfy({ $0 <= 255 }) else { return nil }
        return (integers + [Int](repeating: 0, count: 4 - integers.count)).map(String.init).joined(separator: ".")
    }
    if integers.count == 4, integers.allSatisfy({ (48...57).contains($0) }) {
        return String(decoding: integers.map { UInt8($0) }, as: UTF8.self)
    }
    guard integers[0] <= 99, integers.dropFirst().allSatisfy({ $0 <= 9 }) else { return nil }
    let text = (integers[0] < 10 ? "0" : "") + integers.map(String.init).joined()
    guard text.count <= 4 else { return nil }
    return text + String(repeating: "0", count: 4 - text.count)
}

// MARK: - 产物

/// 产物第 0 张图的位深（kCGImagePropertyDepth）；读不出是 nil。
func imageDepth(_ url: URL) -> Int? {
    guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else { return nil }
    return (props[kCGImagePropertyDepth] as? NSNumber)?.intValue
}

/// RAW 的产物必须是 10 位：不是的话是失败的原因，是 10 位时 nil。别静默交出一张 8 位的图——
/// 那是显影没走 RAW 的路（比如 ImageIO 读到的其实是预览图）。
func rawProductDepthProblem(_ url: URL) -> String? {
    guard let depth = imageDepth(url) else { return "读不出产物的位深" }
    return depth == 10 ? nil : "产物不是 10 位（Depth = \(depth)），没有交出"
}

// MARK: - 校验

/// RAW 源的 --verify。JPEG 专有的核对一律不跑——原始 EXIF 清点、EXIF 与 IPTC 打架合成一行、备注与
/// 三个文字标签的原文核对、照搬核对、Windows 标签、搬不走的段与 Photoshop 资源，读的都是 JPEG 的
/// 段结构（APP1、APP13、MPF……），RAW 里没有这些；按源类型分派（metadataDiff），不是读不通才跳过。
///
/// 比的是：
/// - 产物本身（rawProductIssues）：10 位、存储的宽高与源相同、方向标签相同；
/// - 两边的键空间（属性视图加 XMP，不修补 UserComment——那读的也是 JPEG 的 APP1），按源的原值比，
///   只有三处不同于 JPEG：版本号字段按规范写法比（collapsingVersions）；源里描述传感器原始数据与
///   RAW 容器的结构字段不比（isRawStructuralKey）；GPS 只差在写入器的取整范围内时合成一行（gpsRounding）；
/// - 扩展属性，与 JPEG 同一套。
func rawMetadataDiff(source: URL, dest: URL, sourceImage: CGImageSource, destImage: CGImageSource) -> [String] {
    let sourceProps = CGImageSourceCopyPropertiesAtIndex(sourceImage, 0, nil) as? [CFString: Any] ?? [:]
    let productProps = CGImageSourceCopyPropertiesAtIndex(destImage, 0, nil) as? [CFString: Any] ?? [:]
    return rawProductIssues(source: sourceProps, product: productProps)
        + rawKeySpaceDiff(before: metadataKeySpace(of: sourceImage, url: source, repairing: false),
                          after: metadataKeySpace(of: destImage, url: dest, repairing: false))
        + extendedAttributeIssues(source: source.path, dest: dest.path)
}

/// RAW 源的键空间比对，纯函数，单测直接喂字典：两边先规范化版本号（collapsingVersions），源侧去掉
/// 结构字段（isRawStructuralKey），GPS 取整合成一行（gpsRounding，行排在最后），其余照 keySpaceDiff。
/// 顶层的 Orientation 由 rawProductIssues 核对（源里没有时按 1 算），这里不再报一遍。
func rawKeySpaceDiff(before: [String: String], after: [String: String]) -> [String] {
    let before = collapsingVersions(before).filter { !isRawStructuralKey($0.key) }
    let after = collapsingVersions(after)
    let gps = gpsRounding(before: before, after: after)
    return keySpaceDiff(before: before, after: after, covered: gps.covered.union([kCGImagePropertyOrientation as String]))
        + gps.issues
}

/// RAW 的产物另外核对的三样，`source`、`product` 是两边第 0 张图的属性：
/// - 位深是 10（kCGImagePropertyDepth；位深在键空间里是尺子不比的键，所以单独核对）；
/// - 存储的像素宽高与源相同，不按方向转正（显影不裁切、不旋转像素）；
/// - 方向标签相同，没有的按 1 算（像素不转，标签就得照抄；源里没有、产物里多出一个方向，键空间
///   比对看不见，这里看得见）。
func rawProductIssues(source: [CFString: Any], product: [CFString: Any]) -> [String] {
    func int(_ props: [CFString: Any], _ key: CFString) -> Int? { (props[key] as? NSNumber)?.intValue }
    var issues: [String] = []
    switch int(product, kCGImagePropertyDepth) {
    case 10?: break
    case let depth?: issues.append("产物不是 10 位（Depth = \(depth)）")
    case nil: issues.append("读不出产物的位深")
    }
    func size(_ props: [CFString: Any]) -> String {
        let w = int(props, kCGImagePropertyPixelWidth).map(String.init) ?? "?"
        let h = int(props, kCGImagePropertyPixelHeight).map(String.init) ?? "?"
        return "\(w)×\(h)"
    }
    if size(source) != size(product) || size(source).contains("?") {
        issues.append("变化 像素尺寸（不按方向转正）：\(size(source)) → \(size(product))")
    }
    let a = int(source, kCGImagePropertyOrientation) ?? 1, b = int(product, kCGImagePropertyOrientation) ?? 1
    if a != b { issues.append("变化 方向标签：\(a) → \(b)") }
    return issues
}

/// RAW 源里描述传感器原始数据或 RAW 容器本身的键，校验不比：HEIC 是显影后的图像，没有这些。
/// 只收实测过的（主会话的 CR3、RW2 与 Tests/DNG.swift 的 DNG），别的照报。
func isRawStructuralKey(_ key: String) -> Bool {
    // RAW 容器给的裁切、传感器尺寸与内嵌缩略图（CropSize、SensorSize、Thumbnails[n]/…）。ImageIO 实际
    // 给的字典名是小写的 {raw}，不是 kCGImagePropertyRawDictionary 的 {Raw}。
    if key.hasPrefix("{raw}/") { return true }
    // DNG 的色彩矩阵、黑白电平、默认裁切、DNGVersion……：怎么显影原始数据的参数，显影完就用不着了。
    if key.hasPrefix("\(kCGImagePropertyDNGDictionary as String)/") { return true }
    switch strippingArrayIndex(key) {
    // 拜耳阵列的排列：显影后每个像素都是完整的 RGB。
    case exifKey(kCGImagePropertyExifCFAPattern): return true
    // 原始数据每个样本的位数（CR3 给的 BitsPerPixel[n]）：产物的位深另有核对（rawProductIssues）。
    case metadataKey(kCGImagePropertyTIFFDictionary, "BitsPerPixel" as CFString): return true
    // RAW 容器里 TIFF 的宽高（CR3 给的是原始数据的）：产物的宽高另有核对。SDK 没有这两个常量。
    case metadataKey(kCGImagePropertyTIFFDictionary, "Width" as CFString),
         metadataKey(kCGImagePropertyTIFFDictionary, "Height" as CFString): return true
    // 原始数据的压缩方式（属性视图里的 {TIFF}/Compression 已在 volatileKeys 里）。
    case xmpKey("tiff:Compression"): return true
    default: return false
    }
}

/// 三个版本号字段（ExifVersion、FlashPixVersion、GPSVersion）在键空间里按下标展开成好几个键；
/// 能规范化（canonicalVersion）时合成一个不带下标的键，值是规范写法。两边都过一遍，于是源里的
/// 字符码 `[48,50,51,49]` 和产物里的 `[2,3,1]` 都是 "0231"，写坏的 `[48,0,1]` 是 "4801"，报出来；
/// 产物里没有这个字段就报丢失。规范化不了的照原样逐个元素比。
func collapsingVersions(_ flat: [String: String]) -> [String: String] {
    var result = flat
    let fields: [(key: String, characterCodes: Bool)] = [
        (exifKey(kCGImagePropertyExifVersion), true),
        (exifKey(kCGImagePropertyExifFlashPixVersion), true),
        (metadataKey(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSVersion), false),
    ]
    for field in fields {
        let indexed = flat.keys.filter { strippingArrayIndex($0) == field.key && $0 != field.key }
        let elements = (0..<indexed.count).compactMap { flat["\(field.key)[\($0)]"] }
        guard !indexed.isEmpty, elements.count == indexed.count,
              let canonical = canonicalVersion(elements, characterCodes: field.characterCodes) else { continue }
        for k in indexed { result.removeValue(forKey: k) }
        result[field.key] = canonical
    }
    return result
}

// MARK: - GPS 取整

/// GPS 取整那一行的判定结果：要报的行（零或一行）与它盖住的键。
struct GPSRounding: Equatable {
    var issues: [String] = []
    var covered: Set<String> = []
}

/// 一度纬度（以及赤道上一度经度）按 111 km 算。
let metersPerDegree = 111_000.0

/// 坐标只差在取整范围内时合成一行的上限：超过它就是真的改了坐标，逐字段报。写入器把分取整到
/// 小数点后 4 位（实测 `13.761315` → `13.7613`），最多差 0.00005 分，约 9 厘米；1 米留足了余量，
/// 又远小于任何有意义的位置改动。
let gpsRoundingLimit = 1.0

/// GPS 的视图键和由它们派生的 XMP 键：坐标只差在写入器的取整范围内时，这几个键的差异不逐条报，
/// 合成一行 `GPS 精度降低：最大偏差 N 厘米（ImageIO 写入时取整）`。这一行算差异（--verify 照样
/// 有差异），不是放行。
///
/// 先找出这几个键里报得出差异的（keyVerdict 是丢失或变化）；没有就什么都不报。有的话，下面每一条都
/// 成立才合成一行，任何一条不成立就什么都不盖，照原来逐字段报：
/// 1. 两边的 {GPS}/Latitude、Longitude、LatitudeRef、LongitudeRef 都在、读得出，方向（N/S、E/W）相同；
/// 2. 有差异的 XMP 坐标（exif:GPSLatitude / GPSLongitude，写成 `度,分N` 或 `度,分,秒N`）两边都在、
///    读得出，方向与 {GPS} 的相同；
/// 3. 有差异的 XMP 方向（exif:GPSLatitudeRef / GPSLongitudeRef）只能是产物里没了，且产物的 XMP 坐标
///    里还带着同一个方向——方向没丢，只是换了写法；
/// 4. 所有坐标的偏差（两边都有的那几对，按真实距离：纬度差 × 111 km，经度差 × 111 km × cos 纬度）
///    都不超过 gpsRoundingLimit。
/// 行里的厘米数是最大偏差取整到厘米，不到 1 厘米写「不到 1 厘米」。
func gpsRounding(before: [String: String], after: [String: String]) -> GPSRounding {
    let gps = { (name: CFString) in metadataKey(kCGImagePropertyGPSDictionary, name) }
    let latKey = gps(kCGImagePropertyGPSLatitude), lonKey = gps(kCGImagePropertyGPSLongitude)
    let latRefKey = gps(kCGImagePropertyGPSLatitudeRef), lonRefKey = gps(kCGImagePropertyGPSLongitudeRef)
    let xmpLat = xmpKey("exif:GPSLatitude"), xmpLon = xmpKey("exif:GPSLongitude")
    let xmpLatRef = xmpKey("exif:GPSLatitudeRef"), xmpLonRef = xmpKey("exif:GPSLongitudeRef")

    let differing = Set([latKey, lonKey, xmpLat, xmpLon, xmpLatRef, xmpLonRef].filter { key in
        guard let value = before[key] else { return false }
        let verdict = keyVerdict(key, value, after: after)
        return verdict == .lost || verdict == .changed
    })
    guard !differing.isEmpty else { return GPSRounding() }

    // 1. {GPS} 的四个键两边都在，方向相同。
    func coordinate(_ view: [String: String], _ key: String, _ refKey: String) -> (degrees: Double, ref: String)? {
        guard let text = view[key], let degrees = Double(text), let ref = view[refKey], !ref.isEmpty else { return nil }
        return (degrees, ref)
    }
    guard let latS = coordinate(before, latKey, latRefKey), let latP = coordinate(after, latKey, latRefKey),
          let lonS = coordinate(before, lonKey, lonRefKey), let lonP = coordinate(after, lonKey, lonRefKey),
          latS.ref == latP.ref, lonS.ref == lonP.ref else { return GPSRounding() }

    let cosLat = cos(latS.degrees * .pi / 180)
    var deviations = [abs(latS.degrees - latP.degrees) * metersPerDegree,
                      abs(lonS.degrees - lonP.degrees) * metersPerDegree * cosLat]

    // 2. 有差异的 XMP 坐标两边都在、方向不变；两边都在的都算进偏差。
    for (key, ref, scale) in [(xmpLat, latS.ref, 1.0), (xmpLon, lonS.ref, cosLat)] {
        let s = before[key].flatMap(xmpGPSCoordinate), p = after[key].flatMap(xmpGPSCoordinate)
        if differing.contains(key) {
            guard let s, let p, s.ref == ref, p.ref == ref else { return GPSRounding() }
        }
        if let s, let p { deviations.append(abs(s.degrees - p.degrees) * metersPerDegree * scale) }
    }
    // 3. 有差异的 XMP 方向：产物里没了，且产物的 XMP 坐标里带着同一个方向。
    for (refKey, coordKey) in [(xmpLatRef, xmpLat), (xmpLonRef, xmpLon)] where differing.contains(refKey) {
        guard after[refKey] == nil, let carried = after[coordKey].flatMap(xmpGPSCoordinate),
              carried.ref == before[refKey] else { return GPSRounding() }
    }
    // 4. 偏差都在取整范围内。
    let worst = deviations.max() ?? 0
    guard worst <= gpsRoundingLimit else { return GPSRounding() }
    let centimeters = Int((worst * 100).rounded())
    let amount = centimeters == 0 ? "不到 1 厘米" : "\(centimeters) 厘米"
    return GPSRounding(issues: ["GPS 精度降低：最大偏差 \(amount)（ImageIO 写入时取整）"], covered: differing)
}

/// XMP 的 GPS 坐标（`31,13.761315N`、`31,13,45.6789N`）→ 度数与方向；不是这两种写法是 nil。
/// 度、分、秒只认 ASCII 数字（分与秒可以带一个小数点），分、秒小于 60，方向是 N、S、E、W 之一。
func xmpGPSCoordinate(_ text: String) -> (degrees: Double, ref: String)? {
    guard let last = text.last, "NSEW".contains(last) else { return nil }
    let parts = text.dropLast().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard (2...3).contains(parts.count), isAllDigits(Array(parts[0])) else { return nil }
    var values: [Double] = []
    for part in parts {
        guard part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let v = Double(part) else { return nil }
        values.append(v)
    }
    guard values[1] < 60, parts.count == 2 || values[2] < 60 else { return nil }
    return (values[0] + values[1] / 60 + (parts.count == 3 ? values[2] / 3600 : 0), String(last))
}
