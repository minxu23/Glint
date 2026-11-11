import ImageIO
import CoreGraphics
import Foundation
func decode(_ p: String) -> [Float] {
  let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
  let img = CGImageSourceCreateImageAtIndex(s, 0, (ProcessInfo.processInfo.environment["SDR"] != nil ? nil : [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))!
  let w = img.width / 4, h = img.height / 4   // downsample for speed
  var buf = [Float](repeating: 0, count: w*h*4)
  let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  buf.withUnsafeMutableBytes { p in
    let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w*16, space: cs,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
  return buf
}
let ref = decode(CommandLine.arguments[1])
func pct(_ a: [Float], _ q: Double) -> Float { let s = a.sorted(); return s[min(s.count-1, Int(Double(s.count)*q))] }
var lum = [Float](); for i in stride(from: 0, to: ref.count, by: 4) { lum.append(0.2*ref[i]+0.7*ref[i+1]+0.1*ref[i+2]) }
print("ref  lum p50=\(pct(lum,0.5)) p99=\(pct(lum,0.99)) max=\(lum.max()!)")
for p in CommandLine.arguments.dropFirst(2) {
  let x = decode(p)
  var err = [Float](), hiErr = [Float](), chroma = [Float]()
  for i in stride(from: 0, to: ref.count, by: 4) {
    let e = (abs(ref[i]-x[i]) + abs(ref[i+1]-x[i+1]) + abs(ref[i+2]-x[i+2])) / 3
    err.append(e)
    if lum[i/4] > 1.0 { hiErr.append(e / lum[i/4]) }
    // chroma: ratio r/g diff
    let rr = ref[i]/max(ref[i+1],1e-4), xr = x[i]/max(x[i+1],1e-4); chroma.append(abs(rr-xr))
  }
  let xl = stride(from: 0, to: x.count, by: 4).map { 0.2*x[$0]+0.7*x[$0+1]+0.1*x[$0+2] }
  print(p.split(separator: "/").last!, "meanAbs=\(err.reduce(0,+)/Float(err.count)) p99=\(pct(err,0.99)) | HDR px(\(hiErr.count)) relErr p50=\(hiErr.isEmpty ? 0 : pct(hiErr,0.5)) p99=\(hiErr.isEmpty ? 0 : pct(hiErr,0.99)) | r/g diff p99=\(pct(chroma,0.99)) | lum max=\(xl.max()!)")
}
