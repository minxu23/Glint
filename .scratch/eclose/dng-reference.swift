// 手写一个最小的 LinearRaw DNG（每像素 RGB 16 位，不压缩），带 Orientation、EXIF 拍摄时间、GPS
import Foundation
let a = CommandLine.arguments
let W = 512, H = 384, orient = UInt16(a.count > 2 ? Int(a[2])! : 1), cfa = a.count > 3 && a[3] == "cfa"
var d = Data()
func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
struct E { let tag: UInt16; let type: UInt16; let count: UInt32; let payload: Data }
func le16(_ v: [UInt16]) -> Data { var o = Data(); for x in v { var y = x.littleEndian; o.append(Data(bytes: &y, count: 2)) }; return o }
func le32(_ v: [UInt32]) -> Data { var o = Data(); for x in v { var y = x.littleEndian; o.append(Data(bytes: &y, count: 4)) }; return o }
func s32(_ v: [Int32]) -> Data { le32(v.map { UInt32(bitPattern: $0) }) }
func ascii(_ s: String) -> Data { var o = s.data(using: .ascii)!; o.append(0); return o }
// 先排布：头 8 字节，然后各 IFD 与数据，最后像素
var blobs = Data(); let blobBase = 2048
func put(_ p: Data) -> UInt32 { let off = UInt32(blobBase + blobs.count); blobs.append(p); if blobs.count % 2 == 1 { blobs.append(0) }; return off }
func ifd(_ es: [E], at base: Int, next: UInt32 = 0) -> Data {
    var o = Data(); var n = UInt16(es.count).littleEndian; o.append(Data(bytes: &n, count: 2))
    for e in es.sorted(by: { $0.tag < $1.tag }) {
        o.append(le16([e.tag, e.type])); o.append(le32([e.count]))
        if e.payload.count <= 4 { var p = e.payload; while p.count < 4 { p.append(0) }; o.append(p) }
        else { o.append(le32([put(e.payload)])) }
    }
    o.append(le32([next])); return o
}
var px = Data()
for y in 0..<H { for x in 0..<W { if cfa { let c = (y % 2) * 2 + (x % 2); px.append(le16([c == 0 ? UInt16(x * 120) : c == 3 ? 20000 : UInt16(y * 160)])) } else { px.append(le16([UInt16(x * 120), UInt16(y * 160), 20000])) } } }
let pixOff: UInt32 = 8192
let exifOff: UInt32 = 1024, gpsOff: UInt32 = 1536
let exif = ifd([E(tag: 0x9003, type: 2, count: 20, payload: ascii("2024:05:06 07:08:09")),
                E(tag: 0x9000, type: 7, count: 4, payload: "0231".data(using: .ascii)!),
                E(tag: 0x829A, type: 5, count: 1, payload: le32([1, 250]))], at: Int(exifOff))
let gps = ifd([E(tag: 0, type: 1, count: 4, payload: Data([2, 3, 0, 0])),
               E(tag: 1, type: 2, count: 2, payload: ascii("N")),
               E(tag: 2, type: 5, count: 3, payload: le32([64, 1, 8, 1, 3000, 100])),
               E(tag: 3, type: 2, count: 2, payload: ascii("W")),
               E(tag: 4, type: 5, count: 3, payload: le32([21, 1, 56, 1, 1234, 100]))], at: Int(gpsOff))
