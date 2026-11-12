import ImageIO
import Foundation
import UniformTypeIdentifiers
// 用 ImageIO 的 HEIC 写入器写几种 UserComment 字符串，看别的读取器怎么读
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
func pad(_ units: [UInt16]) -> String { String(decoding: units + [UInt16](repeating: 0, count: units.count), as: UTF16.self) }
let texts = ["cjk": "鲁汶市政厅是比利时最美的市政厅", "mixed": "中文备注 with ASCII 混排", "asciifirst": "Note: 中文在后面"]
for (name, t) in texts {
  let u = Array(t.utf16)
  let variants: [(String, String)] = [("现行", u[0] <= 0x7F ? pad([0xFEFF] + u) : pad(u)), ("总带BOM", pad([0xFEFF] + u))]
  for (v, s) in variants {
    let url = URL(fileURLWithPath: "wr/\(name)_\(v).heic")
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
    CGImageDestinationAddImageFromSource(d, src, 0, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: s]] as CFDictionary)
    print(name, v, CGImageDestinationFinalize(d))
  }
}
