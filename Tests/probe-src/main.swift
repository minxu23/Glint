// 读取图片里某个元数据字段的值，供 selftest.sh 断言。
// 用法: probe [--raw] <文件> <键路径>   例如: probe a.heic '{GPS}/Latitude'
//
// 默认问的是「--verify 看得见什么」：属性字典 + UserComment 修补 + XMP 包。
// --raw 问的是「ImageIO 自己读得出什么」：只有属性字典，不修补、不含 XMP。
// 两者是不同的问题，断言时必须挑对：UserComment 那一轮的前提恰恰是
// 「ImageIO 读不出这种写法」，用默认模式问就会读到修补后的值，前提自然不成立。
//
// 键空间用的是 Core 里 --verify 同一个 metadataKeySpace，不另写一份：校验探针
// 和校验本身对"有哪些键、键路径长什么样"的理解必须一致，否则断言的是另一回事。
//
// 这条原先只做到一半：当时自己拼了 CGImageSourceCopyPropertiesAtIndex + flatten，
// 漏了 --verify 还会 merge 的 XMP 那一层，于是任何 `XMP/...` 查询都无条件
// 返回「无」。它不报错、不提示，看上去就像"这张图里没有这个字段"——
// 本项目真有一次据此得出过错误结论。

import Foundation
import ImageIO

var args = Array(CommandLine.arguments.dropFirst())
let raw = args.contains("--raw")
args.removeAll { $0 == "--raw" }
guard args.count == 2 else {
    FileHandle.standardError.write(Data("用法: probe [--raw] <文件> <键路径>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: args[0])
let wanted = args[1]

guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
    print("<无法读取>")
    exit(1)
}

let flat: [String: String]
if raw {
    guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
        print("<无法读取>")
        exit(1)
    }
    var f: [String: String] = [:]
    flatten(props, into: &f)
    flat = f
} else {
    flat = metadataKeySpace(of: src, url: url)
}
print(flat[wanted] ?? "<无>")
