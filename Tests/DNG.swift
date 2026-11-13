// 现场生成拜耳 DNG 的测试夹具。
//
// ImageIO 能读 DNG 却不能写（CGImageDestinationCopyTypeIdentifiers 里没有），测试用的 RAW
// 只能自己按 TIFF/DNG 的结构拼出来，二进制不进仓库。
//
// 结构（照 DNG 1.4 规范的最小可用形状）：
//   IFD0  8 位 RGB 小预览（NewSubfileType = 1）+ DNG 标签 + Exif/GPS 指针 + SubIFD 指针
//   SubIFD  原始数据：16 位拜耳阵列（CFA，Photometric = 32803），RGGB
//   Exif IFD、GPS IFD
// ImageIO 认不认作 RAW 有三个条件（实测）：
//   - 推荐的那一串标签（黑白电平、默认裁切、色彩矩阵、AsShotNeutral……）带全，只带最少几个时不认；
//   - 原始数据从 4096 字节以后开始（见 rawAt）；
//   - 尺寸过门槛：256×192 认作 com.adobe.raw-image，128×96、64×48 被当成 public.tiff，读到的是预览图。
// 所以用它的测试一律断言「类型是 RAW、产物是 10 位」，不只看转换成功。

import Foundation

/// 一张要生成的 DNG。
struct DNGSpec {
    var width = 256
    var height = 192
    var orientation = 1
    var make = "Glint"
    var model = "TestCamera"
    var dateTimeOriginal: String? = "2024:05:06 07:08:09"
    var artist: String? = "Glint Tester"
    var copyright: String? = "(c) 2024 Glint Tester"
    var imageDescription: String? = "A test DNG"
    /// 纬度、经度：度、分、秒（秒带小数，好暴露写入器的取整）与方向。nil 是不带 GPS。
    var gps: (lat: (Int, Int, Double, String), lon: (Int, Int, Double, String))? =
        ((31, 13, 45.6789, "N"), (121, 28, 19.1234, "E"))
    /// GPS IFD 里只有 GPSVersion、没有坐标（佳能 CR3 关着定位时就是这样）。gps 是 nil 时不起作用。
    var gpsVersionOnly = false
    /// 值是空串的两个标签（佳能 CR3 里有）：Exif IFD 的 CameraOwnerName（0xA430，照佳能写成 32 个 NUL）
    /// 与 GPS IFD 的 Satellites（0x0008，1 个 NUL）。ImageIO 从属性字典重写 EXIF 时丢掉空串，照搬才
    /// 保得住。ImageIO 读 DNG、HEIC 时都不显示空串，只能按原始字节核对。nil 是不带。
    var cameraOwnerName: String? = ""
    var satellites: String? = ""
    /// Exif IFD 里的 MakerNote（0x927C）。照搬时去掉，产物里不该有。nil 是不带。
    var makerNote: [UInt8]? = Array("GLINT MAKERNOTE \u{1}\u{2}\u{3}".utf8)
}

private struct TIFFEntry {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    let payload: [UInt8]
}

private func le16(_ v: [Int]) -> [UInt8] { v.flatMap { [UInt8($0 & 0xFF), UInt8(($0 >> 8) & 0xFF)] } }
private func le32(_ v: [Int]) -> [UInt8] {
    v.flatMap { x -> [UInt8] in let u = UInt32(truncatingIfNeeded: x); return (0..<4).map { UInt8((u >> (8 * $0)) & 0xFF) } }
}
private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

