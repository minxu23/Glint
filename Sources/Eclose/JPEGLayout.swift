// JPEG 的段结构：哪些标记段、各自的内容在哪、EOI 在哪。
//
// 手写 EXIF 解析（ExifReader.swift）、源侧原始字节里的时间（RawTimes.swift）、
// 「ImageIO 搬不走的段」清单（unportableSegments）、APP13 的 Photoshop 资源
// （photoshopResources）都从这里取段，不各自扫一遍。

import Foundation

struct JPEGSegment {
    /// 标记的第二个字节，如 0xE1 表示 APP1、0xFE 表示 COM。
    let marker: UInt8
    /// 段内容（长度字段之后）在文件里的范围。
    let payload: Range<Int>

    /// 内容是否以给定的标识开头（如 APP1 的 `Exif\0\0`）。
    func begins(with id: [UInt8], in bytes: [UInt8]) -> Bool {
        payload.count >= id.count && Array(bytes[payload.lowerBound..<(payload.lowerBound + id.count)]) == id
    }
}

struct JPEGLayout {
    /// 按文件顺序的全部带长度的标记段（含 SOS 及渐进式 JPEG 扫描之间的段）。
    let segments: [JPEGSegment]
    /// EOI（FF D9）的起点；文件在 EOI 之前就结束了是 nil。
    let eoi: Int?

    /// EOI 之后还有多少字节。
    func trailerCount(in bytes: [UInt8]) -> Int {
        guard let eoi else { return 0 }
        return bytes.count - (eoi + 2)
    }

    /// 解析 `bytes` 的段结构；不以 SOI 开头就是 nil。段长度越界时就停在那里，
    /// 已解析出的段照样返回、`eoi` 为 nil。
    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var segments: [JPEGSegment] = []
        var eoi: Int?
        var i = 2
        scan: while i + 1 < bytes.count {
            guard bytes[i] == 0xFF else { break }
            // 标记前可以有任意个填充用的 0xFF。
            var m = i + 1
            while m < bytes.count, bytes[m] == 0xFF { m += 1 }
            guard m < bytes.count else { break }
            let marker = bytes[m]
            if marker == 0xD9 { eoi = m - 1; break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i = m + 1; continue }
            guard m + 2 < bytes.count else { break }
            let length = Int(bytes[m + 1]) << 8 | Int(bytes[m + 2])
            let end = m + 1 + length
            guard length >= 2, end <= bytes.count else { break }
            segments.append(JPEGSegment(marker: marker, payload: (m + 3)..<end))
            i = end
            guard marker == 0xDA else { continue }
            // 熵编码数据：FF 00 是转义，FF D0–D7 是复位标记，FF FF 是填充；
            // 别的 FF xx 是下一个标记段（渐进式 JPEG 在扫描之间插 DHT 等）或 EOI。
            var j = end
            while j + 1 < bytes.count {
                if bytes[j] != 0xFF { j += 1; continue }
                let next = bytes[j + 1]
                if next == 0x00 || (0xD0...0xD7).contains(next) { j += 2; continue }
                if next == 0xFF { j += 1; continue }
                i = j
                continue scan
            }
            break
        }
        self.segments = segments
        self.eoi = eoi
    }
}

// MARK: - ImageIO 搬不走的部分

