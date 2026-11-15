// RAW 文件截短了（拷到一半、下载没完）时，有的解码器照样显影：缺的那部分由它补上，产物看上去是
// 一张完整的照片，元数据也一条不少。实测松下 RW2 只剩前 5% 也转得出来，ImageIO 的状态照样是
// 「完整」。佳能 CR3、DNG 截短了显影失败，失败那条路已经说清；这里管的是「转出来了但源不完整」。
//
// 判断只看文件结构：文件里登记的图像数据要延伸到哪里，文件是不是那么长。
// - TIFF 系 RAW（DNG、CR2、NEF、ARW、PEF、SRW、ORF）：每个 IFD（IFD0 起的链，加上 SubIFDs）里的
//   条带（StripOffsets/StripByteCounts）、图块（TileOffsets/TileByteCounts）、内嵌 JPEG
//   （JPEGInterchangeFormat/Length）都写明了起点和长度，取最远的终点。
// - 松下 RW2：只写了图像数据的起点（RawDataOffset），长度要按数据格式算。只认实测核对过的
//   RawFormat 4：每 14 个像素装进 16 字节，整块按 0x4000 字节对齐（3864×2754 的样本算出来与文件
//   恰好一样长）。别的格式不判断。
// - CR3、RAF 和别的：不判断。

import Foundation

/// RAW 里登记的图像数据要延伸到第几字节，而文件没有那么长时，`needed` 是应有的长度、`have` 是实际长度。
struct RawShortfall: Equatable {
    let needed: Int
    let have: Int
}

/// 文件结构表明图像数据被截短了就返回缺口；没截短、这种 RAW 看不出来都是 nil。`type` 是 ImageIO 给的类型。
func rawDataShortfall(_ bytes: [UInt8], type: String?) -> RawShortfall? {
    guard let type, let layout = cameraRawExifLayouts[type] else { return nil }
    let needed: Int?
    switch layout {
    case .tiff(let magic):
        needed = TIFFStructure(bytes, base: 0, length: bytes.count, magic: magic).flatMap(tiffImageDataEnd)
    case .rw2:
        needed = TIFFStructure(bytes, base: 0, length: bytes.count, magic: [0x55]).flatMap(rw2ImageDataEnd)
    case .cr3, .raf:
        needed = nil
    }
    guard let needed, needed > bytes.count else { return nil }
    return RawShortfall(needed: needed, have: bytes.count)
}

/// 截短的 RAW 转出来时报的那条差异（没校验时写在状态说明里）。
func rawTruncatedNotice(_ s: RawShortfall) -> String {
    "源文件不完整：RAW 的图像数据应有 \(humanSize(s.needed))，文件只有 \(humanSize(s.have))（缺 \(humanSize(s.needed - s.have))）；"
        + "转出的 HEIF 里缺的部分是解码器补的"
}

/// TIFF 里 SHORT 或 LONG 数组标签的值；别的类型、读不出都是 nil。
private func unsignedArray(_ tiff: TIFFStructure, _ entry: TIFFStructure.Entry) -> [Int]? {
    guard let field = entry.field else { return nil }
    switch entry.type {
    case 3: return stride(from: 0, to: field.size, by: 2).compactMap { tiff.u16(field.offset + $0) }
    case 4, 13: return stride(from: 0, to: field.size, by: 4).compactMap { tiff.u32(field.offset + $0) }
    default: return nil
    }
}

/// 一个 IFD 里登记的数据块（起点、长度）各自的终点里最远的一个；没有登记是 nil。
/// 起点是 0xFFFFFFFF（松下在 StripOffsets 里这么写）、长度是 0 的不算。
private func dataEnd(_ tiff: TIFFStructure, ifd: Int) -> Int? {
    let entries = tiff.entries(ifd)
    func values(_ tag: Int) -> [Int]? { entries.first { $0.tag == tag }.flatMap { unsignedArray(tiff, $0) } }
    var end: Int?
    for (offsets, lengths) in [(0x0111, 0x0117), (0x0144, 0x0145), (0x0201, 0x0202)] {
        guard let starts = values(offsets), let counts = values(lengths), starts.count == counts.count else { continue }
        for (start, count) in zip(starts, counts) where count > 0 && start != 0xFFFF_FFFF {
            end = max(end ?? 0, start + count)
        }
    }
    return end
}

/// TIFF 系 RAW 的图像数据终点：IFD0 起的链和各 IFD 的 SubIFDs（0x014A）里最远的那个。
/// 走过的 IFD 记下来防止成环，最多走 64 个。
func tiffImageDataEnd(_ tiff: TIFFStructure) -> Int? {
    var pending = [tiff.ifd0].compactMap { $0 }
    var seen = Set<Int>()
    var end: Int?
    while let ifd = pending.popLast(), seen.count < 64 {
        guard ifd >= 8, seen.insert(ifd).inserted else { continue }
        if let e = dataEnd(tiff, ifd: ifd) { end = max(end ?? 0, e) }
        let entries = tiff.entries(ifd)
        if let sub = entries.first(where: { $0.tag == 0x014A }).flatMap({ unsignedArray(tiff, $0) }) {
            pending += sub
        }
        // 下一个 IFD 的偏移在条目表之后。
        if let count = tiff.u16(ifd), let next = tiff.u32(ifd + 2 + 12 * count), next != 0 {
            pending.append(next)
        }
    }
    return end
}

/// 松下 RW2 的图像数据终点：RawDataOffset（0x0118）加上按 RawFormat（0x002D）算出的长度。
/// 只认 RawFormat 4（见文件头）；尺寸取 SensorWidth/SensorHeight（0x0002/0x0003）。
func rw2ImageDataEnd(_ tiff: TIFFStructure) -> Int? {
    guard let ifd0 = tiff.ifd0 else { return nil }
    let entries = tiff.entries(ifd0)
    func value(_ tag: Int) -> Int? {
        entries.first { $0.tag == tag }.flatMap { unsignedArray(tiff, $0) }?.first
    }
    guard value(0x002D) == 4, let start = value(0x0118), let width = value(0x0002), let height = value(0x0003),
          width > 0, height > 0, width * height < 1 << 32 else { return nil }
    let packed = (width * height + 13) / 14 * 16
    let block = 0x4000
    return start + (packed + block - 1) / block * block
}
