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
//       EB 是 APP11），内容是 <内容> 的 UTF-8 字节。
//   mangle --append <文件.jpg> <内容>
//       在文件末尾（EOI 之后）追加 <内容> 的 UTF-8 字节。
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
//   mangle --8bim <文件.jpg> <资源号十六进制> <内容>
//       往 APP13 Photoshop 资源块末尾追加一个 8BIM 资源，内容是 <内容> 的 UTF-8 字节。

import Foundation

let usage = """
用法: mangle <文件.jpg> <备注文本>
      mangle --replace <文件.jpg> <旧文本> <新文本>
      mangle --segment <文件.jpg> <标记十六进制> <内容>
      mangle --append <文件.jpg> <内容>
      mangle --unicode-comment <文件.jpg> <备注文本>
      mangle --strip-trailer <文件.jpg>
      mangle --ifd0 <文件.jpg> <标签十六进制>=<值>...
      mangle --8bim <文件.jpg> <资源号十六进制> <内容>
"""

func die(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { die(usage, 2) }
let mode = first.hasPrefix("--") ? first : ""
let rest = mode.isEmpty ? args : Array(args.dropFirst())
let expected = ["": 2, "--replace": 3, "--segment": 3, "--append": 2, "--unicode-comment": 2, "--strip-trailer": 1, "--8bim": 3]
if mode == "--ifd0" {
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

func ifd0Entries(_ specs: [String]) {
    guard let tiff = TIFFStructure(jpeg: bytes), let ifd0 = tiff.ifd0, let count = tiff.u16(ifd0),
          let next = tiff.u32(ifd0 + 2 + count * 12),
          let segment = JPEGLayout(bytes)?.segments.first(where: {
              $0.marker == 0xE1 && $0.begins(with: Array("Exif".utf8) + [0, 0], in: bytes)
          })
    else { die("这张图里没有可改写的 EXIF IFD0") }
    func u16(_ v: Int) -> [UInt8] {
        tiff.bigEndian ? [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]
    }
    func u32(_ v: Int) -> [UInt8] {
        let be = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return tiff.bigEndian ? be : be.reversed()
    }
    // 标签号 → (类型, 个数, 值的字节)；原有条目原样保留 12 字节。
    var entries: [Int: [UInt8]] = [:]
    for k in 0..<count {
        let at = tiff.base + ifd0 + 2 + k * 12
        guard let tag = tiff.u16(ifd0 + 2 + k * 12) else { die("IFD0 条目越界") }
        entries[tag] = Array(bytes[at..<(at + 12)])
    }
    var added: [(tag: Int, type: Int, count: Int, value: [UInt8])] = []
    for spec in specs {
        let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let tag = Int(parts[0].replacingOccurrences(of: "0x", with: ""), radix: 16)
        else { die("标签写成 <十六进制>=<值>：\(spec)") }
        let text = String(parts[1])
        switch tag {
        case 0x9C9B...0x9C9F:
            let value: [UInt8] = text.utf16.flatMap { (u: UInt16) -> [UInt8] in [UInt8(u & 0xFF), UInt8(u >> 8)] }
                + [0, 0]
            added.append((tag, 1, value.count, value))
        case 0x4746, 0x4749:
            guard let n = Int(text), (0...0xFFFF).contains(n) else { die("SHORT 值不合法：\(spec)") }
            added.append((tag, 3, 1, u16(n)))
        default:
            let value = Array(text.utf8) + [0]
            added.append((tag, 2, value.count, value))
        }
    }
    // 新表放在 TIFF 数据末尾（偶数对齐），超过 4 字节的值紧跟在表后面。
    let total = entries.count + added.filter { entries[$0.tag] == nil }.count
    let tableStart = tiff.length + tiff.length % 2
    var dataAt = tableStart + 2 + total * 12 + 4
    var values: [UInt8] = []
    for a in added {
        var entry = u16(a.tag) + u16(a.type) + u32(a.count)
        if a.value.count <= 4 {
            entry += a.value + [UInt8](repeating: 0, count: 4 - a.value.count)
        } else {
            entry += u32(dataAt)
            values += a.value
            dataAt += a.value.count
            if a.value.count % 2 == 1 { values.append(0); dataAt += 1 }
        }
        entries[a.tag] = entry
    }
    var table = u16(entries.count)
    for tag in entries.keys.sorted() { table += entries[tag]! }
    table += u32(next)
    var payload = Array(bytes[segment.payload])
    let tiffStart = tiff.base - segment.payload.lowerBound
    if tiff.length % 2 == 1 { payload.append(0) }
    payload += table + values
    let pointer = u32(tableStart)
    payload.replaceSubrange((tiffStart + 4)..<(tiffStart + 8), with: pointer)
    replacePayload(of: segment, with: payload)
    print("IFD0 写入 \(added.count) 个标签")
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

switch mode {
case "--ifd0":
    ifd0Entries(Array(rest.dropFirst()))
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
    let content = Array(rest[2].utf8)
    guard content.count + 2 <= 0xFFFF else { die("内容太长，一个段放不下") }
    guard let layout = JPEGLayout(bytes) else { die("不是 JPEG") }
    // 插在最后一个 APPn 之后；没有 APPn 就紧跟 SOI。
    let at = layout.segments.prefix { (0xE0...0xEF).contains($0.marker) }.last?.payload.upperBound ?? 2
    let length = content.count + 2
    bytes.insert(contentsOf: [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + content, at: at)
    print("插入了 FF\(rest[1].uppercased()) 段（\(content.count) 字节）")
case "--append":
    bytes.append(contentsOf: Array(rest[1].utf8))
    print("追加了 \(rest[1].utf8.count) 字节")
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
