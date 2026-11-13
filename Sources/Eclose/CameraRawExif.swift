// 相机 RAW 的 EXIF 整块照搬：从 RAW 里取出 EXIF，拼成一块干净的 TIFF，交给 carryingExif
// （RawExifCarry.swift）放进 HEIF 的 Exif 项。
//
// 为什么要拼：RAW 转 HEIC 时，EXIF 由 ImageIO 从属性字典重写。写入器把 GPS 坐标重新编成
// 度分秒时取整（几厘米）、丢掉值是空串的标签（佳能的 CameraOwnerName、GPS 的 Satellites）、
// 把只有 GPSVersion 没有坐标的 GPS 字典整个丢掉。JPEG 那条路靠整块照搬源 EXIF 绕开了它；
// RAW 里没有一段现成的 EXIF 可搬，EXIF 散在 RAW 容器里，所以先取出来拼成一块：
//
// - 佳能 CR3（ISO BMFF）：moov 里 UUID 为 85c0b687-820f-11e0-8111-f4ce462b6a48 的 uuid 盒子，
//   CMT1 是 IFD0、CMT2 是 Exif IFD、CMT4 是 GPS IFD，每个都是带 TIFF 头的完整 TIFF。CMT3 是佳能的
//   MakerNote，不搬。
// - TIFF 系 RAW（DNG、CR2、NEF、NRW、ARW、PEF、SRW、RW2、ORF）：文件本身就是 TIFF（RW2、ORF 换了
//   头里的魔数），IFD0 里的 0x8769 指向 Exif IFD、0x8825 指向 GPS IFD。
// - 富士 RAF：文件头后面嵌着一张 JPEG，EXIF 在它的 APP1 里（sourceExifTIFF），取出来再按 TIFF 系拼。
// 支持哪些格式按 ImageIO 给的类型查表（cameraRawExifLayouts）。别的格式（CRW、MRW、X3F、IIQ、
// SR2、RWL……）不照搬：没有样本、单测里也没有按它的结构搭的样本，结构没把握。
//
// 拼出来的块：
// - 字节序与源相同：值的字节原样搬，换字节序就得逐个按类型翻转，不翻转就全错了。
// - IFD0 只留描述照片的标签（rawExifIFD0Tags，理由写在那里）。
// - Exif IFD 全部条目照搬，只去掉 MakerNote（0x927C）。厂商私有块里满是相对原文件的偏移，
//   挪到新位置就指错了；ImageIO 写的产物里本来也没有它，校验照旧报 MakerNote 那一行。
// - Interop IFD（Exif IFD 里 0xA005 指向的那个）整个搬过去，指针改成新位置。它只有两三条
//   （R98/R03 是 sRGB 还是 Adobe RGB 的 DCF 标记、版本号），说的是相机设置的色彩空间，与
//   Exif IFD 里的 ColorSpace 同一类，交接要求 Exif IFD 照搬，它就跟着搬；JPEG 那条路也原样留着它。
//   去掉指针的话 Exif IFD 就不再是「全部条目照搬」。
// - GPS IFD 全部条目照搬。
// - 值的字节一个不改（GPS 的 rational 不重算，这正是坐标精度保得住的原因），排布重新来过：
//   头 → IFD0 → Exif IFD → Interop IFD → GPS IFD，每个 IFD 的条目按标签号升序、外置的值紧跟在
//   表后、按 2 字节对齐，偏移全部重算，块里不留指向原文件的偏移。IFD0、Exif IFD 后面的
//   「下一个 IFD」写 0：IFD1 的缩略图是 RAW 里的预览，不搬。
//
// 闸门：源的长度、偏移、个数一律不信，任何一条读不通或拿不准就不照搬（RawExifSkip），产物保持
// ImageIO 写的样子，转换照常完成。
//
// 这里只有纯函数，进字节出字节。落盘、方向核对与自检在 Converter.swift 的 carryCameraRawExif。

import Foundation

// MARK: - 格式

