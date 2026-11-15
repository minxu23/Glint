// EXIF 整块照搬：ImageIO 写完 HEIC 之后，把产物里 Exif 项的内容换成源 JPEG 的 EXIF
// 原始字节。ImageIO 从属性字典重写 EXIF 时，它不认识的东西（各家 MakerNote、规范新标签、
// 不合规范的写法、GPS 秒的精度）一读一写就没了；照搬让它们原样留在产物里。
//
// 照搬的是源的 TIFF 原样，或者只改了备注那一条的源 TIFF：源里的 UserComment 要修补时
// （SourceUserComment.toRepair：ImageIO 读不出而自己解析出可靠的文本，或 `ASCII` 头里装着
// 非 ASCII 的 UTF-8），备注改写成 ImageIO 读得对的写法（rewritingUserComment）。
//
// 这里是纯函数部分：闸门与改写，进字节、出字节，不碰文件也不碰 ImageIO。改写完的自检
// （读回、视图不退步）和落盘在 Converter.swift 的 carryRawExif。
//
// 改写的布局：新内容（原前缀 + 源的 TIFF）接在文件末尾，也就是最后那个 `mdat` 的末尾；
// `mdat` 的长度字段加上新内容的长度；`iloc` 里 Exif 项的偏移与长度指向新内容；原内容
// 所在的范围清零。除这四处以外，旧文件末尾之前的字节一个不动，图像数据不挪位置。
//
// 闸门：产物的所有长度、偏移、个数都不信，任何一条读不通或拿不准就不换，产物保持
// ImageIO 写出来的样子。

import Foundation

/// 不照搬的原因。不是错误：产物照旧是 ImageIO 写出来的那一份。
struct RawExifSkip: Error, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// `Exif\0\0`：JPEG 的 APP1 与 HEIF 的 Exif 项里，TIFF 头前面的那 6 个字节。
let exifHeader: [UInt8] = Array("Exif".utf8) + [0, 0]

/// Exif 项开头的「TIFF 头偏移」允许的上限。ImageIO 写的是 6（正好跳过 `Exif\0\0`）。
let maxExifPrefixSkip = 64

/// 源 JPEG 的 EXIF 段里的 TIFF 字节（`Exif\0\0` 之后的全部内容）。
///
/// 闸门（源一侧）：恰好一个以 `Exif\0\0` 开头的 APP1，内容是合法的 TIFF 头。
func sourceExifTIFF(_ source: SourceJPEG) -> Result<[UInt8], RawExifSkip> {
    guard let layout = source.layout else { return .failure(.init("源文件的 JPEG 结构读不通")) }
    let jpeg = source.bytes
    let segments = layout.segments.filter { $0.marker == 0xE1 && $0.begins(with: exifHeader, in: jpeg) }
    guard !segments.isEmpty else { return .failure(.init("源里没有 EXIF 段")) }
    guard segments.count == 1 else { return .failure(.init("源里的 EXIF 段不止一个")) }
    let base = segments[0].payload.lowerBound + exifHeader.count
    let length = segments[0].payload.upperBound - base
    guard TIFFStructure(jpeg, base: base, length: length) != nil else {
        return .failure(.init("源里的 EXIF 段不是合法的 TIFF"))
    }
    return .success(Array(jpeg[base..<(base + length)]))
}

/// 同上，给手里只有字节的调用方（RAF 内嵌的 JPEG、单测）。
func sourceExifTIFF(_ jpeg: [UInt8]) -> Result<[UInt8], RawExifSkip> {
    sourceExifTIFF(SourceJPEG(jpeg))
}

// MARK: - 备注改写

/// ExifIFD 里唯一那个 UserComment（0x9286）条目的位置（条目头相对 TIFF 头的偏移）。
/// ExifIFD 指针读得通、表里每个条目的 12 个字节都在块内、0x9286 恰好一个，才有；否则 nil。
/// 照搬时的备注改写（rewritingUserComment）与校验认改写（isUserCommentRewrite）都以它为准。
func soleUserCommentEntry(_ tiff: TIFFStructure) -> Int? {
    guard let ifd = tiff.exifIFD, let count = tiff.u16(ifd) else { return nil }
    var found: [Int] = []
    for k in 0..<count {
        let entry = ifd + 2 + k * 12
        guard entry + 12 <= tiff.length, let tag = tiff.u16(entry) else { return nil }
        if tag == 0x9286 { found.append(entry) }
    }
    return found.count == 1 ? found[0] : nil
}