/// ImageIO 读得懂、会搬或有意不搬（编码相关）的 APPn 段，按标记与内容开头的标识认。
/// 别的 APPn 它既不读也不写，转成 HEIF 后整段消失。
private let portableAppSegments: [(marker: UInt8, id: [UInt8])] = [
    (0xE0, Array("JFIF".utf8) + [0]),
    (0xE0, Array("JFXX".utf8) + [0]),
    (0xE1, Array("Exif".utf8) + [0]),
    (0xE1, Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]),
    // 扩展 XMP：ImageIO 读源时把它并进 XMP 视图，转换时随 XMP 一起搬走；
    // 真搬丢了，键空间比对会逐个标签报出来。
    (0xE1, Array("http://ns.adobe.com/xmp/extension/".utf8) + [0]),
    (0xE2, Array("ICC_PROFILE".utf8) + [0]),
    // MPF 只是 EOI 之后那些附加图像的目录，丢失由尾部数据那一条报。
    (0xE2, mpfID),
    (0xED, Array("Photoshop 3.0".utf8) + [0]),
    (0xEE, Array("Adobe".utf8)),
    // 苹果的 ImageIO 写大图 JPEG 时加的 APP10 `AROT\0\0`：这份 JPEG 压缩数据的逐行索引。
    // 实测一张 5712×4284 的：4 字节一条共 269 条，MCU 行数（高 ÷ 16）是 268；同一个文件
    // DRI 的重启间隔 357 正好是一行的 MCU 数（宽 ÷ 16），即每行一个重启标记，索引指向它们，
    // 供快速解码或旋转。有没有增益图都在（exiftool 叫它 HDRGainCurve，但与增益图无关）。
    // 它只对这份 JPEG 的码流有意义，转成 HEIF 后不该存在。只认后面紧跟两个 0 的。
    (0xEA, Array("AROT".utf8) + [0, 0]),
]
private let mpfID: [UInt8] = Array("MPF".utf8) + [0]

/// 带 ISO 增益图的 JPEG 主图里的 ISO 21496-1 版本标记段：APP2，内容是标识
/// `urn:iso:std:iso:ts:21496:-1\0` 加 4 字节（最低版本、写入方版本各 2 字节），
/// 一共 32 字节。多出任何字节都不算——那就不只是版本号了。
func isISOGainMapVersionSegment(_ s: JPEGSegment, in bytes: [UInt8]) -> Bool {
    let id: [UInt8] = Array("urn:iso:std:iso:ts:21496:-1".utf8) + [0]
    return s.marker == 0xE2 && s.payload.count == id.count + 4 && s.begins(with: id, in: bytes)
}

/// FlashPix 扩展：APP2，内容以 `FPXR\0` 开头。富士等相机用它存一张预览 JPEG 和它的目录，
/// 都是主图的派生物。目录段和数据段一样认。
func isFlashPixSegment(_ s: JPEGSegment, in bytes: [UInt8]) -> Bool {
    s.marker == 0xE2 && s.begins(with: Array("FPXR".utf8) + [0], in: bytes)
}

/// Photoshop「存储为 Web 格式」写的 APP12 `Ducky` 段，且里面只有保存质量。
///
/// `Ducky` 之后是一串记录：2 字节标签、2 字节长度、数据，大端；遇到标签 0（必须是段的
/// 最后 2 字节）或段尾结束。只认至少一条、每条都是标签 1（保存质量，长度 4）的；有注释
/// （标签 2）、版权（标签 3）或别的标签，记录越界，标签 0 后面还有字节，都不认。
func isDuckyQualityOnlySegment(_ s: JPEGSegment, in bytes: [UInt8]) -> Bool {
    let id = Array("Ducky".utf8)
    guard s.marker == 0xEC, s.begins(with: id, in: bytes) else { return false }
    let end = s.payload.upperBound
    func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
    var i = s.payload.lowerBound + id.count, records = 0
    while i < end {
        guard i + 2 <= end else { return false }
        if u16(i) == 0 { if i + 2 == end { break } else { return false } }
        guard i + 4 <= end, u16(i) == 1, u16(i + 2) == 4, i + 4 + 4 <= end else { return false }
        records += 1
        i += 4 + 4
    }
    return records > 0
}

/// 微信导出的图在 EOI 之后加的 8 字节：`tyf-` 加 4 个 0。
private let weChatTrailer: [UInt8] = Array("tyf-".utf8) + [0, 0, 0, 0]