/// RAW 的 EXIF 放在哪里。
enum CameraRawExifLayout: Equatable {
    /// 文件本身是 TIFF；`magic` 是头里字节序标记后面那个数允许的值。
    case tiff(magic: Set<Int>)
    /// 佳能 CR3：CMT1/CMT2/CMT4。
    case cr3
    /// 富士 RAF：内嵌 JPEG 的 APP1。
    case raf
}

/// 奥林巴斯 ORF 头里的魔数：`IIRO`、`IIRS` 按小端读是 0x4F52、0x5352，`MMOR` 按大端读是 0x4F52。
let orfMagic: Set<Int> = [0x4F52, 0x5352]

/// 能照搬 EXIF 的 RAW：ImageIO 给的类型（CGImageSourceGetType）→ EXIF 放在哪里。不在表里的不照搬。
/// 每一种在单测里都有一个按它的结构手搭的样本（「RAW 的 EXIF 拼块：每种格式」那一组），
/// DNG 另有端到端的夹具（Tests/DNG.swift）。真样本只量过 CR3、RW2（主会话）。
let cameraRawExifLayouts: [String: CameraRawExifLayout] = [
    "com.adobe.raw-image": .tiff(magic: [42]),          // DNG
    "com.canon.cr2-raw-image": .tiff(magic: [42]),
    "com.nikon.raw-image": .tiff(magic: [42]),          // NEF
    "com.nikon.nrw-raw-image": .tiff(magic: [42]),
    "com.sony.arw-raw-image": .tiff(magic: [42]),
    "com.pentax.raw-image": .tiff(magic: [42]),         // PEF
    "com.samsung.raw-image": .tiff(magic: [42]),        // SRW
    "com.panasonic.rw2-raw-image": .tiff(magic: [0x55]),
    "com.olympus.or-raw-image": .tiff(magic: orfMagic),
    "com.olympus.sr-raw-image": .tiff(magic: orfMagic),
    "com.canon.cr3-raw-image": .cr3,
    "com.fuji.raw-image": .raf,
]

/// CR3 里装 CMT1…CMT4 的那个 uuid 盒子的 UUID：85c0b687-820f-11e0-8111-f4ce462b6a48。
let canonCR3MetadataUUID: [UInt8] = [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0,
                                     0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48]

// MARK: - 拼块的白名单

/// 拼块的 IFD0 只留这些标签（标签号 → 名字，名字只为读代码与报原因）。它们描述的是照片本身——
/// 什么相机、谁拍的、什么时候、怎么摆、版权与说明、评级、该印多大——显影成 HEIC 以后照样成立。
///
/// 别的一概不要：
/// - 描述图像数据怎么存的：ImageWidth/ImageLength、BitsPerSample、Compression、
///   PhotometricInterpretation、StripOffsets/RowsPerStrip/StripByteCounts、TileWidth/…/TileByteCounts、
///   SamplesPerPixel、PlanarConfiguration、YCbCr 那几个、NewSubfileType、WhitePoint、
///   PrimaryChromaticities、ReferenceBlackWhite。RAW 的 IFD0 里它们说的是那张小预览图或原始数据，
///   HEIC 的图像在它自己的项里，留着只会让读的人把 HEIC 当成 CFA、未压缩、几十像素宽。
/// - 描述 RAW 容器的：SubIFDs（0x014A）、DNG 的私有标签（50706 起）、各家的私有标签（松下 RW2
///   的 IFD0 里 0x0001–0x002F 那一串传感器参数、内嵌的 JpgFromRaw……）。
/// - 另有去处的：ICC（0x8773）由 ImageIO 按显影结果写色彩描述；XMP（0x02BC）走 HEIF 的 XMP 项；
///   IPTC（0x83BB）走属性字典。再塞一份进 EXIF 只会有两份打架。
/// - Exif、GPS 的指针（0x8769、0x8825）由拼块时重新生成。
/// - 打印匹配（PrintIM，0xC4A5）这类厂商私有块：只有厂商软件看得懂，ImageIO 的视图里也没有。
let rawExifIFD0Tags: [Int: String] = [
    0x010D: "DocumentName", 0x010E: "ImageDescription", 0x010F: "Make", 0x0110: "Model",
    0x0112: "Orientation", 0x011A: "XResolution", 0x011B: "YResolution", 0x0128: "ResolutionUnit",
    0x0131: "Software", 0x0132: "DateTime", 0x013B: "Artist", 0x013C: "HostComputer",
    0x4746: "Rating", 0x4749: "RatingPercent", 0x8298: "Copyright",
    0x9C9B: "XPTitle", 0x9C9C: "XPComment", 0x9C9D: "XPAuthor", 0x9C9E: "XPKeywords", 0x9C9F: "XPSubject",
]

