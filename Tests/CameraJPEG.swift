// 自造的「相机直出」JPEG：替代原来入库的两张真实照片（松下 DMC-LX5 一张、佳能 EOS 550D 一张），
// 结构照着它们搭，值全是编的。fixture --camera panasonic|canon 调用这里。
//
// 为什么要手搭而不用 ImageIO 写：
// - MakerNote：ImageIO 写 JPEG 时会静默丢掉 MakerNote，而测试要的正是「ImageIO 读得出、
//   系统重写时丢失」的厂商私有块。块里的偏移相对 TIFF 头，必须知道块落在哪才写得对，
//   所以整个 EXIF 段都在这里按字节排。
// - 4:2:2 色度抽样：ImageIO 重新编码 JPEG 只出 4:2:0 或 4:4:4，相机常见的 4:2:2 只能自己编。
//   下面是一个最小的基线 JPEG 编码器（标准量化表与霍夫曼表），主图、IFD1 缩略图和 MPF 预览图
//   都用它编，不经过 ImageIO——产物逐字节确定，测试里写死的字节数在哪台机器上都对得上。
//
// 两种样本各自承担原来那张照片在 selftest.sh 里的角色：
//   panasonic：小端 EXIF、APP1 是第一个段（TIFF 头在文件第 12 字节）；松下 MakerNote（ImageIO 解析，
//              {ExifAux}/ImageStabilization 由它来）；没有 UserComment、没有 XMP 包；IFD1 缩略图；
//              主图 4:2:2；APP2 MPF 登记一张 EOI 之后的大尺寸预览图（类型码 0x010002），预览图前后
//              各有一段 MPF 没登记的相机数据：16 字节 0xFF + 128 字节、33 字节 0xFF + 256 字节，共 433 字节。
//   canon：    佳能 MakerNote（{MakerCanon}/LensModel 读得出）；Windows 写的作者：IFD0 Artist 与 XPAuthor
//              同为 `Zhang San;Li Si`，XMP 包里 dc:creator 是对应的两项；UserComment 是 264 个 NUL（空备注）；
//              IFD1 缩略图；主图 4:2:2；EOI 之后没有数据。

import Foundation

// MARK: - TIFF

enum TIFFValue {
    case bytes([UInt8])        // BYTE
    case ascii(String)          // ASCII，自动补一个 NUL
    case asciiPadded(String, Int) // 定长 ASCII，补 NUL 到给定字节数
    case undefined([UInt8])
    case shorts([Int])
    case longs([Int])
    case rationals([(Int, Int)])
    case srationals([(Int, Int)])

    var type: Int {
        switch self {
        case .bytes: return 1
        case .ascii, .asciiPadded: return 2
        case .undefined: return 7
        case .shorts: return 3
        case .longs: return 4
        case .rationals: return 5
        case .srationals: return 10
        }
    }
}

struct TIFFTag {
    let tag: Int
    let value: TIFFValue
    init(_ tag: Int, _ value: TIFFValue) { self.tag = tag; self.value = value }
}

struct TIFFWriter {
    let littleEndian: Bool

    func u16(_ v: Int) -> [UInt8] {
        let a = UInt8(v & 0xFF), b = UInt8((v >> 8) & 0xFF)
        return littleEndian ? [a, b] : [b, a]
    }
    func u32(_ v: Int) -> [UInt8] {
        let u = UInt32(truncatingIfNeeded: v)
        let le = (0..<4).map { UInt8((u >> (8 * UInt32($0))) & 0xFF) }
        return littleEndian ? le : le.reversed()
    }

