import ImageIO
import Foundation
import CryptoKit
import CoreGraphics
// 不强制从全图生成：看读取器会不会改用 EXIF 里内嵌的缩略图
for p in CommandLine.arguments.dropFirst() {
  let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
  var line = p
  for (name, opt) in [("embedded-only", [:] as [CFString: Any]), ("ifAbsent", [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 160]), ("ifAbsent+transform", [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 160, kCGImageSourceCreateThumbnailWithTransform: true])] {
    if let t = CGImageSourceCreateThumbnailAtIndex(s, 0, opt as CFDictionary) {
      let w = t.width, h = t.height
      var buf = [UInt8](repeating: 0, count: w*h*4)
      let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      ctx.draw(t, in: CGRect(x: 0, y: 0, width: w, height: h))
      line += "  \(name)=\(w)x\(h) " + SHA256.hash(data: Data(buf)).prefix(4).map { String(format: "%02x", $0) }.joined()
    } else { line += "  \(name)=nil" }
  }
  let d = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [String: Any]
  print(line, " Orientation=\(d["Orientation"] ?? "-") tiff=\((d["{TIFF}"] as? [String: Any])?["Orientation"] ?? "-") WxH=\(d["PixelWidth"]!)x\(d["PixelHeight"]!)")
}