/// 不报的段：没有可带的信息。各自的形状见判据函数，差一点就不认。
///   - ISO 21496-1 版本标记段只有版本号；增益图本身丢没丢由尾部记账和辅助图的键比对负责。
///   - FlashPix 扩展是相机的预览图，主图的派生物。
///   - 只有保存质量的 Ducky 段是编码参数。
func isWorthlessSegment(_ s: JPEGSegment, in bytes: [UInt8]) -> Bool {
    isISOGainMapVersionSegment(s, in: bytes) || isFlashPixSegment(s, in: bytes) || isDuckyQualityOnlySegment(s, in: bytes)
}

// MARK: - MPF 多图索引与尾部记账

/// MPF 索引里登记的一张附加图像。
struct MPFImage: Equatable {
    /// MP 类型码：条目属性字段的低 24 位。辅助图（增益图、深度图、蒙版）多写 0（未定义），
    /// 新版 MPF 给增益图另定了 0x050000；大尺寸预览图是 0x010001/0x010002，多视角图是
    /// 0x02xxxx，编辑前的原图（Original Preservation Image）是 0x040000。
    let typeCode: Int
    /// 在文件里的绝对字节范围，已核对过落在文件之内。
    let range: Range<Int>
}

/// 读 APP2 `MPF\0` 段里的 MP 索引，返回第二个条目起的附加图像（第一个条目是主图
/// 自己）。偏移、长度、条目数都来自源文件，一律不信：段内结构越界或自相矛盾就整个
/// 返回空数组；单个条目的范围越出文件或长度为 0 就不收这一条（越出文件的见 mpfMissingImages）。
/// 只读文件里第一个 MPF 段，偏移按 MP 规范从段内 TIFF 头的起点算。
func mpfImages(in bytes: [UInt8], _ layout: JPEGLayout) -> [MPFImage] {
    mpfEntries(in: bytes, layout).compactMap { e in
        guard e.start + e.size <= bytes.count else { return nil }
        return MPFImage(typeCode: e.typeCode, range: e.start..<(e.start + e.size))
    }
}

/// MPF 索引登记了、范围却越出文件末尾的附加图像：文件截短了，或者编辑软件重存主图时把旧索引原样留着
/// （主图变小了，附加图像没带上）。源里本来就没有这张图，产物里也不会有。
/// 大尺寸预览图（0x010001/0x010002）不算：它是主图的派生物，在文件里也不带（previewTrailerRanges），
/// 不在了也没少什么。去掉尾部的工具常把预览图连同索引里的登记一起留成这样。
func mpfMissingImages(in bytes: [UInt8], _ layout: JPEGLayout) -> [(typeCode: Int, size: Int)] {
    mpfEntries(in: bytes, layout)
        .filter { $0.start + $0.size > bytes.count && !previewMPFTypes.contains($0.typeCode) }
        .map { ($0.typeCode, $0.size) }
}

/// 原图的 MPF 索引登记了不在文件里的附加图像时，写进状态说明的那句；都在是 nil。
/// 只是说明，不算校验差异：源里本来就没有这些图，转换没丢东西。要不要因此保留源文件由
/// ConversionOptions.keepStaleMPF 定（默认照删）。
func staleMPFNotice(_ bytes: [UInt8]) -> String? {
    guard let layout = JPEGLayout(bytes) else { return nil }
    let missing = mpfMissingImages(in: bytes, layout)
    guard !missing.isEmpty else { return nil }
    let items = missing.map { m -> String in
        let kind = m.typeCode == 0x050000 ? "增益图，" : ""
        return kind + "类型码 " + String(format: "0x%06X", m.typeCode) + "，\(m.size) 字节"
    }
    return "原图的 MPF 索引登记的附加图像（" + items.joined(separator: "；") + "）不在文件里："
        + "原图被编辑或截短过，这张图转换前就没了，HEIF 里也没有"
}