    func payload(_ v: TIFFValue) -> (count: Int, bytes: [UInt8]) {
        switch v {
        case .bytes(let b), .undefined(let b): return (b.count, b)
        case .ascii(let s): let b = Array(s.utf8) + [0]; return (b.count, b)
        case .asciiPadded(let s, let n):
            let b = Array(s.utf8) + [UInt8](repeating: 0, count: max(n - s.utf8.count, 0))
            return (b.count, b)
        case .shorts(let a): return (a.count, a.flatMap(u16))
        case .longs(let a): return (a.count, a.flatMap(u32))
        case .rationals(let a), .srationals(let a): return (a.count, a.flatMap { u32($0.0) + u32($0.1) })
        }
    }

    /// 一个 IFD 连同外置值的字节数（值按 2 字节对齐）。
    func size(_ tags: [TIFFTag]) -> Int {
        2 + 12 * tags.count + 4 + tags.reduce(0) { n, t in
            let p = payload(t.value).bytes.count
            return n + (p > 4 ? (p + 1) & ~1 : 0)
        }
    }

    /// 写一个从 TIFF 偏移 `at` 开始的 IFD；返回字节和每个外置值落在哪（标签 → TIFF 偏移）。
    func ifd(_ tags: [TIFFTag], at: Int, next: Int = 0) -> (bytes: [UInt8], valueAt: [Int: Int]) {
        let sorted = tags.sorted { $0.tag < $1.tag }
        var head = u16(sorted.count)
        var values: [UInt8] = []
        var valueAt: [Int: Int] = [:]
        var cursor = at + 2 + 12 * sorted.count + 4
        for t in sorted {
            let (count, bytes) = payload(t.value)
            head += u16(t.tag) + u16(t.value.type) + u32(count)
            if bytes.count <= 4 {
                head += bytes + [UInt8](repeating: 0, count: 4 - bytes.count)
            } else {
                head += u32(cursor)
                valueAt[t.tag] = cursor
                var p = bytes
                if p.count % 2 == 1 { p.append(0) }
                values += p
                cursor += p.count
            }
        }
        return (head + u32(next) + values, valueAt)
    }

