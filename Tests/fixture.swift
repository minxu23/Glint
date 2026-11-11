// 生成一张带完整元数据的测试 JPEG：拍摄时间、GPS 位置、备注、相机参数、
// IPTC 与 XMP 字段一应俱全，供 selftest.sh 校验转换后是否原样保留。
//
// 用法串是下面的 `usage` 常量，不在注释里另写一份：改了旗标只改一处就够。
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
//   --cmyk   像素画在 Generic CMYK 色彩空间里，写出 CMYK JPEG（带 CMYK 的 ICC）。
//            转成 HEIF 后色彩模型和描述文件都会变成 RGB/sRGB，校验必须报出来。
//   --rich-xmp
//            XMP 包里再加上属性字典表达不了的几类标签：dc:title 的多语言、
//            lr:hierarchicalSubject、人脸区域（mwg-rs:Regions，含 Name）、
//            xmpMM:*、一个自定义命名空间。默认那张只有一个纯 XMP 键 xmp:Label。
//   --extended-xmp
//            再加一个扩展 XMP 段（APP1 `http://ns.adobe.com/xmp/extension/`），
//            里面有一个只存在于扩展包的标签 jt:Extended。
//   --ms-rating
//            XMP 包里再加一个 MicrosoftPhoto:Rating="99"：Windows 百分制评级在 XMP
//            里的字段，对应 EXIF IFD0 的 RatingPercent（0x4749）。
//   --no-text
//            不写描述、作者、备注、关键词和星级评分（TIFF ImageDescription/Artist、
//            EXIF UserComment、IPTC Caption/Keywords/Byline/StarRating）。目标里于是
//            没有任何能承载 Windows XP 标签和评级的字段。
//   --aux <种类>
//            再加一张辅助图，可以重复。种类：depth（深度，32 位浮点）、disparity
//            （视差，32 位浮点）、matte（人像蒙版，8 位）、skin（语义分割的皮肤蒙版，
//            8 位）、gainmap（苹果增益图，8 位，带 HDRGainMap:HDRGainMapVersion 与
//            HDRGainMap:HDRGainMapHeadroom 两个元数据标签）。内容是有纹理的平滑图案，
//            每种的图案不同；宽 150 不是对齐宽度，ImageIO 读回时每行带填充。
//            加辅助图要用 ImageIO 从头写一遍 JPEG，那一遍不带上面并进 XMP 包的标签。
//   --thumbnail
//            内嵌一张缩略图（kCGImageDestinationEmbedThumbnail）。

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

var args = Array(CommandLine.arguments.dropFirst())
let lossy = args.contains("--lossy")
let noExifOffset = args.contains("--no-exif-offset")
let cmyk = args.contains("--cmyk")
let richXMP = args.contains("--rich-xmp")
let extendedXMP = args.contains("--extended-xmp")
let msRating = args.contains("--ms-rating")
let noText = args.contains("--no-text")
let thumbnail = args.contains("--thumbnail")
args.removeAll {
    ["--lossy", "--no-exif-offset", "--cmyk", "--rich-xmp", "--extended-xmp", "--ms-rating", "--no-text",
     "--thumbnail"].contains($0)
}
let usage = "用法: fixture [--lossy] [--no-exif-offset] [--cmyk] [--rich-xmp] [--extended-xmp] [--ms-rating]"
    + " [--no-text] [--aux depth|disparity|matte|skin|gainmap]... [--thumbnail] <输出.jpg>"
var auxKinds: [String] = []
while let at = args.firstIndex(of: "--aux") {
    guard at + 1 < args.count else {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
    auxKinds.append(args[at + 1])
    args.removeSubrange(at...(at + 1))
}
guard let path = args.first else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    exit(2)
}
let w = 1200, h = 900
let cs = CGColorSpace(name: cmyk ? CGColorSpace.genericCMYK : CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: (cmyk ? CGImageAlphaInfo.none : .noneSkipLast).rawValue)!
for i in 0..<30 {
    let t = Double(i) / 30
    if cmyk {
        ctx.setFillColor(cyan: t, magenta: 0.45, yellow: 1 - t, black: 0.1, alpha: 1)
    } else {
        ctx.setFillColor(red: t, green: 0.45, blue: 1 - t, alpha: 1)
    }
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
        // 这两行让 --verify 的等价判定（equivalentCarries）跑在真实 ImageIO 输出上，
        // 而不只是单元测试里手搭的字典。时间带着 +0800，也覆盖"偏移必须在目标里
        // 找得到"那条。
        kCGImagePropertyIPTCDateCreated: "20240915",
        kCGImagePropertyIPTCTimeCreated: "184207+0800",
    ],
    kCGImageDestinationLossyCompressionQuality: 0.95,
]