/// MP 索引里第二个条目起的原始登记：类型码、在文件里的绝对起点、长度。偏移或长度为 0 的不收。
private func mpfEntries(in bytes: [UInt8], _ layout: JPEGLayout) -> [(typeCode: Int, start: Int, size: Int)] {
    guard let segment = layout.segments.first(where: { $0.marker == 0xE2 && $0.begins(with: mpfID, in: bytes) })
    else { return [] }
    let base = segment.payload.lowerBound + mpfID.count
    let end = segment.payload.upperBound
    guard base + 8 <= end else { return [] }
    let little: Bool
    switch (bytes[base], bytes[base + 1], bytes[base + 2], bytes[base + 3]) {
    case (0x49, 0x49, 0x2A, 0x00): little = true
    case (0x4D, 0x4D, 0x00, 0x2A): little = false
    default: return []
    }
    func u16(_ at: Int) -> Int? {
        guard at >= base, at + 2 <= end else { return nil }
        return little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
    }
    func u32(_ at: Int) -> Int? {
        guard let a = u16(at), let b = u16(at + 2) else { return nil }
        return little ? a | b << 16 : a << 16 | b
    }
    guard let ifdOffset = u32(base + 4), let tagCount = u16(base + ifdOffset) else { return [] }
    // MP 索引 IFD 的条目全在段内：每个 12 字节。条目数离谱就在这里越界返回。
    let tags = base + ifdOffset + 2
    guard tags + tagCount * 12 <= end else { return [] }
    var entries: (count: Int, offset: Int)?
    for t in 0..<tagCount {
        let at = tags + t * 12
        // 0xB002 MPEntry：类型 7（UNDEFINED），长度是 16 × 图像数，值是偏移。
        guard u16(at) == 0xB002 else { continue }
        guard u16(at + 2) == 7, let count = u32(at + 4), let offset = u32(at + 8),
              count % 16 == 0, base + offset + count <= end else { return [] }
        entries = (count / 16, base + offset)
        break
    }
    guard let entries, entries.count >= 1 else { return [] }
    var images: [(typeCode: Int, start: Int, size: Int)] = []
    for k in 1..<entries.count {
        let at = entries.offset + k * 16
        guard let attribute = u32(at), let size = u32(at + 4), let offset = u32(at + 8) else { return [] }
        guard offset > 0, size > 0 else { continue }
        images.append((attribute & 0xFF_FFFF, base + offset, size))
    }
    return images
}

/// 一段字节是不是恰好一张完整的 JPEG（从 SOI 到 EOI，后面没有多余的字节），是的话
/// 给出它的 SOF 里的宽和高。
func standaloneJPEGSize(_ bytes: ArraySlice<UInt8>) -> (width: Int, height: Int)? {
    let image = Array(bytes)
    guard let layout = JPEGLayout(image), let eoi = layout.eoi, eoi + 2 == image.count else { return nil }
    // SOF0–SOF15，除去 DHT（C4）、JPG（C8）、DAC（CC）。内容：精度、高、宽、分量数。
    guard let sof = layout.segments.first(where: {
        (0xC0...0xCF).contains($0.marker) && ![0xC4, 0xC8, 0xCC].contains($0.marker)
    }), sof.payload.count >= 6 else { return nil }
    let p = sof.payload.lowerBound
    return (Int(image[p + 3]) << 8 | Int(image[p + 4]), Int(image[p + 1]) << 8 | Int(image[p + 2]))
}

