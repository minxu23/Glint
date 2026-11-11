import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
// 用法: auxcarry <in.jpg> <out前缀>
// 模拟现行的两遍写入，并在第一遍里把源的辅助图逐个加进去；分别检查「只做第一遍」和「两遍都做」的产物里辅助图还在不在、数据是否逐字节相同。
let types: [(String, CFString)] = [
    ("HDRGainMap", kCGImageAuxiliaryDataTypeHDRGainMap), ("ISOGainMap", kCGImageAuxiliaryDataTypeISOGainMap),
    ("Depth", kCGImageAuxiliaryDataTypeDepth), ("Disparity", kCGImageAuxiliaryDataTypeDisparity),
    ("PortraitMatte", kCGImageAuxiliaryDataTypePortraitEffectsMatte),
    ("SkinMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte), ("HairMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte),
    ("TeethMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte), ("GlassesMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte),
    ("SkyMatte", kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte)]
func aux(_ s: CGImageSource) -> [String: [CFString: Any]] {
    var r: [String: [CFString: Any]] = [:]
    for (n, t) in types { if let i = CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, t) as? [CFString: Any] { r[n] = i } }
    return r
}
func describe(_ label: String, _ a: [String: [CFString: Any]], against src: [String: [CFString: Any]]? = nil) {
    if a.isEmpty { print("  \(label): 没有辅助图"); return }
    for (n, i) in a.sorted(by: { $0.key < $1.key }) {
        let d = i[kCGImageAuxiliaryDataInfoData] as? Data ?? Data()
        let desc = i[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] ?? [:]
        var cmp = ""
        if let s = src?[n] {
            let sd = s[kCGImageAuxiliaryDataInfoData] as? Data ?? Data()
            cmp = sd == d ? "，数据与源逐字节相同" : "，数据与源不同（源 \(sd.count) 字节）"
        }
        print("  \(label): \(n) \(d.count) 字节 \(desc[kCGImagePropertyWidth] ?? "?")x\(desc[kCGImagePropertyHeight] ?? "?") 格式 \(desc[kCGImagePropertyPixelFormat] ?? "?")，带元数据: \(i[kCGImageAuxiliaryDataInfoMetadata] != nil)\(cmp)")
    }
}
let inURL = URL(fileURLWithPath: CommandLine.arguments[1]), prefix = CommandLine.arguments[2]
let src = CGImageSourceCreateWithURL(inURL as CFURL, nil)!
let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
let srcAux = aux(src); describe("源", srcAux)
let heic = UTType.heic.identifier as CFString
// 第一遍：AddImageFromSource + 逐个加辅助图
let mem = NSMutableData()
let d1 = CGImageDestinationCreateWithData(mem, heic, 1, nil)!
CGImageDestinationAddImageFromSource(d1, src, 0, props as CFDictionary)
for (n, t) in types { if let i = srcAux[n] { CGImageDestinationAddAuxiliaryDataInfo(d1, t, i as CFDictionary) } }
print("  第一遍 Finalize:", CGImageDestinationFinalize(d1))
try! (mem as Data).write(to: URL(fileURLWithPath: prefix + "-pass1.heic"))
let p1 = CGImageSourceCreateWithData(mem, nil)!
describe("只做第一遍的产物", aux(p1), against: srcAux)
// 第二遍：CopyImageSource 合并 XMP
if let xmp = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
    let d2 = CGImageDestinationCreateWithURL(URL(fileURLWithPath: prefix + "-pass2.heic") as CFURL, heic, 1, nil)!
    let ok = CGImageDestinationCopyImageSource(d2, p1, [kCGImageDestinationMetadata: xmp, kCGImageDestinationMergeMetadata: true] as CFDictionary, nil)
    print("  第二遍 CopyImageSource:", ok)
    if ok, let p2 = CGImageSourceCreateWithURL(URL(fileURLWithPath: prefix + "-pass2.heic") as CFURL, nil) { describe("两遍之后的产物", aux(p2), against: srcAux) }
} else { print("  源没有 XMP，不做第二遍") }
