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
    /// 命令行与界面共用的默认值。一律从这里取，想分叉就必须显式写出来并说明理由
    /// （单测「命令行与界面的默认值」一组守着）。
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
/// 缺少字符集前缀的 EXIF UserComment（见 rawExifUserComment 的说明）。它同时是 --verify
/// 源侧的视图；不进视图的 ImageUniqueID 另在 propertiesToWrite 里补。
func repairedProperties(_ src: CGImageSource, url: URL) -> [CFString: Any] {
    var props = imageProperties(src)
    var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
    let seenByImageIO = trimPadding((exif[kCGImagePropertyExifUserComment] as? String) ?? "")
    guard seenByImageIO.isEmpty, let recovered = rawExifUserComment(of: url) else { return props }
    // 这里放的是备注本身。为 HEIC 写入器做的改写只在 encodeHEIF 里做一次，
    // 这个函数的结果同时是 --verify 源侧的视图，不能掺进写入用的填充。
    exif[kCGImagePropertyExifUserComment] = recovered
    props[kCGImagePropertyExifDictionary] = exif
    return props
}

/// 要写进产物的属性：在 repairedProperties 的结果上补回 ImageIO 读不出的 ImageUniqueID
/// （33 字节以外的写法，规则见 restorableImageUniqueID）。视图里已经有它时原样返回同一个字典。
///
/// 补回的值只用于写入，不进 --verify 的源侧视图：产物一侧的 ImageIO 视图同样读不出这类值，
/// 放进源侧视图就会被键空间比对报成丢失。值写对没有，由原始清点按两边的原始字节核对
/// （compareRawExif）。
func propertiesToWrite(_ props: [CFString: Any], source url: URL) -> [CFString: Any] {
    var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
    guard exif[kCGImagePropertyExifImageUniqueID] == nil,
          let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          let tiff = TIFFStructure(jpeg: [UInt8](data)),
          let id = restorableImageUniqueID(rawExifEntries(tiff)) else { return props }
    exif[kCGImagePropertyExifImageUniqueID] = id
    var result = props
    result[kCGImagePropertyExifDictionary] = exif
    return result
}

/// 把 UserComment 改写成 ImageIO 的 HEIC 写入器能完整写下的形式。
///
/// 写入器的行为（实测，L 为传入字符串的 UTF-16 单元数，含其中的 NUL）：
/// - 首个 UTF-16 单元是 ASCII：用 `ASCII\0\0\0` 前缀写 L 字节，每个非 ASCII
///   单元都换成 `?`。
/// - 否则：用 `UNICODE\0` 前缀，字段留 2×(L+1) 字节，只写进前 ⌊L/2⌋ 个
///   UTF-16 单元，其余是 NUL。
/// 读取时 ImageIO 去掉开头的 BOM，尾部 NUL 原样返回。
///
/// 所以含非 ASCII 的备注：去掉已有的尾部 NUL；首单元是 ASCII 就在前面加 BOM，
/// 让写入器选 UNICODE；再补上与此时单元数相等的 NUL，写进去的前 ⌊2L/2⌋ = L 个
/// 单元正好是完整文本，字段尾部剩 L+1 个 NUL 单元（写入器总会留下的那一个，加上
/// 本该装文本的后一半）。纯 ASCII 的备注原样返回。
func userCommentForHEIFWriter(_ comment: String) -> String {
    var units = Array(comment.utf16)
    guard units.contains(where: { $0 > 0x7F }) else { return comment }
    while units.last == 0 { units.removeLast() }
    if units[0] <= 0x7F { units.insert(0xFEFF, at: 0) }
    return String(decoding: units + [UInt16](repeating: 0, count: units.count), as: UTF16.self)
}

/// 写 HEIC 前对属性字典做的唯一一处改写：UserComment 换成
/// `userCommentForHEIFWriter` 的结果。不需要改写时原样返回同一个字典。
func propertiesForHEIFWriter(_ properties: [CFString: Any]) -> [CFString: Any] {
    guard var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
          let comment = exif[kCGImagePropertyExifUserComment] as? String else { return properties }
    let written = userCommentForHEIFWriter(comment)
    guard written != comment else { return properties }
    exif[kCGImagePropertyExifUserComment] = written
    var result = properties
    result[kCGImagePropertyExifDictionary] = exif
    return result
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

/// 一张图转换成功后的全部结果。
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

    /// 与元数据差异无关的状态说明：产物比原图大，以及请求了删除源文件却没删的原因
    /// （校验未通过、产物比原图大）。几句用「；」连成一行。没有要说的就是 nil。
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
    let props = propertiesToWrite(repairedProperties(src, url: input), source: input)
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
    let outBytes = fileSize(dest)

    // 删源文件的前提是逐条比对确认无损，而且产物不比原图大——换成更大的文件不是
    // 用户要的结果。不删就说明为什么。
    var notes: [String] = []
    let growth = growthPercent(inBytes: inBytes, outBytes: outBytes)
    if let growth { notes.append("HEIF 比原图大 \(growth)") }
    if opts.deleteOriginal {
        if verification != .passed {
            notes.append("因元数据校验未通过，保留了源文件")
        } else if growth != nil {
            notes.append("因产物比原图大，保留了源文件")
        } else {
            try? fm.removeItem(at: input)
        }
    }

    return .converted(ConversionReport(dest: dest, inBytes: inBytes, outBytes: outBytes,
                                      tagCount: tagCount, xattrCount: xattrs,
                                      verification: verification,
                                      note: notes.isEmpty ? nil : notes.joined(separator: "；")))
}

