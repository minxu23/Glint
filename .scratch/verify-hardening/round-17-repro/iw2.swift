import ImageIO
import Foundation
import UniformTypeIdentifiers
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let vals = ["abc", "0123456789abcdef", "J12LLKF00SM J12LLKL01GM", "0123456789abcdef0123456789abcdef0123", "OPPO_20201019_204116_0001", "唯一标识"]
for (i, v) in vals.enumerated() {
  let url = URL(fileURLWithPath: CommandLine.arguments[2] + "\(i).heic")
  let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
  CGImageDestinationAddImageFromSource(d, src, 0, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifImageUniqueID: v]] as CFDictionary)
  print(i, "\"\(v)\"", CGImageDestinationFinalize(d))
}
