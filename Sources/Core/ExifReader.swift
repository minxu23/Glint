// 手写的 EXIF 解析器：只为把 ImageIO 读不出来的 UserComment 捞回来。
//
// 从 Converter.swift 拆出来——它有完全独立的变更理由（EXIF/TIFF 的字节布局），
// 和转码流程、校验比对都不相干。

import Foundation

// MARK: - 直接解析 EXIF UserComment

// EXIF 规定 UserComment(0x9286) 以 8 字节字符集标识开头（ASCII/UNICODE/JIS/全零）。
// 但不少安卓机型（如 vivo + MediaTek 相机）不写这个前缀，直接塞裸 UTF-8。
// ImageIO 认不出这种写法，会当作该字段不存在——于是备注在转码时被静默丢掉，
// 连 --verify 也发现不了，因为它比的也是 ImageIO 的视角。
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
    guard data.count > 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }

    // 逐段扫描找到带 "Exif\0\0" 的 APP1（不能直接搜字符串，图像数据里可能撞车）。
    var tiff = -1
    var exifLength = 0
    var i = 2
    while i + 4 <= data.count {
        guard data[i] == 0xFF else { break }
        let marker = data[i + 1]
        if marker == 0xD8 || marker == 0xD9 || (0xD0...0xD7).contains(marker) { i += 2; continue }
        if marker == 0xDA { break }   // 进入图像数据，后面没有元数据段了
        let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
        guard length >= 2, i + 2 + length <= data.count else { break }
        if marker == 0xE1, length > 8,
           data[i + 4] == 0x45, data[i + 5] == 0x78, data[i + 6] == 0x69,
           data[i + 7] == 0x66, data[i + 8] == 0, data[i + 9] == 0 {
            tiff = i + 10
            exifLength = length - 8
            break
        }
        i += 2 + length
    }
    guard tiff >= 0, exifLength > 8, tiff + exifLength <= data.count else { return nil }

    let bigEndian: Bool
    switch (data[tiff], data[tiff + 1]) {
    case (0x4D, 0x4D): bigEndian = true
    case (0x49, 0x49): bigEndian = false
    default: return nil
    }

    // 以下偏移都是相对 TIFF 头的，与 EXIF 内部的偏移体系一致。
    func u16(_ off: Int) -> Int? {
        guard off >= 0, off + 2 <= exifLength else { return nil }
        let a = Int(data[tiff + off]), b = Int(data[tiff + off + 1])
        return bigEndian ? (a << 8 | b) : (b << 8 | a)
    }
    func u32(_ off: Int) -> Int? {
        guard off >= 0, off + 4 <= exifLength else { return nil }
        let bytes = (0..<4).map { Int(data[tiff + off + $0]) }
        return bigEndian
            ? bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
            : bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
    }

    guard u16(2) == 42, let ifd0 = u32(4) else { return nil }

    /// 在某个 IFD 里找标签，返回它的值所在偏移和字节数。
    func find(_ ifd: Int, tag wanted: Int) -> (offset: Int, size: Int)? {
        let unitSize = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]
        guard let count = u16(ifd), count > 0, count < 4096 else { return nil }
        for k in 0..<count {
            let entry = ifd + 2 + k * 12
            guard let tag = u16(entry), let type = u16(entry + 2), let n = u32(entry + 4) else { return nil }
            guard tag == wanted else { continue }
            let unit = type < unitSize.count ? unitSize[type] : 0
            guard unit > 0, n > 0, n < exifLength else { return nil }
            let size = unit * n
            // 值不超过 4 字节时就地存放，否则存的是偏移。
            let offset = size > 4 ? (u32(entry + 8) ?? -1) : entry + 8
            guard offset >= 0, offset + size <= exifLength else { return nil }
            return (offset, size)
        }
        return nil
    }

    // UserComment 在 Exif 子 IFD 里，先取子 IFD 的指针（0x8769）。
    guard let pointerField = find(ifd0, tag: 0x8769),
          let exifIFD = u32(pointerField.offset),
          let field = find(exifIFD, tag: 0x9286) else { return nil }

    let start = tiff + field.offset
    return start..<(start + field.size)
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