    var header: [UInt8] { (littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(42) + u32(8) }
}

// MARK: - 基线 JPEG 编码器

/// 把 RGB 像素编成基线 JPEG（SOI … EOI）。亮度按 `h`×`v` 抽样（2×1 是 4:2:2，2×2 是 4:2:0，
/// 1×1 是 4:4:4），色度各一份。量化表是 JPEG 标准附录 K 的表按 `quality`（1–100）缩放。
func encodeBaselineJPEG(width: Int, height: Int, h: Int, v: Int, quality: Int,
                        pixel: (Int, Int) -> (Double, Double, Double)) -> [UInt8] {
    let lumaQ0 = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
                  14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
                  49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
    let chromaQ0 = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99,
                    47, 66, 99, 99, 99, 99, 99, 99] + [Int](repeating: 99, count: 32)
    let scale = quality < 50 ? 5000 / quality : 200 - 2 * quality
    func scaled(_ t: [Int]) -> [Int] { t.map { max(1, min(255, ($0 * scale + 50) / 100)) } }
    let lumaQ = scaled(lumaQ0), chromaQ = scaled(chromaQ0)
    let zigzag = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14,
                  21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53,
                  60, 61, 54, 47, 55, 62, 63]

    // 标准霍夫曼表（附录 K.3）：每个码长的码字个数，和按顺序的符号。
    let dcLumaBits = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    let dcLumaVals = Array(0...11)
    let dcChromaBits = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
    let dcChromaVals = Array(0...11)
    let acLumaBits = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d]
    let acLumaVals: [Int] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71,
        0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
        0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37,
        0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83,
        0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
        0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa]
    let acChromaBits = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
    let acChromaVals: [Int] = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22,
        0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1,
        0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36,
        0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
        0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
        0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba,
        0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa]

    /// 符号 → (码字, 码长)。
    func codes(_ bits: [Int], _ vals: [Int]) -> [Int: (Int, Int)] {
        var table: [Int: (Int, Int)] = [:]
        var code = 0, k = 0
        for len in 1...16 {
            for _ in 0..<bits[len - 1] {
                table[vals[k]] = (code, len)
                code += 1
                k += 1
            }
            code <<= 1
        }
        return table
    }
    let dcL = codes(dcLumaBits, dcLumaVals), acL = codes(acLumaBits, acLumaVals)
    let dcC = codes(dcChromaBits, dcChromaVals), acC = codes(acChromaBits, acChromaVals)

    // 先转成 YCbCr 平面，色度按抽样取平均。
    let mcuW = 8 * h, mcuH = 8 * v
    let paddedW = (width + mcuW - 1) / mcuW * mcuW, paddedH = (height + mcuH - 1) / mcuH * mcuH
    var Y = [Double](repeating: 0, count: paddedW * paddedH)
    var Cb = Y, Cr = Y
    for y in 0..<paddedH {
        for x in 0..<paddedW {
            let (r, g, b) = pixel(min(x, width - 1), min(y, height - 1))
            let i = y * paddedW + x
            Y[i] = 0.299 * r + 0.587 * g + 0.114 * b - 128
            Cb[i] = -0.168736 * r - 0.331264 * g + 0.5 * b
            Cr[i] = 0.5 * r - 0.418688 * g - 0.081312 * b
        }
    }
    let cw = paddedW / h, ch = paddedH / v
    var sCb = [Double](repeating: 0, count: cw * ch), sCr = sCb
    for y in 0..<ch {
        for x in 0..<cw {
            var a = 0.0, c = 0.0
            for dy in 0..<v { for dx in 0..<h { let i = (y * v + dy) * paddedW + x * h + dx; a += Cb[i]; c += Cr[i] } }
            sCb[y * cw + x] = a / Double(h * v)
            sCr[y * cw + x] = c / Double(h * v)
        }
    }

    var cosTable = [Double](repeating: 0, count: 64)
    for x in 0..<8 { for u in 0..<8 { cosTable[x * 8 + u] = cos(Double(2 * x + 1) * Double(u) * .pi / 16) } }

    var out: [UInt8] = []
    var bitBuffer = 0, bitCount = 0
    func put(_ code: Int, _ len: Int) {
        bitBuffer = (bitBuffer << len) | (code & ((1 << len) - 1))
        bitCount += len
        while bitCount >= 8 {
            let byte = UInt8((bitBuffer >> (bitCount - 8)) & 0xFF)
            out.append(byte)
            if byte == 0xFF { out.append(0) }
            bitCount -= 8
        }
        bitBuffer &= (1 << bitCount) - 1
    }
    func magnitude(_ v: Int) -> (size: Int, bits: Int) {
        var a = abs(v), size = 0
        while a > 0 { size += 1; a >>= 1 }
        return (size, v >= 0 ? v : v + (1 << size) - 1)
    }

    var block = [Double](repeating: 0, count: 64)
    var coef = [Double](repeating: 0, count: 64)
    func encodeBlock(_ plane: [Double], _ stride: Int, _ bx: Int, _ by: Int, _ q: [Int], _ prevDC: inout Int,
                     _ dc: [Int: (Int, Int)], _ ac: [Int: (Int, Int)]) {
        for y in 0..<8 { for x in 0..<8 { block[y * 8 + x] = plane[(by + y) * stride + bx + x] } }
        for v in 0..<8 {
            for u in 0..<8 {
                var s = 0.0
                for y in 0..<8 {
                    let cy = cosTable[y * 8 + v]
                    for x in 0..<8 { s += block[y * 8 + x] * cosTable[x * 8 + u] * cy }
                }
                let cu = u == 0 ? 1 / 2.0.squareRoot() : 1, cv = v == 0 ? 1 / 2.0.squareRoot() : 1
                coef[v * 8 + u] = 0.25 * cu * cv * s
            }
        }
        var quantized = [Int](repeating: 0, count: 64)
        for k in 0..<64 { let n = zigzag[k]; quantized[k] = Int((coef[n] / Double(q[n])).rounded()) }
        let diff = quantized[0] - prevDC
        prevDC = quantized[0]
        let (s, b) = magnitude(diff)
        put(dc[s]!.0, dc[s]!.1)
        if s > 0 { put(b, s) }
        var run = 0
        for k in 1..<64 {
            if quantized[k] == 0 { run += 1; continue }
            while run > 15 { put(ac[0xF0]!.0, ac[0xF0]!.1); run -= 16 }
            let (s, b) = magnitude(quantized[k])
            let sym = (run << 4) | s
            put(ac[sym]!.0, ac[sym]!.1)
            put(b, s)
            run = 0
        }
        if run > 0 { put(ac[0]!.0, ac[0]!.1) }
    }

    var pY = 0, pCb = 0, pCr = 0
    for my in stride(from: 0, to: paddedH, by: mcuH) {
        for mx in stride(from: 0, to: paddedW, by: mcuW) {
            for dy in 0..<v { for dx in 0..<h { encodeBlock(Y, paddedW, mx + 8 * dx, my + 8 * dy, lumaQ, &pY, dcL, acL) } }
            encodeBlock(sCb, cw, mx / h, my / v, chromaQ, &pCb, dcC, acC)
            encodeBlock(sCr, cw, mx / h, my / v, chromaQ, &pCr, dcC, acC)
        }
    }
    if bitCount > 0 { put((1 << (8 - bitCount)) - 1, 8 - bitCount) }

    func segment(_ marker: UInt8, _ body: [UInt8]) -> [UInt8] {
        [0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)] + body
    }
    let dqt = segment(0xDB, [0] + zigzag.map { UInt8(lumaQ[$0]) } + [1] + zigzag.map { UInt8(chromaQ[$0]) })
    let sof = segment(0xC0, [8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 3,
                             1, UInt8(h << 4 | v), 0, 2, 0x11, 1, 3, 0x11, 1])
    func dht(_ cls: Int, _ id: Int, _ bits: [Int], _ vals: [Int]) -> [UInt8] {
        [UInt8(cls << 4 | id)] + bits.map { UInt8($0) } + vals.map { UInt8($0) }
    }
    let dhts = segment(0xC4, dht(0, 0, dcLumaBits, dcLumaVals) + dht(1, 0, acLumaBits, acLumaVals)
                       + dht(0, 1, dcChromaBits, dcChromaVals) + dht(1, 1, acChromaBits, acChromaVals))
    let sos = segment(0xDA, [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0])
    return [0xFF, 0xD8] + dqt + sof + dhts + sos + out + [0xFF, 0xD9]
}

