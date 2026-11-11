import ImageIO
import Foundation
for p in CommandLine.arguments.dropFirst() {
  let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
  let d = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [String: Any]
  let e = d["{Exif}"] as? [String: Any] ?? [:]
  print(p, "ImageUniqueID=\(e["ImageUniqueID"] ?? "-")")
}