private func byte(_ tag: Int, _ v: [Int]) -> TIFFEntry { TIFFEntry(tag: UInt16(tag), type: 1, count: UInt32(v.count), payload: v.map { UInt8($0) }) }
private func text(_ tag: Int, _ s: String) -> TIFFEntry { let b = ascii(s); return TIFFEntry(tag: UInt16(tag), type: 2, count: UInt32(b.count), payload: b) }
/// 定长的 ASCII：文本后面补 NUL 到 `width` 字节（佳能把 CameraOwnerName 写成 32 字节，空的就是 32 个 NUL）。
private func paddedText(_ tag: Int, _ s: String, _ width: Int) -> TIFFEntry {
    let b = Array(s.utf8) + [UInt8](repeating: 0, count: max(width - s.utf8.count, 1))
    return TIFFEntry(tag: UInt16(tag), type: 2, count: UInt32(b.count), payload: b)
}
private func short(_ tag: Int, _ v: [Int]) -> TIFFEntry { TIFFEntry(tag: UInt16(tag), type: 3, count: UInt32(v.count), payload: le16(v)) }
private func long(_ tag: Int, _ v: [Int]) -> TIFFEntry { TIFFEntry(tag: UInt16(tag), type: 4, count: UInt32(v.count), payload: le32(v)) }
/// RATIONAL：成对的分子、分母。
private func rational(_ tag: Int, _ v: [Int]) -> TIFFEntry { TIFFEntry(tag: UInt16(tag), type: 5, count: UInt32(v.count / 2), payload: le32(v)) }
private func undefined(_ tag: Int, _ v: [UInt8]) -> TIFFEntry { TIFFEntry(tag: UInt16(tag), type: 7, count: UInt32(v.count), payload: v) }
private func srational(_ tag: Int, _ v: [Int]) -> TIFFEntry { TIFFEntry(tag: UInt16(tag), type: 10, count: UInt32(v.count / 2), payload: le32(v)) }

/// 一个 IFD 连同它的外置值占多少字节（值按 2 字节对齐）。指针的值不影响大小。
private func blockSize(_ entries: [TIFFEntry]) -> Int {
    2 + 12 * entries.count + 4 + entries.reduce(0) { $0 + ($1.payload.count > 4 ? ($1.payload.count + 1) & ~1 : 0) }
}

/// 把一个 IFD 和它的外置值写成从 `offset` 开始的字节。
private func block(_ entries: [TIFFEntry], at offset: Int) -> [UInt8] {
    let sorted = entries.sorted { $0.tag < $1.tag }
    var head = le16([sorted.count])
    var values: [UInt8] = []
    var valueOffset = offset + 2 + 12 * sorted.count + 4
    for e in sorted {
        head += le16([Int(e.tag), Int(e.type)]) + le32([Int(e.count)])
        if e.payload.count <= 4 {
            head += e.payload + [UInt8](repeating: 0, count: 4 - e.payload.count)
        } else {
            head += le32([valueOffset])
            var p = e.payload
            if p.count % 2 == 1 { p.append(0) }
            values += p
            valueOffset += p.count
        }
    }
    return head + le32([0]) + values
}

/// 度分秒 → 三个 RATIONAL（秒按 1/10000 记）。
private func dms(_ d: Int, _ m: Int, _ s: Double) -> [Int] { [d, 1, m, 1, Int((s * 10000).rounded()), 10000] }