/// 像照片的图案：两道柔和的渐变、几个起伏，叠一层固定种子的细噪声（让 JPEG 有正常的体积，
/// 转成 HEIF 照常变小）。`variant` 让两种样本的画面不同。
func cameraPattern(width: Int, height: Int, variant: Int) -> (Int, Int) -> (Double, Double, Double) {
    return { x, y in
        let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
        var seed = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663 ^ variant &* 83_492_791)
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        let noise = Double(seed % 17) - 8
        let wave = sin(fx * 9 + Double(variant)) * cos(fy * 7) * 40
        let r = 70 + 130 * fx + wave + noise
        let g = 90 + 90 * (1 - fy) + wave * 0.6 + noise
        let b = 150 + 80 * fy - wave * 0.5 + noise
        return (min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
    }
}

// MARK: - 两种相机样本

enum CameraKind { case panasonic, canon }

func app(_ marker: UInt8, _ body: [UInt8]) -> [UInt8] {
    [0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)] + body
}

/// 一个 MakerNote：可选的头（松下是 `Panasonic\0\0\0`），后面是一个 IFD，外置值的偏移相对 TIFF 头。
/// `at` 是这个 MakerNote 在 TIFF 里的起点。
func makerNote(_ w: TIFFWriter, header: [UInt8], tags: [TIFFTag], at: Int) -> [UInt8] {
    header + w.ifd(tags, at: at + header.count).bytes
}

