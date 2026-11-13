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
