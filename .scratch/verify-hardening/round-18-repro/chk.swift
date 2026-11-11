import ImageIO
import CoreGraphics
import Foundation
import CryptoKit
setvbuf(stdout, nil, _IONBF, 0)
func flat(_ v: Any, _ p: String, _ out: inout [String]) {
  if let d = v as? [String: Any] { for (k, x) in d { flat(x, p.isEmpty ? k : p + "/" + k, &out) } }
  else if let a = v as? [Any] { out.append("\(p)=[\(a.map { "\($0)" }.joined(separator: ","))]") }
  else if let d = v as? Data { out.append("\(p)=<\(d.count) bytes \(SHA256.hash(data: d).prefix(4).map { String(format: "%02x", $0) }.joined())>") }
  else { out.append("\(p)=\(v)") }
}
func hash(_ img: CGImage) -> String {
  let w = img.width, h = img.height
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
  return "\(w)x\(h) " + SHA256.hash(data: Data(buf)).prefix(6).map { String(format: "%02x", $0) }.joined()
}
let p = CommandLine.arguments[1]
guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { print("OPEN FAIL"); exit(1) }
print("status=\(CGImageSourceGetStatus(s).rawValue) count=\(CGImageSourceGetCount(s)) type=\(CGImageSourceGetType(s) as String? ?? "-")")
var out: [String] = []
if let d = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any] { flat(d, "", &out) } else { print("NO PROPS") }
if let d = CGImageSourceCopyProperties(s, nil) as? [String: Any] { flat(d, "{File}", &out) }
for l in out.sorted() { print(l) }
if let m = CGImageSourceCopyMetadataAtIndex(s, 0, nil), let x = CGImageMetadataCreateXMPData(m, nil) as Data? {
  print("XMP=\(x.count) bytes \(SHA256.hash(data: x).prefix(4).map { String(format: "%02x", $0) }.joined())") }
if let img = CGImageSourceCreateImageAtIndex(s, 0, nil) { print("PIXELS \(hash(img))") } else { print("DECODE FAIL") }
let topt: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256]
if let t = CGImageSourceCreateThumbnailAtIndex(s, 0, topt as CFDictionary) { print("THUMB_TRANSFORMED \(hash(t))") } else { print("THUMB FAIL") }
if let img = CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary) { print("HDR \(img.width)x\(img.height) bpc=\(img.bitsPerComponent) cs=\(img.colorSpace?.name as String? ?? "-")") }
for t in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte] {
  if let a = CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, t) as? [CFString: Any] {
    let d = a[kCGImageAuxiliaryDataInfoData] as? Data
    print("AUX \(t) data=\(d.map { "\($0.count) " + SHA256.hash(data: $0).prefix(4).map { String(format: "%02x", $0) }.joined() } ?? "nil")") } }
