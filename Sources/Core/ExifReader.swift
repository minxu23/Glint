// 手写的 EXIF 解析器：按标签读 EXIF 字段的原始字节，不经过 ImageIO。
//
// 两处要用：把 ImageIO 读不出来的 UserComment 捞回来；以及 --verify 在源侧取
// 时间字段的原始值（ImageIO 的属性视图会把 EXIF、IIM、XMP 的时间互相调和，
// 见 RawTimes.swift）。

import Foundation

// MARK: - TIFF/EXIF 结构

/// JPEG 里 APP1 `Exif\0\0` 段内的 TIFF 结构。偏移都相对 TIFF 头，与 EXIF 内部的
/// 偏移体系一致；越界的读取一律返回 nil。
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
        let length = app1.payload.upperBound - base
        guard length > 8 else { return nil }
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

    /// 在某个 IFD 里找标签，返回它的值所在偏移和字节数。
    func find(_ ifd: Int, tag wanted: Int) -> (offset: Int, size: Int)? {
        let unitSize = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]
        guard let count = u16(ifd), count > 0, count < 4096 else { return nil }
        for k in 0..<count {
            let entry = ifd + 2 + k * 12
            guard let tag = u16(entry), let type = u16(entry + 2), let n = u32(entry + 4) else { return nil }
            guard tag == wanted else { continue }
            let unit = type < unitSize.count ? unitSize[type] : 0
            guard unit > 0, n > 0, n < length else { return nil }
            let size = unit * n
            // 值不超过 4 字节时就地存放，否则存的是偏移。
            let offset = size > 4 ? (u32(entry + 8) ?? -1) : entry + 8
            guard offset >= 0, offset + size <= length else { return nil }
            return (offset, size)
        }
        return nil
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
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          let range = exifUserCommentRange(in: data) else { return nil }
    return decodeUserComment(Array(data[range]))
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