let rawOff: UInt32 = 640, prevOff: UInt32 = 6144
var prev = Data(); for _ in 0..<(16 * 12) { prev.append(contentsOf: [128, 128, 128]) }
let raw = ifd([
    E(tag: 254, type: 4, count: 1, payload: le32([0])),
    E(tag: 256, type: 3, count: 1, payload: le16([UInt16(W)])),
    E(tag: 257, type: 3, count: 1, payload: le16([UInt16(H)])),
    cfa ? E(tag: 258, type: 3, count: 1, payload: le16([16])) : E(tag: 258, type: 3, count: 3, payload: le16([16, 16, 16])),
    E(tag: 259, type: 3, count: 1, payload: le16([1])),
    E(tag: 262, type: 3, count: 1, payload: le16([cfa ? 32803 : 34892])),
    E(tag: 273, type: 4, count: 1, payload: le32([pixOff])),
    E(tag: 277, type: 3, count: 1, payload: le16([cfa ? 1 : 3])),
    E(tag: 278, type: 3, count: 1, payload: le16([UInt16(H)])),
    E(tag: 279, type: 4, count: 1, payload: le32([UInt32(px.count)])),
    E(tag: 284, type: 3, count: 1, payload: le16([1])),
    E(tag: 33421, type: 3, count: 2, payload: le16([2, 2])),
    E(tag: 33422, type: 1, count: 4, payload: Data([0, 1, 1, 2])),
    E(tag: 50710, type: 1, count: 3, payload: Data([0, 1, 2])),
    E(tag: 50711, type: 3, count: 1, payload: le16([1])),
    E(tag: 50713, type: 3, count: 2, payload: le16([1, 1])),
    E(tag: 50714, type: 3, count: 1, payload: le16([0])),
    E(tag: 50718, type: 5, count: 2, payload: le32([1, 1, 1, 1])),
    E(tag: 50733, type: 4, count: 1, payload: le32([0])),
    E(tag: 50780, type: 5, count: 1, payload: le32([1, 1])),
    E(tag: 50829, type: 4, count: 4, payload: le32([0, 0, UInt32(H), UInt32(W)])),
    cfa ? E(tag: 50717, type: 3, count: 1, payload: le16([65535])) : E(tag: 50717, type: 3, count: 3, payload: le16([65535, 65535, 65535])),
    E(tag: 50719, type: 3, count: 2, payload: le16([0, 0])),
    E(tag: 50720, type: 3, count: 2, payload: le16([UInt16(W), UInt16(H)])),
].filter { cfa || ![33421, 33422, 50710, 50711].contains($0.tag) }, at: Int(rawOff))
let main = ifd([
    E(tag: 254, type: 4, count: 1, payload: le32([1])),
    E(tag: 256, type: 3, count: 1, payload: le16([16])),
    E(tag: 257, type: 3, count: 1, payload: le16([12])),
    E(tag: 258, type: 3, count: 3, payload: le16([8, 8, 8])),
    E(tag: 259, type: 3, count: 1, payload: le16([1])),
    E(tag: 262, type: 3, count: 1, payload: le16([2])),
    E(tag: 271, type: 2, count: 6, payload: ascii("Glint")),
    E(tag: 272, type: 2, count: 11, payload: ascii("TestCamera")),
    E(tag: 273, type: 4, count: 1, payload: le32([prevOff])),
    E(tag: 274, type: 3, count: 1, payload: le16([orient])),
    E(tag: 277, type: 3, count: 1, payload: le16([3])),
    E(tag: 278, type: 3, count: 1, payload: le16([12])),
    E(tag: 279, type: 4, count: 1, payload: le32([UInt32(prev.count)])),
    E(tag: 284, type: 3, count: 1, payload: le16([1])),
    E(tag: 330, type: 4, count: 1, payload: le32([rawOff])),
    E(tag: 0x8769, type: 4, count: 1, payload: le32([exifOff])),
    E(tag: 0x8825, type: 4, count: 1, payload: le32([gpsOff])),
    E(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0])),
    E(tag: 50707, type: 1, count: 4, payload: Data([1, 1, 0, 0])),
    E(tag: 50708, type: 2, count: 17, payload: ascii("Glint TestCamera")),
    E(tag: 50721, type: 10, count: 9, payload: s32([32406, 10000, -15372, 10000, -4986, 10000, -9689, 10000, 18758, 10000, 415, 10000, 557, 10000, -2040, 10000, 10570, 10000])),
    E(tag: 50727, type: 5, count: 3, payload: le32([1, 1, 1, 1, 1, 1])),
    E(tag: 50730, type: 10, count: 1, payload: s32([0, 1])),
    E(tag: 50731, type: 5, count: 1, payload: le32([1, 1])),
    E(tag: 50732, type: 5, count: 1, payload: le32([1, 1])),
    E(tag: 50728, type: 5, count: 3, payload: le32([1, 1, 1, 1, 1, 1])),
    E(tag: 50778, type: 3, count: 1, payload: le16([21])),
], at: 8)
d.append(contentsOf: [0x49, 0x49]); u16(42); u32(8)
d.append(main)
precondition(d.count <= Int(rawOff)); while d.count < Int(rawOff) { d.append(0) }; d.append(raw)
while d.count < Int(exifOff) { d.append(0) }; d.append(exif)
while d.count < Int(gpsOff) { d.append(0) }; d.append(gps)
precondition(d.count <= blobBase); while d.count < blobBase { d.append(0) }; d.append(blobs)
precondition(d.count <= Int(prevOff)); while d.count < Int(prevOff) { d.append(0) }; d.append(prev)
precondition(d.count <= Int(pixOff)); while d.count < Int(pixOff) { d.append(0) }; d.append(px)
try! d.write(to: URL(fileURLWithPath: a[1]))
print("写了 \(d.count) 字节")
