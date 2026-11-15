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

public struct ConversionOptions: Equatable {
    /// 命令行与界面共用的默认值。一律从这里取，想分叉就必须显式写出来并说明理由
    /// （单测「命令行与界面的默认值」一组守着）。
    public static let `default` = ConversionOptions()

    public var quality: Double = 0.8
    /// 输出位置。用 URL 而不是路径字符串：界面本来就持有 URL，命令行解析时
    /// 展开一次 ~ 即可，省得在边界上来回转换。
    public var output: URL?
    public var recursive = false
    public var overwrite = false
    public var deleteOriginal = false
    public var dryRun = false
    public var verbose = false
    public var verify = false
    /// ImageIO 写完 HEIC 后，把产物里的 EXIF 换成源文件的 EXIF：JPEG 是 EXIF 段的原始字节
    /// （见 carryRawExif），RAW 是从 RAW 里取出来拼成的一块（见 carryCameraRawExif）。
    /// 命令行 --no-raw-exif 关掉它；关掉时 EXIF 全由 ImageIO 从属性字典重写。
    public var rawExif = true
    /// 把源文件扩展属性里「照片」App 的说明写进产物 XMP 的 dc:description（见 captionPlan）。
    /// 命令行 --embed-caption 打开；界面没有这个开关。
    public var embedCaption = false
    /// CMYK 的 JPEG 也转。默认跳过（见 cmykSkipReason）：HEIF 只能存 RGB，转了颜色会变。
    /// 命令行 jpeg2heif --allow-cmyk、界面转换面板「高级」里的「也转 CMYK 的 JPEG」打开。
    /// 强制转换时校验照样报出 ColorModel、ProfileName 两条变化，--delete-original 不删源。
    public var convertCMYK = false
    /// 转完核对画质（只对 JPEG，见 QualityCheck.swift）：产物交出之前与源比 PSNR 和最差 1% 局部 SSIM，
    /// 不达标按 `onQualityDrop` 处理。命令行 jpeg2heif --no-quality-check 关掉；界面转换面板「高级」里
    /// 的「转完核对画质」。
    public var qualityCheck = true
    /// 画质核对的两个门槛。命令行 --min-ssim / --min-psnr。
    public var qualityThresholds = QualityThresholds(minSSIM: 0.90, minPSNR: 33)
    /// 不达标时怎么办。命令行 --on-quality-drop skip|retry。
    public var onQualityDrop = QualityDropAction.skip
    public var jobs = ProcessInfo.processInfo.activeProcessorCount
    public var inputs: [String] = []
    /// 收哪几种源：jpeg2heif 是 [.jpeg]，raw2heif 是 [.raw]。界面每批开始时设成两种都收（ConversionTargets.apply）。
    /// 目录扫描按它挑扩展名，convert 按内容判定后不在这里的跳过（并指路到另一个命令）。
    public var sources: Set<SourceKind> = [.jpeg]

    /// RAW 的默认并发数：min(核数, 4)。保守的临时值：一张 4500 万像素的 CR3 显影时要把全尺寸的
    /// 16 位数据和显影结果都放在内存里，按核数开满可能把内存吃紧；4 这个数没有实测依据，
    /// 待用真 RAW 量峰值内存（`/usr/bin/time -l`）后再定。
    /// 手写的小 DNG 量不出真 RAW 的量级。用户给了 -j 时照 -j。
    public static let defaultRAWJobs = min(ProcessInfo.processInfo.activeProcessorCount, 4)

    /// 要删除源文件就必须先校验——否则一旦有元数据丢失，原始信息将无法找回。
    public var verifyEnabled: Bool { verify || deleteOriginal }
}

// MARK: - 元数据搬运