/// Exif IFD 里不搬的标签：MakerNote（理由见文件头）。
let rawExifMakerNoteTag = 0x927C

/// 子 IFD 指针。拼块时只认它们出现在规范的位置（IFD0 的 Exif/GPS、Exif IFD 的 Interop），
/// 别处出现就不照搬：那是指向原文件的偏移，搬过去就指错了。
let rawExifPointerTags: Set<Int> = [0x8769, 0x8825, 0xA005, 0x014A]

/// 一个 IFD 的条目数上限。真实的 IFD 几十到两三百条；超过它就不像真的，不照搬。
let maxCarriedIFDEntries = 1000

// MARK: - 读

/// 一个 IFD 条目，值已经取出来（原始字节，按源的字节序）。
struct CarriedEntry: Equatable {
    let tag: Int
    let type: Int
    let count: Int
    let value: [UInt8]
}

/// 拼块的材料：四个 IFD 要搬的条目（不含子 IFD 指针，拼的时候重新生成）与字节序。
struct RawExifParts: Equatable {
    var bigEndian: Bool
    var ifd0: [CarriedEntry] = []
    var exif: [CarriedEntry] = []
    var interop: [CarriedEntry] = []
    var gps: [CarriedEntry] = []
}

private func tagName(_ tag: Int) -> String { String(format: "0x%04X", tag) }

/// 严格地读一个 IFD 的全部条目：位置在头之后、条目数不超过上限、整张表在块内、每个条目的
/// 类型认识（1–13，13 是 IFD 指针）、值整个在块内、同一个标签不出现两次。任何一条不成立就
/// 抛出原因（`name` 是 IFD 的名字，写进原因里）。不读「下一个 IFD」。
func carriedIFD(_ tiff: TIFFStructure, at offset: Int, name: String) throws -> [CarriedEntry] {
    func skip(_ why: String) -> RawExifSkip { RawExifSkip("\(name) \(why)") }
    guard offset >= 8, let count = tiff.u16(offset) else { throw skip("的位置越界") }
    guard count <= maxCarriedIFDEntries else { throw skip("的条目数 \(count) 不像真的") }
    guard offset + 2 + 12 * count <= tiff.length else { throw skip("的条目表越界") }
    var entries: [CarriedEntry] = []
    var seen = Set<Int>()
    for k in 0..<count {
        let at = offset + 2 + 12 * k
        guard let tag = tiff.u16(at), let type = tiff.u16(at + 2), let n = tiff.u32(at + 4),
              let field = tiff.u32(at + 8) else { throw skip("的条目表越界") }
        guard (1...13).contains(type) else { throw skip("里 \(tagName(tag)) 的类型 \(type) 不认识") }
        guard seen.insert(tag).inserted else { throw skip("里 \(tagName(tag)) 不止一个") }
        let unit = TIFFStructure.unitSize[type]
        guard n <= tiff.length / unit else { throw skip("里 \(tagName(tag)) 的值越界") }
        let size = unit * n
        let valueAt = size <= 4 ? at + 8 : field
        guard valueAt <= tiff.length - size else { throw skip("里 \(tagName(tag)) 的值越界") }
        entries.append(CarriedEntry(tag: tag, type: type, count: n,
                                    value: Array(tiff.bytes[(tiff.base + valueAt)..<(tiff.base + valueAt + size)])))
    }
    return entries
}

