import ImageIO
import Foundation
import UniformTypeIdentifiers
setvbuf(stdout, nil, _IONBF, 0)
// args: src out mode   mode = preserve | preserve+aux | aux
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let url = URL(fileURLWithPath: CommandLine.arguments[2]); let mode = CommandLine.arguments[3]
let types = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap]
let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
CGImageDestinationAddImageFromSource(d, src, 0, (mode.hasPrefix("preserve") ? [kCGImageDestinationPreserveGainMap: true] : [:]) as CFDictionary)
if mode.hasSuffix("aux") { for t in types { if let i = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, t) { CGImageDestinationAddAuxiliaryDataInfo(d, t, i) } } }
let ok = CGImageDestinationFinalize(d)
let s = CGImageSourceCreateWithURL(url as CFURL, nil)!
let srcHas = types.map { CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, $0) != nil ? "Y" : "-" }.joined()
let outHas = types.map { CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, $0) != nil ? "Y" : "-" }.joined()
print(mode, "ok=\(ok)", "src[HDR,ISO]=\(srcHas) out=\(outHas)", "size=\((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) ?? 0)")
