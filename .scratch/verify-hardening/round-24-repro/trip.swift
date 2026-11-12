import ImageIO
import Foundation
setvbuf(stdout, nil, _IONBF, 0)
// 单线程、一个进程只比一对：源与产物的 XMP 按（命名空间 URI 链 + 名字 → 值）比，不看前缀
func triples(_ p: String) -> [String: String]? {
  guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
  guard let m = CGImageSourceCopyMetadataAtIndex(s, 0, nil) else { return [:] }
  var pre2ns: [String: String] = [:]; var raw: [(String, String)] = []
  CGImageMetadataEnumerateTagsUsingBlock(m, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
    if let p = CGImageMetadataTagCopyPrefix(tag) as String?, let n = CGImageMetadataTagCopyNamespace(tag) as String? { pre2ns[p] = n }
    if let v = CGImageMetadataTagCopyValue(tag) as? String { raw.append((path as String, v)) } else if let v = CGImageMetadataTagCopyValue(tag) as? NSNumber { raw.append((path as String, v.stringValue)) }
    return true }
  var out: [String: String] = [:]
  for (path, v) in raw {
    var key = path
    for (p, n) in pre2ns.sorted(by: { $0.key.count > $1.key.count }) { key = key.replacingOccurrences(of: p + ":", with: "{" + n + "}") }
    out[key] = v }
  return out
}
let a = triples(CommandLine.arguments[1]), b = triples(CommandLine.arguments[2])
guard let a, let b else { print("打不开"); exit(2) }
let lost = a.filter { b[$0.key] == nil }.count, changed = a.filter { b[$0.key] != nil && b[$0.key] != $0.value }.count
for (k, v) in a where b[k] == nil { print("   丢:", k.unicodeScalars.map { $0.isASCII && $0.value >= 32 ? String($0) : "·" }.joined(), "=", v.prefix(30)) }
print(lost == 0 && changed == 0 ? "一致 \(a.count)" : "不一致 丢 \(lost) 变 \(changed) / \(a.count)")