/// 备注改写时接在块末尾的新值：文本全是 ASCII 用 `ASCII\0\0\0` + 文本；否则
/// `UNICODE\0` + BOM + UTF-16，字节序（BOM 也一样）与 TIFF 头相同。
///
/// BOM 不能省：ImageIO 读 `UNICODE` 备注时有 BOM 认 BOM，没有就一律当大端，小端块里
/// 不带 BOM 的 UTF-16 会读成乱码。非 ASCII 文本也不能用 `ASCII` 头，ImageIO 按 Latin-1 解。
func userCommentValue(_ text: String, bigEndian: Bool) -> [UInt8] {
    if text.utf8.allSatisfy({ $0 < 0x80 }) { return Array("ASCII\0\0\0".utf8) + Array(text.utf8) }
    let units = [UInt16(0xFEFF)] + Array(text.utf16)
    return Array("UNICODE\0".utf8) + units.flatMap { u -> [UInt8] in
        bigEndian ? [UInt8(u >> 8), UInt8(u & 0xFF)] : [UInt8(u & 0xFF), UInt8(u >> 8)]
    }
}

/// 把源 TIFF 里的 UserComment 改写成 ImageIO 读得出的写法，返回新的 TIFF；不改写是 nil。
///
/// 新值（userCommentValue）接在块末尾，块长为奇数时先补一个 0；0x9286 条目的 type 改成 7
/// （UNDEFINED）、count 改成新值的字节数、offset 指向新值，按块的字节序写。除这 10 个字节
/// 以外源 TIFF 的每个字节都不动，旧的备注字节留在原处、不再有人引用。
///
/// 不改写：块不是合法的 TIFF、soleUserCommentEntry 是 nil、文本是空的、新值的偏移或长度
/// 放不进 4 字节。
func rewritingUserComment(_ tiff: [UInt8], text: String) -> [UInt8]? {
    guard !text.isEmpty, let structure = TIFFStructure(tiff, base: 0, length: tiff.count),
          let entry = soleUserCommentEntry(structure) else { return nil }
    let value = userCommentValue(text, bigEndian: structure.bigEndian)
    var out = tiff
    if out.count % 2 == 1 { out.append(0) }
    let at = out.count
    guard at + value.count <= 0xFFFF_FFFF else { return nil }
    func put(_ v: Int, width: Int, at offset: Int) {
        let be = (0..<width).map { UInt8(truncatingIfNeeded: v >> (8 * (width - 1 - $0))) }
        out.replaceSubrange(offset..<(offset + width), with: structure.bigEndian ? be : be.reversed())
    }
    put(7, width: 2, at: entry + 2)
    put(value.count, width: 4, at: entry + 4)
    put(at, width: 4, at: entry + 8)
    return out + value
}

/// 产物的 TIFF `product` 是不是源 TIFF `source` 按文本 `text` 做的备注改写。
///
/// 全部满足才是：源里 soleUserCommentEntry 找得到那一条；`product` 的前 |source| 个字节与
/// 源相同，只有那一条的 type、count、offset 这 10 个字节可以不同；补齐字节（源长为奇数时）
/// 是 0；那一条在 `product` 里是 type 7，offset 指向补齐之后，count 恰好到 `product` 末尾；
/// 这段值解出来是 userCommentValue 规定的写法：文本全是 ASCII 时是 `ASCII\0\0\0` 加文本
/// 的字节，否则是 `UNICODE\0` 加 BOM 加文本的 UTF-16，字节序与 TIFF 头相同。
///
/// 值是解出来逐项核对的，不调用 userCommentValue 比字节：写的一侧写错了（漏了 BOM、
/// 选错了头），这里不会跟着它错。
func isUserCommentRewrite(source: [UInt8], product: [UInt8], text: String) -> Bool {
    guard let s = TIFFStructure(source, base: 0, length: source.count),
          let entry = soleUserCommentEntry(s) else { return false }
    let start = source.count + source.count % 2
    guard product.count > start else { return false }
    let editable = (entry + 2)..<(entry + 12)
    for i in 0..<source.count where !editable.contains(i) && product[i] != source[i] { return false }
    if start > source.count, product[source.count] != 0 { return false }
    guard let p = TIFFStructure(product, base: 0, length: product.count),
          p.u16(entry + 2) == 7, p.u32(entry + 4) == product.count - start, p.u32(entry + 8) == start
    else { return false }
    let head = Array(product[start..<min(start + 8, product.count)]), body = Array(product[min(start + 8, product.count)...])
    if text.utf8.allSatisfy({ $0 < 0x80 }) {
        return !text.isEmpty && head == Array("ASCII\0\0\0".utf8) && body == Array(text.utf8)
    }
    guard head == Array("UNICODE\0".utf8), body.count % 2 == 0 else { return false }
    let units = stride(from: 0, to: body.count, by: 2).map { i -> UInt16 in
        s.bigEndian ? UInt16(body[i]) << 8 | UInt16(body[i + 1]) : UInt16(body[i + 1]) << 8 | UInt16(body[i])
    }
    return units == [0xFEFF] + Array(text.utf16)
}

