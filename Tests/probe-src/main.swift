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
let usage = """
    用法: probe [--no-repair] <文件> <键路径>
          probe --aux <文件> <辅助图类型>            宽x高 与像素格式
          probe --aux-tags <文件> <辅助图类型>       辅助图附带的元数据标签，一行一个
          probe --aux-diff <源> <产物> <辅助图类型>  两边辅助图数据的最大差（8 位级数）
          probe --headroom <文件>                    按 HDR 解码的内容余量
    辅助图类型是 kCGImageAuxiliaryDataType 后面那一截，如 HDRGainMap、Depth。
    """
func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

// 辅助图与 HDR 的几种问法。读不出来一律打印哨兵（<无> 或 <无法读取>），selftest 的
// check_same 拒绝拿哨兵当期望值。
if let mode = args.first, ["--aux", "--aux-tags", "--aux-diff", "--headroom"].contains(mode) {
    let operands = Array(args.dropFirst())
    func source(_ path: String) -> CGImageSource {
        guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(s) > 0 else {
            print("<无法读取>")
            exit(1)
        }
        return s
    }
    func auxiliary(_ path: String, _ name: String) -> [CFString: Any]? {
        guard let type = auxiliaryDataTypes.first(where: { ($0 as String) == "kCGImageAuxiliaryDataType" + name })
        else { die("不认识的辅助图类型：\(name)\n\(usage)") }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source(path), 0, type) as? [CFString: Any]
    }
    func description(_ info: [CFString: Any]) -> (width: Int, height: Int, rowBytes: Int, format: Int)? {
        guard let d = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
              let w = d[kCGImagePropertyWidth] as? Int, let h = d[kCGImagePropertyHeight] as? Int,
              let r = d[kCGImagePropertyBytesPerRow] as? Int, let f = d[kCGImagePropertyPixelFormat] as? Int
        else { return nil }
        return (w, h, r, f)
    }
    switch (mode, operands.count) {
    case ("--aux", 2):
        guard let info = auxiliary(operands[0], operands[1]), let d = description(info) else { print("<无>"); exit(0) }
        print("\(d.width)x\(d.height) \(d.format)")
    case ("--aux-tags", 2):
        // 和 --verify 同一套展开（xmpTags）与同一张易变键表：iio: 开头的是 ImageIO
        // 给自己打的标记，不是辅助图的元数据。
        guard let info = auxiliary(operands[0], operands[1]) else { print("<无>"); exit(0) }
        let metadata = info[kCGImageAuxiliaryDataInfoMetadata].map { $0 as! CGImageMetadata }
        let tags = metadata.map(xmpTags) ?? [:]
        print(tags.filter { !isVolatile($0.key) }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    case ("--aux-diff", 3):
        // 去掉行尾填充后逐像素比。8 位类型直接取差；32 位浮点类型换算成源的取值
        // 范围的 1/255 为一级（JPEG 里的深度图、视差图就是按这个量化成 8 位存的），
        // 两种类型于是用同一把尺子。尺寸、像素格式不一致就是 <无法读取>。
        guard let a = auxiliary(operands[0], operands[2]), let b = auxiliary(operands[1], operands[2]),
              let da = description(a), let db = description(b),
              da.width == db.width, da.height == db.height, da.format == db.format,
              let pa = a[kCGImageAuxiliaryDataInfoData] as? Data, let pb = b[kCGImageAuxiliaryDataInfoData] as? Data
        else { print("<无法读取>"); exit(1) }
        let bytesPerPixel = da.rowBytes / da.width
        guard bytesPerPixel == 1 || bytesPerPixel == 4, da.width * bytesPerPixel <= min(da.rowBytes, db.rowBytes),
              pa.count >= da.rowBytes * da.height, pb.count >= db.rowBytes * db.height
        else { print("<无法读取>"); exit(1) }
        func value(_ data: Data, _ rowBytes: Int, _ x: Int, _ y: Int) -> Double {
            data.withUnsafeBytes { raw in
                let at = y * rowBytes + x * bytesPerPixel
                return bytesPerPixel == 1 ? Double(raw[at]) : Double(raw.loadUnaligned(fromByteOffset: at, as: Float.self))
            }
        }
        var low = Double.infinity, high = -Double.infinity, largest = 0.0
        for y in 0..<da.height {
            for x in 0..<da.width {
                let v = value(pa, da.rowBytes, x, y)
                low = min(low, v); high = max(high, v)
                largest = max(largest, abs(v - value(pb, db.rowBytes, x, y)))
            }
        }
        let step = bytesPerPixel == 1 ? 1 : (high - low) / 255
        guard step > 0 else { print("<无法读取>"); exit(1) }
        print(Int((largest / step).rounded()))
    case ("--headroom", 1):
        guard #available(macOS 15.0, *),
              let image = CGImageSourceCreateImageAtIndex(source(operands[0]), 0,
                                                          [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)
        else { print("<无法读取>"); exit(1) }
        print(String(format: "%.2f", image.contentHeadroom))
    default:
        die(usage)
    }
    exit(0)
}

let noRepair = args.contains("--no-repair")
args.removeAll { $0 == "--no-repair" }
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
