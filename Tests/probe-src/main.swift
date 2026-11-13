// 读取图片里某个元数据字段的值，供 selftest.sh 断言。
// 用法串是下面的 `usage` 常量，不在注释里另写一份。
// 例如: probe a.heic '{GPS}/Latitude'
//
// 默认问的是「--verify 看得见什么」。--no-repair 只关掉 UserComment 那一处修补，
// 键空间的其余部分（含 XMP 层）完全一样：UserComment 那一轮的前提恰恰是
// 「ImageIO 读不出这种写法」，用默认模式问就会读到修补后的值，前提自然不成立。
// 两种模式走的是同一个 metadataKeySpace，差别只有那一个布尔量。
//
// 键空间用的是 Eclose 里 --verify 同一个 metadataKeySpace，不另写一份：校验探针
// 和校验本身对"有哪些键、键路径长什么样"的理解必须一致，否则断言的是另一回事。
// 自己拼一份最容易漏掉 XMP 那一层，漏了就对每个 `XMP/...` 查询都答「无」，
// 不报错、不提示，看上去就像"这张图里没有这个字段"。

@testable import Eclose
import Foundation
import ImageIO

var args = Array(CommandLine.arguments.dropFirst())
let usage = """
    用法: probe [--no-repair] <文件> <键路径>
          probe --aux <文件> <辅助图类型>            宽x高 与像素格式
          probe --aux-tags <文件> <辅助图类型>       辅助图附带的元数据标签，一行一个
          probe --aux-diff <源> <产物> <辅助图类型>  两边辅助图数据的最大差（8 位级数）
          probe --headroom <文件>                    按 HDR 解码的内容余量
          probe --hdr-peak <文件>                    按 HDR 解码后最亮的线性亮度
          probe --aux-items <文件.heic>              HEIF 里辅助图项的个数（iref 的 auxl 条数）
          probe --raw-exif <文件> <标签十六进制>     原始 EXIF 里 IFD0/Exif 子 IFD 的这个标签，
                                                     每个条目一行：IFD 类型 个数 值的十六进制
          probe --exif-same <源.jpg> <产物.heic>     产物 Exif 项里的 TIFF 与源 EXIF 段的是否逐字节相同：
                                                     「相同」、「只差备注改写」（isUserCommentRewrite）或
                                                     「不同（N 字节 → M 字节，第 K 个字节起不同）」
          probe --exif-at-end <文件.heic>            Exif 项是否结束在文件末尾：「末尾」或「不在末尾」
          probe --pixels <文件>                      解码出的 8 位 RGBA 像素的宽高与散列（FNV-1a 64 位）
    辅助图类型是 kCGImageAuxiliaryDataType 后面那一截，如 HDRGainMap、Depth。
    """
func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

// HEIF 里有几个辅助图项：数 meta → iref 里的 auxl 引用（每个辅助图项一条，指向主图）。
// ImageIO 的视图每种辅助图只给一份，同一张增益图写了两份在那里看不出来，只能数盒子。
if args.first == "--aux-items", args.count == 2 {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          case .success(let children) = heifMetaChildren([UInt8](data)) else { print("<无法读取>"); exit(1) }
    let bytes = [UInt8](data)
    guard let iref = children.first(where: { $0.type == "iref" }) else { print(0); exit(0) }
    // iref 是 FullBox：1 字节版本、3 字节标志，之后是一串引用盒子。
    guard iref.content.count >= 4,
          let references = heifBoxes(bytes, in: (iref.content.lowerBound + 4)..<iref.content.upperBound)
    else { print("<无法读取>"); exit(1) }
    print(references.filter { $0.type == "auxl" }.count)
    exit(0)
}

