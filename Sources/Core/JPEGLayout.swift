// JPEG 的段结构：哪些标记段、各自的内容在哪、EOI 在哪。
//
// 手写 EXIF 解析（ExifReader.swift）、源侧原始字节里的时间（RawTimes.swift）、
// 「ImageIO 搬不走的段」清单（unportableSegments）都从这里取段，不各自扫一遍。

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
    (0xE2, Array("ICC_PROFILE".utf8) + [0]),
    // MPF 只是 EOI 之后那些附加图像的目录，丢失由尾部数据那一条报。
    (0xE2, mpfID),
    (0xED, Array("Photoshop 3.0".utf8) + [0]),
    (0xEE, Array("Adobe".utf8)),
]
private let mpfID: [UInt8] = Array("MPF".utf8) + [0]

/// 源 JPEG 里 ImageIO 看不见、因而转换后必然丢失的部分，每段一条差异：
/// COM 注释段、不认识的 APPn 段、EOI 之后的数据（全是 0x00/0xFF 填充的不算）。
/// 这些都不在属性视图里，键空间比对发现不了。
func unportableSegments(in bytes: [UInt8]) -> [String] {
    guard let layout = JPEGLayout(bytes) else { return [] }
    var issues: [String] = []
    for s in layout.segments {
        let content = Array(bytes[s.payload])
        if s.marker == 0xFE {
            let text = String(bytes: content, encoding: .utf8)
                ?? String(bytes: content, encoding: .isoLatin1) ?? ""
            issues.append("丢失 JPEG 注释段（COM）= \(truncate(trimPadding(text)))")
        } else if (0xE0...0xEF).contains(s.marker),
                  !portableAppSegments.contains(where: { $0.marker == s.marker && s.begins(with: $0.id, in: bytes) }) {
            let id = String(decoding: content.prefix { $0 >= 0x20 && $0 < 0x7F }.prefix(32), as: UTF8.self)
            issues.append("丢失 APP\(s.marker - 0xE0) 段（\(id.isEmpty ? "无标识" : id)，\(content.count) 字节）")
        }
    }
    if let eoi = layout.eoi {
        let trailer = bytes[(eoi + 2)...]
        if trailer.contains(where: { $0 != 0x00 && $0 != 0xFF }) {
            let mpf = layout.segments.contains { $0.marker == 0xE2 && $0.begins(with: mpfID, in: bytes) }
            issues.append("丢失 EOI 之后的 \(trailer.count) 字节" + (mpf ? "（MPF 多图格式的附加图像）" : ""))
        }
    }
    return issues
}
