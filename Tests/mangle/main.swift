// 测试夹具：把一张 JPEG 的 EXIF UserComment 就地改写成"不合规范"的形式——
// 去掉 EXIF 要求的 8 字节字符集前缀，直接写裸 UTF-8。不少安卓机型就是这么写的，
// ImageIO 认不出来会当作字段不存在。用它来验证工具能把这种备注捞回来。
//
// 用法: mangle <文件.jpg> <备注文本>

import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else {
    FileHandle.standardError.write(Data("用法: mangle <文件.jpg> <备注文本>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: args[0])
let comment = Array(args[1].utf8)

guard var data = try? Data(contentsOf: url) else {
    FileHandle.standardError.write(Data("读不了 \(url.path)\n".utf8))
    exit(1)
}
guard let range = exifUserCommentRange(in: data) else {
    FileHandle.standardError.write(Data("这张图里没有 UserComment 字段\n".utf8))
    exit(1)
}
guard comment.count <= range.count else {
    FileHandle.standardError.write(Data("备注太长，放不进原字段（\(range.count) 字节）\n".utf8))
    exit(1)
}

// 字段长度保持不变，只换内容，这样 EXIF 里其它偏移都不用动。
var replacement = comment
replacement.append(contentsOf: [UInt8](repeating: 0, count: range.count - comment.count))
data.replaceSubrange(range, with: replacement)

try data.write(to: url)
print("已改写 \(url.lastPathComponent) 的 UserComment 为无前缀 UTF-8（\(range.count) 字节字段）")
