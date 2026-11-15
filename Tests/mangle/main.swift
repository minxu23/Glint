// 测试夹具：就地改写一张 JPEG，造出 ImageIO 或 --verify 容易看漏的样本。
//
//   mangle <文件.jpg> <备注文本>
//       把 EXIF UserComment 改写成去掉 8 字节字符集前缀的裸 UTF-8。不少安卓机型
//       这么写，ImageIO 认不出来会当作字段不存在。
//   mangle --replace <文件.jpg> <旧文本> <新文本>
//       把文件里每一处 <旧文本> 的字节等长替换成 <新文本>，打印替换了几处；
//       一处都没有就失败。用来造"只改过某一处时间"的样本，段长度和偏移都不用动。
//   mangle --segment <文件.jpg> <标记> <内容>
//       在最后一个 APPn 段之后插入一个标记段（标记写十六进制，如 FE 是 COM、
//       EB 是 APP11），内容是 <内容> 的 UTF-8 字节；`\0` 是 NUL、`\xHH` 是任意一个字节。
//   mangle --append <文件.jpg> <内容>
//       在文件末尾（EOI 之后）追加 <内容> 的 UTF-8 字节；`\0`、`\xHH` 同 --segment。
//   mangle --mpf-type <文件.jpg> <条目号> <类型码十六进制>
//       把 MPF 索引第 <条目号> 个条目（0 是主图自己，1 是第一张附加图像）的 MP 类型码
//       （属性字段的低 24 位）改成给定的值，高 8 位的标志不动。造新版 MPF 的增益图
//       （0x050000）、编辑前的原图（0x040000）这类类型码的样本。
//   mangle --pad-trailer <文件.jpg>
//       EOI 之后不在任何 MPF 条目范围里的字节全部改成 0xFF，长度不变。
//   mangle --unicode-comment <文件.jpg> <备注文本>
//       把 EXIF UserComment 原地改写成 `UNICODE\0` 前缀加 <备注文本> 的 UTF-16
//       （字节序随 TIFF 头），剩下的字节补 NUL。字段长度不变；放不下就失败。
//   mangle --strip-trailer <文件.jpg>
//       截掉 EOI 之后的全部字节。
//   mangle --ifd0 <文件.jpg> <标签十六进制>=<值>...
//       往 EXIF IFD0 里写这些标签（已有同号标签就替换）。值的编码按标签定：
//       0x9C9B–0x9C9F（Windows XP 标签）写 UTF-16LE 加 NUL 结尾的 BYTE 串，
//       0x4746/0x4749（Rating/RatingPercent）写 SHORT，其余写 ASCII。
//       IFD0 整张表连同新值挪到 TIFF 数据末尾、改写 IFD0 指针，原有的值偏移都不用动。
//   mangle --tags <文件.jpg> <IFD>:<标签十六进制>:<类型>=<值>...
//       往 IFD0（ifd0）、Exif 子 IFD（exif）或 GPS IFD（gps）里写类型由自己指定的条目，
//       用来造 ImageIO 不认的写法（ASCII 类型的 GPSProcessingMethod、LONG 类型的
//       LightSource、放错 IFD 的标签、空条目）。类型：ascii（值加 NUL 结尾；值为空时
//       写个数 0）、undef（值的字节）、short / long（逗号分隔的十进制）、
//       rational（逗号分隔的 n/d）、none（类型 0、个数 0）。ascii 与 undef 的值里 `\0` 是
//       NUL、`\xHH` 是任意一个字节（造不是合法 UTF-8 的值）。同一张表里同号的条目全部
//       换成这里给的；同一个标签号给几次就写几条。
//       类型后面可以接 `#<个数>` 和 `@<十六进制偏移>`，把条目里的个数、值偏移改成给定的数，
//       值的字节照常写在表后面：造个数离谱、值越出 EXIF 的条目（如 `exif:A420:ascii#99999=x`、
//       `exif:A420:ascii@7FFFFFF0=0123456789abcdef`）。
//   mangle --8bim <文件.jpg> <资源号十六进制> <内容>
//       往 APP13 Photoshop 资源块末尾追加一个 8BIM 资源，内容是 <内容> 的 UTF-8 字节。
//   mangle --iim <文件.jpg> <记录>:<数据集>[=<值>]...
//       改写 APP13 Photoshop 段里 IPTC（8BIM 0x0404）资源的数据集，别的资源（含 IIM 摘要
//       0x0425）不动——摘要于是对不上，ImageIO 改用 IIM 的值去调和说明、作者、版权。
//       `2:120=新说明` 把这个数据集换成新值（有几条同号的只留第一条的位置；没有就加在最后），
//       `1:90` 不带 `=` 是删掉这个数据集的全部条目。值的写法同 --tags（`\0`、`\xHH`）。
//   mangle --color-gainmap <文件.jpg>
//       把 MPF 登记的第一张附加图像（ISO 增益图）换成 3 通道的 JPEG：解码出原来的单通道
//       增益图，三个通道分别取它的 1、3/4、1/3 倍重新编码，保留原增益图 JPEG 的 APPn 段
//       （ISO 21496-1 元数据在那里），改写 MPF 条目里的长度，后面条目的偏移跟着挪。
//       ImageIO 合成 JPEG 时增益图总是单通道的，手机 HDR 照片里的 3 通道增益图只能这样造；
//       造出来的样本 ImageIO 读回的像素格式是 `420f`、字典里没有数据键，与真实照片一样。
//   mangle --graft-aux <文件.jpg> <提供辅助图的.jpg>
//       把另一张图的辅助图接到这张图上，主图的编码字节一个不动：去掉这张图 EOI 之后的
//       数据和它自己的 MPF 段，插入提供方的 MPF 段，接上提供方 EOI 之后的附加图像，改写
//       MP 条目里的主图长度和附加图像偏移。ImageIO 重新编码 JPEG 时色度抽样只会是 4:2:0
//       或 4:4:4，要「4:2:2 且带辅助图」的样本只能拿 4:2:2 的照片这样接。
//   mangle --break-icc <文件.jpg>
//       把 ICC 描述文件头里的签名 `acsp` 改成 0（没有 ICC 段就先插一份 Display P3）。普通 JFIF 的
//       JPEG ImageIO 不理会它、按 sRGB 解码；配上 --apple-jfif 就一张图都解不出来。
//   mangle --icc-profile-id <文件.jpg>
//       给 ICC 描述文件填上算对的 Profile ID（没有 ICC 段就先插一份 Display P3）。iPhone 照片带着它，
//       ImageIO 写 HEIF 时清零。
//   mangle --apple-jfif <文件.jpg>
//       把 JFIF 段换成 iPhone 写的那种（300 dpi，末尾多 `AMPF`）。ImageIO 见到它换一条更严的解码路子。
//   mangle --dqt-clobber <文件.jpg>
//       把第二张量化表的编号改成 0，色度那张就没了定义。配上 --apple-jfif 时 ImageIO 照样给一张图、
//       到解码才失败。

