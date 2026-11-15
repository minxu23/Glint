// 手写的 EXIF 解析器：按标签读 EXIF 字段的原始字节，不经过 ImageIO。
//
// 用处：把 ImageIO 读不出来的 UserComment 捞回来；转换时补回 ImageIO 读不出的
// ImageUniqueID（见 RawExifTags.swift 的 restorableImageUniqueID）；--verify 在源侧取时间字段的
// 原始值（ImageIO 的属性视图会把 EXIF、IIM、XMP 的时间互相调和，见 RawTimes.swift）；
// --verify 读 ImageIO 不读的 Windows XP 标签和评级（见 WindowsTags.swift）；--verify 的
// 原始 EXIF 标签清点读源与产物两边的 TIFF 结构（见 RawExifTags.swift、HEIFExif.swift）。

import Foundation

// MARK: - TIFF/EXIF 结构

/// 一段 EXIF 数据里的 TIFF 结构（JPEG 的 APP1 `Exif\0\0` 段，或 HEIF 的 Exif 项）。
/// 偏移都相对 TIFF 头，与 EXIF 内部的偏移体系一致；越界的读取一律返回 nil。
struct TIFFStructure {
    let bytes: [UInt8]
    /// TIFF 头在 `bytes` 里的起点。
    let base: Int
    let length: Int
    let bigEndian: Bool

    static let exifIFDPointer = 0x8769

    /// 在 JPEG 里找带 `Exif\0\0` 的 APP1 并解析出 TIFF 头；没有或不合法就是 nil。
    /// 要先解析段结构；手里已有 SourceJPEG 的用它的 `exif`。
    init?(jpeg bytes: [UInt8]) {
        self.init(jpeg: bytes, layout: JPEGLayout(bytes))
    }

    /// 同上，`layout` 是 `bytes` 已经解析好的段结构（nil 时就是 nil）。取第一个这样的 APP1。
    init?(jpeg bytes: [UInt8], layout: JPEGLayout?) {
        let exifID: [UInt8] = Array("Exif".utf8) + [0, 0]
        guard let layout,
              let app1 = layout.segments.first(where: { $0.marker == 0xE1 && $0.begins(with: exifID, in: bytes) })
        else { return nil }
        let base = app1.payload.lowerBound + exifID.count
        self.init(bytes, base: base, length: app1.payload.upperBound - base)
    }

    /// `bytes[base..<base+length]` 是一段以 TIFF 头开头的数据；头不合法或范围越界就是 nil。
    ///
    /// `magic` 是字节序标记后面那个 16 位数（按头里的字节序读）允许的值。EXIF 里总是 42；
    /// 几种相机 RAW 换了这个数、其余照 TIFF 的规矩排（松下 RW2 是 0x55，奥林巴斯 ORF 是
    /// `IIRO`/`IIRS`/`MMOR` 的 `RO`/`RS`/`OR`，见 CameraRawExif.swift）。
    init?(_ bytes: [UInt8], base: Int, length: Int, magic: Set<Int> = [42]) {
        guard base >= 0, length > 8, base <= bytes.count - length else { return nil }
        switch (bytes[base], bytes[base + 1]) {
        case (0x4D, 0x4D): bigEndian = true
        case (0x49, 0x49): bigEndian = false
        default: return nil
        }
        self.bytes = bytes
        self.base = base
        self.length = length
        guard let found = u16(2), magic.contains(found) else { return nil }
    }

    func u16(_ off: Int) -> Int? {
        guard off >= 0, off + 2 <= length else { return nil }
        let a = Int(bytes[base + off]), b = Int(bytes[base + off + 1])
        return bigEndian ? (a << 8 | b) : (b << 8 | a)
    }

