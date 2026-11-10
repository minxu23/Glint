// 生成一张带完整元数据的测试 JPEG：拍摄时间、GPS 位置、备注、相机参数、
// IPTC 与 XMP 字段一应俱全，供 selftest.sh 校验转换后是否原样保留。
//
// 用法串是下面的 `usage` 常量，不在注释里另写一份：改了旗标只改一处就够，
// 否则必然漂移（实测漂移过——加了 --no-exif-offset 之后 stderr 那份还是旧的）。
// 各旗标的含义：
//   --lossy  额外写入一个转成 HEIF 必定丢失的字段（IPTC EditStatus，IIM 2:07
//            在 HEIF 里没有对应容器，也没有等价的 XMP 映射）。用来测试
//            --delete-original 在校验不通过时是否真的保留源文件——没有这样
//            一张图，那条安全边界就只能靠读代码确认。
//   --no-exif-offset
//            不写 EXIF OffsetTimeOriginal。源里的 UTC 偏移于是只剩 IIM
//            TimeCreated 的后缀（`184207+0800`），而目标 HEIC 里既没有
//            OffsetTime* 也没有 IIM 容器——offsetSurvives 能找到它的唯一地方
//            是 ImageIO 合成的 XMP/photoshop:DateCreated。默认那张图里
//            OffsetTimeOriginal 自己就承载了偏移，于是 XMP 那条腿怎么写都
//            不影响结果，整条分支是空跑。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var args = Array(CommandLine.arguments.dropFirst())
let lossy = args.contains("--lossy")
let noExifOffset = args.contains("--no-exif-offset")
args.removeAll { $0 == "--lossy" || $0 == "--no-exif-offset" }
let usage = "用法: fixture [--lossy] [--no-exif-offset] <输出.jpg>"
guard let path = args.first else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    exit(2)
}
let w = 1200, h = 900
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
for i in 0..<30 {
    ctx.setFillColor(red: Double(i) / 30, green: 0.45, blue: 1 - Double(i) / 30, alpha: 1)
    ctx.fill(CGRect(x: i * (w / 30), y: 0, width: w / 30, height: h))
}

var props: [CFString: Any] = [
    kCGImagePropertyOrientation: 1,
    kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Canon",
        kCGImagePropertyTIFFModel: "Canon EOS R5",
        kCGImagePropertyTIFFImageDescription: "西湖日落 sunset at West Lake",
        kCGImagePropertyTIFFArtist: "测试作者",
        kCGImagePropertyTIFFCopyright: "(C) 2024 测试",
        kCGImagePropertyTIFFDateTime: "2024:09:15 18:42:07",
    ],
    kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2024:09:15 18:42:07",
        kCGImagePropertyExifDateTimeDigitized: "2024:09:15 18:42:07",
        kCGImagePropertyExifSubsecTimeOriginal: "42",
        // 写得长一些，好让 mangle-tool 有足够空间就地改写成不合规范的样本。
        kCGImagePropertyExifUserComment: "备注：这是拍摄当时写下的一段说明文字，用于测试",
        kCGImagePropertyExifFNumber: 1.8,
        kCGImagePropertyExifExposureTime: 0.004,
        kCGImagePropertyExifISOSpeedRatings: [400],
        kCGImagePropertyExifFocalLength: 50.0,
        kCGImagePropertyExifLensModel: "RF50mm F1.2 L USM",
        kCGImagePropertyExifBodySerialNumber: "SN-TEST-0001",
    ],
    kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 30.242361,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 120.148694,
        kCGImagePropertyGPSLongitudeRef: "E",
        kCGImagePropertyGPSAltitude: 12.5,
        kCGImagePropertyGPSAltitudeRef: 0,
        kCGImagePropertyGPSDateStamp: "2024:09:15",
        kCGImagePropertyGPSTimeStamp: "10:42:07",
        kCGImagePropertyGPSImgDirection: 271.3,
        kCGImagePropertyGPSImgDirectionRef: "T",
    ],
    kCGImagePropertyIPTCDictionary: [
        kCGImagePropertyIPTCCaptionAbstract: "IPTC 备注字段",
        kCGImagePropertyIPTCKeywords: ["sunset", "hangzhou"],
        kCGImagePropertyIPTCCity: "杭州",
        kCGImagePropertyIPTCCountryPrimaryLocationName: "中国",
        kCGImagePropertyIPTCByline: "测试作者",
        kCGImagePropertyIPTCStarRating: 5,
        // IIM 的日期与时间：HEIF 没有 IIM 容器，这两条转换后必然消失，
        // 由 EXIF 的 DateTimeOriginal + OffsetTimeOriginal 承载
        // （加 --no-exif-offset 时偏移只剩 XMP 那条腿，见文件头）。
        // --verify 的等价判定（equivalentCarries）此前只有单元测试跑在手搭的
        // 字典上，目标侧的键拼法从没跟真实 ImageIO 输出对过——这两行把它接上。
        // 时间带着 +0800，正好也覆盖"偏移必须在目标里找得到"那条。
        kCGImagePropertyIPTCDateCreated: "20240915",
        kCGImagePropertyIPTCTimeCreated: "184207+0800",
    ],
    kCGImageDestinationLossyCompressionQuality: 0.95,
]

if lossy, var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
    iptc[kCGImagePropertyIPTCEditStatus] = "已编辑"
    props[kCGImagePropertyIPTCDictionary] = iptc
}

// 默认写上；--no-exif-offset 时不写，让 IIM 时间后缀成为偏移的唯一源头。
if !noExifOffset, var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
    exif[kCGImagePropertyExifOffsetTimeOriginal] = "+08:00"
    props[kCGImagePropertyExifDictionary] = exif
}

let url = URL(fileURLWithPath: path)
guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("无法创建 JPEG 编码器\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dst, ctx.makeImage()!, props as CFDictionary)
guard CGImageDestinationFinalize(dst) else {
    FileHandle.standardError.write(Data("写入测试图失败\n".utf8))
    exit(1)
}
print("已生成测试图: \(path)")
