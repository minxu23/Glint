// 从 HEIF 文件里取出 Exif 项的原始字节，不经过 ImageIO。
//
// --verify 的原始 EXIF 标签清点（RawExifTags.swift）要在产物一侧也读原始标签：
// ImageIO 在源一侧就读不出的标签，产物的 ImageIO 视图里同样没有，两边视图一比
// 什么也看不出来。
//
// 只走 ImageIO 自己写出来的那条路：顶层 `meta` → `iinf` 里类型为 `Exif` 的项 →
// `iloc` 里它的范围（构造方式 0 是文件偏移，1 是 `meta` 里 `idat` 的偏移）。项的内容
// 先是 4 字节大端的「TIFF 头偏移」，跳过它和这么多字节之后是 TIFF 头。
// 所有长度、偏移、个数都来自被校验的文件，一律不信：越界、自相矛盾、读到一半
// 就停的都算「读不出」，由调用方报出来，不当作没有标签。

import Foundation

enum HEIFExif {
    /// 文件结构读得通，里面没有 Exif 项。
    case absent
    /// 结构读不通或 Exif 项的内容不是合法的 TIFF，附带原因。
    case unreadable(String)
    case tiff(TIFFStructure)
}

/// ISO BMFF 的一个盒子：类型与内容（盒头之后）在文件里的范围。
struct HEIFBox {
    let type: String
    /// 盒头的起点（长度字段所在的位置）。
    let start: Int
    let content: Range<Int>
}

/// 大端读整数，越界返回 nil。
func bigEndianInt(_ bytes: [UInt8], _ at: Int, _ width: Int) -> Int? {
    guard width >= 0, width <= 8, at >= 0, at <= bytes.count - width else { return nil }
    var v = 0
    for i in 0..<width {
        // 8 字节的值高位不为 0 时已经远超任何真实文件的大小，当作越界。
        if i == 0, width == 8, bytes[at] != 0 { return nil }
        v = v << 8 | Int(bytes[at + i])
    }
    return v
}

/// `range` 里按顺序排列的盒子。盒子越出 `range` 就返回 nil：结构已经不可信，
/// 不能只取前半截当作全部。
func heifBoxes(_ bytes: [UInt8], in range: Range<Int>) -> [HEIFBox]? {
    var result: [HEIFBox] = []
    var at = range.lowerBound
    while at < range.upperBound {
        guard let size32 = bigEndianInt(bytes, at, 4), at + 8 <= range.upperBound else { return nil }
        let type = String(decoding: bytes[(at + 4)..<(at + 8)], as: UTF8.self)
        var header = 8, size = size32
        if size32 == 1 {
            guard let large = bigEndianInt(bytes, at + 8, 8) else { return nil }
            header = 16
            size = large
        } else if size32 == 0 {
            size = range.upperBound - at
        }
        guard size >= header, size <= range.upperBound - at else { return nil }
        result.append(HEIFBox(type: type, start: at, content: (at + header)..<(at + size)))
        at += size
        // 一个合法的文件远到不了这个数；到了就是构造出来卡循环的。
        guard result.count < 100_000 else { return nil }
    }
    return result
}

/// 顶层 `meta` 盒子里的子盒子；读不通时是原因。
func heifMetaChildren(_ bytes: [UInt8]) -> Result<[HEIFBox], HEIFStructureError> {
    guard let top = heifBoxes(bytes, in: 0..<bytes.count) else { return .failure(.init("顶层盒子越界")) }
    guard let meta = top.first(where: { $0.type == "meta" }) else { return .failure(.init("没有 meta 盒子")) }
    // meta 是 FullBox：先是 1 字节版本、3 字节标志。
    guard meta.content.count >= 4,
          let children = heifBoxes(bytes, in: (meta.content.lowerBound + 4)..<meta.content.upperBound)
    else { return .failure(.init("meta 盒子越界")) }
    return .success(children)
}