/// 把 CGImageSource 的所有属性字典读出来，作为写入 HEIC 时的属性。
/// 这些字典里就是拍摄时间（Exif/DateTimeOriginal）、位置（GPS）、备注
/// （Exif/UserComment、TIFF/ImageDescription、IPTC/Caption）等信息。
public func imageProperties(_ src: CGImageSource) -> [CFString: Any] {
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

/// encodeHEIF 对属性字典做的唯一一处改写：UserComment 换成 `userCommentForHEIFWriter` 的结果。
/// 不需要改写时原样返回同一个字典。（RAW 源的版本号在这之前由 convert 整理，见
/// versionFieldsForHEIFWriter。）
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

/// 不应该跟着复制到新文件上的扩展属性。转换时不拷、--verify 也不核对（extendedAttributeIssues），
/// 两处用的都是这一份。
///
/// `com.apple.provenance` 由系统管：每个新建文件都会被自动加上，值由创建它的进程决定；setxattr
/// 写源的值返回 0，读回来仍是系统给的值，写不进去。源由别的 App 创建时两边的值必然不同，核对它
/// 只会误报。
let skippedXattrs: Set<String> = ["com.apple.quarantine", "com.apple.ResourceFork", "com.apple.provenance"]

/// `path` 上的扩展属性名，按 listxattr 给出的顺序；listxattr 出错（含文件系统不支持扩展属性）
/// 或两次读到的长度不一致是 nil。没有扩展属性是空数组。
func extendedAttributeNames(_ path: String) -> [String]? {
    let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard size >= 0 else { return nil }
    guard size > 0 else { return [] }
    var namebuf = [CChar](repeating: 0, count: size)
    guard listxattr(path, &namebuf, size, XATTR_NOFOLLOW) == size else { return nil }
    var names: [String] = []
    var start = 0
    for i in 0..<size where namebuf[i] == 0 {
        defer { start = i + 1 }
        guard i > start else { continue }
        names.append(String(cString: Array(namebuf[start..<i]) + [0]))
    }
    return names
}

/// `path` 上名为 `name` 的扩展属性的值；读不出是 nil。
func extendedAttributeValue(_ path: String, _ name: String) -> [UInt8]? {
    let vlen = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard vlen >= 0 else { return nil }
    var value = [UInt8](repeating: 0, count: max(vlen, 1))
    guard getxattr(path, name, &value, vlen, 0, XATTR_NOFOLLOW) == vlen else { return nil }
    return Array(value.prefix(vlen))
}

func copyExtendedAttributes(from src: String, to dst: String) -> Int {
    var copied = 0
    for name in extendedAttributeNames(src) ?? [] where !skippedXattrs.contains(name) {
        guard let value = extendedAttributeValue(src, name) else { continue }
        if setxattr(dst, name, value, value.count, 0, XATTR_NOFOLLOW) == 0 { copied += 1 }
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
public struct ConversionReport {
    public let dest: URL
    public let inBytes: Int
    public let outBytes: Int
    /// 搬运过去的元数据条目数。
    public let tagCount: Int
    /// 搬运过去的扩展属性条数。
    public let xattrCount: Int
    /// 元数据校验的结果：没校验、通过、有差异，三者在类型上分开。
    public let verification: Verification
    /// EXIF 整块照搬的结果；没开照搬（--no-raw-exif）或预演时是 nil。只在 -v 时显示。
    public let rawExif: RawExifOutcome?
    /// 产物比原图大而重编过一次时，两遍的大小；没重编是 nil。只在 -v 时显示。
    public let reencode: Reencode?
    /// 「照片」的说明写进文件了没有；没开 --embed-caption 或预演时是 nil。只在 -v 时显示。
    public let caption: CaptionOutcome?
    /// 画质核对的结果；没核对（RAW、预演、关掉了画质核对）是 nil。-v 时显示；重编过的另在 note 里留一句。
    public let quality: QualityOutcome?

    /// 与元数据差异无关的状态说明：画质不达标而用更高的质量重编过、产物比原图大，以及请求了删除源文件却没删的原因
    /// （校验未通过、产物比原图大、源是符号链接、删的时候出错）。几句用「；」连成一行。没有要说的就是 nil。
    public let note: String?
    /// 源文件确实被删掉了。界面据此把源从图库里拿掉：删不删的规则只在 convert 里，删的时候还可能出错，
    /// 下游不该自己再推一遍。
    public let sourceDeleted: Bool

    public var savingPercent: Int? { percentSaved(inBytes: inBytes, outBytes: outBytes) }
}

/// 一次元数据校验的结果。"没校验"和"校验通过"是两个值，下游只能靠匹配
/// `.passed` 得出"通过"——没有一个空数组能同时表示这两件事。
public enum Verification: Equatable {
    case notVerified
    case passed
    /// 非空。只装元数据差异，别的什么都不要塞：下游（命令行的"发现 N 处差异"、
    /// 界面的橙色徽章与弹窗标题）拿它的条数当差异条数，混进一句状态说明就会虚增。
    case differences([String])

    /// 由比对结果构造：空表示通过。只在真的做过比对时调用。
    init(comparing differences: [String]) {
        self = differences.isEmpty ? .passed : .differences(differences)
    }

    public var hasDifferences: Bool {
        if case .differences = self { return true }
        return false
    }
}

/// 产物比原图大时重编一次的经过（见 convert）。
public struct Reencode: Equatable {
    /// 第一遍「编码 + 照搬」得到的产物字节数。
    public let first: Int
    /// 第二遍的字节数；第二遍编码失败是 nil。
    public let second: Int?

    /// -v 时显示的那一行（不含缩进）。
    public var description: String {
        let head = "产物比原图大，重编了一次：\(humanSize(first)) → "
        guard let second else { return head + "重编失败（用了第一份）" }
        let tail = second == first ? "（两次一样大）" : "（用了较小的一份）"
        return head + humanSize(second) + tail
    }
}

/// 「编码」那一步：把源图连同属性和 XMP 编码成 HEIF 写到给定的路径，成功返回 true。
/// 签名与 encodeHEIF 相同。
typealias HEIFEncoder = (CGImageSource, [CFString: Any], CGImageMetadata?, URL) -> Bool

/// CMYK 的 JPEG 默认跳过时的原因。命令行、界面认这个值另加怎么强制转换的提示，所以是公开的常量。
public let cmykSkipReason = "CMYK 的 JPEG：HEIF 只能存 RGB，转了颜色会变"

/// 图像的色彩模型是不是 CMYK。`props` 是 CGImageSourceCopyPropertiesAtIndex 给的属性。
/// Adobe 写的 YCCK 的 JPEG，ImageIO 也报成 CMYK。界面判断「这批里有几张 CMYK」用同一个函数。
public func isCMYK(_ props: [CFString: Any]) -> Bool {
    (props[kCGImagePropertyColorModel] as? String) == (kCGImagePropertyColorModelCMYK as String)
}

public enum ConvertResult {
    case converted(ConversionReport)
    case skipped(String)
    case failed(String)
    /// 画质核对不达标，没有转换：没有产物，源原样留着（不删、目标位置上原有的文件也没动）。
    case qualityDropped(QualityDrop)
}

/// 转换单张。`dest` 由 assignDestinations 预先定好且保证全局唯一——不要在这里
/// 自行推导目标路径，并发下那样会让两个任务抢同一个文件。
///
/// 源按内容分成 JPEG 与 RAW（SourceKind），不在 `opts.sources` 里的跳过。两种共用同一套编码
/// （encodeHEIF）、文件层属性、说明、校验与删除的流程，不同之处按源类型显式分派：
/// - 写进产物的属性：JPEG 修补 UserComment、补回 ImageUniqueID（都要解析 JPEG 的段结构）；
///   RAW 只整理版本号（versionFieldsForHEIFWriter）。
/// - 编码之后、校验之前对产物 EXIF 的那一步（carryExif）：JPEG 整块照搬源 EXIF；RAW 照搬从 RAW 里
///   拼出来的一块 EXIF。`opts.rawExif` 关掉时两种都不做，EXIF 全由 ImageIO 从属性字典重写。
/// - RAW 的产物必须是 10 位，读回确认，不是就算失败。系统默认显影：AddImageFromSource 从 RAW
///   直接编码就是，方向标签照抄、像素不转。
/// - 产物比源大时重编一次：只对 JPEG。RAW 显影后的 HEIF 总比 RAW 小得多，不做。
/// - RAW 永远不删，`deleteOriginal` 对它不起作用（raw2heif 在解析参数时就拒绝 --delete-original）。
///
/// JPEG 的「编码 + EXIF 整块照搬」得到的产物比源大（判据是 growthPercent）时，这一段原样再做
/// 一遍写到另一个临时文件，第二份更小就用第二份，否则（一样大、更大、第二遍编码失败）
/// 用第一份，没用上的那份删掉。只重编这一次。硬件编码器偶尔会把一张图按高得多的质量
/// 编出来，这一遍能把它换回正常大小的产物。
///
/// 画质核对（只对 JPEG，`opts.qualityCheck`，预演不做）在上面那一步之后、产物挪到目标位置之前：
/// 留下的那份与编码用的源比（qualityReading），按 `opts.qualityThresholds` 判。不达标时：
/// - 处理方式是「不转」，或用户设的质量已不低于 qualityRetryLevel：删掉产物，返回 qualityDropped；
/// - 处理方式是「提高质量再试」：按 qualityRetryLevel 把「编码 + 照搬」再做一遍，再核对一次。
///   达标就用这一份（之后照常走变大、校验、删源的规则）；编码失败或仍不达标，删掉产物，返回 qualityDropped。
/// 返回 qualityDropped 时目标位置一个字节都没动，源也不删。
///
/// 公开的入口，编码一律用 encodeHEIF。批量转换请用 runConversions：它先统一分配目标路径。
public func convert(_ input: URL, opts: ConversionOptions, dest: URL) -> ConvertResult {
    convert(input, opts: opts, dest: dest, encode: encodeHEIF)
}

/// `encode` 只供单测注入假的编码步骤；命令行和界面都走上面那个公开的入口（encodeHEIF）。
func convert(_ given: URL, opts: ConversionOptions, dest: URL,
             encode: HEIFEncoder) -> ConvertResult {
    // 源是符号链接时，读的是它指向的那个文件：大小、文件时间、扩展属性（访达备注与标签、「照片」的
    // 说明）都在那个文件上，符号链接自己身上是另一套（扩展属性按 XATTR_NOFOLLOW 读）。不解开的话
    // 这些会悄悄换成符号链接的，校验也读同一个符号链接，发现不了。产物的名字照旧取符号链接的名字
    // （dest 早已定好）。删源时不删：删符号链接省不下空间，删它指向的文件又不是用户点名的那个。
    let isSymlink = (try? given.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    let input = isSymlink ? given.resolvingSymlinksInPath() : given
    guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
        let fm = FileManager.default
        if fm.fileExists(atPath: input.path) && !fm.isReadableFile(atPath: input.path) {
            return .failed("没有读取权限")
        }
        return .failed("无法读取图像")
    }
    let type = CGImageSourceGetType(src) as String?
    guard let kind = SourceKind(typeIdentifier: type), opts.sources.contains(kind) else {
        return .skipped(skipReason(type: type, accepted: opts.sources))
    }
    guard CGImageSourceGetCount(src) > 0 else { return .failed("文件中没有图像") }
    if kind == .jpeg, !opts.convertCMYK,
       isCMYK((CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]) {
        return .skipped(cmykSkipReason)
    }

    let fm = FileManager.default

    if fm.fileExists(atPath: dest.path) && !opts.overwrite {
        return .skipped("输出已存在: \(dest.lastPathComponent)（用 -f 覆盖）")
    }
    if dest.standardizedFileURL == input.standardizedFileURL {
        return .failed("输出路径与输入相同")
    }

    let inBytes = fileSize(input)   // 要在可能删除源文件之前读
    let props: [CFString: Any]
    switch kind {
    case .jpeg: props = propertiesToWrite(repairedProperties(src, url: input), source: input)
    case .raw: props = versionFieldsForHEIFWriter(imageProperties(src))
    }
    let sourceXMP = CGImageSourceCopyMetadataAtIndex(src, 0, nil)

    var flatProps: [String: String] = [:]
    flatten(props, into: &flatProps)
    let tagCount = flatProps.count

    if opts.dryRun {
        return .converted(ConversionReport(dest: dest, inBytes: inBytes, outBytes: 0,
                                          tagCount: tagCount, xattrCount: 0,
                                          verification: .notVerified, rawExif: nil, reencode: nil,
                                          caption: nil, quality: nil, note: nil, sourceDeleted: false))
    }

    // 要写说明时，要合并进产物的 XMP 换成带说明的那份（源里没有 XMP 时是只有说明的一份）。
    var xmp = sourceXMP
    let caption = opts.embedCaption ? captionPlan(source: input, properties: imageProperties(src), xmp: sourceXMP) : nil
    var captionOutcome: CaptionOutcome?
    switch caption {
    case .write(let text)?:
        if let merged = xmpWithCaption(sourceXMP, caption: text) { xmp = merged } else { captionOutcome = .failed }
    case .skip(let why)?: captionOutcome = .skipped(why)
    case nil: break
    }

    // 先写临时文件，成功后再原子替换，避免中断留下半个文件。
    // 目录到这里才建：被重名避让挪开的那些路径就不会留下空文件夹。
    let folder = dest.deletingLastPathComponent()
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

    var destProps = props
    destProps[kCGImageDestinationLossyCompressionQuality] = opts.quality
    /// 「编码 + 照搬」一遍，写进一个新的临时文件。编码失败是 nil，临时文件已删。
    /// 临时文件登记在 TemporaryFiles 里，进程被打断时由命令行或应用删掉；convert 返回时注销。
    var temporaries: [URL] = []
    defer {
        TemporaryFiles.shared.forget(temporaries)
        _ = ProductWriteFailures.shared.take(temporaries)   // 没用上的写盘错误（例如重编那一遍的）不留着
    }
    // 编码用的源。源里的 ICC 色彩描述文件坏了、ImageIO 因此解不出图像时，换成去掉 ICC 的那份。
    var pixels = src
    var droppedICC = false
    func encodeAndCarry() -> (url: URL, rawExif: RawExifOutcome?)? {
        let tmp = folder.appendingPathComponent(".glint-\(UUID().uuidString).heic")
        guard TemporaryFiles.shared.register(tmp) else { return nil }   // 已经在收尾
        temporaries.append(tmp)
        guard encode(pixels, destProps, xmp, tmp) else {
            _ = TemporaryFiles.remove(tmp)
            return nil
        }
        return (tmp, opts.rawExif ? carryExif(kind, source: input, product: tmp) : nil)
    }
    /// 编码失败、源解不出图像，而去掉 ICC 后解得出：按去掉 ICC 的那份再编一次。
    func encodeWithoutDamagedICC() -> (url: URL, rawExif: RawExifOutcome?)? {
        guard kind == .jpeg, !TemporaryFiles.shared.isShuttingDown, !imageDecodes(src),
              let stripped = jpegWithoutICC(input),
              let repaired = CGImageSourceCreateWithData(stripped as CFData, nil),
              imageDecodes(repaired) else { return nil }
        pixels = repaired
        droppedICC = true
        return encodeAndCarry()
    }
    guard var product = encodeAndCarry() ?? encodeWithoutDamagedICC() else {
        return .failed(encodeFailureReason(src, kind: kind, folder: folder,
                                           writeError: ProductWriteFailures.shared.take(temporaries)))
    }
    if kind == .raw, let problem = rawProductDepthProblem(product.url) {
        try? fm.removeItem(at: product.url)
        return .failed(problem)
    }
    var reencode: Reencode?
    let firstBytes = fileSize(product.url)
    if kind == .jpeg, growthPercent(inBytes: inBytes, outBytes: firstBytes) != nil {
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
    var quality: QualityOutcome?
    if kind == .jpeg, opts.qualityCheck {
        let thresholds = opts.qualityThresholds
        let first = qualityReading(source: pixels, product: product.url)
        if case .measured(let m) = first, thresholds.accepts(m) {
            quality = .passed(m)
        } else {
            try? fm.removeItem(at: product.url)
            func dropped(_ retry: QualityDrop.Retry?) -> ConvertResult {
                .qualityDropped(QualityDrop(first: first, firstQuality: opts.quality, thresholds: thresholds, retry: retry))
            }
            guard opts.onQualityDrop == .retry else { return dropped(nil) }
            guard opts.quality < qualityRetryLevel else { return dropped(.notNeeded) }
            destProps[kCGImageDestinationLossyCompressionQuality] = qualityRetryLevel
            guard let again = encodeAndCarry() else { return dropped(.encodeFailed) }
            let second = qualityReading(source: pixels, product: again.url)
            guard case .measured(let m) = second, thresholds.accepts(m) else {
                try? fm.removeItem(at: again.url)
                return dropped(.stillBelow(second))
            }
            product = again
            quality = .passedAfterRetry(first: first, firstQuality: opts.quality, retried: m)
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

    // 读回核对：产物 XMP 里的 dc:description（x-default）与说明不同或没有，算没写成。
    if case .write(let text)? = caption, captionOutcome == nil {
        captionOutcome = embeddedCaption(at: dest) == text ? .written(characters: text.count) : .failed
    }
    // 去掉了坏的 ICC：颜色按 sRGB 解释，可能和原图有偏差。算一条差异，--delete-original 因此不删源。
    // RAW 截短了而解码器照样显影出来（缺的部分是它补的）：同样算一条差异，见 RawCompleteness.swift。
    let rawShortfall = kind == .raw
        ? (try? Data(contentsOf: input, options: .mappedIfSafe)).flatMap {
            rawDataShortfall([UInt8]($0), type: CGImageSourceGetType(src) as String?)
        } : nil
    let conversionIssues = (droppedICC ? [damagedICCNotice] : [])
        + (rawShortfall.map { [rawTruncatedNotice($0)] } ?? [])
        + (captionOutcome == .failed ? [CaptionOutcome.failureIssue] : [])
    // ICC 没原样搬过去（坏掉的描述文件 ImageIO 当作没有）。去掉坏 ICC 的那条已经说了，不重复。
    let iccIssues = opts.verifyEnabled && kind == .jpeg && !droppedICC
        ? [iccCarryIssue(source: input, dest: dest)].compactMap { $0 } : []
    let verification = opts.verifyEnabled
        ? Verification(comparing: metadataDiff(source: input, dest: dest) + iccIssues + conversionIssues) : .notVerified
    let outBytes = fileSize(dest)

    // 删源文件的前提是逐条比对确认无损，而且产物不比原图大——换成更大的文件不是
    // 用户要的结果。不删就说明为什么。
    var notes: [String] = []
    var sourceDeleted = false
    let growth = growthPercent(inBytes: inBytes, outBytes: outBytes)
    if let qualityNote = quality?.note { notes.append(qualityNote) }
    if let growth { notes.append("HEIF 比原图大 \(growth)") }
    // 没校验时差异列表不存在，去掉坏 ICC、说明没写成这些放进状态说明，不让它们静默。
    if !opts.verifyEnabled { notes += conversionIssues }
    if opts.deleteOriginal {
        if kind == .raw {
            notes.append("RAW 原片永远保留，没有删除")
        } else if isSymlink {
            notes.append("源是符号链接，没有删除（它指向的文件也没删）")
        } else if verification != .passed {
            notes.append("因元数据校验未通过，保留了源文件")
        } else if growth != nil {
            notes.append("因产物比原图大，保留了源文件")
        } else {
            do {
                try fm.removeItem(at: input)
                sourceDeleted = true
            } catch {
                // 删不掉（源所在的目录只读、文件被锁）不能不出声：不然看上去和删掉了一样。
                let code = (error as NSError).code
                let why = code == NSFileWriteNoPermissionError ? "没有权限" : error.localizedDescription
                notes.append("没能删除源文件：\(why)")
            }
        }
    }

    return .converted(ConversionReport(dest: dest, inBytes: inBytes, outBytes: outBytes,
                                      tagCount: tagCount, xattrCount: xattrs,
                                      verification: verification, rawExif: rawExif,
                                      reencode: reencode, caption: captionOutcome, quality: quality,
                                      note: notes.isEmpty ? nil : notes.joined(separator: "；"),
                                      sourceDeleted: sourceDeleted))
}

// MARK: - 把「照片」的说明写进文件（--embed-caption）

/// 「照片」App 把照片的说明存在文件的这个扩展属性里（UTF-8 文本），不在图像文件内部。
let photosCaptionXattr = "com.apple.assetsd.description"

/// 一张图要不要写说明。
enum CaptionPlan: Equatable {
    case write(String)
    case skip(String)
}

/// 说明写进文件了没有（-v 那一行）。
public enum CaptionOutcome: Equatable {
    case written(characters: Int)
    /// 不写，附带原因。
    case skipped(String)
    /// 该写而没写成：读回的产物 XMP 里没有这段说明。
    case failed

    /// 没写成时 --verify 结果里加的那一条差异。
    static let failureIssue = "没能把「照片」的说明写进文件"

    /// -v 时显示的那一行（不含缩进）。
    public var description: String {
        switch self {
        case .written(let n): return "「照片」的说明：写进了 XMP 的 dc:description（\(n) 个字符）"
        case .skipped(let why): return "「照片」的说明：没写（\(why)）"
        case .failed: return "「照片」的说明：没写成"
        }
    }
}

/// 要不要把源文件扩展属性里的说明写进产物。依次：
/// 1. 扩展属性没有、不是合法的 UTF-8、去掉首尾空白后为空：不写。
/// 2. 源的元数据里已经有说明字段——XMP 里有 dc:description（任何语言，值空不空都算）、
///    `{IPTC}/Caption/Abstract` 或 `{TIFF}/ImageDescription` 在（空的也算）：不写，不覆盖也不追加。
///    这一条也是在挡崩溃：XMP 里已经有 dc:description 时再往要合并的 XMP 上设说明，
///    CGImageDestinationCopyImageSource 抛 ObjC 异常，Swift 接不住，进程直接退出。
///    空字段也挡，是因为写第一遍时它照样会落进产物。
/// 3. 否则写，写的是扩展属性里的原文（不去首尾空白）。
/// `properties` 是源的 imageProperties，`xmp` 是源的 XMP。
func captionPlan(source: URL, properties: [CFString: Any], xmp: CGImageMetadata?) -> CaptionPlan {
    guard let raw = extendedAttributeValue(source.path, photosCaptionXattr) else { return .skip("没有说明") }
    guard let text = String(validatingUTF8Bytes: raw) else { return .skip("不是合法的 UTF-8") }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .skip("没有说明") }
    func field(_ dictionary: CFString, _ key: CFString) -> String? {
        guard let value = (properties[dictionary] as? [CFString: Any])?[key] else { return nil }
        return trimPadding(String(describing: value)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let fields = [field(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription),
                  field(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract)]
        + [xmpDescription(xmp)]
    let present = fields.compactMap { $0 }
    if present.contains(where: { !$0.isEmpty }) { return .skip("文件里已有说明") }
    if !present.isEmpty { return .skip("文件里已有说明字段（空的）") }
    return .write(text)
}

/// XMP 里 dc:description 的全部文本（各语言连起来）；没有这个标签是 nil，有标签而没有文本是空串。
public func xmpDescription(_ xmp: CGImageMetadata?) -> String? {
    guard let xmp, CGImageMetadataCopyTagWithPath(xmp, nil, "dc:description" as CFString) != nil else { return nil }
    return xmpTags(xmp).filter { $0.key.hasPrefix(xmpKey("dc:description")) }.values.sorted().joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 要合并进产物的 XMP：`base`（源的 XMP，没有时从空的开始）的一份拷贝，dc:description 设成
/// `caption`。`base` 里已经有 dc:description 时不设，是 nil（见 captionPlan 第 2 条的崩溃）；
/// 设不上也是 nil。只动 XMP，EXIF 不碰。
func xmpWithCaption(_ base: CGImageMetadata?, caption: String) -> CGImageMetadata? {
    if let base, CGImageMetadataCopyTagWithPath(base, nil, "dc:description" as CFString) != nil { return nil }
    let md = base.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
    guard CGImageMetadataSetValueMatchingImageProperty(md, kCGImagePropertyIPTCDictionary,
                                                       kCGImagePropertyIPTCCaptionAbstract, caption as CFString)
    else { return nil }
    return md
}

/// 产物 XMP 里 dc:description 的 x-default 文本；读不出是 nil。
func embeddedCaption(at url: URL) -> String? {
    guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
          let md = CGImageSourceCopyMetadataAtIndex(image, 0, nil) else { return nil }
    return CGImageMetadataCopyStringValueWithPath(md, nil, "dc:description[x-default]" as CFString) as String?
}

// MARK: - EXIF 整块照搬

/// 一张图的 EXIF 照搬了没有。
public enum RawExifOutcome: Equatable {
    /// 照搬了源文件 EXIF 段里这么多字节的 TIFF；`commentRewritten` 是照搬的块上改写过备注
    /// （见 rewritingUserComment），字节数仍是源 TIFF 的。`keptOriginals` 是与 IPTC 打架、
    /// 照搬后视图显示 EXIF 原值的那几组（自检放行的，见 splitRegressions），按组的固定顺序。
    case carried(bytes: Int, commentRewritten: Bool, keptOriginals: [ReconciledGroup] = [])
    /// 没照搬，产物保持 ImageIO 写出来的样子；附带原因。
    case kept(String)

    /// -v 时显示的那一行（不含缩进）。
    public var description: String {
        switch self {
        case .carried(let bytes, let rewritten, let kept):
            var detail = "\(bytes) 字节"
            if rewritten { detail += "，备注改写成 ImageIO 读得出的写法" }
            if !kept.isEmpty {
                detail += "；\(kept.map(\.label).joined(separator: "、"))与 IPTC 不一致，保留 EXIF 的原值"
            }
            return "EXIF 整块照搬（\(detail)）"
        case .kept(let why):
            return "EXIF 没有照搬：\(why)"
        }
    }
}

/// 编码之后、校验之前对产物 EXIF 做的那一步，按源类型分派。
/// - JPEG：整块照搬源 EXIF（carryRawExif）。
/// - RAW：照搬 RAW 自己的 EXIF（CR3 的 CMT1/CMT2/CMT4，TIFF 系 RAW 的 IFD0/ExifIFD/GPS IFD，RAF 内嵌
///   JPEG 的 EXIF），先拼成一块干净的 TIFF（CameraRawExif.swift），再同样交给 carryingExif
///   （carryCameraRawExif）。
func carryExif(_ kind: SourceKind, source: URL, product: URL) -> RawExifOutcome {
    switch kind {
    case .jpeg: return carryRawExif(source: source, product: product)
    case .raw: return carryCameraRawExif(source: source, product: product)
    }
}

/// 照搬后的字节 `carried` 先写进 `product` 同目录的另一个临时文件，`check` 对它说没有问题（nil）
/// 才原子地替换 `product`；否则是原因，`product` 一个字节都不动。中断时最多留下那个另起的
/// 临时文件，不会留下半个产物。
private func replacingProduct(_ product: URL, with carried: [UInt8], check: (URL) -> String?) -> String? {
    let candidate = product.deletingLastPathComponent()
        .appendingPathComponent(".glint-\(UUID().uuidString).heic")
    defer { try? FileManager.default.removeItem(at: candidate) }
    do { try Data(carried).write(to: candidate) } catch {
        return "写不出照搬后的产物" + (isOutOfSpace(error) ? "：磁盘空间不够" : "")
    }
    if let problem = check(candidate) { return problem }
    guard rename(candidate.path, product.path) == 0 else { return "换不上照搬后的产物" }
    return nil
}

/// 把 `product`（ImageIO 刚从 RAW 写好的 HEIC）里 Exif 项的内容换成从 RAW 里拼出来的 TIFF。
///
/// 拼块与它的闸门见 CameraRawExif.swift；块里 IFD0 的方向必须与产物现在的方向相同（cameraRawCarryPlan）。
/// 换的那一步与 JPEG 同一个 carryingExif，落盘前过 cameraRawExifRegression 的自检，闸门或自检不过，
/// `product` 一个字节都不动，原因写进报告（-v 那一行）。MakerNote 拼块时就去掉了，校验照旧报那一行。
func carryCameraRawExif(source: URL, product: URL) -> RawExifOutcome {
    guard let sourceData = try? Data(contentsOf: source, options: .mappedIfSafe),
          let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil) else { return .kept("读不出源文件") }
    guard let productImage = CGImageSourceCreateWithURL(product as CFURL, nil),
          let productProps = CGImageSourceCopyPropertiesAtIndex(productImage, 0, nil) as? [CFString: Any] else {
        return .kept("读不出产物")
    }
    let orientation = (productProps[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let sourceBytes = [UInt8](sourceData), type = CGImageSourceGetType(sourceImage) as String?
    let tiff: [UInt8]
    switch cameraRawCarryPlan(source: sourceBytes, type: type, productOrientation: orientation) {
    case .success(let t): tiff = t
    case .failure(let skip): return .kept(skip.reason)
    }
    // 自检拿的源条目另读一遍（拼块之前的材料），不用拼块时那一份。
    guard case .success(let parts) = cameraRawExifParts(sourceBytes, type: type) else { return .kept("另读一遍 RAW 的 EXIF 读不通") }
    guard let productData = try? Data(contentsOf: product) else { return .kept("读不出产物") }
    let carried: [UInt8]
    switch carryingExif(tiff, into: [UInt8](productData)) {
    case .success(let bytes): carried = bytes
    case .failure(let skip): return .kept(skip.reason)
    }
    if let problem = replacingProduct(product, with: carried, check: { candidate in
        cameraRawExifRegression(source: parts, intended: tiff, before: product, after: candidate)
    }) { return .kept(problem) }
    return .carried(bytes: tiff.count, commentRewritten: false)
}

/// RAW 照搬后的产物 `after` 能不能换上：不能时是原因，能是 nil。不拿源的视图当参照——同一组字节，
/// ImageIO 按 RAW 读与按 HEIC 读给出的视图不同（见 CameraRawExif.swift「照搬之后的核对」），拿视图比
/// 必然「退步」。改以字节为证：
///
/// 1. 从 `after` 里重新取出 Exif 项，TIFF 字节与拼好的那块（`intended`）逐字节相同。
/// 2. 块里的每个条目与 RAW 里的（`source`，另读的一份材料）逐字节相同，一条不多一条不少
///    （carriedEntryIssues）。拼块时按构造就是这样，这里独立再核一遍。
/// 3. ImageIO 打得开，状态完整，图像数、顶层 PixelWidth/PixelHeight/Orientation/Depth 与 `before` 相同
///    （RAW 的产物必须是 10 位，照搬不能动它）。
/// 4. ImageIO 读得懂这个块：产物视图里 EXIF 派生的键（isExifDerivedKey），与同一个块包进一张最小
///    JPEG 后读出的相同（exifReadingMismatch）。块放不进 JPEG 的 APP1（64 KB）就核对不了，不换。
func cameraRawExifRegression(source: RawExifParts, intended: [UInt8], before: URL, after: URL) -> String? {
    guard let afterData = try? Data(contentsOf: after),
          case .tiff(let readBack) = heifExif([UInt8](afterData)),
          Array(readBack.bytes[readBack.base..<(readBack.base + readBack.length)]) == intended else {
        return "照搬后读回的 EXIF 与打算照搬的不一致"
    }
    if let issue = carriedEntryIssues(source: source, product: TIFFStructure(intended, base: 0, length: intended.count)).first {
        return "拼出来的块与 RAW 里的条目不一致：\(issue)"
    }
    guard let beforeImage = CGImageSourceCreateWithURL(before as CFURL, nil),
          let afterImage = CGImageSourceCreateWithURL(after as CFURL, nil),
          CGImageSourceGetStatus(afterImage) == .statusComplete else {
        return "照搬后 ImageIO 打不开产物"
    }
    guard CGImageSourceGetCount(afterImage) == CGImageSourceGetCount(beforeImage) else { return "照搬后图像数变了" }
    let a = CGImageSourceCopyPropertiesAtIndex(afterImage, 0, nil) as? [CFString: Any] ?? [:]
    let b = CGImageSourceCopyPropertiesAtIndex(beforeImage, 0, nil) as? [CFString: Any] ?? [:]
    for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation,
                kCGImagePropertyDepth] {
        guard (a[key] as? NSNumber) == (b[key] as? NSNumber) else { return "照搬后 \(key as String) 变了" }
    }
    guard let jpeg = jpegWrapping(exif: intended),
          let jpegImage = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil) else {
        return "拼出来的块放不进 JPEG 的 APP1，核对不了 ImageIO 的读法"
    }
    func derived(_ image: CGImageSource, _ url: URL) -> [String: String] {
        metadataKeySpace(of: image, url: url, repairing: false).filter { isExifDerivedKey($0.key) }
    }
    return exifReadingMismatch(reference: derived(jpegImage, after), heic: derived(afterImage, after),
                               before: derived(beforeImage, before))
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
    var keptOriginals: [ReconciledGroup] = []
    if let problem = replacingProduct(product, with: carried, check: { candidate in
        let check = rawExifRegression(source: source, sourceBytes: sourceBytes, intended: intended,
                                      before: product, after: candidate)
        keptOriginals = check.keptOriginals
        return check.regression
    }) { return .kept(problem) }
    return .carried(bytes: tiff.count, commentRewritten: rewritten != nil, keptOriginals: keptOriginals)
}

/// 照搬后的产物 `after` 与照搬前的 `before` 比，有没有退步：`regression` 有就是原因，没有是 nil；
/// 没有退步时 `keptOriginals` 是第 3 条放行了的组。
///
/// 1. 从 `after` 里重新取出 Exif 项，TIFF 字节与打算照搬的那份（`intended`）逐字节相同。
/// 2. ImageIO 打得开，状态完整，图像数、顶层 PixelWidth/PixelHeight/Orientation 与 `before` 相同。
/// 3. 视图不退步：用 --verify 的源侧键空间（sourceKeySpace）当 V源，`after` 里与源不一致的键
///    （inconsistentKeys）必须都已经在 `before` 里不一致。原来一致的键变坏了就是退步，只有一种
///    放行（splitRegressions）：键属于说明、作者、版权三组之一，且照搬后的值等于源 EXIF 里那个
///    标签的原文（可靠的文本）——EXIF 与 IIM 打架，产物只是如实显示了源 EXIF 自己写的东西。
///    时间字段的打架、缺字符集头而没能改写的 UserComment（照搬后 ImageIO 读不出）照旧靠这一条
///    退回旧路。
func rawExifRegression(source: URL, sourceBytes: [UInt8], intended: [UInt8], before: URL,
                       after: URL) -> (regression: String?, keptOriginals: [ReconciledGroup]) {
    func regression(_ why: String) -> (regression: String?, keptOriginals: [ReconciledGroup]) { (why, []) }
    guard let afterData = try? Data(contentsOf: after),
          case .tiff(let readBack) = heifExif([UInt8](afterData)),
          Array(readBack.bytes[readBack.base..<(readBack.base + readBack.length)]) == intended else {
        return regression("照搬后读回的 EXIF 与打算照搬的不一致")
    }
    guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
          let beforeImage = CGImageSourceCreateWithURL(before as CFURL, nil),
          let afterImage = CGImageSourceCreateWithURL(after as CFURL, nil),
          CGImageSourceGetStatus(afterImage) == .statusComplete else {
        return regression("照搬后 ImageIO 打不开产物")
    }
    guard CGImageSourceGetCount(afterImage) == CGImageSourceGetCount(beforeImage) else {
        return regression("照搬后图像数变了")
    }
    let a = CGImageSourceCopyPropertiesAtIndex(afterImage, 0, nil) as? [CFString: Any] ?? [:]
    let b = CGImageSourceCopyPropertiesAtIndex(beforeImage, 0, nil) as? [CFString: Any] ?? [:]
    for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] {
        guard (a[key] as? NSNumber) == (b[key] as? NSNumber) else { return regression("照搬后 \(key as String) 变了") }
    }
    let reference = sourceKeySpace(of: sourceImage, url: source, bytes: sourceBytes)
    let afterView = metadataKeySpace(of: afterImage, url: after)
    let newlyInconsistent = inconsistentKeys(before: reference, after: afterView)
        .subtracting(inconsistentKeys(before: reference, after: metadataKeySpace(of: beforeImage, url: before)))
    let split = splitRegressions(newlyInconsistent, afterView: afterView,
                                 originals: exifTextOriginals(TIFFStructure(jpeg: sourceBytes)))
    let worse = split.blocking
    guard let key = worse.sorted().first else { return (nil, split.kept) }
    let more = worse.count > 1 ? "（共 \(worse.count) 处）" : ""
    if reference[key] == nil { return regression("照搬后会多出源里没有的 \(key)\(more)") }
    return regression(afterView[key] == nil ? "照搬后 \(key) 会读不出\(more)" : "照搬后 \(key) 会与源不一致\(more)")
}

/// 产物比源大多少，写成「33%」；不比源大（或缺体积数据）是 nil。不到 1% 的写「不到 1%」，
/// 免得出现「大 0%」。命令行、界面和批量汇总的「变大」都以这里为准。
public func growthPercent(inBytes: Int, outBytes: Int) -> String? {
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
/// 2. CopyImageSource 把第一遍的结果再写一遍，同时把源的 XMP 合并进去。
///    这一步只改元数据，不重新编码像素，第一遍加进去的辅助图原样留在产物里。
///    它的选项里只有 XMP 和合并开关起作用：属性字典传进来会被忽略（实测带不带它，
///    产物逐字节相同），所以 EXIF 等字典只能靠第一遍写进去。
///
/// 两遍都写进内存，最后由这里自己写到 `url`（writeProduct）。交给 ImageIO 直接写文件的话，
/// 卷满了它只回一个 false，说不清是编码器还是磁盘的问题，还会在旁边留下写了一半的临时文件。
func encodeHEIF(_ src: CGImageSource, properties: [CFString: Any],
                xmp: CGImageMetadata?, to url: URL) -> Bool {
    let properties = propertiesForHEIFWriter(properties)
    let heic = UTType.heic.identifier as CFString
    var encoded = NSMutableData()
    guard encodeFirstPass(src, properties: properties, makeDestination: {
        encoded = NSMutableData()
        return CGImageDestinationCreateWithData(encoded, heic, 1, nil)
    }) else { return false }
    // 源里没有 XMP 就没有第二遍可做；CopyImageSource 不带元数据选项时直接失败。
    guard let xmp else { return writeProduct(encoded as Data, to: url) }
    let merged = NSMutableData()
    guard let firstPass = CGImageSourceCreateWithData(encoded, nil),
          let out = CGImageDestinationCreateWithData(merged, heic, 1, nil) else { return false }
    let options = [kCGImageDestinationMetadata: xmp, kCGImageDestinationMergeMetadata: true] as CFDictionary
    guard CGImageDestinationCopyImageSource(out, firstPass, options, nil) else { return false }
    return writeProduct(merged as Data, to: url)
}

/// 把编好的产物写进 `url`（一个临时文件，写完由 convert 挪到目标位置）。写不进去时记下原因
/// （ProductWriteFailures），convert 报失败原因时据此说清是磁盘满了还是别的写盘错误。
/// 写了一半的文件留给调用方删（它登记在 TemporaryFiles 里）。
func writeProduct(_ data: Data, to url: URL) -> Bool {
    do {
        try data.write(to: url)
        return true
    } catch {
        ProductWriteFailures.shared.record(error, for: url)
        return false
    }
}

/// 产物文件写不进去的原因，按临时文件的路径记。encode 只回成功与否（测试里换成假编码器），
/// 原因从这里取；取一次就清掉。
final class ProductWriteFailures {
    static let shared = ProductWriteFailures()
    private let lock = NSLock()
    private var errors: [URL: Error] = [:]

    func record(_ error: Error, for url: URL) {
        lock.lock(); errors[url] = error; lock.unlock()
    }

    /// 取出并清掉这些路径上记下的写盘错误；有好几个时给最后一个。
    func take(_ urls: [URL]) -> Error? {
        lock.lock(); defer { lock.unlock() }
        return urls.reduce(nil) { found, url in errors.removeValue(forKey: url) ?? found }
    }
}

/// 写盘错误是不是卷满了（含超出配额）。Data.write 给的是 Cocoa 错误，底下的 POSIX 错误在 underlying 里。
func isOutOfSpace(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
    if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)) { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
    return false
}

/// 源图第 0 张真解得出像素。CGImageSourceCreateImageAtIndex 拿到图不算：它先不解码，量化表
/// 损坏、ICC 损坏的 JPEG 也照样给一张图，画出来是空的、交给编码器则收尾失败。取一次像素数据
/// 才真解码，解不出时是 nil。整幅解一遍，只在编码已经失败时用。
func imageDecodes(_ src: CGImageSource) -> Bool {
    guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
    return image.dataProvider?.data != nil
}

/// 去掉 ICC 后转换时加的那条差异（没校验时是状态说明）。
let damagedICCNotice = "源文件里的 ICC 色彩描述文件损坏，按它解不出图像；去掉它转换，颜色按 sRGB 解释，可能和原图有偏差"

private let iccSegmentID: [UInt8] = Array("ICC_PROFILE".utf8) + [0]

/// JPEG 里的 APP2 `ICC_PROFILE` 段，只看第一个 SOS 之前的：图像数据里不会有 ICC。
func iccSegments(_ bytes: [UInt8], _ layout: JPEGLayout) -> [JPEGSegment] {
    layout.segments.prefix { $0.marker != 0xDA }.filter { $0.marker == 0xE2 && $0.begins(with: iccSegmentID, in: bytes) }
}

/// JPEG 里嵌的 ICC 色彩描述文件本身：各段 `ICC_PROFILE\0`、序号、总数之后的内容，按序号接起来。没有是 nil。
func embeddedICC(_ bytes: [UInt8]) -> [UInt8]? {
    guard let layout = JPEGLayout(bytes) else { return nil }
    let header = iccSegmentID.count + 2
    let chunks = iccSegments(bytes, layout).filter { $0.payload.count > header }
    guard !chunks.isEmpty else { return nil }
    return chunks.sorted { bytes[$0.payload.lowerBound + iccSegmentID.count] < bytes[$1.payload.lowerBound + iccSegmentID.count] }
        .flatMap { bytes[($0.payload.lowerBound + header)..<$0.payload.upperBound] }
}

/// 源 JPEG 里嵌的 ICC 色彩描述文件没有原样到产物里时的那条差异；原样到了、源里没有都是 nil。
///
/// 好的描述文件 ImageIO 逐字节搬过去（测试集里带 ICC 的每一张都是），只把 Profile ID 清零。搬不过去的是它读不懂的：
/// 坏掉的描述文件它当作没有，按 sRGB 解码，产物里写的是系统的 sRGB。这时源和产物的色彩描述名
/// 都读成 sRGB，键比对看不出来，得比描述文件的字节。描述名本身变了（如 CMYK 的转成 RGB）时
/// 键比对已经报了 ProfileName 的变化，这里不再重复。
func iccCarryIssue(source: URL, dest: URL) -> String? {
    guard let data = try? Data(contentsOf: source), let embedded = embeddedICC([UInt8](data)),
          let product = CGImageSourceCreateWithURL(dest as CFURL, nil),
          let original = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
    let carried = CGImageSourceCreateImageAtIndex(product, 0, nil)?.colorSpace?.copyICCData().map { [UInt8]($0 as Data) }
    guard carried.map(withoutProfileID) != withoutProfileID(embedded) else { return nil }
    func profileName(_ src: CGImageSource) -> String? {
        (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyProfileName] as? String
    }
    let name = profileName(product)
    guard profileName(original) == name else { return nil }
    let replacement = [name, carried.map { "\($0.count) 字节" }].compactMap { $0 }.joined(separator: "，")
    return "源里嵌的 ICC 色彩描述文件（\(embedded.count) 字节）没有原样搬过去，产物里是另一份"
        + (replacement.isEmpty ? "" : "（\(replacement)）") + "，颜色可能和原图有偏差"
}

/// 描述文件头里的 Profile ID（第 84–99 字节，整个文件的 MD5）抹成 0。ImageIO 写 HEIF 时把它清零，
/// 别的字节原样：iPhone 照片的描述文件带着它，不抹掉的话每一张都会误报。它只是校验和，全 0
/// 按 ICC 规范就是「没算」。
func withoutProfileID(_ profile: [UInt8]) -> [UInt8] {
    guard profile.count >= 100 else { return profile }
    var out = profile
    out.replaceSubrange(84..<100, with: [UInt8](repeating: 0, count: 16))
    return out
}

/// 去掉 APP2 `ICC_PROFILE` 段之后的 JPEG 字节。没有这种段、读不了文件都是 nil。
func jpegWithoutICC(_ url: URL) -> Data? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let bytes = [UInt8](data)
    guard let layout = JPEGLayout(bytes) else { return nil }
    let icc = iccSegments(bytes, layout)
    guard !icc.isEmpty else { return nil }
    var out = bytes
    // 从后往前删，前面的偏移不变。段从标记 FF xx 和两字节长度开始，在内容之前 4 字节。
    for s in icc.reversed() { out.removeSubrange((s.payload.lowerBound - 4)..<s.payload.upperBound) }
    return Data(out)
}

/// 编码失败时说清是哪一头的问题。源本身解不出图像（截断、损坏的文件）时，「HEIC 编码失败」
/// 会让人去怀疑编码器；这里先试着解一次源图。只在失败时才解：RAW 解一次就是整幅显影，平时不该多花这一遍。
/// 输出目录写不进去（没有写权限、建不出来）、编好的产物写盘失败（`writeError`，见 writeProduct），
/// 也都表现为编码失败，先查这两条。卷满了是写盘失败里最常见的，单说「磁盘空间不够」。
func encodeFailureReason(_ src: CGImageSource, kind: SourceKind, folder: URL, writeError: Error?) -> String {
    if TemporaryFiles.shared.isShuttingDown { return "已中断" }
    if !FileManager.default.isWritableFile(atPath: folder.path) {
        return "写不进输出目录（没有写权限或建不出来）：\(folder.path)"
    }
    if let writeError {
        guard isOutOfSpace(writeError) else {
            return "写不进输出文件：\(writeError.localizedDescription)"
        }
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
        return "磁盘空间不够" + (free.map { "：输出目录所在的卷只剩 \(humanSize($0))" } ?? "")
    }
    guard !imageDecodes(src) else { return "HEIC 编码失败" }
    switch kind {
    case .raw: return "显影失败：读不出 RAW 的图像数据，文件可能不完整或已损坏"
    case .jpeg: return "读不出图像数据，文件可能不完整或已损坏"
    }
}

func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
}

public func humanSize(_ bytes: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var v = Double(bytes), i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(bytes) B" : String(format: "%.1f %@", v, units[i])
}