/// 按字节序读一个无符号整数（1、2、4 字节）。
private func unsigned(_ bytes: [UInt8], bigEndian: Bool) -> Int {
    (bigEndian ? bytes : bytes.reversed()).reduce(0) { $0 << 8 | Int($1) }
}

/// 子 IFD 指针 `tag` 的值：没有这个标签是 nil；有而不是恰好一个 LONG（或 IFD 类型）就抛出。
private func pointer(_ entries: [CarriedEntry], _ tag: Int, bigEndian: Bool, in name: String) throws -> Int? {
    guard let e = entries.first(where: { $0.tag == tag }) else { return nil }
    guard e.type == 4 || e.type == 13, e.count == 1 else { throw RawExifSkip("\(name) 里的子 IFD 指针 \(tagName(tag)) 不是一个 LONG") }
    return unsigned(e.value, bigEndian: bigEndian)
}

/// 要搬的条目里不能再有子 IFD 指针：标签是 rawExifPointerTags 之一，或类型是 13（IFD）。
private func rejectingPointers(_ entries: [CarriedEntry], in name: String) throws -> [CarriedEntry] {
    if let e = entries.first(where: { rawExifPointerTags.contains($0.tag) || $0.type == 13 }) {
        throw RawExifSkip("\(name) 里有不该在那里的子 IFD 指针 \(tagName(e.tag))")
    }
    return entries
}

/// IFD0 要留的条目（rawExifIFD0Tags）。Orientation 在的话必须是 1–8 之间的一个 SHORT：
/// 照搬前要拿它与产物的方向核对（cameraRawCarryPlan），读不准就不照搬。
private func keptIFD0(_ entries: [CarriedEntry], bigEndian: Bool, in name: String) throws -> [CarriedEntry] {
    let kept = try rejectingPointers(entries.filter { rawExifIFD0Tags[$0.tag] != nil }, in: name)
    if let o = kept.first(where: { $0.tag == 0x0112 }),
       !(o.type == 3 && o.count == 1 && (1...8).contains(unsigned(o.value, bigEndian: bigEndian))) {
        throw RawExifSkip("\(name) 里的 Orientation 不是 1–8 之间的一个 SHORT")
    }
    return kept
}

/// Exif IFD（`at`）要搬的条目与它的 Interop IFD。`taken` 是已经读过的 IFD 偏移：指回它们就是
/// IFD 互相指向，不照搬。
private func exifAndInterop(_ tiff: TIFFStructure, at: Int, name: String,
                            taken: Set<Int>) throws -> (exif: [CarriedEntry], interop: [CarriedEntry]) {
    let entries = try carriedIFD(tiff, at: at, name: name)
    var interop: [CarriedEntry] = []
    if let interopAt = try pointer(entries, 0xA005, bigEndian: tiff.bigEndian, in: name) {
        guard !taken.union([at]).contains(interopAt) else { throw RawExifSkip("Interop IFD 指回了别的 IFD") }
        interop = try rejectingPointers(try carriedIFD(tiff, at: interopAt, name: "Interop IFD"), in: "Interop IFD")
    }
    let exif = try rejectingPointers(entries.filter { $0.tag != rawExifMakerNoteTag && $0.tag != 0xA005 }, in: name)
    return (exif, interop)
}