struct HEIFStructureError: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// 取出 HEIF 文件里的 Exif 项并解析出 TIFF 结构。
func heifExif(_ bytes: [UInt8]) -> HEIFExif {
    let children: [HEIFBox]
    switch heifMetaChildren(bytes) {
    case .success(let boxes): children = boxes
    case .failure(let error): return .unreadable(error.reason)
    }
    guard let iinf = children.first(where: { $0.type == "iinf" }) else { return .unreadable("没有 iinf 盒子") }
    guard let exifIDs = exifItemIDs(bytes, iinf) else { return .unreadable("iinf 盒子读不通") }
    guard let exifID = exifIDs.first else { return .absent }
    guard let iloc = children.first(where: { $0.type == "iloc" }) else { return .unreadable("没有 iloc 盒子") }
    guard let extents = itemExtents(bytes, iloc, item: exifID) else { return .unreadable("iloc 里读不出 Exif 项的位置") }
    let idat = children.first(where: { $0.type == "idat" })?.content
    var data: [UInt8] = []
    for extent in extents {
        let origin: Int
        switch extent.method {
        case 0: origin = 0
        case 1:
            guard let idat else { return .unreadable("Exif 项放在 idat 里，但没有 idat 盒子") }
            origin = idat.lowerBound
        default: return .unreadable("Exif 项的构造方式 \(extent.method) 不支持")
        }
        let start = origin + extent.offset
        let limit = extent.method == 1 ? idat!.upperBound : bytes.count
        // 长度 0 表示「到所在数据的末尾」。
        let length = extent.length == 0 ? limit - start : extent.length
        guard start >= origin, length >= 0, start <= limit - length else { return .unreadable("Exif 项的范围越出文件") }
        data += bytes[start..<(start + length)]
    }
    guard let skip = bigEndianInt(data, 0, 4), skip <= data.count - 4 else { return .unreadable("Exif 项的 TIFF 头偏移越界") }
    guard let tiff = TIFFStructure(data, base: 4 + skip, length: data.count - 4 - skip) else {
        return .unreadable("Exif 项里不是合法的 TIFF 头")
    }
    return .tiff(tiff)
}

/// iinf 里类型为 `Exif` 的项号，按出现顺序。结构读不通是 nil。
func exifItemIDs(_ bytes: [UInt8], _ iinf: HEIFBox) -> [Int]? {
    // 每一步都先核对盒子自己的内容够不够长：盒子内的字段不能借用后面盒子的字节。
    let c = iinf.content
    guard c.count >= 4, let version = bigEndianInt(bytes, c.lowerBound, 1) else { return nil }
    let countWidth = version == 0 ? 2 : 4
    guard c.count >= 4 + countWidth,
          let entries = heifBoxes(bytes, in: (c.lowerBound + 4 + countWidth)..<c.upperBound) else { return nil }
    var ids: [Int] = []
    for infe in entries where infe.type == "infe" {
        let at = infe.content.lowerBound
        guard infe.content.count >= 4, let v = bigEndianInt(bytes, at, 1) else { return nil }
        // 版本 0、1 没有项类型字段，不会是 Exif 项。
        guard v >= 2 else { continue }
        let idWidth = v == 2 ? 2 : 4
        guard let id = bigEndianInt(bytes, at + 4, idWidth), at + 4 + idWidth + 2 + 4 <= infe.content.upperBound else { return nil }
        let typeAt = at + 4 + idWidth + 2
        if Array(bytes[typeAt..<(typeAt + 4)]) == Array("Exif".utf8) { ids.append(id) }
    }
    return ids
}

/// iloc 里一项的一段。`offset` 是 iloc 里写的值（不含项的基址），`offsetField`、`lengthField`
/// 是这两个字段在文件里的起点，改写时原地改它们。
struct ILocExtent {
    let offset: Int
    let length: Int
    let offsetField: Int
    let lengthField: Int
}