/// 拼出整个 TIFF（EXIF 段 `Exif\0\0` 之后的部分）。布局：头、IFD0、Exif IFD、Interop IFD、IFD1、缩略图。
/// MakerNote 的偏移要知道它落在哪：先用同样大小的占位算一遍布局，再按真实位置写一遍。
func cameraTIFF(_ w: TIFFWriter, ifd0: [TIFFTag], exif: [TIFFTag], interop: [TIFFTag], ifd1: [TIFFTag],
                makerHeader: [UInt8], makerTags: [TIFFTag], thumbnail: [UInt8]) -> [UInt8] {
    let makerSize = makerHeader.count + w.size(makerTags)
    func layout(maker: [UInt8]) -> (bytes: [UInt8], makerAt: Int) {
        let exifTags = exif + [TIFFTag(0x927C, .undefined(maker))]
        let ifd0Full = ifd0 + [TIFFTag(0x8769, .longs([0]))]
        let exifFull = exifTags + [TIFFTag(0xA005, .longs([0]))]
        let ifd1Full = ifd1 + [TIFFTag(0x0201, .longs([0])), TIFFTag(0x0202, .longs([thumbnail.count]))]
        let exifAt = 8 + w.size(ifd0Full)
        let interopAt = exifAt + w.size(exifFull)
        let ifd1At = interopAt + w.size(interop)
        let thumbAt = ifd1At + w.size(ifd1Full)
        let a = w.ifd(ifd0 + [TIFFTag(0x8769, .longs([exifAt]))], at: 8, next: ifd1At)
        let b = w.ifd(exifTags + [TIFFTag(0xA005, .longs([interopAt]))], at: exifAt)
        let c = w.ifd(interop, at: interopAt)
        let d = w.ifd(ifd1 + [TIFFTag(0x0201, .longs([thumbAt])), TIFFTag(0x0202, .longs([thumbnail.count]))], at: ifd1At)
        let bytes = w.header + a.bytes + b.bytes + c.bytes + d.bytes + thumbnail
        precondition(bytes.count == thumbAt + thumbnail.count, "EXIF 布局算错了")
        return (bytes, b.valueAt[0x927C]!)
    }
    let first = layout(maker: [UInt8](repeating: 0, count: makerSize))
    let maker = makerNote(w, header: makerHeader, tags: makerTags, at: first.makerAt)
    precondition(maker.count == makerSize)
    let second = layout(maker: maker)
    precondition(second.makerAt == first.makerAt)
    return second.bytes
}

