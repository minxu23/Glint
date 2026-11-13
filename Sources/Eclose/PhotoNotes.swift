// 图形界面信息栏读「备注」要用的几条规则。
//
// 规则本身（UserComment 怎么修补、什么样的说明能写进文件）和转换、校验是同一把尺子，所以留在
// 模块里；界面只拿结果，不碰原始字节的读法、修补条件这些内部类型。

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 访达备注所在的扩展属性（值是二进制 plist 的字符串）。
let finderCommentXattr = "com.apple.metadata:kMDItemFinderComment"

/// 「照片」App 的说明：扩展属性 photosCaptionXattr 里的文本；没有、或不是合法的 UTF-8 是 nil。
/// 不去首尾空白（显示时界面自己去）。
public func photosCaption(of url: URL) -> String? {
    extendedAttributeValue(url.path, photosCaptionXattr).flatMap { String(validatingUTF8Bytes: $0) }
}

/// 访达备注：扩展属性 finderCommentXattr 里的 plist 字符串；没有或解不出是 nil。
public func finderComment(of url: URL) -> String? {
    extendedAttributeValue(url.path, finderCommentXattr).flatMap { plistValue($0) as? String }
}

/// 读 EXIF 备注原始字节时只读文件开头这么多：EXIF 的 APP1 段不超过 64 KB，前面通常只有
/// 一个很短的 APP0。段落在这个范围之外时 JPEGLayout 解析不出它，读法是 `.absent`，
/// 显示退回 ImageIO 视图里的值。
let userCommentPrefixBytes = 192 * 1024

/// 文件开头的至多 `count` 个字节；读不出是空数组。
func filePrefix(_ url: URL, _ count: Int) -> [UInt8] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    return [UInt8]((try? handle.read(upToCount: count)) ?? Data())
}

/// EXIF 备注该显示什么。`seenByImageIO` 是 ImageIO 视图里的 UserComment，`reading` 是解析原始
/// 字节（readUserComment）的结果。
/// - 修补规则（SourceUserComment.toRepair，与转换、校验同一把尺子）要修补时，用修补出的文本；
/// - 原始字节解出来只是猜的（不是合法的 UTF-8 等）：不显示——ImageIO 视图里那串是乱码；
/// - 否则用 ImageIO 视图里的值。
func displayedUserComment(seenByImageIO: String?, reading: UserCommentReading) -> String? {
    let source = SourceUserComment(seenByImageIO: seenByImageIO, reading: reading)
    if let repaired = source.toRepair { return repaired }
    if case .guessed = reading { return nil }
    guard let seen = seenByImageIO else { return nil }
    let text = normalizedUserComment(seen)
    return text.isEmpty ? nil : text
}

/// 信息栏显示的 EXIF 备注（规则见 displayedUserComment）；没有可显示的是 nil。`image` 是 `url`
/// 打开的图像。原始字节只对 JPEG 读（读法认的是 JPEG 的 APP1 段），别的格式只看 ImageIO 视图。
public func displayedExifComment(of url: URL, image: CGImageSource) -> String? {
    let exif = (imageProperties(image)[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
    let isJPEG = (CGImageSourceGetType(image) as String?) == UTType.jpeg.identifier
    let reading: UserCommentReading = isJPEG ? rawExifUserComment(in: filePrefix(url, userCommentPrefixBytes)) : .absent
    return displayedUserComment(seenByImageIO: exif[kCGImagePropertyExifUserComment] as? String, reading: reading)
}

/// 勾「把备注写进文件」时这张图的「照片」说明能不能写进去：是能转换的源（JPEG 或相机 RAW，按内容
/// 判定，同 SourceKind(typeIdentifier:)；转换时两种都走 captionPlan），且 captionPlan 判定要写
/// （与转换时同一把尺子）。`image` 是 `url` 打开的图像。
public func captionCanBeEmbedded(_ url: URL, image: CGImageSource) -> Bool {
    guard SourceKind(typeIdentifier: CGImageSourceGetType(image) as String?) != nil else { return false }
    let xmp = CGImageSourceCopyMetadataAtIndex(image, 0, nil)
    if case .write = captionPlan(source: url, properties: imageProperties(image), xmp: xmp) { return true }
    return false
}
