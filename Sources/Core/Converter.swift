// 单张图的转换：读取元数据、编码 HEIF、搬运文件层属性。
// 批量编排见 Batch.swift，校验比对见 MetadataDiff.swift，
// 手写 EXIF 解析见 ExifReader.swift。
//
// 元数据保留分三层：
//   1. 图像元数据字典（EXIF / GPS / IPTC / TIFF / ExifAux）——拍摄时间、
//      拍摄位置、相机型号、曝光参数、图像描述、UserComment 等。ImageIO 写完以后，
//      产物里的 EXIF 再整块换成源文件 EXIF 段的原始字节（carryRawExif）。
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
    /// ImageIO 写完 HEIC 后，把产物里的 EXIF 换成源文件 EXIF 段的原始字节（见 carryRawExif）。
    /// 命令行 --no-raw-exif 关掉它；关掉时 EXIF 全由 ImageIO 从属性字典重写。
    var rawExif = true
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

/// 在 ImageIO 给出的属性之上，补回它读错或读不出的字段。目前只有一处：UserComment，
/// 满足 SourceUserComment.toRepair 时换成自己解析出的文本。它同时是 --verify 源侧的视图；
/// 不进视图的 ImageUniqueID 和猜出来的备注另在 propertiesToWrite 里补。
func repairedProperties(_ src: CGImageSource, url: URL) -> [CFString: Any] {
    repairedProperties(imageProperties(src), url: url)
}

/// 同上，`props` 是已经取好的 imageProperties。
func repairedProperties(_ props: [CFString: Any], url: URL) -> [CFString: Any] {
    var props = props
    var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
    guard let recovered = SourceUserComment(props, reading: rawExifUserComment(of: url)).toRepair else { return props }
    // 这里放的是备注本身。为 HEIC 写入器做的改写只在 encodeHEIF 里做一次，
    // 这个函数的结果同时是 --verify 源侧的视图，不能掺进写入用的填充。
    exif[kCGImagePropertyExifUserComment] = recovered
    props[kCGImagePropertyExifDictionary] = exif
    return props
}

/// 源里的 UserComment，两种读法：ImageIO 视图里的值，和自己解析原始字节（readUserComment）的结果。
struct SourceUserComment: Equatable {
    var seenByImageIO: String?
    var reading: UserCommentReading

    /// 由 ImageIO 的视图（imageProperties）和自己解析的结果构造。
    init(_ props: [CFString: Any], reading: UserCommentReading) {
        let exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        self.init(seenByImageIO: exif[kCGImagePropertyExifUserComment] as? String, reading: reading)
    }

    init(seenByImageIO: String?, reading: UserCommentReading) {
        self.seenByImageIO = seenByImageIO
        self.reading = reading
    }

    /// ImageIO 读不出：视图里没有，或去掉填充后为空。
    static func imageIOMisses(_ seen: String?) -> Bool { trimPadding(seen ?? "").isEmpty }

    /// 要修补成的文本（过了 normalizedUserComment）；不修补是 nil。修补的条件，两条满足一条：
    /// 1. ImageIO 读不出，且自己解析出的是可靠的文本；
    /// 2. 值是 `ASCII\0\0\0` 头、正文含非 ASCII 的合法 UTF-8——ImageIO 按 Latin-1 把它读成乱码，
    ///    不管它读成什么都修补。
    /// 猜的备注不修补。转换时的修补（repairedProperties）、照搬时的备注改写（carryRawExif）、
    /// 校验认这种改写（carriedTIFFMatches）都以它为准。
    var toRepair: String? {
        guard case .reliable(let decoded, let header) = reading else { return nil }
        let text = normalizedUserComment(decoded)
        if SourceUserComment.imageIOMisses(seenByImageIO) { return text }
        if header == .ascii, !text.unicodeScalars.allSatisfy(\.isASCII) { return text }
        return nil
    }

    /// ImageIO 读不出、自己解析出的是猜的且有猜测串时，是那串（只给系统重写写入用）；否则 nil。
    var guessToWrite: String? {
        guard SourceUserComment.imageIOMisses(seenByImageIO), case .guessed(let guess?, _, _) = reading else { return nil }
        return guess
    }
}

