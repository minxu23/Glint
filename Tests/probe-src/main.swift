// 读取图片里某个元数据字段的值，供 selftest.sh 断言。
// 用法串是下面的 `usage` 常量，不在注释里另写一份（fixture 那边漂移过）。
// 例如: probe a.heic '{GPS}/Latitude'
//
// 默认问的是「--verify 看得见什么」。--no-repair 只关掉 UserComment 那一处修补，
// 键空间的其余部分（含 XMP 层）完全一样：UserComment 那一轮的前提恰恰是
// 「ImageIO 读不出这种写法」，用默认模式问就会读到修补后的值，前提自然不成立。
//
// 这个旗标曾经叫 --raw，含义是"只有属性字典"，于是它也不含 XMP——而第 6 轮
// 只需要不修补。结果 fix 5 刚消除的那个失效形状（XMP 键无条件返回「无」、
// 不报错不提示）被原样搬到旗标后面。现在两种模式走的是同一个 metadataKeySpace，
// 差别只有那一个布尔量，没有第二份键空间可漏。
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
let noRepair = args.contains("--no-repair")
args.removeAll { $0 == "--no-repair" }
let usage = "用法: probe [--no-repair] <文件> <键路径>"
guard args.count == 2 else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: args[0])
let wanted = args[1]

guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
    print("<无法读取>")
    exit(1)
}

// 「整个文件读不出来」和「这个键不存在」必须分开报。CGImageSourceCreateWithURL
// 对垃圾文件也会成功，真正的失败点在 CopyPropertiesAtIndex 返回 nil，而
// imageProperties 把它吞成了 `[:]`（它对 CopyProperties 的 nil 取 `?? [:]`）。两者都打印
// 「无」时，第 6 轮那条前提断言（seen = <无> 即算「确认 ImageIO 读不出这种写法」）
// 在文件整体读不出来时也会通过——正是本项目反复在堵的静默通道。
// 任何能读的图都至少有 PixelWidth 这类键，所以空键空间只会是读取失败。
let space = metadataKeySpace(of: src, url: url, repairing: !noRepair)
guard !space.isEmpty else {
    print("<无法读取>")
    exit(1)
}
print(space[wanted] ?? "<无>")