import CoreGraphics
import CryptoKit
@testable import Eclose
import Foundation
import ImageIO
import UniformTypeIdentifiers

let usage = """
用法: mangle <文件.jpg> <备注文本>
      mangle --replace <文件.jpg> <旧文本> <新文本>
      mangle --segment <文件.jpg> <标记十六进制> <内容>
      mangle --append <文件.jpg> <内容>
      mangle --unicode-comment <文件.jpg> <备注文本>
      mangle --strip-trailer <文件.jpg>
      mangle --ifd0 <文件.jpg> <标签十六进制>=<值>...
      mangle --tags <文件.jpg> <ifd0|exif|gps>:<标签十六进制>:<ascii|undef|short|long|rational|none>=<值>...
      mangle --8bim <文件.jpg> <资源号十六进制> <内容>
      mangle --iim <文件.jpg> <记录>:<数据集>[=<值>]...
      mangle --color-gainmap <文件.jpg>
      mangle --graft-aux <文件.jpg> <提供辅助图的.jpg>
      mangle --mpf-type <文件.jpg> <条目号> <类型码十六进制>
      mangle --pad-trailer <文件.jpg>
      mangle --break-icc <文件.jpg>
      mangle --icc-profile-id <文件.jpg>
      mangle --apple-jfif <文件.jpg>
      mangle --dqt-clobber <文件.jpg>
"""