/// 要写进产物的属性：在 repairedProperties 的结果上补回两样不进 --verify 源侧视图的东西——
/// ImageIO 读不出的 ImageUniqueID（33 字节以外的写法，规则见 restorableImageUniqueID），和 ImageIO
/// 读不出、自己解析也只能猜的备注的猜测串（SourceUserComment.guessToWrite）。都不用补时原样
/// 返回同一个字典。
///
/// ImageUniqueID 不进源侧视图：产物一侧的 ImageIO 视图同样读不出这类值，放进源侧视图就会被
/// 键空间比对报成丢失。值写对没有，由原始清点按两边的原始字节核对（compareRawExif）。
/// 猜测串不进源侧视图：它不是可靠的原文。Latin-1 一个字节对一个码位，原字节还能从产物里一一
/// 还原，所以照写；写了以后由备注原文核对（userCommentOriginalIssues）报出来。
func propertiesToWrite(_ props: [CFString: Any], source url: URL) -> [CFString: Any] {
    var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return props }
    let bytes = [UInt8](data)
    var changed = false
    if exif[kCGImagePropertyExifImageUniqueID] == nil, let tiff = TIFFStructure(jpeg: bytes),
       let id = restorableImageUniqueID(rawExifEntries(tiff)) {
        exif[kCGImagePropertyExifImageUniqueID] = id
        changed = true
    }
    if let guess = SourceUserComment(props, reading: rawExifUserComment(in: bytes)).guessToWrite {
        exif[kCGImagePropertyExifUserComment] = guess
        changed = true
    }
    guard changed else { return props }
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
/// 读取时 ImageIO 去掉开头的 BOM，尾部 NUL 原样返回。写进去的 UTF-16 是大端；没有 BOM 时
/// exiftool 等别的读取器要自己猜字节序，纯中文的备注会被猜成小端、读成乱码。
///
/// 所以含非 ASCII 的备注：去掉已有的尾部 NUL；开头还没有 BOM 就加一个——首单元是 ASCII 时
/// 它让写入器选 UNICODE，任何时候它都让别的读取器认得出字节序；再补上与此时单元数相等的
/// NUL，写进去的前 ⌊2L/2⌋ = L 个单元正好是 BOM 加完整文本，字段尾部剩 L+1 个 NUL 单元
/// （写入器总会留下的那一个，加上本该装文本的后一半）。纯 ASCII 的备注原样返回。
func userCommentForHEIFWriter(_ comment: String) -> String {
    var units = Array(comment.utf16)
    guard units.contains(where: { $0 > 0x7F }) else { return comment }
    while units.last == 0 { units.removeLast() }
    if units[0] != 0xFEFF { units.insert(0xFEFF, at: 0) }
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
    /// EXIF 整块照搬的结果；没开照搬（--no-raw-exif）或预演时是 nil。只在 -v 时显示。
    let rawExif: RawExifOutcome?
    /// 产物比原图大而重编过一次时，两遍的大小；没重编是 nil。只在 -v 时显示。
    let reencode: Reencode?

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

/// 产物比原图大时重编一次的经过（见 convert）。
struct Reencode: Equatable {
    /// 第一遍「编码 + 照搬」得到的产物字节数。
    let first: Int
    /// 第二遍的字节数；第二遍编码失败是 nil。
    let second: Int?

    /// -v 时显示的那一行（不含缩进）。
    var description: String {
        let head = "产物比原图大，重编了一次：\(humanSize(first)) → "
        guard let second else { return head + "重编失败（用了第一份）" }
        let tail = second == first ? "（两次一样大）" : "（用了较小的一份）"
        return head + humanSize(second) + tail
    }
}

/// 「编码」那一步：把源图连同属性和 XMP 编码成 HEIF 写到给定的路径，成功返回 true。
/// 签名与 encodeHEIF 相同。
typealias HEIFEncoder = (CGImageSource, [CFString: Any], CGImageMetadata?, URL) -> Bool

enum ConvertResult {
    case converted(ConversionReport)
    case skipped(String)
    case failed(String)
}

/// 转换单张。`dest` 由 assignDestinations 预先定好且保证全局唯一——不要在这里
/// 自行推导目标路径，并发下那样会让两个任务抢同一个文件。
///
/// 「编码 + EXIF 整块照搬」得到的产物比源大（判据是 growthPercent）时，这一段原样再做
/// 一遍写到另一个临时文件，第二份更小就用第二份，否则（一样大、更大、第二遍编码失败）
/// 用第一份，没用上的那份删掉。只重编这一次。硬件编码器偶尔会把一张图按高得多的质量
/// 编出来，这一遍能把它换回正常大小的产物。
///
/// `encode` 只供单测注入假的编码步骤；命令行和界面都用默认值 encodeHEIF。
func convert(_ input: URL, opts: ConversionOptions, dest: URL,
             encode: HEIFEncoder = encodeHEIF) -> ConvertResult {
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
                                          verification: .notVerified, rawExif: nil, reencode: nil,
                                          note: nil))
    }

    // 先写临时文件，成功后再原子替换，避免中断留下半个文件。
    // 目录到这里才建：被重名避让挪开的那些路径就不会留下空文件夹。
    let folder = dest.deletingLastPathComponent()
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

    var destProps = props
    destProps[kCGImageDestinationLossyCompressionQuality] = opts.quality
    /// 「编码 + 照搬」一遍，写进一个新的临时文件。编码失败是 nil，临时文件已删。
    func encodeAndCarry() -> (url: URL, rawExif: RawExifOutcome?)? {
        let tmp = folder.appendingPathComponent(".jpeg2heif-\(UUID().uuidString).heic")
        guard encode(src, destProps, xmp, tmp) else {
            try? fm.removeItem(at: tmp)
            return nil
        }
        return (tmp, opts.rawExif ? carryRawExif(source: input, product: tmp) : nil)
    }
    guard var product = encodeAndCarry() else { return .failed("HEIC 编码失败") }
    var reencode: Reencode?
    let firstBytes = fileSize(product.url)
    if growthPercent(inBytes: inBytes, outBytes: firstBytes) != nil {
        let second = encodeAndCarry()
        let secondBytes = second.map { fileSize($0.url) }
        reencode = Reencode(first: firstBytes, second: secondBytes)
        if let second, let secondBytes, secondBytes < firstBytes {
            try? fm.removeItem(at: product.url)
            product = second
        } else if let second {
            try? fm.removeItem(at: second.url)
        }
    }
    let tmp = product.url
    let rawExif = product.rawExif

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
                                      verification: verification, rawExif: rawExif,
                                      reencode: reencode, note: notes.isEmpty ? nil : notes.joined(separator: "；")))
}