if noText {
    let drop: [(CFString, [CFString])] = [
        (kCGImagePropertyTIFFDictionary, [kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFArtist]),
        (kCGImagePropertyExifDictionary, [kCGImagePropertyExifUserComment]),
        (kCGImagePropertyIPTCDictionary, [kCGImagePropertyIPTCCaptionAbstract, kCGImagePropertyIPTCKeywords,
                                          kCGImagePropertyIPTCByline, kCGImagePropertyIPTCStarRating]),
    ]
    for (dictionary, keys) in drop {
        guard var d = props[dictionary] as? [CFString: Any] else { die("夹具里没有 \(dictionary)") }
        for k in keys { d.removeValue(forKey: k) }
        props[dictionary] = d
    }
}

if lossy, var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
    iptc[kCGImagePropertyIPTCEditStatus] = "已编辑"
    props[kCGImagePropertyIPTCDictionary] = iptc
}

// 默认写上；--no-exif-offset 时不写，让 IIM 时间后缀成为偏移的唯一源头。
if !noExifOffset, var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
    exif[kCGImagePropertyExifOffsetTimeOriginal] = "+08:00"
    props[kCGImagePropertyExifDictionary] = exif
}

// 只存在于 XMP 包里、属性字典里没有对应字段的标签。默认只有 xmp:Label 一个；
// --rich-xmp 换成下面这一整包。
let xmpNamespaces = """
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
    xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
    xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"
    xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#"
    xmlns:stDim="http://ns.adobe.com/xap/1.0/sType/Dimensions#"
    xmlns:jt="http://example.com/jpeg2heif/test/1.0/"
    xmlns:MicrosoftPhoto="http://ns.microsoft.com/photo/1.0/"
"""
let richBody = """
    xmpMM:DocumentID="xmp.did:0001"
    xmpMM:InstanceID="xmp.iid:0002"
    xmpMM:OriginalDocumentID="xmp.did:0000"
    jt:Custom="自定义命名空间的值">
   <dc:title><rdf:Alt>
     <rdf:li xml:lang="x-default">西湖</rdf:li>
     <rdf:li xml:lang="en-US">West Lake</rdf:li>
     <rdf:li xml:lang="zh-CN">西湖日落</rdf:li>
   </rdf:Alt></dc:title>
   <lr:hierarchicalSubject><rdf:Bag>
     <rdf:li>地点|中国|杭州</rdf:li><rdf:li>主题|日落</rdf:li>
   </rdf:Bag></lr:hierarchicalSubject>
   <mwg-rs:Regions rdf:parseType="Resource">
     <mwg-rs:AppliedToDimensions stDim:w="1200" stDim:h="900" stDim:unit="pixel"/>
     <mwg-rs:RegionList><rdf:Bag><rdf:li rdf:parseType="Resource">
       <mwg-rs:Name>张三</mwg-rs:Name><mwg-rs:Type>Face</mwg-rs:Type>
       <mwg-rs:Area stArea:x="0.5" stArea:y="0.5" stArea:w="0.1" stArea:h="0.1" stArea:unit="normalized"/>
     </rdf:li></rdf:Bag></mwg-rs:RegionList>
   </mwg-rs:Regions>
  </rdf:Description>
"""
let xmpPacket = """
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
\(xmpNamespaces)
    \(msRating ? "MicrosoftPhoto:Rating=\"99\"\n    " : "")xmp:Label="红色"\(richXMP ? "\n" + richBody : "/>")
 </rdf:RDF>
</x:xmpmeta>
"""

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

// 先按属性字典编码到内存，再只替换 XMP 那一个 APP1 段：把上面的标签并进 ImageIO
// 写出的 XMP 包，其余字节保持这一次编码的原样。CopyImageSource 也能并 XMP，但它会
// 把 EXIF 重新序列化一遍。
//
// 上面属性字典里的备注在这一次编码时就已经存不全：ImageIO 写 UserComment 时按字符数
// 当字节数算，非 ASCII 的备注只存下前一半左右（README「已知限制」）。所以断言要拿
// 源文件里实际存下的值来比（用 probe 读），不要拿属性字典里的全文。
let encoded = NSMutableData()
guard let first = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
    die("无法创建 JPEG 编码器")
}
CGImageDestinationAddImage(first, ctx.makeImage()!, props as CFDictionary)
guard CGImageDestinationFinalize(first) else { die("写入测试图失败") }
var bytes = [UInt8](encoded as Data)