func die(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { die(usage, 2) }
let mode = first.hasPrefix("--") ? first : ""
let rest = mode.isEmpty ? args : Array(args.dropFirst())
let expected = ["": 2, "--replace": 3, "--segment": 3, "--append": 2, "--unicode-comment": 2, "--strip-trailer": 1, "--8bim": 3,
                "--color-gainmap": 1, "--graft-aux": 2, "--mpf-type": 3, "--pad-trailer": 1,
                "--break-icc": 1, "--icc-profile-id": 1, "--apple-jfif": 1, "--dqt-clobber": 1]
if mode == "--ifd0" || mode == "--tags" || mode == "--iim" {
    guard rest.count >= 2 else { die(usage, 2) }
} else {
    guard let want = expected[mode], rest.count == want else { die(usage, 2) }
}

let url = URL(fileURLWithPath: rest[0])
guard let original = try? Data(contentsOf: url) else { die("读不了 \(url.path)") }
var bytes = [UInt8](original)

/// 把段内容换成 `payload`，改写段长度。
func replacePayload(of segment: JPEGSegment, with payload: [UInt8]) {
    let length = payload.count + 2
    guard length <= 0xFFFF else { die("改写后一个段放不下") }
    bytes.replaceSubrange(segment.payload, with: payload)
    bytes[segment.payload.lowerBound - 2] = UInt8(length >> 8)
    bytes[segment.payload.lowerBound - 1] = UInt8(length & 0xFF)
}

/// 要写进某个 IFD 的一个条目：值已按 TIFF 头的字节序编好。
struct NewEntry {
    let tag: Int
    let type: Int
    var count: Int
    let value: [UInt8]
    /// 不是 nil 时条目里的值偏移写成它，不指向真正写下值的地方。
    var offset: Int? = nil
}

func encoders(_ tiff: TIFFStructure) -> (u16: (Int) -> [UInt8], u32: (Int) -> [UInt8]) {
    ({ v in tiff.bigEndian ? [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] },
     { v in
         let be = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
         return tiff.bigEndian ? be : be.reversed()
     })
}

/// 往 IFD0、Exif 子 IFD 或 GPS IFD 里写条目。`added` 里出现的标签号，原表里的同号条目
/// 全部去掉；`added` 里同一个标签号出现几次就写几条（造重复条目的样本）。整张表连同
/// 新值挪到 TIFF 数据末尾、改写指向它的指针（IFD0 在 TIFF 头里，另两个在 IFD0 的
/// 0x8769/0x8825 条目里），原有的值偏移都不用动。
func rewriteIFD(_ which: String, _ added: [NewEntry]) {
    guard let tiff = TIFFStructure(jpeg: bytes), let ifd0 = tiff.ifd0,
          let segment = JPEGLayout(bytes)?.segments.first(where: {
              $0.marker == 0xE1 && $0.begins(with: Array("Exif".utf8) + [0, 0], in: bytes)
          })
    else { die("这张图里没有可改写的 EXIF") }
    // pointerAt：存放表偏移的那 4 字节（相对 TIFF 头）。
    let pointerAt: Int
    switch which {
    case "ifd0": pointerAt = 4
    case "exif", "gps":
        guard let field = tiff.find(ifd0, tag: which == "exif" ? 0x8769 : 0x8825), field.size == 4
        else { die("这张图里没有 \(which) IFD") }
        pointerAt = field.offset
    default: die("IFD 只能是 ifd0、exif、gps：\(which)")
    }
    guard let table0 = tiff.u32(pointerAt), let count = tiff.u16(table0),
          let next = tiff.u32(table0 + 2 + count * 12) else { die("\(which) 的表越界") }
    let (u16, u32) = encoders(tiff)
    let replaced = Set(added.map(\.tag))
    // (标签号, 12 字节条目)；原有条目原样保留。
    var entries: [(tag: Int, bytes: [UInt8])] = []
    for k in 0..<count {
        let at = tiff.base + table0 + 2 + k * 12
        guard let tag = tiff.u16(table0 + 2 + k * 12) else { die("\(which) 条目越界") }
        if !replaced.contains(tag) { entries.append((tag, Array(bytes[at..<(at + 12)]))) }
    }
    // 新表放在 TIFF 数据末尾（偶数对齐），超过 4 字节的值紧跟在表后面。
    let total = entries.count + added.count
    let tableStart = tiff.length + tiff.length % 2
    var dataAt = tableStart + 2 + total * 12 + 4
    var values: [UInt8] = []
    for a in added {
        var entry = u16(a.tag) + u16(a.type) + u32(a.count)
        if a.value.count <= 4 && a.offset == nil {
            entry += a.value + [UInt8](repeating: 0, count: 4 - a.value.count)
        } else {
            entry += u32(a.offset ?? dataAt)
            values += a.value
            dataAt += a.value.count
            if a.value.count % 2 == 1 { values.append(0); dataAt += 1 }
        }
        entries.append((a.tag, entry))
    }
    var table = u16(entries.count)
    // 按标签号稳定排序：同号的重复条目保持写入顺序。
    for e in entries.enumerated().sorted(by: { ($0.element.tag, $0.offset) < ($1.element.tag, $1.offset) }) {
        table += e.element.bytes
    }
    table += u32(next)
    var payload = Array(bytes[segment.payload])
    let tiffStart = tiff.base - segment.payload.lowerBound
    if tiff.length % 2 == 1 { payload.append(0) }
    payload += table + values
    payload.replaceSubrange((tiffStart + pointerAt)..<(tiffStart + pointerAt + 4), with: u32(tableStart))
    replacePayload(of: segment, with: payload)
    print("\(which) 写入 \(added.count) 个条目")
}

/// `--ifd0` 的值：按标签号定类型。
func ifd0Entries(_ specs: [String]) {
    guard let tiff = TIFFStructure(jpeg: bytes) else { die("这张图里没有可改写的 EXIF IFD0") }
    let (u16, _) = encoders(tiff)
    var added: [NewEntry] = []
    for spec in specs {
        let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let tag = Int(parts[0].replacingOccurrences(of: "0x", with: ""), radix: 16)
        else { die("标签写成 <十六进制>=<值>：\(spec)") }
        let text = String(parts[1])
        switch tag {
        case 0x9C9B...0x9C9F:
            let value: [UInt8] = text.utf16.flatMap { (u: UInt16) -> [UInt8] in [UInt8(u & 0xFF), UInt8(u >> 8)] }
                + [0, 0]
            added.append(NewEntry(tag: tag, type: 1, count: value.count, value: value))
        case 0x4746, 0x4749:
            guard let n = Int(text), (0...0xFFFF).contains(n) else { die("SHORT 值不合法：\(spec)") }
            added.append(NewEntry(tag: tag, type: 3, count: 1, value: u16(n)))
        default:
            let value = Array(text.utf8) + [0]
            added.append(NewEntry(tag: tag, type: 2, count: value.count, value: value))
        }
    }
    rewriteIFD("ifd0", added)
}

/// 文本的 UTF-8 字节，其中 `\0` 是一个 NUL 字节，`\xHH` 是一个任意字节。
func unescapedBytes(_ text: String) -> [UInt8] {
    var raw: [UInt8] = []
    let utf8 = Array(text.utf8)
    var i = 0
    while i < utf8.count {
        if utf8[i] == 0x5C, i + 1 < utf8.count, utf8[i + 1] == 0x30 {
            raw.append(0); i += 2
        } else if utf8[i] == 0x5C, i + 3 < utf8.count, utf8[i + 1] == 0x78,
                  let b = UInt8(String(decoding: utf8[(i + 2)..<(i + 4)], as: UTF8.self), radix: 16) {
            raw.append(b); i += 4
        } else {
            raw.append(utf8[i]); i += 1
        }
    }
    return raw
}

/// `--tags` 的值：`<IFD>:<标签十六进制>:<类型>=<值>`，类型写明，见文件头。
func typedEntries(_ specs: [String]) {
    guard let tiff = TIFFStructure(jpeg: bytes) else { die("这张图里没有可改写的 EXIF") }
    let (u16, u32) = encoders(tiff)
    var byIFD: [(which: String, entries: [NewEntry])] = []
    for spec in specs {
        let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let head = parts[0].split(separator: ":")
        guard parts.count == 2, head.count == 3, let tag = Int(head[1], radix: 16), (0...0xFFFF).contains(tag)
        else { die("条目写成 <IFD>:<标签十六进制>:<类型>=<值>：\(spec)") }
        let which = String(head[0]), text = String(parts[1])
        // 类型后面的 `#个数`、`@偏移`。
        var typeSpec = Substring(head[2]), countOverride: Int?, offsetOverride: Int?
        if let at = typeSpec.firstIndex(of: "@") {
            guard let o = Int(typeSpec[typeSpec.index(after: at)...], radix: 16) else { die("偏移写十六进制：\(spec)") }
            offsetOverride = o
            typeSpec = typeSpec[..<at]
        }
        if let at = typeSpec.firstIndex(of: "#") {
            guard let n = Int(typeSpec[typeSpec.index(after: at)...]), (0...0xFFFF_FFFF).contains(n) else {
                die("个数写十进制：\(spec)")
            }
            countOverride = n
            typeSpec = typeSpec[..<at]
        }
        let raw = unescapedBytes(text)
        func numbers(_ width: Int, _ encode: (Int) -> [UInt8]) -> [UInt8] {
            text.split(separator: ",").flatMap { item -> [UInt8] in
                guard let n = Int(item), n >= 0, width == 4 || n <= 0xFFFF else { die("数值不合法：\(spec)") }
                return encode(n)
            }
        }
        var entry: NewEntry
        switch typeSpec {
        case "ascii": entry = NewEntry(tag: tag, type: 2, count: raw.isEmpty ? 0 : raw.count + 1, value: raw.isEmpty ? [] : raw + [0])
        case "undef": entry = NewEntry(tag: tag, type: 7, count: raw.count, value: raw)
        case "short": let v = numbers(2, u16); entry = NewEntry(tag: tag, type: 3, count: v.count / 2, value: v)
        case "long": let v = numbers(4, u32); entry = NewEntry(tag: tag, type: 4, count: v.count / 4, value: v)
        case "rational":
            let v = text.split(separator: ",").flatMap { item -> [UInt8] in
                let nd = item.split(separator: "/")
                guard nd.count == 2, let n = Int(nd[0]), let d = Int(nd[1]), n >= 0, d > 0 else { die("分数不合法：\(spec)") }
                return u32(n) + u32(d)
            }
            entry = NewEntry(tag: tag, type: 5, count: v.count / 8, value: v)
        case "none": entry = NewEntry(tag: tag, type: 0, count: 0, value: [])
        default: die("类型只能是 ascii、undef、short、long、rational、none：\(spec)")
        }
        if let countOverride { entry.count = countOverride }
        entry.offset = offsetOverride
        if let i = byIFD.firstIndex(where: { $0.which == which }) {
            byIFD[i].entries.append(entry)
        } else {
            byIFD.append((which, [entry]))
        }
    }
    // 一次改一张表：每改一张都会挪动 TIFF 末尾，下一张从新的字节重新解析。
    for (which, entries) in byIFD { rewriteIFD(which, entries) }
}

func appendPhotoshopResource(id: Int, content: [UInt8]) {
    let photoshopID: [UInt8] = Array("Photoshop 3.0".utf8) + [0]
    guard let segment = JPEGLayout(bytes)?.segments
        .last(where: { $0.marker == 0xED && $0.begins(with: photoshopID, in: bytes) })
    else { die("这张图里没有 APP13 Photoshop 段") }
    let size = content.count
    // 资源名是空的 Pascal 串：长度字节 0 再补一个 0 凑偶数。
    var resource = Array("8BIM".utf8) + [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0]
    resource += [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
    resource += content + (size % 2 == 1 ? [0] : [])
    replacePayload(of: segment, with: Array(bytes[segment.payload]) + resource)
    print("追加了 8BIM 资源 0x\(String(format: "%04X", id))（\(size) 字节）")
}

/// `--iim` 的改写，见文件头。
func rewriteIIM(_ specs: [String]) {
    let photoshopID: [UInt8] = Array("Photoshop 3.0".utf8) + [0]
    guard let segment = JPEGLayout(bytes)?.segments
        .last(where: { $0.marker == 0xED && $0.begins(with: photoshopID, in: bytes) })
    else { die("这张图里没有 APP13 Photoshop 段") }
    var payload = Array(bytes[segment.payload])
    // 找 0x0404：8BIM、资源号、Pascal 名（连长度字节补到偶数）、4 字节大端长度、内容（补到偶数）。
    var i = photoshopID.count
    var found: (start: Int, contentAt: Int, size: Int)?
    while i + 12 <= payload.count, Array(payload[i..<(i + 4)]) == Array("8BIM".utf8) {
        let id = Int(payload[i + 4]) << 8 | Int(payload[i + 5])
        var nameLength = Int(payload[i + 6]) + 1
        if nameLength % 2 == 1 { nameLength += 1 }
        let sizeAt = i + 6 + nameLength
        guard sizeAt + 4 <= payload.count else { break }
        let size = payload[sizeAt..<(sizeAt + 4)].reduce(0) { $0 << 8 | Int($1) }
        let contentAt = sizeAt + 4
        guard contentAt + size <= payload.count else { break }
        if id == 0x0404 { found = (i, contentAt, size); break }
        i = contentAt + size + size % 2
    }
    guard let found else { die("APP13 段里没有 IPTC（0x0404）资源") }
    let content = Array(payload[found.contentAt..<(found.contentAt + found.size)])
    // 数据集：0x1C、记录号、数据集号、2 字节大端长度、值。
    var datasets: [(record: Int, dataset: Int, value: [UInt8])] = []
    var k = 0
    while k + 5 <= content.count, content[k] == 0x1C {
        let length = Int(content[k + 3]) << 8 | Int(content[k + 4])
        guard length < 0x8000, k + 5 + length <= content.count else { die("IIM 里有扩展长度或越界的数据集，改不了") }
        datasets.append((Int(content[k + 1]), Int(content[k + 2]), Array(content[(k + 5)..<(k + 5 + length)])))
        k += 5 + length
    }
    for spec in specs {
        let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let head = parts[0].split(separator: ":")
        guard head.count == 2, let r = Int(head[0]), let d = Int(head[1]), (0...255).contains(r), (0...255).contains(d)
        else { die("数据集写成 <记录>:<数据集>[=<值>]：\(spec)") }
        let first = datasets.firstIndex { $0.record == r && $0.dataset == d }
        if parts.count == 2 {
            let value = unescapedBytes(String(parts[1]))
            guard value.count < 0x8000 else { die("值太长：\(spec)") }
            if let first {
                datasets[first].value = value
                datasets = datasets.enumerated().filter { $0.offset == first || !($0.element.record == r && $0.element.dataset == d) }.map(\.element)
            } else {
                datasets.append((r, d, value))
            }
        } else {
            guard first != nil else { die("IIM 里没有数据集 \(r):\(d)") }
            datasets.removeAll { $0.record == r && $0.dataset == d }
        }
    }
    let rebuilt: [UInt8] = datasets.flatMap { (d) -> [UInt8] in [0x1C, UInt8(d.record), UInt8(d.dataset), UInt8(d.value.count >> 8), UInt8(d.value.count & 0xFF)] + d.value }
    let size = rebuilt.count
    let sizeAt = found.contentAt - 4
    let oldEnd = min(found.contentAt + found.size + found.size % 2, payload.count)
    let padding: [UInt8] = size % 2 == 1 ? [0] : []
    let replacement: [UInt8] = [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
        + rebuilt + padding
    payload.replaceSubrange(sizeAt..<oldEnd, with: replacement)
    replacePayload(of: segment, with: payload)
    print("改写了 IIM（\(found.size) → \(size) 字节）")
}

let mpfSegmentID: [UInt8] = Array("MPF".utf8) + [0]

/// `data` 里的 MPF 段：段本身、段内 TIFF 头的位置、TIFF 结构和 MP 条目表的位置（相对 TIFF 头）。
func mpfIndex(_ data: [UInt8]) -> (segment: JPEGSegment, base: Int, tiff: TIFFStructure, entries: (offset: Int, size: Int))? {
    guard let layout = JPEGLayout(data),
          let segment = layout.segments.first(where: { $0.marker == 0xE2 && $0.begins(with: mpfSegmentID, in: data) })
    else { return nil }
    let base = segment.payload.lowerBound + mpfSegmentID.count
    guard let tiff = TIFFStructure(data, base: base, length: segment.payload.upperBound - base),
          let ifd = tiff.ifd0, let entries = tiff.find(ifd, tag: 0xB002), entries.size >= 32 else { return nil }
    return (segment, base, tiff, entries)
}

/// 见文件头 `--graft-aux`。
func graftAuxiliary(from donorPath: String) {
    guard let donorData = try? Data(contentsOf: URL(fileURLWithPath: donorPath)) else { die("读不了 \(donorPath)") }
    let donor = [UInt8](donorData)
    guard let donorIndex = mpfIndex(donor), let donorEOI = JPEGLayout(donor)?.eoi else { die("提供辅助图的文件里没有 MPF 段") }
    guard let layout = JPEGLayout(bytes), let eoi = layout.eoi else { die("找不到 EOI") }
    // 目标：去掉尾部和自己的 MPF 段，把提供方的 MPF 段插在最后一个 APPn 之后。
    var primary = Array(bytes[..<(eoi + 2)])
    if let own = layout.segments.first(where: { $0.marker == 0xE2 && $0.begins(with: mpfSegmentID, in: bytes) }) {
        primary.removeSubrange((own.payload.lowerBound - 4)..<own.payload.upperBound)
    }
    guard let primaryLayout = JPEGLayout(primary) else { die("去掉 MPF 段后不是 JPEG") }
    let at = primaryLayout.segments.prefix { (0xE0...0xEF).contains($0.marker) }.last?.payload.upperBound ?? 2
    primary.insert(contentsOf: donor[(donorIndex.segment.payload.lowerBound - 4)..<donorIndex.segment.payload.upperBound], at: at)
    let donorTrailer = donorEOI + 2
    bytes = primary + donor[donorTrailer...]
    // 改写插进来的那份 MP 条目：主图的长度，附加图像相对新 MPF 头的偏移。
    guard let index = mpfIndex(bytes) else { die("插进去的 MPF 段读不出") }
    let (_, u32) = encoders(index.tiff)
    func write(_ value: Int, at relative: Int) {
        bytes.replaceSubrange((index.base + relative)..<(index.base + relative + 4), with: u32(value))
    }
    write(primary.count, at: index.entries.offset + 4)
    for k in 1..<(index.entries.size / 16) {
        let entry = index.entries.offset + k * 16
        guard let old = donorIndex.tiff.u32(entry + 8) else { die("MP 条目越界") }
        write(primary.count + (donorIndex.base + old - donorTrailer) - index.base, at: entry + 8)
    }
    print("接上了 \(index.entries.size / 16 - 1) 张附加图像")
}

/// 见文件头 `--color-gainmap`。MPF 的偏移从段内 TIFF 头起算。
func colorizeGainMap() {
    guard let (_, base, tiff, entries) = mpfIndex(bytes) else { die("这张图里没有可读的 MPF 段") }
    let (_, u32) = encoders(tiff)
    // 第二个条目：属性、长度、偏移各 4 字节（另有两个 2 字节的从属条目号）。
    let second = entries.offset + 16
    guard let oldLength = tiff.u32(second + 4), let offset = tiff.u32(second + 8) else { die("MP 条目越界") }
    let start = base + offset
    guard start + oldLength <= bytes.count else { die("增益图越出文件") }
    let old = Array(bytes[start..<(start + oldLength)])
    guard let oldLayout = JPEGLayout(old) else { die("附加图像不是 JPEG") }
    var appSegments: [UInt8] = []
    for s in oldLayout.segments where (0xE1...0xEF).contains(s.marker) {
        appSegments += old[(s.payload.lowerBound - 4)..<s.payload.upperBound]
    }
    guard let source = CGImageSourceCreateWithData(Data(old) as CFData, nil),
          let gray = CGImageSourceCreateImageAtIndex(source, 0, nil) else { die("解码不了原增益图") }
    let w = gray.width, h = gray.height
    var g = [UInt8](repeating: 0, count: w * h)
    let drew = g.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
        ctx.draw(gray, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drew else { die("解码不了原增益图") }
    var rgb = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) {
        rgb[i * 4] = g[i]
        rgb[i * 4 + 1] = UInt8(Int(g[i]) * 3 / 4)
        rgb[i * 4 + 2] = UInt8(Int(g[i]) / 3)
    }
    let colored = rgb.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
    let encoded = NSMutableData()
    guard let colored, let dest = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)
    else { die("编码不了 3 通道增益图") }
    CGImageDestinationAddImage(dest, colored, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { die("编码不了 3 通道增益图") }
    // 新 JPEG 去掉它自己的 APPn 段，换上原增益图的。
    let fresh = [UInt8](encoded as Data)
    guard let freshLayout = JPEGLayout(fresh) else { die("编码出来的不是 JPEG") }
    let bodyStart = freshLayout.segments.first { !(0xE0...0xEF).contains($0.marker) }.map { $0.payload.lowerBound - 4 } ?? 2
    let replacement = [0xFF, 0xD8] + appSegments + Array(fresh[bodyStart...])
    let delta = replacement.count - oldLength
    // MP 条目里的长度与后面条目的偏移就地改写（都在 TIFF 头之后的同一块里）。
    func write(_ value: Int, at relative: Int) { bytes.replaceSubrange((base + relative)..<(base + relative + 4), with: u32(value)) }
    write(replacement.count, at: second + 4)
    for k in 2..<(entries.size / 16) {
        let at = entries.offset + k * 16
        if let o = tiff.u32(at + 8), o > offset { write(o + delta, at: at + 8) }
    }
    bytes.replaceSubrange(start..<(start + oldLength), with: replacement)
    print("增益图换成 3 通道（\(oldLength) → \(replacement.count) 字节）")
}

/// 见文件头 `--mpf-type`。
func setMPFType(entry: Int, to type: Int) {
    guard let (_, base, tiff, entries) = mpfIndex(bytes) else { die("这张图里没有可读的 MPF 段") }
    guard entry >= 0, entry < entries.size / 16 else { die("MPF 索引里没有第 \(entry) 个条目") }
    let at = entries.offset + entry * 16
    guard let old = tiff.u32(at) else { die("MP 条目越界") }
    let (_, u32) = encoders(tiff)
    bytes.replaceSubrange((base + at)..<(base + at + 4), with: u32(old & ~0xFF_FFFF | type))
    print(String(format: "第 %d 个条目的类型码 %06X → %06X", entry, old & 0xFF_FFFF, type))
}

/// 见文件头 `--pad-trailer`。
func padTrailer() {
    guard let layout = JPEGLayout(bytes), let eoi = layout.eoi else { die("找不到 EOI") }
    let registered = mpfImages(in: bytes, layout).map(\.range)
    var count = 0
    for i in (eoi + 2)..<bytes.count where !registered.contains(where: { $0.contains(i) }) && bytes[i] != 0xFF {
        bytes[i] = 0xFF
        count += 1
    }
    print("尾部 \(count) 字节改成了 0xFF")
}

let iccID: [UInt8] = Array("ICC_PROFILE".utf8) + [0]

/// 第一个 ICC 段。没有就先插一份 Display P3 的（v4，手机照片里常见的就是它），插在最后一个 APPn 之后。
/// 段内容是 `ICC_PROFILE\0`、序号、总数，再是描述文件本身。
func iccSegmentAddingDisplayP3() -> JPEGSegment {
    guard var layout = JPEGLayout(bytes) else { die("不是 JPEG") }
    if !layout.segments.contains(where: { $0.marker == 0xE2 && $0.begins(with: iccID, in: bytes) }) {
        guard let profile = CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data? else { die("取不到 Display P3 描述文件") }
        let content = iccID + [1, 1] + [UInt8](profile)
        let at = layout.segments.prefix { (0xE0...0xEF).contains($0.marker) }.last?.payload.upperBound ?? 2
        let length = content.count + 2
        bytes.insert(contentsOf: [0xFF, 0xE2, UInt8(length >> 8), UInt8(length & 0xFF)] + content, at: at)
        layout = JPEGLayout(bytes)!
    }
    return layout.segments.first { $0.marker == 0xE2 && $0.begins(with: iccID, in: bytes) }!
}

switch mode {
case "--mpf-type":
    guard let entry = Int(rest[1]), let type = Int(rest[2], radix: 16), (0...0xFF_FFFF).contains(type) else {
        die("条目号写十进制，类型码写十六进制，如 1 050000")
    }
    setMPFType(entry: entry, to: type)
case "--pad-trailer":
    padTrailer()
case "--break-icc":
    // 弄坏 ICC 色彩描述文件的签名（描述文件第 36–39 字节，本该是 `acsp`）。ImageIO 照样给一张图，
    // 可要再配上 --apple-jfif 才会一解码就失败；普通 JFIF 的 JPEG 它不理会坏掉的 ICC。而且只对 v4 的
    // 描述文件：系统给的 sRGB 是 v2，签名、版本号改坏了照样解得出。
    let icc = iccSegmentAddingDisplayP3()
    let signature = icc.payload.lowerBound + iccID.count + 2 + 36
    guard bytes[signature..<(signature + 4)].elementsEqual(Array("acsp".utf8)) else { die("ICC 描述文件的签名不是 acsp") }
    bytes.replaceSubrange(signature..<(signature + 4), with: [0, 0, 0, 0])
    print("ICC 描述文件的签名改成了 0")
case "--icc-profile-id":
    // 在描述文件头里填上算对了的 Profile ID（第 84–99 字节）：按 ICC 规范，是把标志（44–47）、
    // 再现意图（64–67）和 Profile ID 本身抹成 0 之后整个描述文件的 MD5。iPhone 照片的描述文件带着它，
    // 系统给的描述文件这里是 0。没有 ICC 段就先插一份 Display P3 的。
    let icc = iccSegmentAddingDisplayP3()
    let start = icc.payload.lowerBound + iccID.count + 2
    guard bytes[icc.payload.lowerBound + iccID.count + 1] == 1 else { die("描述文件分在几段里，不处理") }
    var profile = Array(bytes[start..<icc.payload.upperBound])
    var hashed = profile
    for r in [44..<48, 64..<68, 84..<100] { hashed.replaceSubrange(r, with: [UInt8](repeating: 0, count: r.count)) }
    profile.replaceSubrange(84..<100, with: Array(Insecure.MD5.hash(data: hashed)))
    bytes.replaceSubrange(start..<icc.payload.upperBound, with: profile)
    print("ICC 描述文件填上了 Profile ID")
case "--apple-jfif":
    // 把 JFIF 段换成 iPhone 写的那种：密度 300 dpi，末尾多 4 字节 `AMPF`。ImageIO 见到它解码
    // 时换了一条路：ICC 坏了它就解不出来（普通 JFIF 的它不理会）；量化表缺了它照样给一张图，
    // 到解码时才失败（普通 JFIF 的连图都不给）。没有 JFIF 段就插在 SOI 后面。
    let jfif: [UInt8] = Array("JFIF".utf8) + [0, 1, 1, 1, 0x01, 0x2C, 0x01, 0x2C, 0, 0] + Array("AMPF".utf8)
    guard let layout = JPEGLayout(bytes) else { die("不是 JPEG") }
    if let old = layout.segments.first(where: { $0.marker == 0xE0 && $0.begins(with: Array("JFIF".utf8) + [0], in: bytes) }) {
        replacePayload(of: old, with: jfif)
    } else {
        bytes.insert(contentsOf: [0xFF, 0xE0, 0, UInt8(jfif.count + 2)] + jfif, at: 2)
    }
    print("JFIF 段换成了 iPhone 的")
case "--dqt-clobber":
    // 把第二张量化表的编号改成 0：它盖掉第一张，色度用的那张就没了定义。配上 --apple-jfif 时
    // ImageIO 照样给一张图、一解码就失败；不配的话连图都不给。
    let tables: [JPEGSegment] = JPEGLayout(bytes)?.segments.filter({ $0.marker == 0xDB }) ?? []
    guard tables.count >= 2, bytes[tables[1].payload.lowerBound] & 0x0F != 0 else { die("没有分开存的第二张量化表") }
    bytes[tables[1].payload.lowerBound] &= 0xF0
    print("第二张量化表的编号改成了 0")
case "--color-gainmap":
    colorizeGainMap()
case "--graft-aux":
    graftAuxiliary(from: rest[1])
case "--ifd0":
    ifd0Entries(Array(rest.dropFirst()))
case "--tags":
    typedEntries(Array(rest.dropFirst()))
case "--iim":
    rewriteIIM(Array(rest.dropFirst()))
case "--8bim":
    guard let id = Int(rest[1], radix: 16), (0...0xFFFF).contains(id) else { die("资源号写十六进制，如 0BB7") }
    appendPhotoshopResource(id: id, content: Array(rest[2].utf8))
case "--replace":
    let old = Array(rest[1].utf8), new = Array(rest[2].utf8)
    guard old.count == new.count, !old.isEmpty else { die("新旧文本的字节数必须相同且非空") }
    var count = 0
    var i = 0
    while i + old.count <= bytes.count {
        if Array(bytes[i..<(i + old.count)]) == old {
            bytes.replaceSubrange(i..<(i + old.count), with: new)
            count += 1
            i += old.count
        } else {
            i += 1
        }
    }
    guard count > 0 else { die("文件里没有「\(rest[1])」") }
    print("替换了 \(count) 处")
case "--segment":
    guard let marker = UInt8(rest[1], radix: 16), marker >= 0xC0, marker != 0xD8, marker != 0xD9 else {
        die("标记必须是十六进制的段标记，如 FE、EB")
    }
    let content = unescapedBytes(rest[2])
    guard content.count + 2 <= 0xFFFF else { die("内容太长，一个段放不下") }
    guard let layout = JPEGLayout(bytes) else { die("不是 JPEG") }
    // 插在最后一个 APPn 之后；没有 APPn 就紧跟 SOI。
    let at = layout.segments.prefix { (0xE0...0xEF).contains($0.marker) }.last?.payload.upperBound ?? 2
    let length = content.count + 2
    bytes.insert(contentsOf: [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + content, at: at)
    print("插入了 FF\(rest[1].uppercased()) 段（\(content.count) 字节）")
case "--append":
    let content = unescapedBytes(rest[1])
    bytes.append(contentsOf: content)
    print("追加了 \(content.count) 字节")
case "--unicode-comment":
    guard let tiff = TIFFStructure(jpeg: bytes), let range = exifUserCommentRange(in: original) else {
        die("这张图里没有 UserComment 字段")
    }
    let body = rest[1].utf16.flatMap { (u: UInt16) -> [UInt8] in
        tiff.bigEndian ? [UInt8(u >> 8), UInt8(u & 0xFF)] : [UInt8(u & 0xFF), UInt8(u >> 8)]
    }
    let field = Array("UNICODE\0".utf8) + body
    guard field.count <= range.count else { die("备注太长，放不进原字段（\(range.count) 字节）") }
    bytes.replaceSubrange(range, with: field + [UInt8](repeating: 0, count: range.count - field.count))
    print("已改写 UserComment 为 UNICODE 前缀（正文 \(body.count) 字节，字段 \(range.count) 字节）")
case "--strip-trailer":
    guard let eoi = JPEGLayout(bytes)?.eoi else { die("找不到 EOI") }
    let dropped = bytes.count - (eoi + 2)
    bytes.removeSubrange((eoi + 2)...)
    print("截掉了 EOI 之后的 \(dropped) 字节")
default:
    let comment = Array(rest[1].utf8)
    guard let range = exifUserCommentRange(in: original) else { die("这张图里没有 UserComment 字段") }
    guard comment.count <= range.count else { die("备注太长，放不进原字段（\(range.count) 字节）") }
    // 字段长度保持不变，只换内容，这样 EXIF 里其它偏移都不用动。
    bytes.replaceSubrange(range, with: comment + [UInt8](repeating: 0, count: range.count - comment.count))
    print("已改写 \(url.lastPathComponent) 的 UserComment 为无前缀 UTF-8（\(range.count) 字节字段）")
}

do { try Data(bytes).write(to: url) } catch { die("写不回 \(url.path)：\(error.localizedDescription)") }