/// 产物比源大多少，写成「33%」；不比源大（或缺体积数据）是 nil。不到 1% 的写「不到 1%」，
/// 免得出现「大 0%」。命令行、界面和批量汇总的「变大」都以这里为准。
func growthPercent(inBytes: Int, outBytes: Int) -> String? {
    guard inBytes > 0, outBytes > inBytes else { return nil }
    let pct = Int((Double(outBytes - inBytes) / Double(inBytes) * 100).rounded())
    return pct >= 1 ? "\(pct)%" : "不到 1%"
}

/// ImageIO 定义的全部辅助图类型（`kCGImageAuxiliaryDataType*` 的每一个成员）。
/// 转换时逐个从源里取，取得到就加进产物；校验时逐个比源与产物。
let auxiliaryDataTypes: [CFString] = {
    var types = [
        kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
        kCGImageAuxiliaryDataTypePortraitEffectsMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
        kCGImageAuxiliaryDataTypeHDRGainMap,
    ]
    if #available(macOS 15.0, *) { types.append(kCGImageAuxiliaryDataTypeISOGainMap) }
    return types
}()

/// 增益图的两种类型。它们不走 AddAuxiliaryDataInfo，见 encodeFirstPass。
let gainMapTypes: [CFString] = {
    var types = [kCGImageAuxiliaryDataTypeHDRGainMap]
    if #available(macOS 15.0, *) { types.append(kCGImageAuxiliaryDataTypeISOGainMap) }
    return types
}()

/// 源图第 0 张的辅助图，按 auxiliaryDataTypes 的顺序，每种至多一份。
func auxiliaryImages(of src: CGImageSource) -> [(type: CFString, info: CFDictionary)] {
    auxiliaryDataTypes.compactMap { type in
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type).map { (type, $0) }
    }
}

/// 第一遍：从源转码进 `dest`，把源里的辅助图加在主图后面，然后收尾。
///
/// 增益图由 AddImageFromSource 的 kCGImageDestinationPreserveGainMap 带过去，不走
/// AddAuxiliaryDataInfo：3 通道的 ISO 增益图（手机 HDR 照片里有，像素格式 `420f`）
/// 取出来的字典里没有 kCGImageAuxiliaryDataInfoData，交给 AddAuxiliaryDataInfo 时
/// 收尾照样成功、产物里却没有增益图；PreserveGainMap 能搬它。单通道增益图两条路的
/// 产物逐字节相同；两条路一起走，苹果增益图会写两份，ISO 增益图会收尾失败。
/// 深度图、视差图、蒙版照旧走 AddAuxiliaryDataInfo。
///
/// 带辅助图收尾失败时，换一个新目标、连 PreserveGainMap 一起去掉再编一次：辅助图
/// 搬不过去不该让整次转换失败，校验会把没搬过去的辅助图逐项报成丢失。
private func encodeFirstPass(_ src: CGImageSource, properties: [CFString: Any],
                             makeDestination: () -> CGImageDestination?) -> Bool {
    let present = auxiliaryImages(of: src)
    let hasGainMap = present.contains { item in gainMapTypes.contains { $0 == item.type } }
    let auxiliary = present.filter { item in !gainMapTypes.contains { $0 == item.type } }
    var carrying = properties
    if hasGainMap { carrying[kCGImageDestinationPreserveGainMap] = true }
    for carry in present.isEmpty ? [false] : [true, false] {
        guard let dest = makeDestination() else { return false }
        CGImageDestinationAddImageFromSource(dest, src, 0, (carry ? carrying : properties) as CFDictionary)
        if carry {
            for (type, info) in auxiliary { CGImageDestinationAddAuxiliaryDataInfo(dest, type, info) }
        }
        if CGImageDestinationFinalize(dest) { return true }
    }
    return false
}

/// 把源图编码成 HEIF 写到 `url`，分两遍：
///
/// 1. AddImageFromSource 直接从源转码到内存：像素不先解码成位图，ICC 色彩描述
///    文件跟着走，`properties`（含 UserComment 的修补与补回的 ImageUniqueID）写进 EXIF 等字典。
///    写之前先过 propertiesForHEIFWriter：源属性直通的备注和修补出来的备注都走
///    这一处，不在别处另做改写。源里的辅助图也在这一遍加进去：增益图靠
///    PreserveGainMap，深度图、蒙版等靠 AddAuxiliaryDataInfo（见 encodeFirstPass）。
///    它不认 kCGImageDestinationMetadata，XMP 包里属性字典表达不了的标签
///    （xmp:Label、lr:hierarchicalSubject、dc:title 的其它语言、人脸区域的 Name、
///    自定义命名空间、xmpMM:* 等）这一遍都带不过去。
/// 2. CopyImageSource 把第一遍的结果写到 `url`，同时把源的 XMP 合并进去。
///    这一步只改元数据，不重新编码像素，第一遍加进去的辅助图原样留在产物里。
///    它的选项里只有 XMP 和合并开关起作用：属性字典传进来会被忽略（实测带不带它，
///    产物逐字节相同），所以 EXIF 等字典只能靠第一遍写进去。
func encodeHEIF(_ src: CGImageSource, properties: [CFString: Any],
                xmp: CGImageMetadata?, to url: URL) -> Bool {
    let properties = propertiesForHEIFWriter(properties)
    let heic = UTType.heic.identifier as CFString
    // 源里没有 XMP 就没有第二遍可做；CopyImageSource 不带元数据选项时直接失败。
    guard let xmp else {
        return encodeFirstPass(src, properties: properties) {
            CGImageDestinationCreateWithURL(url as CFURL, heic, 1, nil)
        }
    }
    var encoded = NSMutableData()
    guard encodeFirstPass(src, properties: properties, makeDestination: {
              encoded = NSMutableData()
              return CGImageDestinationCreateWithData(encoded, heic, 1, nil)
          }),
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