/// EOI 之后的字节里，哪些是已经搬进产物的辅助图。
///
/// 一个 MPF 条目算作已搬走，必须同时满足：
///   - MP 类型码是 0 或 0x050000（辅助图写的是这两种；预览图、多视角图、编辑前的原图都不是）；
///   - 范围整个落在尾部之内，且不和已认下的条目重叠；
///   - 范围里恰好是一张完整的 JPEG（SOI 开头、EOI 结尾，不多不少）；
///   - 这张 JPEG 的宽高等于 `carried` 里某一张辅助图的宽高——`carried` 是源和产物
///     都有、类型与尺寸都相同的辅助图，由调用方从两边的 ImageIO 视图里比出来。
///     每张辅助图只能认领一个条目。
/// 任何一条不满足，这个条目就不算搬走，它的字节照旧计入丢失。
func carriedTrailerRanges(in bytes: [UInt8], _ layout: JPEGLayout,
                          carried: [(width: Int, height: Int)]) -> [Range<Int>] {
    guard let eoi = layout.eoi else { return [] }
    let trailer = (eoi + 2)..<bytes.count
    var unclaimed = carried
    var accepted: [Range<Int>] = []
    for image in mpfImages(in: bytes, layout) where auxiliaryMPFTypes.contains(image.typeCode) {
        guard image.range.lowerBound >= trailer.lowerBound, image.range.upperBound <= trailer.upperBound,
              !accepted.contains(where: { $0.overlaps(image.range) }),
              let size = standaloneJPEGSize(bytes[image.range]),
              let match = unclaimed.firstIndex(where: { $0.width == size.width && $0.height == size.height })
        else { continue }
        unclaimed.remove(at: match)
        accepted.append(image.range)
    }
    return accepted
}
private let auxiliaryMPFTypes: Set<Int> = [0, 0x050000]

/// EOI 之后的字节里，哪些是 MPF 登记的大尺寸预览图：主图的缩小拷贝，与 EXIF 缩略图同理不需要带。
///
/// 一个条目算作预览图，必须同时满足：MP 类型码是 0x010001 或 0x010002；范围整个落在尾部
/// 之内，且不和 `claimed`（已认下的辅助图）或已认下的预览图重叠；范围里恰好是一张完整的 JPEG。
func previewTrailerRanges(in bytes: [UInt8], _ layout: JPEGLayout, claimed: [Range<Int>]) -> [Range<Int>] {
    guard let eoi = layout.eoi else { return [] }
    let trailer = (eoi + 2)..<bytes.count
    var accepted: [Range<Int>] = []
    for image in mpfImages(in: bytes, layout) where previewMPFTypes.contains(image.typeCode) {
        guard image.range.lowerBound >= trailer.lowerBound, image.range.upperBound <= trailer.upperBound,
              !(claimed + accepted).contains(where: { $0.overlaps(image.range) }),
              standaloneJPEGSize(bytes[image.range]) != nil
        else { continue }
        accepted.append(image.range)
    }
    return accepted
}
private let previewMPFTypes: Set<Int> = [0x010001, 0x010002]

/// 源 JPEG 没有 EOI 时那一条注意（见 unportableSegments）。
let truncatedSourceNotice = "源文件不完整：没有找到 JPEG 的结束标记（EOI），图像数据可能被截断；转出的 HEIF 里缺的部分是解码器补的"

