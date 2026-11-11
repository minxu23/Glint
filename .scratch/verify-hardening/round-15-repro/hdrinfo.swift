import Foundation
import ImageIO
import CoreGraphics
let types: [(String, CFString)] = [("HDRGainMap", kCGImageAuxiliaryDataTypeHDRGainMap), ("ISOGainMap", kCGImageAuxiliaryDataTypeISOGainMap), ("Depth", kCGImageAuxiliaryDataTypeDepth), ("Disparity", kCGImageAuxiliaryDataTypeDisparity), ("PortraitMatte", kCGImageAuxiliaryDataTypePortraitEffectsMatte)]
func stats(_ img: CGImage) -> (max: Float, p999: Float, mean: Float, over1: Double) {
    let w = min(img.width, 400), h = max(1, img.height * w / img.width)
    let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: cs, bitmapInfo: info) else { return (-1, -1, -1, -1) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.bindMemory(to: Float.self, capacity: w * h * 4)
    var lum: [Float] = []; lum.reserveCapacity(w * h)
    for i in 0..<(w * h) { lum.append(max(p[i*4], p[i*4+1], p[i*4+2])) }
    lum.sort()
    return (lum.last!, lum[Int(Double(lum.count - 1) * 0.999)], lum.reduce(0, +) / Float(lum.count), Double(lum.filter { $0 > 1.0 }.count) / Double(lum.count))
}
for path in CommandLine.arguments.dropFirst() {
    print("● \((path as NSString).lastPathComponent)")
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { print("   打不开"); continue }
    var any = false
    for (n, t) in types {
        guard let i = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, t) as? [CFString: Any] else { continue }
        any = true
        let d = i[kCGImageAuxiliaryDataInfoData] as? Data ?? Data(); let desc = i[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] ?? [:]
        var tagText = "无"
        if let m = i[kCGImageAuxiliaryDataInfoMetadata] { let tags = (CGImageMetadataCopyTags(m as! CGImageMetadata) as? [CGImageMetadataTag]) ?? []
            tagText = tags.map { "\(CGImageMetadataTagCopyPrefix($0) as String? ?? "?"):\(CGImageMetadataTagCopyName($0) as String? ?? "?")=\(String(describing: CGImageMetadataTagCopyValue($0) ?? "nil" as CFTypeRef).prefix(28))" }.joined(separator: "; ") }
        print("   辅助图 \(n): \(desc[kCGImagePropertyWidth] ?? "?")x\(desc[kCGImagePropertyHeight] ?? "?")，\(d.count) 字节；元数据: \(tagText)")
    }
    if !any { print("   辅助图: 无") }
    let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    if let ma = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] { print("   MakerApple: 33=\(ma["33"] ?? "无") 48=\(ma["48"] ?? "无")（共 \(ma.count) 项）") } else { print("   MakerApple: 无") }
    for (label, req) in [("按 SDR 解码", kCGImageSourceDecodeToSDR), ("按 HDR 解码", kCGImageSourceDecodeToHDR)] {
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: req] as CFDictionary) else { print("   \(label): 失败"); continue }
        let s = stats(img); var hr = "?"
        if #available(macOS 15.0, *) { hr = String(format: "%.2f", img.contentHeadroom) }
        print(String(format: "   %@: 色彩空间 %@，%d 位，内容余量 %@；最亮 %.2f，99.9%% 分位 %.2f，均值 %.3f，超过 SDR 白的像素 %.1f%%", label, (img.colorSpace?.name as String? ?? "nil").replacingOccurrences(of: "kCGColorSpace", with: ""), img.bitsPerComponent, hr, s.max, s.p999, s.mean, s.over1 * 100))
    }
}
