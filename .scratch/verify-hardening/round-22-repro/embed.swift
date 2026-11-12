import ImageIO
import Foundation
import UniformTypeIdentifiers
// 探针：两遍写 HEIC，第二遍把一段说明并进 XMP 的 dc:description
setvbuf(stdout, nil, _IONBF, 0)
let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
for k in [kCGImagePropertyFileSize, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { props.removeValue(forKey: k) }
props[kCGImageDestinationLossyCompressionQuality] = 0.8
let heic = UTType.heic.identifier as CFString
let mem = NSMutableData()
let d1 = CGImageDestinationCreateWithData(mem, heic, 1, nil)!
CGImageDestinationAddImageFromSource(d1, src, 0, props as CFDictionary)
print("第一遍:", CGImageDestinationFinalize(d1))
let base = CGImageSourceCopyMetadataAtIndex(src, 0, nil)
let md = base.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
let ok = CGImageMetadataSetValueMatchingImageProperty(md, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, a[3] as CFString)
print("写入 Caption:", ok)
let first = CGImageSourceCreateWithData(mem, nil)!
let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, heic, 1, nil)!
var err: Unmanaged<CFError>?
print("第二遍:", CGImageDestinationCopyImageSource(out, first, [kCGImageDestinationMetadata: md, kCGImageDestinationMergeMetadata: true] as CFDictionary, &err), err?.takeRetainedValue() as Any)
