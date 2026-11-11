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
    init?(jpeg bytes: [UInt8]) {
        let exifID: [UInt8] = Array("Exif".utf8) + [0, 0]
        guard let layout = JPEGLayout(bytes),
              let app1 = layout.segments.first(where: { $0.marker == 0xE1 && $0.begins(with: exifID, in: bytes) })
        else { return nil }
        let base = app1.payload.lowerBound + exifID.count
        self.init(bytes, base: base, length: app1.payload.upperBound - base)
    }

    /// `bytes[base..<base+length]` 是一段以 TIFF 头开头的数据；头不合法或范围越界就是 nil。
    init?(_ bytes: [UInt8], base: Int, length: Int) {
        guard base >= 0, length > 8, base <= bytes.count - length else { return nil }
        switch (bytes[base], bytes[base + 1]) {
        case (0x4D, 0x4D): bigEndian = true
        case (0x49, 0x49): bigEndian = false
        default: return nil
        }
        self.bytes = bytes
        self.base = base
        self.length = length
        guard u16(2) == 42 else { return nil }
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
// 但不少安卓机型（如 vivo + MediaTek 相机）不写这个前缀，直接塞裸 UTF-8。
// ImageIO 认不出这种写法，会当作该字段不存在——于是备注在转码时被静默丢掉，
// 而 --verify 比的属性视图里同样没有它。
// 这里自己扫一遍 JPEG 的 EXIF 段把它捞出来，补进要写入的属性里。

/// 从 JPEG 文件里直接读出 EXIF UserComment 的文本；不是 JPEG 或没有该字段时返回 nil。
func rawExifUserComment(of url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return rawExifUserComment(in: [UInt8](data))
}

/// 同 rawExifUserComment(of:)，读的是已经在内存里的 JPEG 字节。
func rawExifUserComment(in bytes: [UInt8]) -> String? {
    guard let tiff = TIFFStructure(jpeg: bytes), let range = tiff.range(in: tiff.exifIFD, tag: 0x9286) else { return nil }
    return decodeUserComment(Array(bytes[range]))
}

/// 定位 JPEG 里 EXIF UserComment 字段的字节范围（相对文件起点）。
/// 单独拆出来是为了让测试夹具能就地改写这个字段，构造出不合规范的样本，
/// 而不必再写一份 EXIF 解析。
func exifUserCommentRange(in data: Data) -> Range<Int>? {
    guard let tiff = TIFFStructure(jpeg: [UInt8](data)) else { return nil }
    return tiff.range(in: tiff.exifIFD, tag: 0x9286)
}


private func decodeUserComment(_ raw: [UInt8]) -> String? {
    func cleaned(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = trimPadding(s)
        return t.isEmpty ? nil : t
    }
    /// UNICODE 前缀没规定字节序，两种都解一遍，取更像正常文本的那个。
    func moreReadable(_ a: String?, _ b: String?) -> String? {
        func score(_ s: String?) -> Int {
            guard let s else { return Int.min }
            return s.unicodeScalars.reduce(0) { $0 + ($1.value >= 32 || $1 == "\n" ? 1 : -4) }
        }
        return score(a) >= score(b) ? a : b
    }
    func text(_ bytes: [UInt8]) -> String? {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
    }

    if raw.count > 8 {
        let head = Array(raw[0..<8])
        let body = Array(raw[8...])
        if head == Array("ASCII\0\0\0".utf8) { return cleaned(text(body)) }
        if head == Array("UNICODE\0".utf8) {
            return cleaned(moreReadable(String(bytes: body, encoding: .utf16BigEndian),
                                        String(bytes: body, encoding: .utf16LittleEndian)))
        }
        if head == Array("JIS\0\0\0\0\0".utf8) { return cleaned(String(bytes: body, encoding: .shiftJIS)) }
        if head.allSatisfy({ $0 == 0 }) { return cleaned(text(body)) }
    }
    // 没有合规前缀：按裸文本解，这正是 ImageIO 会整条丢弃的情况。
    return cleaned(text(raw))
}