// 原始 EXIF 条目：JPEG 读 APP1 的 TIFF，HEIF 读 Exif 项，和 --verify 的原始清点同一套解析。
// 用来断言 ImageIO 视图读不出的值（如非 33 字节的 ImageUniqueID）逐字节带过去了。
if args.first == "--raw-exif", args.count == 3 {
    guard let tag = Int(args[2], radix: 16) else { die(usage) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else { print("<无法读取>"); exit(1) }
    let bytes = [UInt8](data)
    let tiff: TIFFStructure?
    if let jpeg = TIFFStructure(jpeg: bytes) {
        tiff = jpeg
    } else if case .tiff(let heif) = heifExif(bytes) {
        tiff = heif
    } else {
        tiff = nil
    }
    guard let tiff else { print("<无法读取>"); exit(1) }
    let found = rawExifEntries(tiff).filter { $0.space == .main && $0.tag == tag }
    guard !found.isEmpty else { print("<无>"); exit(0) }
    for e in found {
        let hex = e.value.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "值读不出"
        print("\(e.ifd) \(tiffTypeName(e.type)) \(e.count) \(hex)")
    }
    exit(0)
}

// EXIF 数据块：源取 APP1 里 `Exif\0\0` 之后的全部字节，产物取 Exif 项里 TIFF 头偏移之后的
// 全部字节，直接逐字节比，和 --verify 的比较不共用代码。不相同时再问「是不是源的备注改写」，
// 这一问用的是 --verify 同一个 isUserCommentRewrite，它自己的对错由单测管。
if args.first == "--exif-same", args.count == 3 {
    guard let a = try? [UInt8](Data(contentsOf: URL(fileURLWithPath: args[1]))),
          let b = try? [UInt8](Data(contentsOf: URL(fileURLWithPath: args[2]))) else { print("<无法读取>"); exit(1) }
    guard let s = TIFFStructure(jpeg: a), case .tiff(let d) = heifExif(b) else { print("<无>"); exit(0) }
    let x = Array(s.bytes[s.base..<(s.base + s.length)]), y = Array(d.bytes[d.base..<(d.base + d.length)])
    if x == y { print("相同"); exit(0) }
    if let image = CGImageSourceCreateWithData(Data(a) as CFData, nil),
       carriedTIFFMatches(source: x, product: y,
                          comment: SourceUserComment(imageProperties(image), reading: rawExifUserComment(in: a))) {
        print("只差备注改写"); exit(0)
    }
    let k = (0..<min(x.count, y.count)).first { x[$0] != y[$0] } ?? min(x.count, y.count)
    print("不同（\(x.count) 字节 → \(y.count) 字节，第 \(k + 1) 个字节起不同）")
    exit(0)
}
if args.first == "--exif-at-end", args.count == 2 {
    guard let b = try? [UInt8](Data(contentsOf: URL(fileURLWithPath: args[1]))) else { print("<无法读取>"); exit(1) }
    guard case .tiff = heifExif(b) else { print("<无>"); exit(0) }
    print(heifExifEndsAtFileEnd(b) ? "末尾" : "不在末尾")
    exit(0)
}
// 按方向转正之前的原始像素：解码第 0 张，画进 8 位 sRGB RGBA，散列全部字节。
if args.first == "--pixels", args.count == 2 {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(s, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { print("<无法读取>"); exit(1) }
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { print("<无法读取>"); exit(1) }
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in pixels { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    print("\(w)x\(h) \(String(hash, radix: 16))")
    exit(0)
}

// 辅助图与 HDR 的几种问法。读不出来一律打印哨兵（<无> 或 <无法读取>），selftest 的
// check_same 拒绝拿哨兵当期望值。
if let mode = args.first, ["--aux", "--aux-tags", "--aux-diff", "--headroom", "--hdr-peak"].contains(mode) {
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
    case ("--hdr-peak", 1):
        // 内容余量只是增益图元数据里写的数，增益图本身坏了它照样是那个数；按 HDR 解码
        // 出来的像素才说明增益图真的在起作用。画进扩展范围的线性 Display P3，取最亮
        // 像素的亮度（Rec. 709 系数），单位是 SDR 白的倍数，打印成百分数的整数。
        guard #available(macOS 15.0, *),
              let image = CGImageSourceCreateImageAtIndex(source(operands[0]), 0,
                                                          [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        else { print("<无法读取>"); exit(1) }
        let w = image.width, h = image.height
        var pixels = [Float](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { print("<无法读取>"); exit(1) }
        var peak: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            peak = max(peak, 0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2])
        }
        print(Int((peak * 100).rounded()))
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
