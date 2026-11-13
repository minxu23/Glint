// Windows 资源管理器写在 EXIF IFD0 里的标题、备注、作者、关键词、主题和评级。
//
// ImageIO 不读这几个标签：它们不在属性视图里，ImageIO 重写 EXIF 时也不会写进产物。所以
// --verify 直接从源文件的原始字节读，再到目标里找承载它的地方：产物原始 EXIF 的 IFD0 里
// 有同一个标签、解出来的值相同（EXIF 整块照搬过的产物就是这样），或者能承载它的标准字段
// 带着同一个值。Windows 写这些标签时通常同时写一份标准字段（如 XPAuthor 与 Artist），
// 标准字段会被搬走，所以判据和 IIM 日期一样：等价字段**带着同一个值**才算承载，等价字段
// 存在不算。

import Foundation
import ImageIO

/// 一个 Windows 标签和目标里能承载它的字段。
struct WindowsTag {
    enum Kind {
        /// UTF-16LE 文本，整串比较。
        case text
        /// UTF-16LE 文本，分号分隔的多个值（作者、关键词），逐项比较。
        case list
        /// 整数（评级）。
        case number
    }

    let tag: Int
    let name: String
    /// 中文说明，出现在差异行里。
    let gloss: String
    let kind: Kind
    /// 目标里能承载它的键。带下标的字段（`XMP/dc:subject[0]`、
    /// `XMP/dc:title[x-default]`）写不带下标的那一截，全部下标都算。
    let carriers: [String]
}

/// 等价字段表。XPSubject 没有公认的等价字段，出现就报。
let windowsTags: [WindowsTag] = [
    WindowsTag(tag: 0x9C9B, name: "XPTitle", gloss: "标题", kind: .text,
               carriers: [metadataKey(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription),
                          xmpKey("dc:title"), xmpKey("dc:description")]),
    WindowsTag(tag: 0x9C9C, name: "XPComment", gloss: "备注", kind: .text,
               carriers: [exifKey(kCGImagePropertyExifUserComment), xmpKey("exif:UserComment")]),
    WindowsTag(tag: 0x9C9D, name: "XPAuthor", gloss: "作者", kind: .list,
               carriers: [metadataKey(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist),
                          xmpKey("dc:creator")]),
    WindowsTag(tag: 0x9C9E, name: "XPKeywords", gloss: "关键词", kind: .list,
               carriers: [xmpKey("dc:subject"), iptcKey(kCGImagePropertyIPTCKeywords)]),
    WindowsTag(tag: 0x9C9F, name: "XPSubject", gloss: "主题", kind: .text, carriers: []),
    WindowsTag(tag: 0x4746, name: "Rating", gloss: "评级", kind: .number,
               carriers: [xmpKey("xmp:Rating")]),
    WindowsTag(tag: 0x4749, name: "RatingPercent", gloss: "评级百分比", kind: .number,
               carriers: [xmpKey("MicrosoftPhoto:Rating")]),
]

/// 源文件 IFD0 里出现的 Windows 标签：标签号 → 解出的值。条目在、值读不出（越界、
/// 类型不对）时值是 nil，照样列出来——读不出不等于不存在。空文本不列。
func rawWindowsTags(of bytes: [UInt8]) -> [Int: String?] {
    guard let tiff = TIFFStructure(jpeg: bytes) else { return [:] }
    return rawWindowsTags(tiff)
}

/// 一段 TIFF 结构的 IFD0 里出现的 Windows 标签，规则同上。产物一侧用它读 HEIF 的 Exif 项。
func rawWindowsTags(_ tiff: TIFFStructure) -> [Int: String?] {
    guard let ifd0 = tiff.ifd0 else { return [:] }
    let kinds = Dictionary(windowsTags.map { ($0.tag, $0.kind) }) { a, _ in a }
    var found: [Int: String?] = [:]
    for entry in tiff.entries(ifd0) {
        guard let kind = kinds[entry.tag], found[entry.tag] == nil else { continue }
        guard let raw = tiff.value(of: entry) else {
            found[entry.tag] = .some(nil)
            continue
        }
        switch kind {
        case .text, .list:
            let text = decodeXPText(raw)
            if !text.isEmpty { found[entry.tag] = text }
        case .number:
            found[entry.tag] = .some(decodeRating(raw, type: entry.type, bigEndian: tiff.bigEndian))
        }
    }
    return found
}

