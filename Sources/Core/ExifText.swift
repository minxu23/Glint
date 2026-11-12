// EXIF 里的说明、作者、版权，和 ImageIO 视图里与它们调和的那几个键。
//
// ImageIO 读 JPEG 时用 IIM（IPTC）的值调和说明、作者、版权：IIM 摘要对不上时视图显示 IIM 的值，
// 系统重写时这个值写进产物的 EXIF 和 XMP。照搬的产物里 EXIF 是源的原值，HEIC 里 EXIF 压过 XMP，
// 视图显示的就变回 EXIF 的原值。这里定义三组调和字段、EXIF 原文的读法，以及照搬自检的放行
// （exifOriginalKept）。

import Foundation
import ImageIO

/// 一组调和字段：一个 IFD0 文字标签和它在视图里的几个键。
enum ReconciledGroup: CaseIterable, Equatable {
    case description, artist, copyright

    /// 差异行与 -v 里的中文名。
    var label: String {
        switch self {
        case .description: return "说明"
        case .artist: return "作者"
        case .copyright: return "版权"
        }
    }

    /// IFD0 里的标签号。
    var tag: Int {
        switch self {
        case .description: return 0x010E
        case .artist: return 0x013B
        case .copyright: return 0x8298
        }
    }

    var tagName: String {
        switch self {
        case .description: return "ImageDescription"
        case .artist: return "Artist"
        case .copyright: return "Copyright"
        }
    }

    /// 视图里与这个标签直接对应的键（`{TIFF}/…`）。
    var tiffKey: String {
        switch self {
        case .description: return metadataKey(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription)
        case .artist: return metadataKey(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist)
        case .copyright: return metadataKey(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright)
        }
    }

    /// IPTC 与 XMP 的键，不带下标。
    private var bracketedKeys: [String] {
        switch self {
        case .description: return [iptcKey(kCGImagePropertyIPTCCaptionAbstract), xmpKey("dc:description")]
        case .artist: return [iptcKey(kCGImagePropertyIPTCByline), xmpKey("dc:creator")]
        case .copyright: return [iptcKey(kCGImagePropertyIPTCCopyrightNotice), xmpKey("dc:rights")]
        }
    }

    /// 视图键 `key` 属于哪一组：`{TIFF}/…` 那个键本身，或 IPTC、XMP 的键本身或带一个下标
    /// （`[0]`、`[x-default]`）的。都不是是 nil。
    init?(viewKey key: String) {
        for group in ReconciledGroup.allCases {
            if key == group.tiffKey { self = group; return }
            for base in group.bracketedKeys where key.hasPrefix(base) {
                let rest = key.dropFirst(base.count)
                if rest.isEmpty { self = group; return }
                if rest.first == "[", rest.last == "]", rest.count >= 2,
                   !rest.dropFirst().dropLast().contains(where: { $0 == "[" || $0 == "]" || $0 == "/" }) {
                    self = group; return
                }
            }
        }
        return nil
    }
}

/// EXIF 里一个文字标签的原文。
enum ExifTextReading: Equatable {
    /// 没有这个标签、值读不出，或去掉尾部 NUL 与空白后是空的。
    case absent
    /// 去掉尾部 NUL 与空白后是 ASCII 或合法 UTF-8 的文本（中间的 NUL 照留，如 Copyright 的
    /// 「摄影师\0编辑者」）。
    case reliable(String)
    /// 去掉尾部 NUL 与空白后不是合法的 UTF-8（GBK 之类）。附带去掉填充后的字节与值的全部字节数。
    case unreliable(bytes: [UInt8], size: Int)
}

/// 读一个文字标签的值字节。可靠的标准与备注（readUserComment 的无头写法）相同：合法的 UTF-8；
/// 去掉的填充与键空间比对的 trimPadding 相同（NUL、空格、制表、换行、回车）。
func readExifText(_ raw: [UInt8]?) -> ExifTextReading {
    guard let raw else { return .absent }
    var end = raw.count
    while end > 0, [0x00, 0x20, 0x09, 0x0A, 0x0D].contains(raw[end - 1]) { end -= 1 }
    let body = Array(raw[..<end])
    if body.isEmpty { return .absent }
    guard let text = String(validatingUTF8Bytes: body) else { return .unreliable(bytes: body, size: raw.count) }
    return .reliable(text)
}

/// IFD0 里（第一个）这个标签的全部值字节；没有这一条或值读不出是 nil。
func rawIFD0Value(_ tiff: TIFFStructure, tag: Int) -> [UInt8]? {
    guard let ifd0 = tiff.ifd0, let entry = tiff.entries(ifd0).first(where: { $0.tag == tag }) else { return nil }
    return tiff.value(of: entry)
}

/// 一段 TIFF 里三组调和字段的 EXIF 原文。`tiff` 为 nil（没有 EXIF）时全是 absent。
func exifTextOriginals(_ tiff: TIFFStructure?) -> [ReconciledGroup: ExifTextReading] {
    Dictionary(uniqueKeysWithValues: ReconciledGroup.allCases.map { group in
        (group, readExifText(tiff.flatMap { rawIFD0Value($0, tag: group.tag) }))
    })
}

/// 差异行里显示的文本：截断，NUL 写成 `\0`（Copyright 两段之间的那个）。
func shownText(_ text: String) -> String {
    truncate(text.replacingOccurrences(of: "\0", with: "\\0"))
}

// MARK: - 照搬自检的放行

/// 照搬后新变得不一致的视图键 `key`（照搬后的值是 `value`，读不出是 nil）是不是「如实显示了源
/// EXIF 的原文」：属于某一组调和字段，该组的 EXIF 原文 `originals` 可靠，且 `value` 等于它
/// （valuesMatch）。是就返回那一组，否则 nil。
func exifOriginalKept(key: String, value: String?, originals: [ReconciledGroup: ExifTextReading]) -> ReconciledGroup? {
    guard let group = ReconciledGroup(viewKey: key), case .reliable(let original)? = originals[group],
          let value, valuesMatch(value, original) else { return nil }
    return group
}

/// 照搬后新变得不一致的键 `worse` 分成两份：放行的（exifOriginalKept）归到组，按组的固定顺序；
/// 其余的是真退步。
func splitRegressions(_ worse: Set<String>, afterView: [String: String],
                      originals: [ReconciledGroup: ExifTextReading]) -> (blocking: Set<String>, kept: [ReconciledGroup]) {
    var blocking = Set<String>()
    var kept = Set<ReconciledGroup>()
    for key in worse {
        if let group = exifOriginalKept(key: key, value: afterView[key], originals: originals) {
            kept.insert(group)
        } else {
            blocking.insert(key)
        }
    }
    return (blocking, ReconciledGroup.allCases.filter(kept.contains))
}