/// TIFF 系 RAW：IFD0 与它的 Exif、GPS 指针。
func tiffRawExifParts(_ tiff: TIFFStructure) throws -> RawExifParts {
    guard let ifd0At = tiff.ifd0 else { throw RawExifSkip("IFD0 的位置读不出") }
    let ifd0 = try carriedIFD(tiff, at: ifd0At, name: "IFD0")
    var parts = RawExifParts(bigEndian: tiff.bigEndian)
    parts.ifd0 = try keptIFD0(ifd0, bigEndian: tiff.bigEndian, in: "IFD0")
    let exifAt = try pointer(ifd0, 0x8769, bigEndian: tiff.bigEndian, in: "IFD0")
    let gpsAt = try pointer(ifd0, 0x8825, bigEndian: tiff.bigEndian, in: "IFD0")
    var taken: Set<Int> = [ifd0At]
    if let exifAt {
        guard !taken.contains(exifAt) else { throw RawExifSkip("Exif IFD 指回了 IFD0") }
        if let gpsAt, gpsAt == exifAt { throw RawExifSkip("GPS IFD 与 Exif IFD 是同一个") }
        (parts.exif, parts.interop) = try exifAndInterop(tiff, at: exifAt, name: "Exif IFD",
                                                         taken: taken.union(gpsAt.map { [$0] } ?? []))
        taken.insert(exifAt)
    }
    if let gpsAt {
        guard !taken.contains(gpsAt) else { throw RawExifSkip("GPS IFD 指回了别的 IFD") }
        parts.gps = try rejectingPointers(try carriedIFD(tiff, at: gpsAt, name: "GPS IFD"), in: "GPS IFD")
    }
    return parts
}

/// CR3：顶层 ftyp 的主品牌是 `crx `、恰好一个 moov，moov 里恰好一个佳能元数据 uuid 盒子，里面
/// CMT1、CMT2、CMT4 各恰好一个、都是合法的 TIFF、字节序相同。各取第一个 IFD。
func cr3RawExifParts(_ bytes: [UInt8]) throws -> RawExifParts {
    guard let top = heifBoxes(bytes, in: 0..<bytes.count) else { throw RawExifSkip("CR3 的顶层盒子读不通") }
    guard let ftyp = top.first, ftyp.type == "ftyp", ftyp.content.count >= 4,
          Array(bytes[ftyp.content.lowerBound..<(ftyp.content.lowerBound + 4)]) == Array("crx ".utf8) else {
        throw RawExifSkip("不是 CR3 的文件头（ftyp 的主品牌不是 crx）")
    }
    let moovs = top.filter { $0.type == "moov" }
    guard moovs.count == 1 else { throw RawExifSkip("CR3 的 moov 盒子不是恰好一个") }
    guard let children = heifBoxes(bytes, in: moovs[0].content) else { throw RawExifSkip("CR3 的 moov 盒子读不通") }
    let canon = children.filter {
        $0.type == "uuid" && $0.content.count >= 16
            && Array(bytes[$0.content.lowerBound..<($0.content.lowerBound + 16)]) == canonCR3MetadataUUID
    }
    guard canon.count == 1 else { throw RawExifSkip("CR3 的佳能元数据盒子不是恰好一个") }
    guard let cmts = heifBoxes(bytes, in: (canon[0].content.lowerBound + 16)..<canon[0].content.upperBound) else {
        throw RawExifSkip("CR3 的佳能元数据盒子读不通")
    }
    func cmt(_ name: String) throws -> (tiff: TIFFStructure, ifd: Int) {
        let found = cmts.filter { $0.type == name }
        guard found.count == 1 else { throw RawExifSkip(found.isEmpty ? "CR3 里没有 \(name)" : "CR3 里的 \(name) 不止一个") }
        guard let tiff = TIFFStructure(bytes, base: found[0].content.lowerBound, length: found[0].content.count),
              let ifd = tiff.ifd0 else { throw RawExifSkip("CR3 的 \(name) 不是合法的 TIFF") }
        return (tiff, ifd)
    }
    let cmt1 = try cmt("CMT1"), cmt2 = try cmt("CMT2"), cmt4 = try cmt("CMT4")
    guard cmt1.tiff.bigEndian == cmt2.tiff.bigEndian, cmt2.tiff.bigEndian == cmt4.tiff.bigEndian else {
        throw RawExifSkip("CR3 的 CMT1、CMT2、CMT4 字节序不一致")
    }
    var parts = RawExifParts(bigEndian: cmt1.tiff.bigEndian)
    // CMT1 是独立的 TIFF，它的 IFD0 里就算有 Exif/GPS 指针也只指向 CMT1 自己的范围；Exif 与 GPS 取 CMT2、CMT4。
    parts.ifd0 = try keptIFD0(try carriedIFD(cmt1.tiff, at: cmt1.ifd, name: "CMT1"), bigEndian: parts.bigEndian, in: "CMT1")
    (parts.exif, parts.interop) = try exifAndInterop(cmt2.tiff, at: cmt2.ifd, name: "CMT2", taken: [])
    parts.gps = try rejectingPointers(try carriedIFD(cmt4.tiff, at: cmt4.ifd, name: "CMT4"), in: "CMT4")
    return parts
}