    func u32(_ off: Int) -> Int? {
        guard off >= 0, off + 4 <= length else { return nil }
        let b = (0..<4).map { Int(bytes[base + off + $0]) }
        return bigEndian ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
                         : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0]
    }

    /// IFD0 的偏移。
    var ifd0: Int? { u32(4) }

    /// Exif 子 IFD 的偏移（IFD0 里的 0x8769 指针）。
    var exifIFD: Int? {
        guard let ifd0, let pointer = find(ifd0, tag: TIFFStructure.exifIFDPointer) else { return nil }
        return u32(pointer.offset)
    }

    /// 一个 IFD 条目：标签号、类型，以及值所在的偏移和字节数。类型不认识、个数为 0、
    /// 值越界时 `field` 是 nil——条目在，值读不出。
    struct Entry {
        let tag: Int
        let type: Int
        /// 条目里写的值个数（不是字节数）。
        let count: Int
        let field: (offset: Int, size: Int)?
    }

    /// TIFF 类型码 → 每个值的字节数；不认识的类型是 0。13 是 IFD（4 字节偏移）。
    static let unitSize = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4]

    /// 某个 IFD 的全部条目，按表里的顺序。条目头本身越界就停在那里。
    func entries(_ ifd: Int) -> [Entry] {
        guard let count = u16(ifd), count > 0, count < 4096 else { return [] }
        var result: [Entry] = []
        for k in 0..<count {
            let entry = ifd + 2 + k * 12
            guard let tag = u16(entry), let type = u16(entry + 2), let n = u32(entry + 4) else { break }
            let unit = type < TIFFStructure.unitSize.count ? TIFFStructure.unitSize[type] : 0
            var field: (offset: Int, size: Int)?
            if unit > 0, n > 0, n < length {
                let size = unit * n
                // 值不超过 4 字节时就地存放，否则存的是偏移。
                let offset = size > 4 ? (u32(entry + 8) ?? -1) : entry + 8
                if offset >= 0, offset + size <= length { field = (offset, size) }
            }
            result.append(Entry(tag: tag, type: type, count: n, field: field))
        }
        return result
    }

    /// 在某个 IFD 里找标签，返回它的值所在偏移和字节数。
    func find(_ ifd: Int, tag wanted: Int) -> (offset: Int, size: Int)? {
        entries(ifd).first { $0.tag == wanted }?.field
    }

    /// 某个条目值的原始字节。
    func value(of entry: Entry) -> [UInt8]? {
        guard let field = entry.field else { return nil }
        return Array(bytes[(base + field.offset)..<(base + field.offset + field.size)])
    }

    /// 某个标签值的原始字节（相对文件起点的范围）。
    func range(in ifd: Int?, tag: Int) -> Range<Int>? {
        guard let ifd, let field = find(ifd, tag: tag) else { return nil }
        return (base + field.offset)..<(base + field.offset + field.size)
    }

    /// 某个 ASCII 标签的文本，去掉结尾的 NUL 与空白；空串当作没有。
    func ascii(in ifd: Int?, tag: Int) -> String? {
        guard let r = range(in: ifd, tag: tag),
              let s = String(bytes: bytes[r], encoding: .ascii) ?? String(bytes: bytes[r], encoding: .isoLatin1)
        else { return nil }
        let t = trimPadding(s)
        return t.isEmpty ? nil : t
    }
}

// MARK: - 直接解析 EXIF UserComment

// EXIF 规定 UserComment(0x9286) 以 8 字节字符集标识开头（ASCII/UNICODE/JIS/全零）。
// 但不少安卓机型（如 vivo + MediaTek 相机）不写这个前缀，直接塞裸 UTF-8，ImageIO 认不出这种
// 写法，当作该字段不存在；`ASCII` 头里装着 UTF-8 的，ImageIO 按 Latin-1 读成乱码。
// 这里自己解析 0x9286 的原始字节（readUserComment），分清读出来的是可靠的文本还是猜的：
// 转换时的修补、照搬时的备注改写（SourceUserComment.toRepair）和 --verify 的备注原文核对
// （userCommentOriginalIssues）都以它为准。

/// 源 JPEG 里的 EXIF UserComment，自己解析原始字节。不是带 EXIF 的 JPEG 时是 `.absent`。
func rawExifUserComment(in jpeg: SourceJPEG) -> UserCommentReading {
    guard let tiff = jpeg.exif, let value = rawUserCommentValue(tiff) else { return .absent }
    return readUserComment(value)
}

/// 同上，给手里只有字节的调用方（「照片」备注那一路读的是文件开头的一段）。
func rawExifUserComment(in bytes: [UInt8]) -> UserCommentReading {
    rawExifUserComment(in: SourceJPEG(bytes))
}

/// Exif 子 IFD 里（第一个）0x9286 条目的全部值字节，含字符集头；没有这一条或值读不出是 nil。
/// JPEG 的 EXIF 段和 HEIF 的 Exif 项都用它取。
func rawUserCommentValue(_ tiff: TIFFStructure) -> [UInt8]? {
    guard let range = tiff.range(in: tiff.exifIFD, tag: 0x9286) else { return nil }
    return Array(tiff.bytes[range])
}

/// 定位 JPEG 里 EXIF UserComment 字段的字节范围（相对文件起点）。
/// 单独拆出来是为了让测试夹具能就地改写这个字段，构造出不合规范的样本，
/// 而不必再写一份 EXIF 解析。
func exifUserCommentRange(in data: Data) -> Range<Int>? {
    guard let tiff = TIFFStructure(jpeg: [UInt8](data)) else { return nil }
    return tiff.range(in: tiff.exifIFD, tag: 0x9286)
}


