import ImageIO
import Foundation
import UniformTypeIdentifiers
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
var gps = props[kCGImagePropertyGPSDictionary] as! [CFString: Any]
gps[kCGImagePropertyGPSProcessingMethod] = "CELLID"
gps[kCGImagePropertyGPSLatitude] = 22.6482620238889
gps[kCGImagePropertyGPSLongitude] = 114.062385558889
props[kCGImagePropertyGPSDictionary] = gps
for (ut, ext) in [(UTType.heic, "heic"), (UTType.jpeg, "jpg")] {
  let url = URL(fileURLWithPath: CommandLine.arguments[2] + "." + ext)
  let d = CGImageDestinationCreateWithURL(url as CFURL, ut.identifier as CFString, 1, nil)!
  CGImageDestinationAddImageFromSource(d, src, 0, props as CFDictionary)
  print(ext, CGImageDestinationFinalize(d))
}
