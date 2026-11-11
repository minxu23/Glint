import ImageIO
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
setvbuf(stdout, nil, _IONBF, 0)
let w = 96, h = 64
let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
var px = [Float](repeating: 1, count: w*h*4)
for y in 0..<h { for x in 0..<w { let i = (y*w+x)*4
  px[i] = Float(x)/Float(w)*4; px[i+1] = Float(y)/Float(h)*2; px[i+2] = x > w/2 ? 3 : 0.2; px[i+3] = 1 } }
let ctx = px.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w*16, space: cs,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)! }
let img = ctx.makeImage()!
func fourcc(_ s: String) -> Int { s.utf8.reduce(0) { $0 << 8 | Int($1) } }
for (name, fmt) in [("default", nil), ("BGRA", fourcc("BGRA")), ("420f", fourcc("420f")), ("RGBA", fourcc("RGBA")), ("L008", fourcc("L008")), ("24RGB", 24)] as [(String, Int?)] {
  let url = URL(fileURLWithPath: CommandLine.arguments[1] + "_" + name + ".jpg")
  let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
  var opts: [CFString: Any] = [:]
  if let fmt { opts[kCGImageDestinationEncodeGainMapPixelFormatRequest] = fmt }
  CGImageDestinationAddImage(d, img, [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap, kCGImageDestinationEncodeRequestOptions: opts] as CFDictionary)
  let ok = CGImageDestinationFinalize(d)
  var rb = "-"
  if ok, let s = CGImageSourceCreateWithURL(url as CFURL, nil) {
    rb = (CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any]).map { "fmt=\(($0[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])?["PixelFormat"] ?? "?") data=\($0[kCGImageAuxiliaryDataInfoData] != nil)" } ?? "no gain map" }
  print(name, ok, rb)
}