/// 源 JPEG 里 ImageIO 看不见、因而转换后必然丢失的部分，每段一条差异：
/// COM 注释段、不认识的 APPn 段、EOI 之后的数据（全是 0x00/0xFF 填充的不算）。
/// 另外，文件在 EOI 之前就结束了（截断的 JPEG）报一条注意：ImageIO 照样解得出前面那部分、
/// 缺的地方补成灰色，转换和元数据校验都会「成功」，可产物里那块像素是解码器编的。报出来，
/// `--delete-original` 就不会删掉这样的源文件。
/// 这些都不在属性视图里，键空间比对发现不了。没有可带信息的几种段不报（isWorthlessSegment）。
///
/// EOI 之后共 M 字节，其中已经随辅助图搬进产物的 K 字节（carriedTrailerRanges）、MPF 登记的
/// 预览图 P 字节（previewTrailerRanges）不计入。剩下的 R 字节里只要有一个不是填充、又不恰好是
/// 微信的 `tyf-` 标记，就报 R：K、P 都是 0 时，R 里的非填充字节全在 MPF 登记的条目范围内就
/// 注明是 MPF 的附加图像；K 或 P 不是 0 时注明 M 和其中的 K、P。
func unportableSegments(in bytes: [UInt8], carriedAuxiliary: [(width: Int, height: Int)]) -> [String] {
    guard let layout = JPEGLayout(bytes) else { return [] }
    var issues: [String] = []
    for s in layout.segments {
        let content = Array(bytes[s.payload])
        if s.marker == 0xFE {
            let text = String(bytes: content, encoding: .utf8)
                ?? String(bytes: content, encoding: .isoLatin1) ?? ""
            issues.append("丢失 JPEG 注释段（COM）= \(truncate(trimPadding(text)))")
        } else if isWorthlessSegment(s, in: bytes) {
            continue
        } else if (0xE0...0xEF).contains(s.marker),
                  !portableAppSegments.contains(where: { $0.marker == s.marker && s.begins(with: $0.id, in: bytes) }) {
            let id = String(decoding: content.prefix { $0 >= 0x20 && $0 < 0x7F }.prefix(32), as: UTF8.self)
            issues.append("丢失 APP\(s.marker - 0xE0) 段（\(id.isEmpty ? "无标识" : id)，\(content.count) 字节）")
        }
    }
    if layout.eoi == nil {
        issues.append(truncatedSourceNotice)
    }
    issues += extraExifIssues(in: bytes, layout)
    if let eoi = layout.eoi {
        let trailer = (eoi + 2)..<bytes.count
        let carried = carriedTrailerRanges(in: bytes, layout, carried: carriedAuxiliary)
        let previews = previewTrailerRanges(in: bytes, layout, claimed: carried)
        // 两组范围互不重叠、都在尾部之内，所以剩下的字节数可以直接相减。
        let carriedCount = carried.reduce(0) { $0 + $1.count }
        let previewCount = previews.reduce(0) { $0 + $1.count }
        // 剩下的字节：尾部去掉已认下的范围，按文件顺序的几段。
        var rest: [Range<Int>] = [], at = trailer.lowerBound
        for r in (carried + previews).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if at < r.lowerBound { rest.append(at..<r.lowerBound) }
            at = r.upperBound
        }
        if at < trailer.upperBound { rest.append(at..<trailer.upperBound) }
        let restCount = rest.reduce(0) { $0 + $1.count }
        let meaningful = rest.lazy.flatMap { $0 }.filter { bytes[$0] != 0x00 && bytes[$0] != 0xFF }
        let weChat = restCount == weChatTrailer.count && rest.flatMap { bytes[$0] } == weChatTrailer
        if meaningful.first != nil, !weChat {
            var parts: [String] = []
            if carriedCount > 0 { parts.append("\(carriedCount) 字节是已搬进产物的辅助图像") }
            if previewCount > 0 { parts.append("\(previewCount) 字节是 MPF 登记的预览图，不需要带") }
            let registered = mpfImages(in: bytes, layout).map(\.range)
            let note = !parts.isEmpty
                ? "（尾部共 \(trailer.count) 字节，其中 " + parts.joined(separator: "，") + "）"
                : meaningful.allSatisfy { i in registered.contains { $0.contains(i) } } ? "（MPF 多图格式的附加图像）" : ""
            issues.append("丢失 EOI 之后的 \(restCount) 字节" + note)
        }
    }
    return issues
}

// MARK: - 多份 EXIF