// MARK: - EXIF 整块照搬

/// 一张图的 EXIF 照搬了没有。
enum RawExifOutcome: Equatable {
    /// 照搬了源文件 EXIF 段里这么多字节的 TIFF；`commentRewritten` 是照搬的块上改写过备注
    /// （见 rewritingUserComment），字节数仍是源 TIFF 的。
    case carried(bytes: Int, commentRewritten: Bool)
    /// 没照搬，产物保持 ImageIO 写出来的样子；附带原因。
    case kept(String)
}

/// 把 `product`（ImageIO 刚写好的 HEIC）里 Exif 项的内容换成源 JPEG 的 EXIF 原始字节。
///
/// 打算照搬的那份 TIFF：源 TIFF 原样；源里的 UserComment 要修补（SourceUserComment.toRepair）
/// 且 rewritingUserComment 肯改写时，是改写过备注的源 TIFF。猜的备注不改写，原样照搬。
///
/// 闸门与改写见 carryingExif（RawExifCarry.swift）。改写得到的新字节先写进同目录的另一个
/// 临时文件，过了 rawExifRegression 的自检才原子地替换 `product`；闸门或自检不过，`product`
/// 一个字节都不动。中断时最多留下那个另起的临时文件，不会留下半个产物。
func carryRawExif(source: URL, product: URL) -> RawExifOutcome {
    guard let sourceData = try? Data(contentsOf: source, options: .mappedIfSafe) else {
        return .kept("读不出源文件")
    }
    let sourceBytes = [UInt8](sourceData)
    let tiff: [UInt8]
    switch sourceExifTIFF(sourceBytes) {
    case .success(let t): tiff = t
    case .failure(let skip): return .kept(skip.reason)
    }
    var rewritten: [UInt8]?
    if let image = CGImageSourceCreateWithURL(source as CFURL, nil),
       let text = SourceUserComment(imageProperties(image), reading: rawExifUserComment(in: sourceBytes)).toRepair {
        rewritten = rewritingUserComment(tiff, text: text)
    }
    let intended = rewritten ?? tiff
    guard let productData = try? Data(contentsOf: product) else { return .kept("读不出产物") }
    let carried: [UInt8]
    switch carryingExif(intended, into: [UInt8](productData)) {
    case .success(let bytes): carried = bytes
    case .failure(let skip): return .kept(skip.reason)
    }
    let candidate = product.deletingLastPathComponent()
        .appendingPathComponent(".jpeg2heif-\(UUID().uuidString).heic")
    defer { try? FileManager.default.removeItem(at: candidate) }
    guard (try? Data(carried).write(to: candidate)) != nil else { return .kept("写不出照搬后的产物") }
    if let regression = rawExifRegression(source: source, sourceBytes: sourceBytes, intended: intended,
                                          before: product, after: candidate) {
        return .kept(regression)
    }
    guard rename(candidate.path, product.path) == 0 else { return .kept("换不上照搬后的产物") }
    return .carried(bytes: tiff.count, commentRewritten: rewritten != nil)
}