/// RAF 的文件头：前 16 字节，后面第 84、88 字节起是内嵌 JPEG 的偏移与长度（大端 4 字节）。
let rafMagic: [UInt8] = Array("FUJIFILMCCD-RAW ".utf8)

/// RAF：内嵌 JPEG 里恰好一个 EXIF 段（sourceExifTIFF 的闸门），它的 TIFF 按 TIFF 系拼。
func rafRawExifParts(_ bytes: [UInt8]) throws -> RawExifParts {
    guard bytes.starts(with: rafMagic) else { throw RawExifSkip("不是 RAF 的文件头") }
    guard let at = bigEndianInt(bytes, 84, 4), let length = bigEndianInt(bytes, 88, 4),
          length > 0, at >= 92, at <= bytes.count - length else { throw RawExifSkip("RAF 里内嵌 JPEG 的位置越界") }
    switch sourceExifTIFF(Array(bytes[at..<(at + length)])) {
    case .success(let tiff):
        guard let structure = TIFFStructure(tiff, base: 0, length: tiff.count) else {
            throw RawExifSkip("RAF 内嵌 JPEG 的 EXIF 不是合法的 TIFF")
        }
        return try tiffRawExifParts(structure)
    case .failure(let skip):
        throw RawExifSkip("RAF 内嵌的 JPEG：\(skip.reason)")
    }
}

// MARK: - 拼

/// 把材料拼成一块 TIFF（布局见文件头）。超过 4 字节偏移放得下的大小是 nil。
func assembledExifTIFF(_ parts: RawExifParts) -> [UInt8]? {
    let be = parts.bigEndian
    func bytes(_ v: Int, _ width: Int) -> [UInt8] {
        let big = (0..<width).map { UInt8(truncatingIfNeeded: v >> (8 * (width - 1 - $0))) }
        return be ? big : big.reversed()
    }
    func pointerEntry(_ tag: Int, _ at: Int) -> CarriedEntry { CarriedEntry(tag: tag, type: 4, count: 1, value: bytes(at, 4)) }
    func size(_ entries: [CarriedEntry]) -> Int {
        entries.isEmpty ? 0 : 2 + 12 * entries.count + 4
            + entries.reduce(0) { $0 + ($1.value.count > 4 ? ($1.value.count + 1) & ~1 : 0) }
    }
    // 先用占位的指针算出各块的位置，再填上真的指针。指针条目的大小与值无关。
    let interop = parts.interop
    var exif = parts.exif + (interop.isEmpty ? [] : [pointerEntry(0xA005, 0)])
    let gps = parts.gps
    var ifd0 = parts.ifd0 + (exif.isEmpty ? [] : [pointerEntry(0x8769, 0)]) + (gps.isEmpty ? [] : [pointerEntry(0x8825, 0)])
    let ifd0At = 8, exifAt = ifd0At + size(ifd0), interopAt = exifAt + size(exif), gpsAt = interopAt + size(interop)
    guard gpsAt + size(gps) <= 0xFFFF_FFFF else { return nil }
    ifd0 = ifd0.map { $0.tag == 0x8769 ? pointerEntry(0x8769, exifAt) : $0.tag == 0x8825 ? pointerEntry(0x8825, gpsAt) : $0 }
    exif = exif.map { $0.tag == 0xA005 ? pointerEntry(0xA005, interopAt) : $0 }

    var out: [UInt8] = (be ? [0x4D, 0x4D] : [0x49, 0x49]) + bytes(42, 2) + bytes(ifd0At, 4)
    for (entries, at) in [(ifd0, ifd0At), (exif, exifAt), (interop, interopAt), (gps, gpsAt)] where !entries.isEmpty {
        precondition(out.count == at, "EXIF 拼块的布局算错了")
        let sorted = entries.sorted { $0.tag < $1.tag }
        var table = bytes(sorted.count, 2)
        var values: [UInt8] = []
        var valueAt = at + 2 + 12 * sorted.count + 4
        for e in sorted {
            table += bytes(e.tag, 2) + bytes(e.type, 2) + bytes(e.count, 4)
            if e.value.count <= 4 {
                table += e.value + [UInt8](repeating: 0, count: 4 - e.value.count)
            } else {
                table += bytes(valueAt, 4)
                values += e.value + (e.value.count % 2 == 1 ? [0] : [])
                valueAt += (e.value.count + 1) & ~1
            }
        }
        out += table + bytes(0, 4) + values
    }
    return out
}