/// 源里有不止一个 APP1 `Exif` 段时，第二份起每份一条差异：ImageIO 和照搬都只认第一份，后面的
/// 不进产物。后面那份里的每个条目（IFD0、Exif IFD、GPS IFD、Interop IFD；指针不算）在第一份的
/// 同一个 IFD 里都有、值也相同（字节序不同按值比）时，它没有第一份之外的信息，不报。
/// 列出不同或第一份没有的字段名，最多 8 个；读不出结构的整份报。
func extraExifIssues(in bytes: [UInt8], _ layout: JPEGLayout) -> [String] {
    let id: [UInt8] = Array("Exif".utf8) + [0, 0]
    let copies = layout.segments.filter { $0.marker == 0xE1 && $0.begins(with: id, in: bytes) }
    guard copies.count > 1 else { return [] }
    func fields(_ s: JPEGSegment) -> [String: [UInt8]]? {
        let base = s.payload.lowerBound + id.count
        guard let tiff = TIFFStructure(bytes, base: base, length: s.payload.upperBound - base) else { return nil }
        return exifFieldValues(tiff)
    }
    let first = fields(copies[0]) ?? [:]
    var issues: [String] = []
    for (k, copy) in copies.enumerated().dropFirst() {
        let head = "丢失 第 \(k + 1) 份 EXIF（APP1，\(copy.payload.count) 字节）：产物只带第 1 份"
        guard let other = fields(copy) else { issues.append(head + "，这份读不出结构"); continue }
        // 按 IFD0、Exif、GPS、Interop 的顺序，同一个 IFD 里按标签号。
        let order = ["IFD0": 0, "ExifIFD": 1, "GPS": 2, "Interop": 3]
        func rank(_ key: String) -> (Int, Int) {
            let parts = key.split(separator: ":")
            return (order[String(parts[0])] ?? 4, Int(parts[1]) ?? 0)
        }
        let differing = other.filter { first[$0.key] != $0.value }.keys.sorted { rank($0) < rank($1) }
        guard !differing.isEmpty else { continue }
        let names = differing.prefix(8).map { key -> String in
            let parts = key.split(separator: ":")
            return carriedEntryName(String(parts[0]), Int(parts[1]) ?? 0)
        }
        issues.append(head + "，这份里 \(differing.count) 个字段与第 1 份不同或第 1 份没有："
                      + names.joined(separator: "、") + (differing.count > 8 ? " 等" : ""))
    }
    return issues
}

/// 一块 EXIF（TIFF 结构）里各条目的值，键是「IFD:标签号」，值是类型码加按大端序写的值字节——
/// 两份 EXIF 字节序不同时也能直接比。指向子 IFD 的指针（0x8769、0x8825、0xA005）不收。
func exifFieldValues(_ tiff: TIFFStructure) -> [String: [UInt8]] {
    let pointers: Set<Int> = [0x8769, 0x8825, 0xA005]
    var result: [String: [UInt8]] = [:]
    func collect(_ ifd: Int?, _ name: String) {
        guard let ifd else { return }
        for e in tiff.entries(ifd) where !pointers.contains(e.tag) {
            guard var value = tiff.value(of: e) else { continue }
            let unit = [2, 3, 4, 5, 8, 9, 10, 11, 12, 13].contains(e.type)
                ? [2: 1, 3: 2, 4: 4, 5: 4, 8: 2, 9: 4, 10: 4, 11: 4, 12: 8, 13: 4][e.type]! : 1
            if !tiff.bigEndian && unit > 1 {
                value = stride(from: 0, to: value.count, by: unit).flatMap { value[$0..<min($0 + unit, value.count)].reversed() }
            }
            result["\(name):\(e.tag)"] = [UInt8(e.type & 0xFF)] + value
        }
    }
    let ifd0 = tiff.ifd0
    collect(ifd0, "IFD0")
    let exif = ifd0.flatMap { tiff.find($0, tag: 0x8769) }.flatMap { tiff.u32($0.offset) }
    collect(exif, "ExifIFD")
    collect(ifd0.flatMap { tiff.find($0, tag: 0x8825) }.flatMap { tiff.u32($0.offset) }, "GPS")
    collect(exif.flatMap { tiff.find($0, tag: 0xA005) }.flatMap { tiff.u32($0.offset) }, "Interop")
    return result
}