// 定位 XMP 段：逐段走到 SOS 为止，找内容以 XMP 标识开头的 APP1。
let xmpID: [UInt8] = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]
var xmpSegment: Range<Int>?      // 整段（含 FF E1 与长度字段）
var at = 2
while at + 4 <= bytes.count, bytes[at] == 0xFF, bytes[at + 1] != 0xDA {
    let payload = (at + 4)..<(at + 2 + (Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])))
    if bytes[at + 1] == 0xE1, payload.count >= xmpID.count,
       Array(bytes[payload.lowerBound..<(payload.lowerBound + xmpID.count)]) == xmpID {
        xmpSegment = at..<payload.upperBound
        break
    }
    at = payload.upperBound
}
guard let segment = xmpSegment,
      let written = CGImageMetadataCreateFromXMPData(
          Data(bytes[(segment.lowerBound + 4 + xmpID.count)..<segment.upperBound]) as CFData),
      let merged = CGImageMetadataCreateMutableCopy(written),
      let extra = CGImageMetadataCreateFromXMPData(Data(xmpPacket.utf8) as CFData)
else { die("夹具的 XMP 包读不出来") }
for (prefix, uri) in [("lr", "http://ns.adobe.com/lightroom/1.0/"), ("xmpMM", "http://ns.adobe.com/xap/1.0/mm/"),
                      ("mwg-rs", "http://www.metadataworkinggroup.com/schemas/regions/"),
                      ("stArea", "http://ns.adobe.com/xmp/sType/Area#"),
                      ("stDim", "http://ns.adobe.com/xap/1.0/sType/Dimensions#"),
                      ("jt", "http://example.com/jpeg2heif/test/1.0/")]
    + (msRating ? [("MicrosoftPhoto", "http://ns.microsoft.com/photo/1.0/")] : []) {
    CGImageMetadataRegisterNamespaceForPrefix(merged, uri as CFString, prefix as CFString, nil)
}
CGImageMetadataEnumerateTagsUsingBlock(extra, nil, nil) { path, tag in
    CGImageMetadataSetTagWithPath(merged, nil, path, tag)
}
func app1(_ payload: [UInt8]) -> [UInt8] {
    let n = payload.count + 2
    return [0xFF, 0xE1, UInt8(n >> 8), UInt8(n & 0xFF)] + payload
}
// 扩展 XMP：主包里记下扩展包的 MD5（xmpNote:HasExtendedXMP），扩展包放进紧跟其后
// 的 APP1 `http://ns.adobe.com/xmp/extension/` 段：标识 + 32 位 GUID + 全长 + 偏移 + 内容。
var extensionSegment: [UInt8] = []
if extendedXMP {
    let body = Array("""
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
    <rdf:Description rdf:about="" xmlns:jt="http://example.com/jpeg2heif/test/1.0/" \
    jt:Extended="只在扩展包里的值"/></rdf:RDF></x:xmpmeta>
    """.utf8)
    let guid = Insecure.MD5.hash(data: body).map { String(format: "%02X", $0) }.joined()
    let note = "http://ns.adobe.com/xmp/note/" as CFString
    guard CGImageMetadataRegisterNamespaceForPrefix(merged, note, "xmpNote" as CFString, nil),
          let tag = CGImageMetadataTagCreate(note, "xmpNote" as CFString, "HasExtendedXMP" as CFString,
                                             .string, guid as CFString),
          CGImageMetadataSetTagWithPath(merged, nil, "xmpNote:HasExtendedXMP" as CFString, tag)
    else { die("写不进 xmpNote:HasExtendedXMP") }
    let size = UInt32(body.count)
    let be32 = [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]
    extensionSegment = app1(Array("http://ns.adobe.com/xmp/extension/".utf8) + [0] + Array(guid.utf8)
                            + be32 + [0, 0, 0, 0] + body)
}
guard let packet = CGImageMetadataCreateXMPData(merged, nil) as Data?,
      xmpID.count + packet.count + 2 <= 0xFFFF else { die("合并后的 XMP 包写不进一个段") }
bytes.replaceSubrange(segment, with: app1(xmpID + [UInt8](packet)) + extensionSegment)

