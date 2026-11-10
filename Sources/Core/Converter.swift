// 单张图的转换：读取元数据、编码 HEIF、搬运文件层属性。
// 批量编排见 Batch.swift，校验比对见 MetadataDiff.swift，
// 手写 EXIF 解析见 ExifReader.swift。
//
// 元数据保留分三层：
//   1. 图像元数据字典（EXIF / GPS / IPTC / TIFF / ExifAux）——拍摄时间、
//      拍摄位置、相机型号、曝光参数、图像描述、UserComment 等。
//   2. XMP 数据包（CGImageMetadata）——Lightroom / Photoshop / Bridge 写入的
//      备注、标题、评级、版权、人脸区域等。
//   3. 文件层面的元数据——创建/修改时间、POSIX 权限、扩展属性
//      （访达备注 kMDItemFinderComment、标签 kMDItemUserTags 等）。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 转换选项

struct ConversionOptions: Equatable {
    /// 命令行与界面共用的默认值。界面以前自己另写了一份，`recursive` 在两端
    /// 悄悄分叉成 false / true，同一句「指定文件夹下」在两边含义不同。
    /// 一律从这里取，想分叉就必须显式写出来并说明理由。
    static let `default` = ConversionOptions()

    var quality: Double = 0.8
    /// 输出位置。用 URL 而不是路径字符串：界面本来就持有 URL，命令行解析时
    /// 展开一次 ~ 即可，省得在边界上来回转换。
    var output: URL?
    var recursive = false
    var overwrite = false
    var deleteOriginal = false
    var dryRun = false
    var verbose = false
    var verify = false
    var jobs = ProcessInfo.processInfo.activeProcessorCount
    var inputs: [String] = []

    /// 要删除源文件就必须先校验——否则一旦有元数据丢失，原始信息将无法找回。
    var verifyEnabled: Bool { verify || deleteOriginal }
}

// MARK: - 元数据搬运

/// 把 CGImageSource 的所有属性字典读出来，作为写入 HEIC 时的属性。
/// 这些字典里就是拍摄时间（Exif/DateTimeOriginal）、位置（GPS）、备注
/// （Exif/UserComment、TIFF/ImageDescription、IPTC/Caption）等信息。
func imageProperties(_ src: CGImageSource) -> [CFString: Any] {
    var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    // 容器级属性（文件大小等）里偶尔也带有索引级没有的字典，做一次补齐而不是覆盖。
    if let container = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] {
        for (k, v) in container where props[k] == nil { props[k] = v }
    }
    // 这些是源文件的物理描述，不应该写进目标文件的元数据。
    for k in [kCGImagePropertyFileSize, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] {
        props.removeValue(forKey: k)
    }
    return props
}

/// 在 ImageIO 给出的属性之上，补回它读不出来的字段。目前只有一处：
/// 缺少字符集前缀的 EXIF UserComment（见 rawExifUserComment 的说明）。
func repairedProperties(_ src: CGImageSource, url: URL) -> [CFString: Any] {
    var props = imageProperties(src)
    var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
    let seenByImageIO = trimPadding((exif[kCGImagePropertyExifUserComment] as? String) ?? "")
    guard seenByImageIO.isEmpty, let recovered = rawExifUserComment(of: url) else { return props }

    // ImageIO 的写入器把字符数当字节数算，非 ASCII 文本会被截掉一半；
    // 补上等长的 NUL 正好抵消。若哪天 Apple 修了这个缺陷，多出来的 NUL
    // 属于 EXIF 定长字段的正常填充，读取方会自行忽略，两种情况都安全。
    // 纯 ASCII 不受这个缺陷影响（很多机型往这个字段塞的是整段调试信息），
    // 就不必额外补齐。
    let needsPadding = recovered.unicodeScalars.contains { $0.value > 127 }
    exif[kCGImagePropertyExifUserComment] = needsPadding
        ? recovered + String(repeating: "\0", count: recovered.count + 8)
        : recovered
    props[kCGImagePropertyExifDictionary] = exif
    return props
}

// MARK: - 文件层元数据（时间戳 / 权限 / 扩展属性）

/// 不应该跟着复制到新文件上的扩展属性。
let skippedXattrs: Set<String> = ["com.apple.quarantine", "com.apple.ResourceFork"]

