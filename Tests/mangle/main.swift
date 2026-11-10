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
//   mangle --strip-trailer <文件.jpg>
//       截掉 EOI 之后的全部字节。

import Foundation

let usage = """
用法: mangle <文件.jpg> <备注文本>
      mangle --replace <文件.jpg> <旧文本> <新文本>
      mangle --segment <文件.jpg> <标记十六进制> <内容>
      mangle --append <文件.jpg> <内容>
      mangle --strip-trailer <文件.jpg>
"""

func die(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { die(usage, 2) }
let mode = first.hasPrefix("--") ? first : ""
let rest = mode.isEmpty ? args : Array(args.dropFirst())
let expected = ["": 2, "--replace": 3, "--segment": 3, "--append": 2, "--strip-trailer": 1]
guard let want = expected[mode], rest.count == want else { die(usage, 2) }

let url = URL(fileURLWithPath: rest[0])
guard let original = try? Data(contentsOf: url) else { die("读不了 \(url.path)") }
var bytes = [UInt8](original)

switch mode {
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
