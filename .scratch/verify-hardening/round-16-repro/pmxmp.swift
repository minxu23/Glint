import ImageIO
import Foundation
import UniformTypeIdentifiers
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let m = CGImageMetadataCreateMutable()
let ok1 = CGImageMetadataSetValueWithPath(m, nil, "exif:GPSProcessingMethod" as CFString, "CELLID" as CFString)
let mid = NSMutableData()
let d1 = CGImageDestinationCreateWithData(mid, UTType.heic.identifier as CFString, 1, nil)!
CGImageDestinationAddImageFromSource(d1, src, 0, nil); CGImageDestinationFinalize(d1)
let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, UTType.heic.identifier as CFString, 1, nil)!
let ok = CGImageDestinationCopyImageSource(out, CGImageSourceCreateWithData(mid, nil)!, [kCGImageDestinationMetadata: m, kCGImageDestinationMergeMetadata: true] as CFDictionary, nil)
print("set=\(ok1) copy=\(ok)")