func makeDNG(_ spec: DNGSpec) -> Data {
    let w = spec.width, h = spec.height
    let previewW = max(w / 16, 1), previewH = max(h / 16, 1)
    // 原始数据：RGGB 拜耳阵列，红、蓝各一道渐变，绿是常数，显影后不是一片灰。
    var raw: [UInt8] = []
    raw.reserveCapacity(w * h * 2)
    for y in 0..<h {
        for x in 0..<w {
            let v: Int
            switch (y % 2, x % 2) {
            case (0, 0): v = x * 60000 / max(w - 1, 1)
            case (1, 1): v = y * 60000 / max(h - 1, 1)
            default: v = 20000
            }
            raw += le16([v])
        }
    }
    let preview = [UInt8](repeating: 128, count: previewW * previewH * 3)

    func ifd0(sub: Int, exif: Int, gps: Int, previewAt: Int) -> [TIFFEntry] {
        var e = [
            long(254, [1]),
            short(256, [previewW]), short(257, [previewH]),
            short(258, [8, 8, 8]), short(259, [1]), short(262, [2]),
            text(271, spec.make), text(272, spec.model),
            long(273, [previewAt]),
            short(274, [spec.orientation]),
            short(277, [3]), short(278, [previewH]), long(279, [preview.count]), short(284, [1]),
            long(330, [sub]), long(0x8769, [exif]),
            byte(50706, [1, 4, 0, 0]), byte(50707, [1, 1, 0, 0]),
            text(50708, "\(spec.make) \(spec.model)"),
            srational(50721, [32406, 10000, -15372, 10000, -4986, 10000, -9689, 10000, 18758, 10000,
                              415, 10000, 557, 10000, -2040, 10000, 10570, 10000]),
            rational(50727, [1, 1, 1, 1, 1, 1]),
            rational(50728, [1, 1, 1, 1, 1, 1]),
            srational(50730, [0, 1]),
            rational(50731, [1, 1]), rational(50732, [1, 1]),
            short(50778, [21]),
        ]
        if spec.gps != nil { e.append(long(0x8825, [gps])) }
        if let a = spec.artist { e.append(text(315, a)) }
        if let c = spec.copyright { e.append(text(33432, c)) }
        if let d = spec.imageDescription { e.append(text(270, d)) }
        return e
    }
    func subIFD(rawAt: Int) -> [TIFFEntry] {
        [
            long(254, [0]),
            short(256, [w]), short(257, [h]),
            short(258, [16]), short(259, [1]), short(262, [32803]),
            long(273, [rawAt]), short(277, [1]), short(278, [h]), long(279, [raw.count]), short(284, [1]),
            short(33421, [2, 2]), byte(33422, [0, 1, 1, 2]),
            byte(50710, [0, 1, 2]), short(50711, [1]),
            short(50713, [1, 1]), short(50714, [0]), short(50717, [65535]),
            rational(50718, [1, 1, 1, 1]),
            short(50719, [0, 0]), short(50720, [w, h]),
            long(50733, [0]), rational(50780, [1, 1]),
            long(50829, [0, 0, h, w]),
        ]
    }
    var exifEntries = [
        undefined(0x9000, Array("0231".utf8)),
        rational(0x829A, [1, 250]),
    ]
    if let t = spec.dateTimeOriginal { exifEntries.append(text(0x9003, t)) }
    if let o = spec.cameraOwnerName { exifEntries.append(paddedText(0xA430, o, 32)) }
    if let m = spec.makerNote { exifEntries.append(undefined(0x927C, m)) }
    var gpsEntries: [TIFFEntry] = []
    if let g = spec.gps {
        gpsEntries = [byte(0, [2, 3, 0, 0])]
        if !spec.gpsVersionOnly {
            gpsEntries += [
                text(1, g.lat.3), rational(2, dms(g.lat.0, g.lat.1, g.lat.2)),
                text(3, g.lon.3), rational(4, dms(g.lon.0, g.lon.1, g.lon.2)),
            ]
            if let s = spec.satellites { gpsEntries.append(text(8, s)) }
        }
    }

    // 先按占位的指针算出各块的大小与位置，再用真实的指针写一遍。
    let ifd0Size = blockSize(ifd0(sub: 0, exif: 0, gps: 0, previewAt: 0))
    let subAt = 8 + ifd0Size
    let exifAt = subAt + blockSize(subIFD(rawAt: 0))
    let gpsAt = exifAt + blockSize(exifEntries)
    let previewAt = gpsAt + (gpsEntries.isEmpty ? 0 : blockSize(gpsEntries))
    // 原始数据要从 4096 字节以后开始：实测从 4000 开始时 ImageIO 把文件认作 public.tiff，
    // 读到的是预览图；从 4096、4100、8192 开始都认作 RAW。所以按 4096 对齐。
    let rawAt = (previewAt + preview.count + 4095) / 4096 * 4096

    var out: [UInt8] = [0x49, 0x49] + le16([42]) + le32([8])
    out += block(ifd0(sub: subAt, exif: exifAt, gps: gpsAt, previewAt: previewAt), at: 8)
    out += block(subIFD(rawAt: rawAt), at: subAt)
    out += block(exifEntries, at: exifAt)
    if !gpsEntries.isEmpty { out += block(gpsEntries, at: gpsAt) }
    precondition(out.count == previewAt, "DNG 布局算错了")
    out += preview
    out += [UInt8](repeating: 0, count: rawAt - out.count)
    out += raw
    return Data(out)
}