// MARK: - 入口

/// 从 RAW 文件的字节里拼出照搬用的 TIFF；不照搬时是原因。`type` 是 ImageIO 给的类型。
func cameraRawExifTIFF(_ bytes: [UInt8], type: String?) -> Result<[UInt8], RawExifSkip> {
    guard let type, let layout = cameraRawExifLayouts[type] else {
        return .failure(.init("这种 RAW（\(type ?? "类型不明")）的 EXIF 还不能整块照搬"))
    }
    do {
        let parts: RawExifParts
        switch layout {
        case .tiff(let magic):
            guard let tiff = TIFFStructure(bytes, base: 0, length: bytes.count, magic: magic) else {
                throw RawExifSkip("文件头不是 \(type) 应有的 TIFF 头")
            }
            parts = try tiffRawExifParts(tiff)
        case .cr3: parts = try cr3RawExifParts(bytes)
        case .raf: parts = try rafRawExifParts(bytes)
        }
        guard !(parts.ifd0.isEmpty && parts.exif.isEmpty && parts.interop.isEmpty && parts.gps.isEmpty) else {
            throw RawExifSkip("RAW 里没有可照搬的 EXIF")
        }
        guard let block = assembledExifTIFF(parts) else { throw RawExifSkip("拼出来的 EXIF 太大，4 字节的偏移放不下") }
        return .success(block)
    } catch let skip as RawExifSkip {
        return .failure(skip)
    } catch {
        return .failure(.init("\(error)"))
    }
}

/// 拼好的块里 IFD0 的方向，没有 Orientation 按 1 算；块读不出是 nil。
func carriedOrientation(_ block: [UInt8]) -> Int? {
    guard let tiff = TIFFStructure(block, base: 0, length: block.count), let ifd0 = tiff.ifd0 else { return nil }
    guard let field = tiff.find(ifd0, tag: 0x0112) else { return 1 }
    return field.size == 2 ? tiff.u16(field.offset) : nil
}

/// 要照搬进产物的那块 TIFF：从 RAW 里拼出来（cameraRawExifTIFF），而且块里 IFD0 的方向（没有按 1 算）
/// 与产物现在的方向 `productOrientation`（ImageIO 写的，就是源的方向）相同。方向不同时不照搬：
/// 像素没转，换了 EXIF 方向就把照片摆错了。
func cameraRawCarryPlan(source: [UInt8], type: String?, productOrientation: Int) -> Result<[UInt8], RawExifSkip> {
    let block: [UInt8]
    switch cameraRawExifTIFF(source, type: type) {
    case .success(let b): block = b
    case .failure(let skip): return .failure(skip)
    }
    let carried = carriedOrientation(block)
    guard carried == productOrientation else {
        return .failure(.init("RAW 里 EXIF 的方向（\(carried.map(String.init) ?? "读不出")）与产物的方向（\(productOrientation)）不同"))
    }
    return .success(block)
}
