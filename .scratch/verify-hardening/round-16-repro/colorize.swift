import ImageIO
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
setvbuf(stdout, nil, _IONBF, 0)
// args: in.jpg (single-channel ISO gain map, MPF) out.jpg
var d = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
func be32(_ o: Int, _ little: Bool) -> Int { little ? Int(d[o]) | Int(d[o+1])<<8 | Int(d[o+2])<<16 | Int(d[o+3])<<24 : Int(d[o])<<24 | Int(d[o+1])<<16 | Int(d[o+2])<<8 | Int(d[o+3]) }
// find MPF APP2
var p = 2, mpfBase = -1
while p < d.count - 4, d[p] == 0xFF, d[p+1] != 0xDA {
  let len = Int(d[p+2])<<8 | Int(d[p+3])
  if d[p+1] == 0xE2, Array(d[(p+4)..<(p+8)]) == Array("MPF\0".utf8) { mpfBase = p + 8 }
  p += 2 + len
}
precondition(mpfBase > 0)
let little = d[mpfBase] == 0x49
let ifd = mpfBase + be32(mpfBase + 4, little)
let n = little ? Int(d[ifd]) | Int(d[ifd+1])<<8 : Int(d[ifd])<<8 | Int(d[ifd+1])
var entryOff = -1
for k in 0..<n { let e = ifd + 2 + 12*k; let tag = little ? Int(d[e]) | Int(d[e+1])<<8 : Int(d[e])<<8 | Int(d[e+1]); if tag == 0xB002 { entryOff = mpfBase + be32(e + 8, little) } }
let e2 = entryOff + 16
let len2 = be32(e2 + 4, little), off2 = be32(e2 + 8, little)
let secStart = mpfBase + off2
let sec = Array(d[secStart..<(secStart+len2)])
// copy APPn segments (except APP0) of the secondary — they hold the ISO 21496 metadata
var q = 2; var appSegs = [UInt8]()
while sec[q] == 0xFF, sec[q+1] != 0xDA, sec[q+1] != 0xDB, sec[q+1] != 0xC0, sec[q+1] != 0xC4 {
  let len = Int(sec[q+2])<<8 | Int(sec[q+3]); if sec[q+1] >= 0xE1 && sec[q+1] <= 0xEF { appSegs += sec[q..<(q+2+len)] }; q += 2 + len }
// decode gray gain map, build colored version
let gsrc = CGImageSourceCreateWithData(Data(sec) as CFData, nil)!
let g = CGImageSourceCreateImageAtIndex(gsrc, 0, nil)!
let w = g.width, h = g.height
var gray = [UInt8](repeating: 0, count: w*h)
gray.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!.draw(g, in: CGRect(x: 0, y: 0, width: w, height: h)) }
var rgb = [UInt8](repeating: 255, count: w*h*4)
for i in 0..<(w*h) { rgb[i*4] = gray[i]; rgb[i*4+1] = UInt8(Int(gray[i]) * 3 / 4); rgb[i*4+2] = UInt8(Int(gray[i]) / 3) }
let cimg = rgb.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()! }
let enc = NSMutableData()
let dst = CGImageDestinationCreateWithData(enc, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dst, cimg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
precondition(CGImageDestinationFinalize(dst))
var newSec = [UInt8](enc as Data)
// strip new APPn segments, insert old ones after SOI
var r = 2; var body = [UInt8]()
while newSec[r] == 0xFF, newSec[r+1] >= 0xE0, newSec[r+1] <= 0xEF { let len = Int(newSec[r+2])<<8 | Int(newSec[r+3]); r += 2 + len }
body = Array(newSec[r...])
newSec = [0xFF, 0xD8] + appSegs + body
// patch length, rebuild file
let L = newSec.count
let lb: [UInt8] = little ? [UInt8(L & 255), UInt8(L>>8 & 255), UInt8(L>>16 & 255), UInt8(L>>24)] : [UInt8(L>>24), UInt8(L>>16 & 255), UInt8(L>>8 & 255), UInt8(L & 255)]
for k in 0..<4 { d[e2 + 4 + k] = lb[k] }
let out = Array(d[0..<secStart]) + newSec + Array(d[(secStart+len2)...])
try! Data(out).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, nil)!
let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any]
print("gain map:", info.map { "fmt=\(($0[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])?["PixelFormat"] ?? "?") data=\($0[kCGImageAuxiliaryDataInfoData] != nil)" } ?? "none", "sec bytes \(len2) -> \(L)")