func copyExtendedAttributes(from src: String, to dst: String) -> Int {
    let size = listxattr(src, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return 0 }
    var namebuf = [CChar](repeating: 0, count: size)
    guard listxattr(src, &namebuf, size, XATTR_NOFOLLOW) == size else { return 0 }

    var copied = 0
    var start = 0
    for i in 0..<size where namebuf[i] == 0 {
        defer { start = i + 1 }
        guard i > start else { continue }
        let name = String(cString: Array(namebuf[start..<i]) + [0])
        if skippedXattrs.contains(name) { continue }
        let vlen = getxattr(src, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard vlen >= 0 else { continue }
        var value = [UInt8](repeating: 0, count: max(vlen, 1))
        guard getxattr(src, name, &value, vlen, 0, XATTR_NOFOLLOW) == vlen else { continue }
        if setxattr(dst, name, value, vlen, 0, XATTR_NOFOLLOW) == 0 { copied += 1 }
    }
    return copied
}

/// 复制创建时间、修改时间和权限。相册类 App 在没有 EXIF 时会回退到文件时间，
/// 所以这一步对"拍摄时间"的完整性同样重要。
func copyFileAttributes(from src: URL, to dst: URL) {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: src.path) else { return }
    var toSet: [FileAttributeKey: Any] = [:]
    for key in [FileAttributeKey.creationDate, .modificationDate, .posixPermissions] {
        if let v = attrs[key] { toSet[key] = v }
    }
    try? fm.setAttributes(toSet, ofItemAtPath: dst.path)
}

// MARK: - 转换

/// 一张图转换成功后的全部结果。原先是 ConvertResult.converted 的六个关联值，
/// 在命令行和界面两处各自逐个解包再搬进别的结构——六项总是一起出现，
/// 本来就是一个类型。
struct ConversionReport {
    let dest: URL
    let inBytes: Int
    let outBytes: Int
    /// 搬运过去的元数据条目数。
    let tagCount: Int
    /// 搬运过去的扩展属性条数。
    let xattrCount: Int
    /// 元数据校验的结果：没校验、通过、有差异，三者在类型上分开。
    let verification: Verification

    /// 与元数据差异无关的一句状态说明，目前只有一种：请求了删除源文件但
    /// 因校验未通过而没删。没有要说的就是 nil。
    let note: String?

    var savingPercent: Int? { percentSaved(inBytes: inBytes, outBytes: outBytes) }
}

/// 一次元数据校验的结果。"没校验"和"校验通过"是两个值，下游只能靠匹配
/// `.passed` 得出"通过"——没有一个空数组能同时表示这两件事。
enum Verification: Equatable {
    case notVerified
    case passed
    /// 非空。只装元数据差异，别的什么都不要塞：下游（命令行的"发现 N 处差异"、
    /// 界面的橙色徽章与弹窗标题）拿它的条数当差异条数，混进一句状态说明就会虚增。
    case differences([String])

    /// 由比对结果构造：空表示通过。只在真的做过比对时调用。
    init(comparing differences: [String]) {
        self = differences.isEmpty ? .passed : .differences(differences)
    }

    var hasDifferences: Bool {
        if case .differences = self { return true }
        return false
    }
}

enum ConvertResult {
    case converted(ConversionReport)
    case skipped(String)
    case failed(String)
}