func makeCameraJPEG(_ kind: CameraKind) -> [UInt8] {
    let width = 1536, height = 1024
    let variant = kind == .panasonic ? 1 : 2
    let pattern = cameraPattern(width: width, height: height, variant: variant)
    let primary = encodeBaselineJPEG(width: width, height: height, h: 2, v: 1, quality: 92, pixel: pattern)
    let thumbnail = encodeBaselineJPEG(width: 160, height: 120, h: 2, v: 2, quality: 80) { x, y in
        pattern(x * width / 160, y * height / 120)
    }
    // primary 是 SOI … EOI；元数据段插在 SOI 之后。
    let body = Array(primary.dropFirst(2))

    switch kind {
    case .panasonic:
        let w = TIFFWriter(littleEndian: true)
        let date = "2024:05:06 07:08:09"
        let printIM = Array("PrintIM\u{0}0250".utf8) + [0, 0, 0x0E, 0] + [UInt8](repeating: 0, count: 192)
        let ifd0: [TIFFTag] = [
            .init(0x010F, .ascii("Panasonic")), .init(0x0110, .ascii("DMC-LX5")), .init(0x0112, .shorts([1])),
            .init(0x011A, .rationals([(180, 1)])), .init(0x011B, .rationals([(180, 1)])), .init(0x0128, .shorts([2])),
            .init(0x0131, .ascii("Ver.2.0  ")), .init(0x0132, .ascii(date)), .init(0x013B, .ascii("")),
            .init(0x0213, .shorts([2])), .init(0xC4A5, .undefined(printIM)),
            .init(0xC6D2, .undefined([UInt8](repeating: 0, count: 64))),
            .init(0xC6D3, .undefined([UInt8](repeating: 0, count: 128))),
        ]
        let exif: [TIFFTag] = [
            .init(0x829A, .rationals([(10, 400)])), .init(0x829D, .rationals([(26, 10)])), .init(0x8822, .shorts([2])),
            .init(0x8827, .shorts([400])), .init(0x8830, .shorts([1])), .init(0x9000, .undefined(Array("0230".utf8))),
            .init(0x9003, .ascii(date)), .init(0x9004, .ascii(date)), .init(0x9101, .undefined([1, 2, 3, 0])),
            .init(0x9102, .rationals([(4, 1)])), .init(0x9204, .srationals([(0, 100)])), .init(0x9205, .rationals([(20, 10)])),
            .init(0x9207, .shorts([5])), .init(0x9208, .shorts([0])), .init(0x9209, .shorts([16])),
            .init(0x920A, .rationals([(100, 10)])), .init(0xA000, .undefined(Array("0100".utf8))), .init(0xA001, .shorts([1])),
            .init(0xA002, .longs([width])), .init(0xA003, .longs([height])), .init(0xA217, .shorts([2])),
            .init(0xA300, .undefined([3])), .init(0xA301, .undefined([1])), .init(0xA401, .shorts([0])),
            .init(0xA402, .shorts([0])), .init(0xA403, .shorts([0])), .init(0xA404, .rationals([(0, 10)])),
            .init(0xA405, .shorts([47])), .init(0xA406, .shorts([0])), .init(0xA407, .shorts([2])),
            .init(0xA408, .shorts([0])), .init(0xA409, .shorts([0])), .init(0xA40A, .shorts([0])),
        ]
        let interop: [TIFFTag] = [.init(0x0001, .ascii("R98")), .init(0x0002, .undefined(Array("0100".utf8)))]
        let ifd1: [TIFFTag] = [
            .init(0x0103, .shorts([6])), .init(0x0112, .shorts([1])), .init(0x011A, .rationals([(180, 1)])),
            .init(0x011B, .rationals([(180, 1)])), .init(0x0128, .shorts([2])), .init(0x0213, .shorts([2])),
        ]
        // 松下 MakerNote 的一部分标签（编号、类型照 DMC-LX5，值是编的；不带机身序列号）。
        let maker: [TIFFTag] = [
            .init(0x0001, .shorts([2])), .init(0x0002, .undefined([0, 2, 0, 0])), .init(0x0003, .shorts([1])),
            .init(0x0007, .shorts([1])), .init(0x000F, .bytes([0x20, 0])), .init(0x001A, .shorts([2])),
            .init(0x001C, .shorts([2])), .init(0x001F, .shorts([37])), .init(0x0020, .shorts([2])),
            .init(0x0022, .shorts([0])), .init(0x0024, .shorts([0])), .init(0x0026, .undefined(Array("0370".utf8))),
            .init(0x0028, .shorts([1])), .init(0x0029, .longs([1216])), .init(0x002A, .shorts([0])),
            .init(0x0033, .ascii("9999:99:99 00:00:00")), .init(0x004D, .rationals([(128, 256), (128, 256)])),
            .init(0x0070, .bytes([2])), .init(0x8000, .undefined(Array("0139".utf8))), .init(0x8001, .shorts([37])),
            .init(0x8010, .ascii("9999:99:99 00:00:00")),
        ]
        let tiff = cameraTIFF(w, ifd0: ifd0, exif: exif, interop: interop, ifd1: ifd1,
                              makerHeader: Array("Panasonic".utf8) + [0, 0, 0], makerTags: maker, thumbnail: thumbnail)
        let exifSegment = app(0xE1, Array("Exif".utf8) + [0, 0] + tiff)

        // EOI 之后：MPF 没登记的相机数据、预览图、又一段没登记的数据。
        let preview = encodeBaselineJPEG(width: 960, height: 640, h: 2, v: 1, quality: 85) { x, y in
            pattern(x * width / 960, y * height / 640)
        }
        let before = [UInt8](repeating: 0xFF, count: 16) + (0..<128).map { UInt8(0xF0 | ($0 & 0x07)) }
        let after = [UInt8](repeating: 0xFF, count: 33) + (0..<256).map { UInt8(0x10 + ($0 % 0x60)) }

        // APP2 MPF：MP 索引 IFD 里两条 MP Entry（16 字节一条）：主图（代表图像，类型 0x030000，
        // 偏移 0）、预览图（类型 0x010002）。偏移相对 MPF 段里 TIFF 头的位置。
        let m = TIFFWriter(littleEndian: true)
        func mpf(previewOffset: Int, primarySize: Int) -> [UInt8] {
            let entries = m.u32(0x2003_0000) + m.u32(primarySize) + m.u32(0) + m.u16(0) + m.u16(0)
                + m.u32(0x0001_0002) + m.u32(preview.count) + m.u32(previewOffset) + m.u16(0) + m.u16(0)
            let tags: [TIFFTag] = [
                .init(0xB000, .undefined(Array("0100".utf8))), .init(0xB001, .longs([2])),
                .init(0xB002, .undefined(entries)),
            ]
            return app(0xE2, Array("MPF".utf8) + [0] + m.header + m.ifd(tags, at: 8).bytes)
        }
        let placeholder = mpf(previewOffset: 0, primarySize: 0)
        let primarySize = 2 + exifSegment.count + placeholder.count + body.count
        // MPF 段的 TIFF 头在：SOI(2) + EXIF 段 + MPF 段的标记与长度(4) + "MPF\0"(4)。
        let mpfTIFFAt = 2 + exifSegment.count + 8
        let previewAt = primarySize + before.count
        let mpfSegment = mpf(previewOffset: previewAt - mpfTIFFAt, primarySize: primarySize)
        precondition(mpfSegment.count == placeholder.count)
        return [0xFF, 0xD8] + exifSegment + mpfSegment + body + before + preview + after

    case .canon:
        let w = TIFFWriter(littleEndian: true)
        let date = "2024:05:06 18:01:00"
        let author = "Zhang San;Li Si"
        let xpAuthor: [UInt8] = author.utf16.flatMap { (u: UInt16) -> [UInt8] in [UInt8(u & 0xFF), UInt8(u >> 8)] } + [0, 0]
        let ifd0: [TIFFTag] = [
            .init(0x010F, .ascii("Canon")), .init(0x0110, .ascii("Canon EOS 550D")), .init(0x0112, .shorts([1])),
            .init(0x011A, .rationals([(72, 1)])), .init(0x011B, .rationals([(72, 1)])), .init(0x0128, .shorts([2])),
            .init(0x0132, .ascii(date)), .init(0x013B, .ascii(author)), .init(0x0213, .shorts([2])),
            .init(0x8298, .ascii("")), .init(0x9C9D, .bytes(xpAuthor)),
        ]
        let exif: [TIFFTag] = [
            .init(0x829A, .rationals([(1, 13)])), .init(0x829D, .rationals([(4, 1)])), .init(0x8822, .shorts([0])),
            .init(0x8827, .shorts([3200])), .init(0x9000, .undefined(Array("0221".utf8))), .init(0x9003, .ascii(date)),
            .init(0x9004, .ascii(date)), .init(0x9101, .undefined([1, 2, 3, 0])),
            .init(0x9201, .srationals([(237_568, 65536)])), .init(0x9202, .rationals([(262_144, 65536)])),
            .init(0x9204, .srationals([(0, 1)])), .init(0x9207, .shorts([5])), .init(0x9209, .shorts([16])),
            .init(0x920A, .rationals([(34, 1)])), .init(0x9286, .undefined([UInt8](repeating: 0, count: 264))),
            .init(0x9290, .ascii("00")), .init(0x9291, .ascii("00")), .init(0x9292, .ascii("00")),
            .init(0xA000, .undefined(Array("0100".utf8))), .init(0xA001, .shorts([1])), .init(0xA002, .shorts([width])),
            .init(0xA003, .shorts([height])), .init(0xA20E, .rationals([(3_456_000, 905)])),
            .init(0xA20F, .rationals([(2_304_000, 595)])), .init(0xA210, .shorts([2])), .init(0xA401, .shorts([0])),
            .init(0xA402, .shorts([0])), .init(0xA403, .shorts([0])), .init(0xA406, .shorts([0])),
        ]
        let interop: [TIFFTag] = [.init(0x0002, .undefined(Array("0100".utf8)))]
        let ifd1: [TIFFTag] = [
            .init(0x0103, .shorts([6])), .init(0x011A, .rationals([(72, 1)])), .init(0x011B, .rationals([(72, 1)])),
            .init(0x0128, .shorts([2])),
        ]
        // 佳能 MakerNote 的一部分标签（编号、类型照 EOS 550D，值是编的；不带机主名与机身序列号）。
        var settings = [Int](repeating: 0, count: 49); settings[0] = 98
        var shot = [Int](repeating: 0, count: 34); shot[0] = 68
        let maker: [TIFFTag] = [
            .init(0x0001, .shorts(settings)), .init(0x0002, .shorts([0, 18, 0, 0])), .init(0x0003, .shorts([0, 0, 0, 0])),
            .init(0x0004, .shorts(shot)), .init(0x0006, .ascii("Canon EOS 550D")),
            .init(0x0007, .ascii("Firmware Version 1.0.9")), .init(0x0009, .asciiPadded("", 32)),
            .init(0x0010, .longs([0x8000_0270])), .init(0x0013, .shorts([0, 0, 0, 0])),
            .init(0x0095, .asciiPadded("EF-S18-55mm f/3.5-5.6 IS", 70)), .init(0x0098, .shorts([0, 0, 0, 0])),
            .init(0x4008, .shorts([0, 0, 0])), .init(0x4009, .shorts([0, 0, 0])),
        ]
        let tiff = cameraTIFF(w, ifd0: ifd0, exif: exif, interop: interop, ifd1: ifd1,
                              makerHeader: [], makerTags: maker, thumbnail: thumbnail)
        let exifSegment = app(0xE1, Array("Exif".utf8) + [0, 0] + tiff)
        // Windows 照片查看器写的那种 XMP 包：只有 dc:creator，两项对应 Artist 里分号隔开的两个名字。
        let xmp = """
        <?xpacket begin='\u{FEFF}' id='W5M0MpCehiHzreSzNTczkc9d'?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="uuid:faf5bdd5-ba3d-11da-ad31-d33d75182f1b" xmlns:dc="http://purl.org/dc/elements/1.1/">\
        <dc:creator><rdf:Seq xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:li>Zhang San</rdf:li>\
        <rdf:li>Li Si</rdf:li></rdf:Seq></dc:creator></rdf:Description></rdf:RDF></x:xmpmeta>
        <?xpacket end='w'?>
        """
        let xmpSegment = app(0xE1, Array("http://ns.adobe.com/xap/1.0/".utf8) + [0] + Array(xmp.utf8))
        return [0xFF, 0xD8] + exifSegment + xmpSegment + body
    }
}
