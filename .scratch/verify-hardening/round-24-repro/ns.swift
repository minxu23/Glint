import ImageIO
import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// 依次读每个文件的 XMP，打印各标签的前缀与命名空间
for p in CommandLine.arguments.dropFirst() {
  guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { print(p, "打不开"); continue }
  guard let m = CGImageSourceCopyMetadataAtIndex(s, 0, nil) else { print((p as NSString).lastPathComponent, "没有 XMP"); continue }
  var seen: [String: String] = [:]; var n = 0
  CGImageMetadataEnumerateTagsUsingBlock(m, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
    n += 1
    let pre = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? "?", ns = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? "?"
    seen[pre] = ns; return true }
  print((p as NSString).lastPathComponent, "标签 \(n) 个:", seen.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
}