/// 照搬后的产物 `after` 与照搬前的 `before` 比，有没有退步；有就是原因，没有是 nil。
///
/// 1. 从 `after` 里重新取出 Exif 项，TIFF 字节与打算照搬的那份（`intended`）逐字节相同。
/// 2. ImageIO 打得开，状态完整，图像数、顶层 PixelWidth/PixelHeight/Orientation 与 `before` 相同。
/// 3. 视图不退步：用 --verify 的源侧键空间（sourceKeySpace）当 V源，`after` 里与源不一致的键
///    （inconsistentKeys）必须都已经在 `before` 里不一致。原来一致的键，一个都不许变坏。
///    EXIF 与 IIM 打架（ImageIO 调和出的值写进了产物，照搬后视图里变回 EXIF 的原值）、
///    缺字符集头而没能改写的 UserComment（照搬后 ImageIO 读不出）都靠这一条退回旧路。
func rawExifRegression(source: URL, sourceBytes: [UInt8], intended: [UInt8], before: URL, after: URL) -> String? {
    guard let afterData = try? Data(contentsOf: after),
          case .tiff(let readBack) = heifExif([UInt8](afterData)),
          Array(readBack.bytes[readBack.base..<(readBack.base + readBack.length)]) == intended else {
        return "照搬后读回的 EXIF 与打算照搬的不一致"
    }
    guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
          let beforeImage = CGImageSourceCreateWithURL(before as CFURL, nil),
          let afterImage = CGImageSourceCreateWithURL(after as CFURL, nil),
          CGImageSourceGetStatus(afterImage) == .statusComplete else {
        return "照搬后 ImageIO 打不开产物"
    }
    guard CGImageSourceGetCount(afterImage) == CGImageSourceGetCount(beforeImage) else {
        return "照搬后图像数变了"
    }
    let a = CGImageSourceCopyPropertiesAtIndex(afterImage, 0, nil) as? [CFString: Any] ?? [:]
    let b = CGImageSourceCopyPropertiesAtIndex(beforeImage, 0, nil) as? [CFString: Any] ?? [:]
    for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] {
        guard (a[key] as? NSNumber) == (b[key] as? NSNumber) else { return "照搬后 \(key as String) 变了" }
    }
    let reference = sourceKeySpace(of: sourceImage, url: source, bytes: sourceBytes)
    let afterView = metadataKeySpace(of: afterImage, url: after)
    let worse = inconsistentKeys(before: reference, after: afterView)
        .subtracting(inconsistentKeys(before: reference, after: metadataKeySpace(of: beforeImage, url: before)))
    guard let key = worse.sorted().first else { return nil }
    let more = worse.count > 1 ? "（共 \(worse.count) 处）" : ""
    if reference[key] == nil { return "照搬后会多出源里没有的 \(key)\(more)" }
    return afterView[key] == nil ? "照搬后 \(key) 会读不出\(more)" : "照搬后 \(key) 会与源不一致\(more)"
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
