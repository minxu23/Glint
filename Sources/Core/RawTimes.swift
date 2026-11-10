// 源文件里时间字段的原始值，直接从 JPEG 字节读，不经过 ImageIO 的属性视图。
//
// ImageIO 读 JPEG 时会把 EXIF、IPTC-IIM、XMP 三处的时间互相调和：只改过 EXIF
// 时间的照片，属性视图里 IIM 的 `184207+0800` 会变成 `184208`、XMP 的
// `…+08:00` 会被改写、偏移随之消失；反过来只改 IIM 时，视图里的 EXIF 拍摄时间
// 会跟着变。拿这个视图当源侧的真相，源文件里实际存在的时间与偏移就会在比对
// 之前被抹掉。metadataDiff 因此用这里读出的原始值覆盖视图里的同名键。
//
// 覆盖的范围：
//   EXIF  IFD0 的 DateTime(0x0132)；Exif 子 IFD 的 DateTimeOriginal(0x9003)、
//         DateTimeDigitized(0x9004)、OffsetTime*(0x9010–0x9012)
//   IIM   2:55 DateCreated、2:60 TimeCreated、2:62 DigitalCreationDate、
//         2:63 DigitalCreationTime（APP13 Photoshop 3.0 段里 8BIM 0x0404 资源）
//   XMP   APP1 XMP 包里值形如时间戳的全部标签（独立解析这个包，不取合并视图）

import Foundation
import ImageIO

/// 源文件里时间字段的原始值，键路径与 metadataKeySpace 一致。读不出的字段不出现。
func rawTimeFields(of bytes: [UInt8]) -> [String: String] {
    var fields: [String: String] = [:]
    if let tiff = TIFFStructure(jpeg: bytes) {
        let ifd0Tags: [(Int, String)] = [
            (0x0132, metadataKey(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime)),
        ]
        let exifTags: [(Int, String)] = [
            (0x9003, exifKey(kCGImagePropertyExifDateTimeOriginal)),
            (0x9004, exifKey(kCGImagePropertyExifDateTimeDigitized)),
            (0x9010, exifKey(kCGImagePropertyExifOffsetTime)),
            (0x9011, exifKey(kCGImagePropertyExifOffsetTimeOriginal)),
            (0x9012, exifKey(kCGImagePropertyExifOffsetTimeDigitized)),
        ]
        for (tag, key) in ifd0Tags { fields[key] = tiff.ascii(in: tiff.ifd0, tag: tag) }
        let exifIFD = tiff.exifIFD
        for (tag, key) in exifTags { fields[key] = tiff.ascii(in: exifIFD, tag: tag) }
    }
    guard let layout = JPEGLayout(bytes) else { return fields }
    fields.merge(rawIIMTimes(bytes, layout)) { $1 }
    fields.merge(rawXMPTimes(bytes, layout)) { $1 }
    return fields
}

/// IIM 记录 2 里的四个日期/时间数据集。
private func rawIIMTimes(_ bytes: [UInt8], _ layout: JPEGLayout) -> [String: String] {
    let datasets: [UInt8: String] = [
        55: iptcKey(kCGImagePropertyIPTCDateCreated),
        60: iptcKey(kCGImagePropertyIPTCTimeCreated),
        62: iptcKey(kCGImagePropertyIPTCDigitalCreationDate),
        63: iptcKey(kCGImagePropertyIPTCDigitalCreationTime),
    ]
    // 一份 Photoshop 资源块可以跨多个 APP13 段，按顺序拼起来再解析。
    let photoshopID: [UInt8] = Array("Photoshop 3.0".utf8) + [0]
    var block: [UInt8] = []
    for s in layout.segments where s.marker == 0xED && s.begins(with: photoshopID, in: bytes) {
        block += bytes[(s.payload.lowerBound + photoshopID.count)..<s.payload.upperBound]
    }
    var fields: [String: String] = [:]
    for iim in photoshopResources(block, id: 0x0404) {
        var i = 0
        while i + 5 <= iim.count, iim[i] == 0x1C {
            let record = iim[i + 1], dataset = iim[i + 2]
            let length = Int(iim[i + 3]) << 8 | Int(iim[i + 4])
            // 长度最高位置位是扩展长度，日期时间字段不会用到；遇到就停，不猜。
            guard length & 0x8000 == 0, i + 5 + length <= iim.count else { break }
            if record == 2, let key = datasets[dataset],
               let text = String(bytes: iim[(i + 5)..<(i + 5 + length)], encoding: .ascii) {
                let t = trimPadding(text)
                if !t.isEmpty { fields[key] = t }
            }
            i += 5 + length
        }
    }
    return fields
}

/// Photoshop 资源块（一串 `8BIM` 资源）里给定编号的资源内容。
private func photoshopResources(_ block: [UInt8], id wanted: Int) -> [[UInt8]] {
    var found: [[UInt8]] = []
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
        guard size >= 0, start + size <= block.count else { break }
        if id == wanted { found.append(Array(block[start..<(start + size)])) }
        i = start + size + (size % 2)
    }
    return found
}

/// XMP 包里值形如时间戳（见 Timestamp）的标签。
private func rawXMPTimes(_ bytes: [UInt8], _ layout: JPEGLayout) -> [String: String] {
    let xmpID: [UInt8] = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]
    guard let s = layout.segments.first(where: { $0.marker == 0xE1 && $0.begins(with: xmpID, in: bytes) }),
          let md = CGImageMetadataCreateFromXMPData(
              Data(bytes[(s.payload.lowerBound + xmpID.count)..<s.payload.upperBound]) as CFData)
    else { return [:] }
    return xmpTags(md).filter { Timestamp(parsing: $0.value) != nil }
}