/// UserComment 值开头的 8 字节字符集头。
enum UserCommentHeader: Equatable {
    case ascii, unicode, jis
    /// 8 个 0（EXIF 的「未定义」字符集）。
    case undefined
    /// 没有合规的头：整段值都是正文。
    case none
}

/// 自己解析一段 UserComment 原始值（readUserComment）的结果。
enum UserCommentReading: Equatable {
    /// 没有 0x9286，或正文去掉填充（normalizedUserComment）后是空的。
    case absent
    /// 可靠的文本，照解码的原样：开头的 BOM、尾部的 NUL 与空白都还在，比较和修补之前一律过
    /// normalizedUserComment。`header` 是值开头的字符集头。
    case reliable(String, header: UserCommentHeader)
    /// 解不出可靠的文本。`raw` 是 0x9286 的全部值字节（含头）。`guess`：ASCII 头、8 个 0 的头、
    /// 没有头的值按 Latin-1 解出、过了 normalizedUserComment 的那串（Latin-1 什么字节都解得出，
    /// 所以只是猜测）；JIS 头、UNICODE 头解不出时是 nil。
    case guessed(String?, raw: [UInt8], header: UserCommentHeader)
}

/// 比较、修补备注文本用的那把尺子：去掉开头的一个 BOM（U+FEFF），再去掉尾部的 NUL 与空白
/// （trimPadding，与键空间比对同一把）。
func normalizedUserComment(_ s: String) -> String {
    var scalars = Substring(s).unicodeScalars
    if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
    return trimPadding(String(scalars))
}

/// 解析一段 UserComment 原始值（含字符集头）。
///
/// - `UNICODE\0` 头：正文以 BOM 开头时按 BOM 的字节序解；没有 BOM 时大端、小端各解一遍，取更像
///   正常文本的那个（打平取大端）。两种都解不出（如落单的代理项）是猜的，没有猜测串。
/// - `JIS\0\0\0\0\0` 头：按 Shift-JIS 解，解不出是猜的，没有猜测串。
/// - `ASCII\0\0\0` 头、8 个 0 的头、没有头：正文是合法的 UTF-8（全是 ASCII 也算）才是可靠的文本；
///   含 ≥ 0x80 的字节又不是合法 UTF-8 的（GBK、Latin-1 写的西欧文字……）是猜的，猜测串按 Latin-1 解。
/// 值不足 8 字节时没有头。解出来去掉填充后是空的，是 `.absent`。
func readUserComment(_ raw: [UInt8]) -> UserCommentReading {
    let headers: [([UInt8], UserCommentHeader)] = [
        (Array("ASCII\0\0\0".utf8), .ascii), (Array("UNICODE\0".utf8), .unicode),
        (Array("JIS\0\0\0\0\0".utf8), .jis), ([UInt8](repeating: 0, count: 8), .undefined),
    ]
    var header = UserCommentHeader.none
    var body = raw
    if raw.count >= 8, let found = headers.first(where: { $0.0 == Array(raw[0..<8]) }) {
        header = found.1
        body = Array(raw[8...])
    }
    /// 没有 BOM 的 UTF-16 两种都解一遍，取更像正常文本的那个。
    func moreReadable(_ a: String?, _ b: String?) -> String? {
        func score(_ s: String?) -> Int {
            guard let s else { return Int.min }
            return s.unicodeScalars.reduce(0) { $0 + ($1.value >= 32 || $1 == "\n" ? 1 : -4) }
        }
        return score(a) >= score(b) ? a : b
    }
    let decoded: String?
    switch header {
    case .unicode:
        if body.starts(with: [0xFE, 0xFF]) {
            decoded = String(bytes: body, encoding: .utf16BigEndian)
        } else if body.starts(with: [0xFF, 0xFE]) {
            decoded = String(bytes: body, encoding: .utf16LittleEndian)
        } else {
            decoded = moreReadable(String(bytes: body, encoding: .utf16BigEndian),
                                   String(bytes: body, encoding: .utf16LittleEndian))
        }
    case .jis:
        decoded = String(bytes: body, encoding: .shiftJIS)
    case .ascii, .undefined, .none:
        decoded = String(bytes: body, encoding: .utf8)
    }
    if let decoded {
        return normalizedUserComment(decoded).isEmpty ? .absent : .reliable(decoded, header: header)
    }
    let guess = header == .unicode || header == .jis
        ? nil : String(bytes: body, encoding: .isoLatin1).map(normalizedUserComment)
    return .guessed(guess, raw: raw, header: header)
}