/// 一张辅助图的描述与数据。图案是两个正弦的叠加，`seed` 让每种的图案不同，好让
/// 「数据被换成另一种」也看得出来。浮点类型的值落在 0.5…3.5（单位是米或 1/米），
/// 8 位类型落在 0…255。每行按 `width` 紧排，不带填充。
func auxiliaryInfo(_ kind: String, seed: Double) -> (type: CFString, info: [CFString: Any]) {
    let width = 150, height = 120
    func pattern(_ x: Int, _ y: Int) -> Double {
        0.5 + 0.25 * sin(Double(x) * (0.21 + 0.05 * seed)) + 0.25 * cos(Double(y) * (0.17 + 0.03 * seed) + Double(x) * 0.04)
    }
    let type: CFString, format: UInt32, float: Bool
    switch kind {
    case "depth": (type, format, float) = (kCGImageAuxiliaryDataTypeDepth, kCVPixelFormatDepthFloat32, true)
    case "disparity": (type, format, float) = (kCGImageAuxiliaryDataTypeDisparity, kCVPixelFormatDisparityFloat32, true)
    case "matte": (type, format, float) = (kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCVPixelFormatOneComponent8, false)
    case "skin": (type, format, float) = (kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, kCVPixelFormatOneComponent8, false)
    case "gainmap": (type, format, float) = (kCGImageAuxiliaryDataTypeHDRGainMap, kCVPixelFormatOneComponent8, false)
    default: die("不认识的辅助图种类：\(kind)\n\(usage)")
    }
    var data = Data()
    for y in 0..<height {
        for x in 0..<width {
            if float {
                var v = Float(0.5 + 3 * pattern(x, y))
                withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
            } else {
                data.append(UInt8(max(0, min(255, (pattern(x, y) * 255).rounded()))))
            }
        }
    }
    var info: [CFString: Any] = [
        kCGImageAuxiliaryDataInfoData: data,
        kCGImageAuxiliaryDataInfoDataDescription: [
            kCGImagePropertyWidth: width, kCGImagePropertyHeight: height,
            kCGImagePropertyBytesPerRow: width * (float ? 4 : 1), kCGImagePropertyPixelFormat: format,
        ] as [CFString: Any],
    ]
    let tags: (namespace: String, prefix: String, values: [(String, CFTypeRef)])?
    switch kind {
    case "gainmap":
        tags = ("http://ns.apple.com/HDRGainMap/1.0/", "HDRGainMap",
                [("HDRGainMapVersion", 131072 as CFNumber), ("HDRGainMapHeadroom", 3.5 as CFNumber)])
    case "depth", "disparity":
        tags = ("http://ns.apple.com/depthData/1.0/", "depthData",
                [("Accuracy", "relative" as CFString), ("Filtered", "true" as CFString), ("Quality", "high" as CFString)])
    case "matte":
        tags = ("http://ns.apple.com/portraitEffectsMatte/1.0/", "portraitEffectsMatte",
                [("PortraitEffectsMatteVersion", 65536 as CFNumber)])
    case "skin":
        tags = ("http://ns.apple.com/semanticSegmentationMatte/1.0/", "semanticSegmentationMatte",
                [("SemanticSegmentationMatteVersion", 65536 as CFNumber),
                 ("SemanticSegmentationMatteType", "skin" as CFString)])
    default:
        tags = nil
    }
    if let tags {
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, tags.namespace as CFString, tags.prefix as CFString, nil)
        else { die("写不进 \(kind) 的元数据") }
        for (name, value) in tags.values {
            guard CGImageMetadataSetValueWithPath(metadata, nil, "\(tags.prefix):\(name)" as CFString, value)
            else { die("写不进 \(kind) 的元数据 \(name)") }
        }
        info[kCGImageAuxiliaryDataInfoMetadata] = metadata
    }
    return (type, info)
}
// CoreVideo 的像素格式码（四字符码），夹具不链 CoreVideo，在这里写出来。
let kCVPixelFormatDepthFloat32: UInt32 = 0x6664_6570          // 'fdep'
let kCVPixelFormatDisparityFloat32: UInt32 = 0x6664_6973      // 'fdis'
let kCVPixelFormatOneComponent8: UInt32 = 0x4C30_3038         // 'L008'

// 辅助图与缩略图只能在编码时加：从上面拼好的字节重新读一遍，用 ImageIO 再写一次
// JPEG，把它们加在主图后面（辅助图进 MPF 登记的尾部，缩略图进 EXIF IFD1）。
if !auxKinds.isEmpty || thumbnail {
    guard let assembled = CGImageSourceCreateWithData(Data(bytes) as CFData, nil) else { die("读不回拼好的测试图") }
    let reencoded = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(reencoded, UTType.jpeg.identifier as CFString, 1, nil) else {
        die("无法创建 JPEG 编码器")
    }
    CGImageDestinationAddImageFromSource(dest, assembled, 0, [
        kCGImageDestinationLossyCompressionQuality: 0.95,
        kCGImageDestinationEmbedThumbnail: thumbnail,
    ] as CFDictionary)
    for (i, kind) in auxKinds.enumerated() {
        let (type, info) = auxiliaryInfo(kind, seed: Double(i))
        CGImageDestinationAddAuxiliaryDataInfo(dest, type, info as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { die("写入带辅助图的测试图失败") }
    bytes = [UInt8](reencoded as Data)
}
do { try Data(bytes).write(to: URL(fileURLWithPath: path)) } catch { die("写入测试图失败") }
print("已生成测试图: \(path)")