/// 转换单张。`dest` 由 assignDestinations 预先定好且保证全局唯一——不要在这里
/// 自行推导目标路径，并发下那样会让两个任务抢同一个文件。
func convert(_ input: URL, opts: ConversionOptions, dest: URL) -> ConvertResult {
    guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
        return .failed("无法读取图像")
    }
    guard let type = CGImageSourceGetType(src) as String?, type == UTType.jpeg.identifier else {
        return .skipped("不是 JPEG 文件")
    }
    guard CGImageSourceGetCount(src) > 0 else { return .failed("文件中没有图像") }

    let fm = FileManager.default

    if fm.fileExists(atPath: dest.path) && !opts.overwrite {
        return .skipped("输出已存在: \(dest.lastPathComponent)（用 -f 覆盖）")
    }
    if dest.standardizedFileURL == input.standardizedFileURL {
        return .failed("输出路径与输入相同")
    }

    let inBytes = fileSize(input)   // 要在可能删除源文件之前读
    let props = repairedProperties(src, url: input)
    let xmp = CGImageSourceCopyMetadataAtIndex(src, 0, nil)

    var flatProps: [String: String] = [:]
    flatten(props, into: &flatProps)
    let tagCount = flatProps.count

    if opts.dryRun {
        return .converted(ConversionReport(dest: dest, inBytes: inBytes, outBytes: 0,
                                          tagCount: tagCount, xattrCount: 0,
                                          verification: .notVerified, note: nil))
    }

    // 先写临时文件，成功后再原子替换，避免中断留下半个文件。
    // 目录到这里才建：被重名避让挪开的那些路径就不会留下空文件夹。
    let folder = dest.deletingLastPathComponent()
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let tmp = folder.appendingPathComponent(".jpeg2heif-\(UUID().uuidString).heic")

    var destProps = props
    destProps[kCGImageDestinationLossyCompressionQuality] = opts.quality
    guard encodeHEIF(src, properties: destProps, xmp: xmp, to: tmp) else {
        try? fm.removeItem(at: tmp)
        return .failed("HEIC 编码失败")
    }

    copyFileAttributes(from: input, to: tmp)
    let xattrs = copyExtendedAttributes(from: input.path, to: tmp.path)

    do {
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
    } catch {
        try? fm.removeItem(at: tmp)
        return .failed("写入目标失败: \(error.localizedDescription)")
    }

    let verification = opts.verifyEnabled
        ? Verification(comparing: metadataDiff(source: input, dest: dest)) : .notVerified

    // 删源文件的前提是逐条比对确认无损；有差异就留着，并说明为什么留。
    var note: String?
    if opts.deleteOriginal {
        if verification == .passed {
            try? fm.removeItem(at: input)
        } else {
            note = "因元数据校验未通过，保留了源文件"
        }
    }

    return .converted(ConversionReport(dest: dest, inBytes: inBytes, outBytes: fileSize(dest),
                                      tagCount: tagCount, xattrCount: xattrs,
                                      verification: verification, note: note))
}

/// 把源图编码成 HEIF 写到 `url`，分两遍：
///
/// 1. AddImageFromSource 直接从源转码到内存：像素不先解码成位图，ICC 色彩描述
///    文件跟着走，`properties`（含 UserComment 的修补）写进 EXIF 等字典。
///    它不认 kCGImageDestinationMetadata，XMP 包里属性字典表达不了的标签
///    （xmp:Label、lr:hierarchicalSubject、dc:title 的其它语言、人脸区域的 Name、
///    自定义命名空间、xmpMM:* 等）这一遍都带不过去。
/// 2. CopyImageSource 把第一遍的结果写到 `url`，同时把源的 XMP 合并进去。
///    这一步只改元数据，不重新编码像素。
func encodeHEIF(_ src: CGImageSource, properties: [CFString: Any],
                xmp: CGImageMetadata?, to url: URL) -> Bool {
    let heic = UTType.heic.identifier as CFString
    // 源里没有 XMP 就没有第二遍可做；CopyImageSource 不带元数据选项时直接失败。
    guard let xmp else {
        guard let out = CGImageDestinationCreateWithURL(url as CFURL, heic, 1, nil) else { return false }
        CGImageDestinationAddImageFromSource(out, src, 0, properties as CFDictionary)
        return CGImageDestinationFinalize(out)
    }
    let encoded = NSMutableData()
    guard let first = CGImageDestinationCreateWithData(encoded, heic, 1, nil) else { return false }
    CGImageDestinationAddImageFromSource(first, src, 0, properties as CFDictionary)
    guard CGImageDestinationFinalize(first),
          let firstPass = CGImageSourceCreateWithData(encoded, nil),
          let out = CGImageDestinationCreateWithURL(url as CFURL, heic, 1, nil) else { return false }
    let options = [kCGImageDestinationMetadata: xmp, kCGImageDestinationMergeMetadata: true] as CFDictionary
    return CGImageDestinationCopyImageSource(out, firstPass, options, nil)
}

func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
}

func humanSize(_ bytes: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var v = Double(bytes), i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(bytes) B" : String(format: "%.1f %@", v, units[i])
}