/// XP 标签的值：UTF-16LE，到第一个 NUL 字符为止；奇数长度时丢掉最后那个字节。
/// 不成对的代理项解成替换字符，不会失败。
func decodeXPText(_ raw: [UInt8]) -> String {
    var units: [UInt16] = []
    var i = 0
    while i + 1 < raw.count {
        let u = UInt16(raw[i]) | UInt16(raw[i + 1]) << 8
        if u == 0 { break }
        units.append(u)
        i += 2
    }
    return trimPadding(String(decoding: units, as: UTF16.self))
}

/// Rating 是 SHORT，也接受 BYTE 和 LONG；只取第一个值。别的类型解不出，返回 nil。
private func decodeRating(_ raw: [UInt8], type: Int, bigEndian: Bool) -> String? {
    let width: Int
    switch type {
    case 1: width = 1
    case 3: width = 2
    case 4: width = 4
    default: return nil
    }
    guard raw.count >= width else { return nil }
    let digits = bigEndian ? Array(raw[0..<width]) : Array(raw[0..<width]).reversed()
    return String(digits.reduce(0) { $0 << 8 | Int($1) })
}

/// 目标里某个承载字段的全部值：`key` 本身，加上 `key[下标]`。数字下标按数字排序。
func carrierValues(_ key: String, in after: [String: String]) -> [String] {
    if let v = after[key] { return [v] }
    let prefix = key + "["
    let items = after.filter { k, _ in
        guard k.hasPrefix(prefix), k.hasSuffix("]") else { return false }
        return !k.dropFirst(prefix.count).dropLast().contains { "[]/.".contains($0) }
    }
    return items.sorted { a, b in
        let x = Int(a.key.dropFirst(prefix.count).dropLast()), y = Int(b.key.dropFirst(prefix.count).dropLast())
        if let x, let y { return x < y }
        return a.key < b.key
    }.map(\.value)
}

/// 分号分隔的列表拆成各项，去掉两头空白和空项。
func listItems(_ value: String) -> [String] {
    value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// 一个承载字段的全部值 `values` 是否带着源里的 `value`。
///   text   某一个值与源值相同（`dc:title` 的各个语言、`dc:description` 是候选）
///   list   某一个值、或全部值按顺序拼起来，拆成的各项与源值拆成的各项一一相同：
///          ImageIO 不拆 `Artist` 里的分号，`dc:creator[0]` 就是 `甲;乙`；
///          IPTC 关键词是数组，`[甲, 乙]` 也算
///   number 某一个值与源值是同一个整数
func carriesWindowsValue(_ value: String, _ kind: WindowsTag.Kind, _ values: [String]) -> Bool {
    switch kind {
    case .text:
        return values.contains { trimPadding($0) == value }
    case .list:
        let wanted = listItems(value)
        return values.contains { listItems($0) == wanted } || values.flatMap(listItems) == wanted
    case .number:
        guard let n = Int(value) else { return false }
        return values.contains { Int(trimPadding($0)) == n }
    }
}

/// 源里的 Windows 标签在目标里没被承载的，每个一条差异。纯函数，单测直接喂字典。
///
/// `destRaw`：产物原始 EXIF 的 IFD0 里的 Windows 标签（rawWindowsTags）。同一个标签、解出来的值
/// 相同就算承载；源里值读不出的不靠它放过（两边都读不出，说明不了值带过去了）。
func windowsTagLosses(_ raw: [Int: String?], after: [String: String],
                      destRaw: [Int: String?] = [:]) -> [String] {
    var issues: [String] = []
    for spec in windowsTags {
        guard let found = raw[spec.tag] else { continue }
        let label = "Windows \(spec.gloss) \(spec.name)（IFD0 0x\(String(format: "%04X", spec.tag))）"
        guard let value = found else {
            issues.append("丢失 \(label)：值读不出（越界或类型不对）")
            continue
        }
        if case .some(.some(let carried)) = destRaw[spec.tag], carried == value { continue }
        if spec.carriers.contains(where: { carriesWindowsValue(value, spec.kind, carrierValues($0, in: after)) }) {
            continue
        }
        issues.append("丢失 \(label) = \(truncate(value))")
    }
    return issues
}
