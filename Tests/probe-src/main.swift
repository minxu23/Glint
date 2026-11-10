// 读取图片里某个元数据字段的值，供 selftest.sh 断言。
// 用法串是下面的 `usage` 常量，不在注释里另写一份。
// 例如: probe a.heic '{GPS}/Latitude'
//
// 默认问的是「--verify 看得见什么」。--no-repair 只关掉 UserComment 那一处修补，
// 键空间的其余部分（含 XMP 层）完全一样：UserComment 那一轮的前提恰恰是
// 「ImageIO 读不出这种写法」，用默认模式问就会读到修补后的值，前提自然不成立。
// 两种模式走的是同一个 metadataKeySpace，差别只有那一个布尔量。
//
// 键空间用的是 Core 里 --verify 同一个 metadataKeySpace，不另写一份：校验探针
// 和校验本身对"有哪些键、键路径长什么样"的理解必须一致，否则断言的是另一回事。
// 自己拼一份最容易漏掉 XMP 那一层，漏了就对每个 `XMP/...` 查询都答「无」，
// 不报错、不提示，看上去就像"这张图里没有这个字段"。

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
// 「无」时，selftest 里不合规范 UserComment 那一轮的前提断言（seen = <无> 即算
// 「确认 ImageIO 读不出这种写法」）在文件整体读不出来时也会通过。
// 空键空间一律当作读取失败。
let space = metadataKeySpace(of: src, url: url, repairing: !noRepair)
guard !space.isEmpty else {
    print("<无法读取>")
    exit(1)
}
print(space[wanted] ?? "<无>")