/// 一个数写进 `width` 字节的大端字段；放不下是 nil。`limit32` 是 4 字节字段装得下的最大值。
private func bigEndianBytes(_ value: Int, width: Int, limit32: Int) -> [UInt8]? {
    guard value >= 0, width == 4 || width == 8 else { return nil }
    if width == 4, value > limit32 { return nil }
    return (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * (width - 1 - $0))) }
}

/// 把 HEIF 产物里 Exif 项的 TIFF 换成 `tiff`，返回新文件的字节；闸门不过是不换的原因。
///
/// 闸门（产物一侧）：
/// - 顶层盒子读得通，恰好一个 `meta`，里面恰好一个 `iinf`、一个 `iloc`；顶层最后一个盒子是 `mdat`。
/// - 恰好一个 Exif 项；`iloc` 里它恰好出现一次、恰好一段，构造方式 0，data_reference_index 0，
///   长度不是 0（0 表示「到文件末尾」）。
/// - 原内容整个落在某个顶层 `mdat` 的内容里，不与 `iloc` 里任何别的项的任何一段重叠
///   （要清零，重叠就会毁掉别人的数据）。别的项有长度写成 0 的段（到文件末尾，接上新内容
///   就会把它吞进去）、或有构造方式 2（按项偏移）的，也不换。
/// - 原内容开头的 TIFF 头偏移不超过 maxExifPrefixSkip，之后是合法的 TIFF 头。
/// - 最后那个 `mdat` 的长度字段放得下新长度（32 位放不下就不换，不改盒头宽度）；
///   新偏移、新长度放得进 `iloc` 现有的字段宽度（宽度 0 的字段改不了，也不换）。
/// - 产物的 TIFF 已与 `tiff` 逐字节相同：无事可做。
///
/// `limit32` 是 4 字节字段装得下的最大值，只有单测会改小它：放不下的情形要 4 GiB 的文件，
/// 手搭不出来。
func carryingExif(_ tiff: [UInt8], into heif: [UInt8], limit32: Int = 0xFFFF_FFFF) -> Result<[UInt8], RawExifSkip> {
    func skip(_ reason: String) -> Result<[UInt8], RawExifSkip> { .failure(.init(reason)) }

    guard let top = heifBoxes(heif, in: 0..<heif.count) else { return skip("产物的顶层盒子读不通") }
    guard top.filter({ $0.type == "meta" }).count == 1 else { return skip("产物的顶层 meta 盒子不是恰好一个") }
    guard let last = top.last, last.type == "mdat" else { return skip("产物的最后一个盒子不是 mdat") }
    guard case .success(let children) = heifMetaChildren(heif) else { return skip("产物的 meta 盒子读不通") }
    let iinfs = children.filter { $0.type == "iinf" }, ilocs = children.filter { $0.type == "iloc" }
    guard iinfs.count == 1, ilocs.count == 1 else { return skip("产物的 iinf、iloc 盒子不是各一个") }
    guard let exifIDs = exifItemIDs(heif, iinfs[0]) else { return skip("产物的 iinf 盒子读不通") }
    guard exifIDs.count == 1 else {
        return skip(exifIDs.isEmpty ? "产物里没有 Exif 项" : "产物里的 Exif 项不止一个")
    }
    let exifID = exifIDs[0]

    var items: [ILocItem] = []
    guard let widths = walkILoc(heif, ilocs[0], visit: { items.append($0); return true }) else {
        return skip("产物的 iloc 盒子读不通")
    }
    let exifItems = items.filter { $0.id == exifID }
    guard exifItems.count == 1 else { return skip("Exif 项在 iloc 里不是恰好出现一次") }
    let item = exifItems[0]
    guard item.extents.count == 1 else { return skip("Exif 项不是恰好一段") }
    guard item.method == 0, item.dataReference == 0 else { return skip("Exif 项不是按文件偏移存放的") }
    let extent = item.extents[0]
    let start = item.baseOffset + extent.offset, length = extent.length
    guard length > 0, start >= 0, start <= heif.count - length else { return skip("Exif 项的范围越出文件") }
    let old = start..<(start + length)
    guard top.contains(where: { $0.type == "mdat" && $0.content.lowerBound <= old.lowerBound
                                && old.upperBound <= $0.content.upperBound }) else {
        return skip("Exif 项不在顶层 mdat 里")
    }
    for other in items where other.id != exifID {
        guard other.method != 2 else { return skip("产物里有按项偏移构造的项") }
        guard other.method == 0, other.dataReference == 0 else { continue }
        for e in other.extents {
            guard e.length > 0 else { return skip("产物里有长度写成「到文件末尾」的项") }
            let s = other.baseOffset + e.offset
            guard s >= 0, s <= heif.count - e.length else { return skip("产物里有越出文件的项") }
            if s < old.upperBound && old.lowerBound < s + e.length { return skip("Exif 项与别的项重叠") }
        }
    }

    guard let skipBytes = bigEndianInt(heif, start, 4), skipBytes <= maxExifPrefixSkip,
          4 + skipBytes < length else { return skip("Exif 项开头的 TIFF 头偏移不对") }
    let tiffStart = start + 4 + skipBytes
    guard TIFFStructure(heif, base: tiffStart, length: old.upperBound - tiffStart) != nil else {
        return skip("产物的 Exif 项里不是合法的 TIFF")
    }
    guard Array(heif[tiffStart..<old.upperBound]) != tiff else { return skip("产物里的 EXIF 已与源逐字节相同") }

    let content = Array(heif[start..<tiffStart]) + tiff
    let newStart = heif.count
    // mdat 的长度字段：32 位、64 位（size == 1）、到文件末尾（size == 0，不用改）。
    guard let size32 = bigEndianInt(heif, last.start, 4) else { return skip("产物的 mdat 盒头读不通") }
    var sizeField: (at: Int, bytes: [UInt8])?
    switch size32 {
    case 0:
        sizeField = nil
    case 1:
        guard let large = bigEndianInt(heif, last.start + 8, 8),
              let field = bigEndianBytes(large + content.count, width: 8, limit32: limit32) else { return skip("产物的 mdat 长度读不通") }
        sizeField = (last.start + 8, field)
    default:
        guard let field = bigEndianBytes(size32 + content.count, width: 4, limit32: limit32) else {
            return skip("产物的 mdat 是 32 位长度，放不下照搬后的长度")
        }
        sizeField = (last.start, field)
    }
    guard newStart >= item.baseOffset,
          let offsetField = bigEndianBytes(newStart - item.baseOffset, width: widths.offset, limit32: limit32) else {
        return skip("iloc 的偏移字段放不下新位置")
    }
    guard let lengthField = bigEndianBytes(content.count, width: widths.length, limit32: limit32) else {
        return skip("iloc 的长度字段放不下新长度")
    }

    var out = heif
    out.replaceSubrange(old, with: [UInt8](repeating: 0, count: length))
    if let sizeField { out.replaceSubrange(sizeField.at..<(sizeField.at + sizeField.bytes.count), with: sizeField.bytes) }
    out.replaceSubrange(extent.offsetField..<(extent.offsetField + widths.offset), with: offsetField)
    out.replaceSubrange(extent.lengthField..<(extent.lengthField + widths.length), with: lengthField)
    out += content
    return .success(out)
}