/// iloc 里的一项。`method` 是构造方式（0 文件偏移、1 idat 偏移、2 项偏移）。
struct ILocItem {
    let id: Int
    let method: Int
    let dataReference: Int
    let baseOffset: Int
    let extents: [ILocExtent]
}

/// iloc 的字段宽度（字节，0、4 或 8）。
struct ILocWidths {
    let offset: Int
    let length: Int
}

/// 按顺序逐项读 iloc，每读完一项交给 `visit`，`visit` 返回 false 就停在那里。
/// 在停下之前结构就读不通（版本不认识、字段宽度不合法、越出盒子）是 nil。
func walkILoc(_ bytes: [UInt8], _ iloc: HEIFBox, visit: (ILocItem) -> Bool) -> ILocWidths? {
    let end = iloc.content.upperBound
    var at = iloc.content.lowerBound
    func read(_ width: Int) -> Int? {
        guard at + width <= end, let v = bigEndianInt(bytes, at, width) else { return nil }
        at += width
        return v
    }
    guard let version = read(1), version <= 2, read(3) != nil,
          let sizes1 = read(1), let sizes2 = read(1) else { return nil }
    let offsetSize = sizes1 >> 4, lengthSize = sizes1 & 0xF, baseOffsetSize = sizes2 >> 4
    let indexSize = version == 0 ? 0 : sizes2 & 0xF
    for width in [offsetSize, lengthSize, baseOffsetSize, indexSize] where ![0, 4, 8].contains(width) { return nil }
    let widths = ILocWidths(offset: offsetSize, length: lengthSize)
    guard let itemCount = read(version < 2 ? 2 : 4) else { return nil }
    for _ in 0..<itemCount {
        guard let id = read(version < 2 ? 2 : 4) else { return nil }
        var method = 0
        if version >= 1 {
            guard let m = read(2) else { return nil }
            method = m & 0xF
        }
        guard let dataReference = read(2), let baseOffset = read(baseOffsetSize),
              let extentCount = read(2) else { return nil }
        var extents: [ILocExtent] = []
        for _ in 0..<extentCount {
            guard read(indexSize) != nil else { return nil }
            let offsetField = at
            guard let offset = read(offsetSize) else { return nil }
            let lengthField = at
            guard let length = read(lengthSize) else { return nil }
            extents.append(ILocExtent(offset: offset, length: length, offsetField: offsetField, lengthField: lengthField))
        }
        if !visit(ILocItem(id: id, method: method, dataReference: dataReference, baseOffset: baseOffset,
                           extents: extents)) { break }
    }
    return widths
}

/// iloc 里某一项的各段范围。结构读不通或找不到这一项是 nil。
private func itemExtents(_ bytes: [UInt8], _ iloc: HEIFBox, item wanted: Int)
    -> [(method: Int, offset: Int, length: Int)]? {
    var found: ILocItem?
    guard walkILoc(bytes, iloc, visit: { item in
        guard item.id == wanted else { return true }
        found = item
        return false
    }) != nil, let found, !found.extents.isEmpty else { return nil }
    return found.extents.map { (found.method, found.baseOffset + $0.offset, $0.length) }
}

/// Exif 项的最后一段是否按文件偏移存放、恰好结束在文件的最后一个字节。ImageIO 写的产物里
/// Exif 项在 `mdat` 靠前的位置（图像数据之前），只有照搬过的产物（carryingExif 把新内容
/// 接在文件末尾）才会这样。结构读不通或没有 Exif 项都是 false。
func heifExifEndsAtFileEnd(_ bytes: [UInt8]) -> Bool {
    guard case .success(let children) = heifMetaChildren(bytes),
          let iinf = children.first(where: { $0.type == "iinf" }),
          let exifID = exifItemIDs(bytes, iinf)?.first,
          let iloc = children.first(where: { $0.type == "iloc" }),
          let last = itemExtents(bytes, iloc, item: exifID)?.last else { return false }
    return last.method == 0 && last.length > 0 && last.offset >= 0
        && last.offset <= bytes.count - last.length && last.offset + last.length == bytes.count
}