// MARK: - APP13 里的 Photoshop 资源

/// IPTC-IIM 所在的资源号。ImageIO 只读、只搬 APP13 里的这一个资源。
let iptcResourceID = 0x0404

/// 不进汇总行的资源：IPTC 由键空间比对逐字段管着；IPTC 摘要（0x0425）是 IPTC
/// 的校验和，从它派生；两个缩略图（0x0409、0x040C）是从像素派生的预览，理由同
/// EXIF 缩略图（README「--verify 到底比什么」）。别的资源一律报。
let ignoredPhotoshopResources: Set<Int> = [iptcResourceID, 0x0425, 0x0409, 0x040C]

/// APP13 `Photoshop 3.0` 段里的资源块。一份资源块可以跨多个段，按顺序拼起来。
func photoshopResourceBlock(_ bytes: [UInt8], _ layout: JPEGLayout) -> [UInt8] {
    let photoshopID: [UInt8] = Array("Photoshop 3.0".utf8) + [0]
    var block: [UInt8] = []
    for s in layout.segments where s.marker == 0xED && s.begins(with: photoshopID, in: bytes) {
        block += bytes[(s.payload.lowerBound + photoshopID.count)..<s.payload.upperBound]
    }
    return block
}

/// 资源块里的 `8BIM` 资源，按出现顺序。遇到不是 `8BIM` 开头或长度越界的地方就停，
/// `unparsed` 是停下之后剩下的非零字节数（资源块末尾可能有 0 填充）。
func photoshopResources(in block: [UInt8]) -> (resources: [(id: Int, content: [UInt8])], unparsed: Int) {
    var found: [(id: Int, content: [UInt8])] = []
    var i = 0
    while i + 12 <= block.count, Array(block[i..<(i + 4)]) == Array("8BIM".utf8) {
        let id = Int(block[i + 4]) << 8 | Int(block[i + 5])
        // 名字是 Pascal 串，连长度字节在内补齐到偶数。
        let nameLength = Int(block[i + 6])
        var j = i + 6 + nameLength + 1
        if (nameLength + 1) % 2 == 1 { j += 1 }
        guard j + 4 <= block.count else { break }
        let size = Int(block[j]) << 24 | Int(block[j + 1]) << 16 | Int(block[j + 2]) << 8 | Int(block[j + 3])
        let start = j + 4
        guard start + size <= block.count else { break }
        found.append((id, Array(block[start..<(start + size)])))
        // 内容补齐到偶数；最后一个资源缺了补齐字节也照收。
        i = min(start + size + (size % 2), block.count)
    }
    let unparsed = block[i...].filter { $0 != 0 }.count
    return (found, unparsed)
}

/// APP13 里 ImageIO 不搬、也不从别处派生的 Photoshop 资源，合成一条差异：
/// Photoshop 存出来的 JPEG 常带十来个资源，每个一行会刷屏。解析不了的数据一并计入。
func unportablePhotoshopResources(in bytes: [UInt8]) -> [String] {
    guard let layout = JPEGLayout(bytes) else { return [] }
    let parsed = photoshopResources(in: photoshopResourceBlock(bytes, layout))
    let lost = parsed.resources.map(\.id).filter { !ignoredPhotoshopResources.contains($0) }
    guard !lost.isEmpty || parsed.unparsed > 0 else { return [] }
    let ids = Set(lost).sorted().map { "0x" + String(format: "%04X", $0) }.joined(separator: "、")
    let unparsed = "\(parsed.unparsed) 字节解析不了"
    let what = lost.isEmpty
        ? "丢失 APP13 里 \(unparsed)的 Photoshop 资源数据"
        : "丢失 APP13 里的 \(lost.count) 个 Photoshop 资源（\(ids)）" + (parsed.unparsed > 0 ? "，另有 \(unparsed)" : "")
    return [what + "——ImageIO 只搬其中的 IPTC（0x0404）"]
}
