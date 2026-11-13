// --verify 的比对规则：把元数据展开成「路径 = 值」逐条对照，并判定
// 哪些差异是真丢失、哪些只是重新编码的噪声。和怎么转码无关。

import Foundation
import ImageIO

// MARK: - 展开成可比较的集合

func flatten(_ value: Any, prefix: String = "", into result: inout [String: String]) {
    switch value {
    // 一条分支接住所有字典：String 键会桥接成 CFString，被这个 as? 一并接走。
    // 「桥接确实管用」由单元测试 flatten 那组守着。
    case let dict as [CFString: Any]:
        for (k, v) in dict {
            let name = k as String
            flatten(v, prefix: prefix.isEmpty ? name : "\(prefix)/\(name)", into: &result)
        }
    case let array as [Any]:
        for (i, v) in array.enumerated() { flatten(v, prefix: "\(prefix)[\(i)]", into: &result) }
    default:
        result[prefix] = trimPadding(String(describing: value))
    }
}

// EXIF 的数值以有理数（分子/分母）存放，写入方重新编码时常常换成另一个等价但
// 不完全相等的分数。两个例子：
//   -15/10 → -3/2                    约分程度不同，值完全相同
//   8192000/1419 → 3769821/653       重新逼近，相对误差约 2e-10
// 后者两边都已是最简分数，光靠约分对不上，所以数值型的值一律按相对误差比较，
// 而不是逐字符比较。
//
// 容差取 1e-8：比实测到的重编码噪声（约 6e-10）宽一个数量级，又远小于任何有
// 意义的改动——GPS 纬度差 1e-8 只相当于几厘米，ISO 差一档是千分之几。宁可报出
// 来也不要漏掉，所以不取更宽的值。
let numericTolerance = 1e-8

/// 把 "5773.08" 或 "8192000/1419" 解析成数值；不是数字就返回 nil（走字符串比较）。
func numericValue(_ s: String) -> Double? {
    if let d = Double(s) { return d }
    let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 else { return nil }
    return n / d
}

/// 两个元数据值是否算作没变。
func valuesMatch(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    guard let x = numericValue(a), let y = numericValue(b) else { return false }
    if x == y { return true }
    let scale = max(abs(x), abs(y))
    return scale > 0 && abs(x - y) <= numericTolerance * scale
}

/// EXIF 的定长字符串字段用 NUL 补齐，补齐长度在 JPEG 与 HEIC 里天然不同，
/// 序列化进 XMP 时 NUL 还会变成空格。比较时只看有效内容，不看尾部填充。
public func trimPadding(_ s: String) -> String {
    var end = s.endIndex
    while end > s.startIndex {
        let i = s.index(before: end)
        let c = s[i]
        guard c == "\0" || c == " " || c == "\t" || c == "\n" || c == "\r" else { break }
        end = i
    }
    return String(s[s.startIndex..<end])
}

// MARK: - 键路径

/// 元数据展开后的键路径形如 `{Exif}/DateTimeOriginal`。下面几张表都用它拼，
/// 拼法只在这里定义。字典名与字段名能用 ImageIO 常量就用常量，Apple 改了值也跟得上。
func metadataKey(_ dictionary: CFString, _ name: CFString) -> String {
    "\(dictionary as String)/\(name as String)"
}

func exifKey(_ name: CFString) -> String { metadataKey(kCGImagePropertyExifDictionary, name) }
func iptcKey(_ name: CFString) -> String { metadataKey(kCGImagePropertyIPTCDictionary, name) }

/// XMP 侧没有 ImageIO 常量，键路径是「命名空间前缀 + 标签名」，再由展开时统一
/// 冠上 `XMP/` 这一层。`path` 形如 `photoshop:DateCreated`。这一层前缀只在这里定义。
/// 键里的命名空间前缀由命名空间 URI 定（xmpKeyPrefixes），规则里写的前缀都在
/// standardXMPPrefixes 里，认的是那个 URI。
func xmpKey(_ path: String) -> String { "XMP/\(path)" }

/// 描述文件本身（编码方式、体积、色深）而非照片内容的键——转换后变化属正常，
/// 不该报成元数据丢失。
///
/// 用**完整键路径**精确匹配，不用子串。子串匹配看着省事，但 "Depth"、
/// "Compression"、"ProfileName" 这类片段太短：任何名字里含这几个字的真实字段
/// （厂商的 FocusDepth、XMP 的 DepthMapInfo 之类）都会被整条跳过，而且悄无声息。
///
/// 有常量的直接引用常量，Apple 改了值也跟得上；XMP 侧没有常量，只能写路径。
///
/// 色彩描述文件名（ProfileName）和色彩模型（ColorModel）不在这里：它们描述
/// 像素该怎么解读，ICC 被换掉（如 CMYK 的描述文件变成 sRGB）就是丢失。
let volatileKeys: Set<String> = {
    let topLevel: [CFString] = [
        kCGImagePropertyDepth, kCGImagePropertyPrimaryImage, kCGImagePropertyHasAlpha,
        kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed,
        kCGImagePropertyFileSize, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
    ]
    return Set(topLevel.map { $0 as String }).union([
        exifKey(kCGImagePropertyExifComponentsConfiguration),
        metadataKey(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCompression),
        xmpKey("exif:ComponentsConfiguration"),
    ])
}()

/// 整类都属于文件自身描述的前缀：JPEG 的 JFIF 段（HEIF 根本没有这个段），
/// 以及 ImageIO 打给自己看的内部标记（iio:hasIIM / iio:hasXMP）。
let volatileKeyPrefixes = ["{JFIF}/", xmpKey("iio:")]

/// 去掉数组下标：ComponentsConfiguration[0] 与 [1] 是同一个字段。
func strippingArrayIndex(_ key: String) -> String {
    guard key.hasSuffix("]"), let bracket = key.lastIndex(of: "[") else { return key }
    return String(key[key.startIndex..<bracket])
}

func isVolatile(_ key: String) -> Bool {
    if volatileKeyPrefixes.contains(where: { key.hasPrefix($0) }) { return true }
    return volatileKeys.contains(strippingArrayIndex(key))
}

/// 内嵌缩略图在属性视图里的键，去掉每一层的数组下标后按**完整键路径**比对。
/// 缩略图是从像素派生的预览，有意不报（README「--verify 到底比什么」）。
///
/// ImageIO 在容器级属性的 `{FileContents}` 字典里给每张缩略图列一组键。实测这个
/// 字典只在 JPEG 带辅助图时出现：带 IFD1 缩略图、不带辅助图的照片（`test_pic/` 两张）
/// 读不出它。子键只收实测见过的五个，ImageIO 以后多吐一个子键，它会照常被报出来，
/// 而不是被一个前缀悄悄吞掉。
let thumbnailKeys: Set<String> = Set(["Width", "Height", "Orientation", "ThumbnailOffset", "ThumbnailSize"]
    .map { "{FileContents}/Images/ThumbnailImages/\($0)" })

/// 去掉键路径里每一层末尾的数组下标：`{FileContents}/Images[0]/ThumbnailImages[1]/Width`
/// → `{FileContents}/Images/ThumbnailImages/Width`。下标里只认 ASCII 数字。
func strippingAllArrayIndices(_ key: String) -> String {
    key.split(separator: "/", omittingEmptySubsequences: false).map { component -> String in
        guard component.hasSuffix("]"), let bracket = component.lastIndex(of: "["),
              isAllDigits(Array(component[component.index(after: bracket)..<component.index(before: component.endIndex)]))
        else { return String(component) }
        return String(component[..<bracket])
    }.joined(separator: "/")
}

func isThumbnailKey(_ key: String) -> Bool {
    thumbnailKeys.contains(strippingAllArrayIndices(key))
}

/// `{FileContents}` 里描述主图编码方式的键，同样去掉每一层的数组下标后按完整键路径比对，
/// 理由同 volatileKeys。带辅助图的 JPEG 在 `{FileContents}/Images[n]/` 下列出的键实测有
/// ImageIndex、Width、Height、Orientation、NamedColorSpace、ChromaSubsampling、FlexRange
/// （以及 AuxiliaryData、DerivationDetails、ThumbnailImages 三组）。只收 ChromaSubsampling：
/// 4:2:2 的源转成 HEIF 后是 4:2:0，这是编码参数，和 Compression 同类。宽高、方向、色彩
/// 空间描述的是照片怎么显示，照常比；FlexRange 的含义 SDK 里没有说明，各样本两边也都
/// 相同，不忽略。
let fileContentsEncodingKeys: Set<String> = ["{FileContents}/Images/ChromaSubsampling"]

func isFileContentsEncodingKey(_ key: String) -> Bool {
    fileContentsEncodingKeys.contains(strippingAllArrayIndices(key))
}

/// JPEG 的 IPTC-IIM 段在 HEIF 里没有对应容器，但同样的信息由 XMP 或 EXIF 承载：
/// IIM 键 → 目标里可能承载它的那几个键。判据见 equivalentCarries。
let equivalentKeys: [String: [String]] = {
    // XMP 侧没有 ImageIO 常量，只能写路径。
    let shotAt = [xmpKey("photoshop:DateCreated"), exifKey(kCGImagePropertyExifDateTimeOriginal)]
    let digitizedAt = [xmpKey("xmp:CreateDate"), exifKey(kCGImagePropertyExifDateTimeDigitized)]
    return [
        iptcKey(kCGImagePropertyIPTCDateCreated): shotAt,
        iptcKey(kCGImagePropertyIPTCTimeCreated): shotAt,
        iptcKey(kCGImagePropertyIPTCDigitalCreationDate): digitizedAt,
        iptcKey(kCGImagePropertyIPTCDigitalCreationTime): digitizedAt,
    ]
}()

/// IIM 里会带 UTC 偏移的键。只有 Time 能带（`HHMMSS±HHMM`），
/// Date 不能——所以要不要拆偏移是**按键**决定的，不是看值的长相。
/// 按长相拆会把不合规范的 `2024-0915` 从减号处砍成 `2024`，截短的源值更容易
/// 被判成承载；Date 键根本不进拆分。
let iimTimeKeys: Set<String> = Set([kCGImagePropertyIPTCTimeCreated,
                                    kCGImagePropertyIPTCDigitalCreationTime].map(iptcKey))

/// 把 IIM 的时间拆成「时间」与「UTC 偏移」：`184207+0800` → (`184207`, `+0800`)。
/// 只拆 IIM 规范的确切形状——`HHMMSSZ`、`HHMMSS±HHMM`、`HHMMSS±HH:MM`；
/// 别的（含不带偏移的 `HHMMSS`）一律原样返回、偏移为 nil。偏移的形状与范围
/// 交给 UTCOffset，源侧与目标侧用同一把尺子。
///
/// 拆的条件：
///   第 7 个字符是 `+`/`-`/`Z` —— 只被它拦住的用例是 `184207.555Z`：UTCOffset 把
///                                `184207.555` 认作带小数秒的时刻，少了这一道就拆成
///                                (`184207`, +0000)，小数秒被悄悄丢掉
///   UTCOffset 认整个值末尾的偏移 —— 解析不出就不拆，如 `184207+9999`、
///                                `184207+12+0800`、`184207+1+080`
/// 「前六位是数字」「总长 ∈ {7, 11, 12}」是这两个条件的推论：UTCOffset 要求偏移前面
/// 为空或是一个完整时刻，而第 7 个字符又必须是偏移的起头，于是前文只能是 `HHMMSS`。
///
/// 每个漏洞都朝静默放过的方向：把源值截短总是让 carriesSameValue 更容易匹配上。
func splitIIMTime(_ value: String) -> (time: String, offset: UTCOffset?) {
    let chars = Array(value)
    guard let seventh = chars.dropFirst(6).first,
          seventh == "+" || seventh == "-" || seventh == "Z",
          let offset = UTCOffset(parsing: value) else { return (value, nil) }
    return (String(chars[0..<6]), offset)
}

/// 一串固定位数的数字字段，字段之间可以有一个字面分隔符。
///
/// 例：`DigitShape([2, 2, 2], ":")` 是 `hh:mm:ss`，`DigitShape([2, 2, 2])` 是
/// `hhmmss`，`DigitShape([4, 2, 2], "-")` 是 `yyyy-mm-dd`。字段宽度和分隔符都是
/// 数据，不编进模板字符串。
struct DigitShape: Equatable {
    let widths: [Int]
    let separator: Character?

    init(_ widths: [Int], _ separator: Character? = nil) {
        self.widths = widths
        self.separator = separator
    }

    /// 这个形状用尽时恰好多长。由形状自己推出来，不在调用点旁边重述成字面量。
    var length: Int {
        widths.reduce(0, +) + (separator == nil ? 0 : widths.count - 1)
    }

    /// 本项目用到的全部形状。命名放在类型旁边，这样生产代码和测试用的是
    /// 同一套名字，而不是生产重复匿名字面量、测试另起一套。
    static let hhmmssColon = DigitShape([2, 2, 2], ":")
    static let hhmmss = DigitShape([2, 2, 2])
    static let hhmmColon = DigitShape([2, 2], ":")
    static let hhmm = DigitShape([2, 2])
    static let ymdDash = DigitShape([4, 2, 2], "-")
    static let ymdPlain = DigitShape([4, 2, 2])
    static let ymdColon = DigitShape([4, 2, 2], ":")

    /// 按用途分组的清单。**每张清单**只在这里出现一次——不是每个形状只属于一张：
    /// `hhmm` 同时在 timeOfDayShapes 和 offsetBodyShapes 里，因为 `18:42` 和
    /// `+08:00` 的数字布局确实一样，只是含义不同。
    static let timeOfDayShapes: [DigitShape] = [.hhmmssColon, .hhmmss, .hhmmColon, .hhmm]
    static let dateShapes: [DigitShape] = [.ymdDash, .ymdPlain, .ymdColon]
    static let offsetBodyShapes: [DigitShape] = [.hhmm, .hhmmColon]
}

/// 按形状从 `value` 里切出各字段的数值。整个 `value` 必须被形状用尽——末尾
/// 多一个字符也不算匹配。分隔符不对、长度不符、出现非 ASCII 数字，一律 nil。
/// 成功时返回的个数恒等于 `shape.widths.count`，所以调用点不必再查字段个数。
/// 时刻、日期、偏移、Timestamp 的形状解析都走这里。
func numericFields(_ value: [Character], _ shape: DigitShape) -> [Int]? {
    var fields: [Int] = []
    var i = 0
    for (index, width) in shape.widths.enumerated() {
        if index > 0, let separator = shape.separator {
            guard i < value.count, value[i] == separator else { return nil }
            i += 1
        }
        guard i + width <= value.count else { return nil }
        let digits = Array(value[i..<(i + width)])
        // isAllDigits 在这里是承重的，不只是 Int(String) 的前置装饰：`Int` 认
        // 前导符号，`Int("+999")` 是 999。少了这一句，`+999-09-15` 会被当成一个
        // 日期，于是 `+999-09-15T18:42:07+08:00` 能读出 `+0800`——目标侧读取器
        // 一松就是静默放过。「ASCII 数字」这个判定只由 isAllDigits 定义。
        guard isAllDigits(digits), let n = Int(String(digits)) else { return nil }
        i += width
        fields.append(n)
    }
    guard i == value.count else { return nil }
    return fields
}

/// `value` 非空且全由 ASCII 数字组成。小数秒这类不分段的数字串用它判。
///
/// 这里的 `isASCII` 是**真守卫**：本函数没有 `Int(String)` 那道后手，
/// 去掉它全角数字就会被当成数字。
func isAllDigits(_ value: [Character]) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
}

/// UTC 偏移，归一化成「符号 + HHMM」（如 `+0800`）。
///
/// 做成类型而不是继续传裸 `String`：它要在 splitIIMTime、offsetSurvives、
/// equivalentCarries 之间传递，而"这个 String 已经归一化过"光看类型看不出来——
/// `+08:00`、`+0800`、`2024-09-15T18:42:07+08:00` 都是合法 String，只有一种
/// 能直接拿去比较。包成类型之后，比较只可能发生在解析之后。
///
/// 刻意不把 `+0000` 与 `-0000` 当同一个值：RFC 3339 里后者是"本地偏移未知"。
/// 真撞上这种差异就报出来——多报一条符合本项目的方向。
struct UTCOffset: Equatable {
    /// 规范写法，形如 `+0800`。
    let text: String

    /// 从 `+08:00`、`+0800`、`2024-09-15T18:42:07+08:00`、`…Z` 里解析出偏移；
    /// 解析不出就是 nil。
    ///
    /// 每种形状都**锚定在末尾**、逐字符核对、再验范围，不是"取最后一个加减号、
    /// 把后面的数字滤出来"。下面这些都必须读不出（单测「UTCOffset」一组）：
    ///   `2024-09-15T18`（日期里的减号）、`184207 -0800mm`（垃圾尾巴）、
    ///   `+9999`（越界）、`abc0Z`、`20240915Z`（Z 前面不是时刻）
    /// 这是**目标侧**的读取器：它一松，offsetSurvives 就会把"偏移其实已经丢了"
    /// 误判成"还在"，方向上正是静默放过。源侧的 splitIIMTime 用的是同一个解析器。
    init?(parsing value: String) {
        guard let text = UTCOffset.normalizedOffset(atEndOf: value) else { return nil }
        self.text = text
    }

    /// 在 `value` 的末尾找一个偏移并归一化。
    ///
    /// 所有形状共用**同一把尺子**：`Z` 和 `±` 的"前文"都必须是空（整个值就是
    /// 一个偏移字段，如 `+08:00`）或一个完整时刻（isTimestamp）。所以
    /// `镜头型号RF50mm1+0800`、`ISO100+0800`、`9999-99-99T18:42:07+08:00`、
    /// `20240915+0800` 都读不出——读出一个合法值比读不出更坏，因为连差异都不剩。
    private static func normalizedOffset(atEndOf value: String) -> String? {
        let chars = Array(value)
        if chars.last == "Z" {
            // Z 本身不带数值，所以它要求前文必须是时刻（空值 `Z` 不算 UTC）。
            return isTimestamp(Array(chars.dropLast())) ? "+0000" : nil
        }
        // `±HHMM` 或 `±HH:MM`：宽度是符号加形状自己的长度，不在这里重述数字。
        for shape in DigitShape.offsetBodyShapes {
            let width = shape.length + 1
            guard chars.count >= width else { continue }
            let head = Array(chars[..<(chars.count - width)])
            guard head.isEmpty || isTimestamp(head) else { continue }
            if let text = normalizedOffset(Array(chars[(chars.count - width)...])) { return text }
        }
        return nil
    }

    /// 整个 `value` 是不是一个完整的时刻。两头都锚定，不是"末尾像就算"：
    ///   `<时刻>`                 如 `184207`、`18:42`、`10:42:07`
    ///   `<日期><分隔><时刻>`      如 `2024-09-15T18:42:07`、`20240915T184207`
    /// 日期是 `YYYY-MM-DD`、`YYYYMMDD` 或 `YYYY:MM:DD`（EXIF 自己的写法，见
    /// isDate），分隔是 `T` 或空格，时刻见 isTimeOfDay。
    ///
    /// 照 ISO 8601 对"时刻"的定义写，两个方向都要对：
    ///   `995999`（59 分 99 秒）、`99:99:99`、`拍摄于 18:42:07` 不是时刻；
    ///   `2024-09-15T18:42`（分钟精度）、`20240915T184207`（基本格式）、
    ///   `2024-09-15T18:42:07,42`（逗号小数秒）是时刻。
    ///
    /// 一个不可消除的歧义：`202409` 既像年月、也像 20:24:09，按形状分不开，
    /// 只能当时刻收下。前提是它必须是**整个值**——没有哪个元数据字段会把年月
    /// 单独写成 6 位。同理 4 位无分隔的 `hhmm` 不接受单独成值（`2024` 会被
    /// 读成 20:24），只在日期后面出现时才算（`…T1842`）。
    private static func isTimestamp(_ value: [Character]) -> Bool {
        var head = value
        // 可选小数秒：ISO 8601 的小数点可以是 `.` 也可以是 `,`。
        if let point = head.lastIndex(where: { $0 == "." || $0 == "," }),
           point < head.count - 1,
           isAllDigits(Array(head[(point + 1)...])) {
            head = Array(head[..<point])
        }
        for shape in DigitShape.timeOfDayShapes where head.count >= shape.length {
            let width = shape.length
            guard isTimeOfDay(Array(head[(head.count - width)...]), shape) else { continue }
            // 整个值就是时刻。无分隔的四位数字与年份分不开（`2024` 会被读成
            // 20:24），不收。直接拿形状本身比，不按它的内部字段重述它。
            if head.count == width { return shape != .hhmm }
            let before = Array(head[..<(head.count - width)])
            guard let separator = before.last, separator == "T" || separator == " " else { continue }
            if isDate(Array(before.dropLast())) { return true }
        }
        return false
    }

    /// 按形状核对一个时刻并验范围。秒允许 60，那是闰秒。`shape` 取自
    /// timeOfDayShapes，每个都至少两个字段，所以 `parts[1]` 总在界内。
    private static func isTimeOfDay(_ value: [Character], _ shape: DigitShape) -> Bool {
        guard let parts = numericFields(value, shape),
              parts[0] <= 23, parts[1] <= 59 else { return false }
        return parts.count == 2 || parts[2] <= 60
    }

    /// `YYYY-MM-DD`、`YYYYMMDD` 或 `YYYY:MM:DD`，并验月日范围。不查某月到底有
    /// 几天：这里只是在判断「这段是不是一个日期」，不是在校验日历。
    ///
    /// 冒号那一种是 **EXIF 自己的日期格式**：`{Exif}/DateTimeOriginal` 写的
    /// 就是 `2024:09:15 18:42:07`，而 README 把它点名为等价承载键之一。
    /// EXIF 的日期不属于 ISO 8601，按 ISO 8601 列形状会漏掉它。
    private static func isDate(_ value: [Character]) -> Bool {
        for shape in DigitShape.dateShapes {
            // dateShapes 都是三字段的，numericFields 保证个数恰好是三。
            guard let parts = numericFields(value, shape) else { continue }
            if (1...12).contains(parts[1]), (1...31).contains(parts[2]) { return true }
        }
        return false
    }

    /// 核对一个候选 token（`±HHMM` 或 `±HH:MM`）并归一化成 `±HHMM`。
    private static func normalizedOffset(_ token: [Character]) -> String? {
        guard let sign = token.first, sign == "+" || sign == "-" else { return nil }
        let body = Array(token.dropFirst())
        // 宽度前提在本函数内成立，不寄托于调用方：形状是在这里按 body 自己的
        // 长度从 `offsetBodyShapes` 挑出来的，调用方传什么都不影响这一步。
        guard let shape = DigitShape.offsetBodyShapes
            .first(where: { $0.length == body.count }) else { return nil }
        // ISO 8601 的偏移范围是 -12:00…+14:00（README「--verify」一节同此），
        // 分钟 < 60。约束的是**总偏移量**，不是时和分各自的上限：
        //   - 要求分钟为 0 会拒掉真实存在的 +05:30、+05:45、+09:30、+13:45；
        //   - 时和分各自设上限（hours <= 14 && minutes <= 59）会放过 +14:30、
        //     +14:59、-12:30、-12:59 这些不存在的偏移。
        // offsetBodyShapes 都是两字段的，numericFields 保证个数恰好是二。
        guard let parts = numericFields(body, shape), parts[1] <= 59 else { return nil }
        let total = (sign == "-" ? -1 : 1) * (parts[0] * 60 + parts[1])
        guard total >= -12 * 60, total <= 14 * 60 else { return nil }
        return "\(sign)\(twoDigits(parts[0]))\(twoDigits(parts[1]))"
    }

    private static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}

/// 一个按位置拆开的时间戳：`<日期>[<T 或空格><时刻>[<小数秒>]][<偏移>]`。
///
/// 日期是 DigitShape.dateShapes 之一并验月日范围；时刻是 timeOfDayShapes 之一
/// 并验时分秒范围（`hhmm` 只在日期之后出现时才认）；小数点可以是 `.` 或 `,`；
/// 偏移是 `Z` 或 UTCOffset 认的 `±HHMM`/`±HH:MM`。字段一律只认 ASCII 数字。
/// 只有日期没有时刻也算（XMP 允许 `2024-09-15`）。别的形状一律 nil。
struct Timestamp: Equatable {
    let date: [Int]
    /// 空、`[时, 分]` 或 `[时, 分, 秒]`。
    let time: [Int]
    /// 小数秒的数字，去掉了末尾的 0；没有就是空串。
    let fraction: String
    let offset: UTCOffset?

    init?(parsing value: String) {
        let chars = Array(value)
        let split = chars.firstIndex { $0 == "T" || $0 == " " }
        let datePart = Array(chars[..<(split ?? chars.count)])
        guard let date = DigitShape.dateShapes.lazy.compactMap({ numericFields(datePart, $0) }).first,
              (1...12).contains(date[1]), (1...31).contains(date[2]) else { return nil }
        self.date = date
        guard let split else {
            time = []; fraction = ""; offset = nil
            return
        }
        var rest = Array(chars[(split + 1)...])
        var offset: UTCOffset?
        if let sign = rest.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let token = String(rest[sign...])
            offset = token == "Z" ? UTCOffset(parsing: "+00:00") : UTCOffset(parsing: token)
            guard offset != nil else { return nil }
            rest = Array(rest[..<sign])
        }
        self.offset = offset
        var fraction = ""
        if let point = rest.firstIndex(where: { $0 == "." || $0 == "," }) {
            let digits = Array(rest[(point + 1)...])
            guard isAllDigits(digits) else { return nil }
            fraction = String(String(digits).reversed().drop { $0 == "0" }.reversed())
            rest = Array(rest[..<point])
        }
        self.fraction = fraction
        guard let time = DigitShape.timeOfDayShapes.lazy.compactMap({ numericFields(rest, $0) }).first,
              time[0] <= 23, time[1] <= 59, time.count == 2 || time[2] <= 60 else { return nil }
        self.time = time
    }

    /// 本时间戳的全部信息在 `other` 里都还在：日期相同；时刻在自己给出的精度
    /// 上相同；自己有小数秒则小数秒相同；自己有偏移则偏移相同。`other` 多带
    /// 小数秒或偏移不算丢失——ImageIO 合成 XMP 时会从 EXIF 补上这两样。
    func isCarried(by other: Timestamp) -> Bool {
        guard date == other.date,
              other.time.count >= time.count, Array(other.time.prefix(time.count)) == time
        else { return false }
        if !fraction.isEmpty, fraction != other.fraction { return false }
        if let offset, other.offset != offset { return false }
        return true
    }
}

/// 目标文件里该带 UTC 偏移的那些字段。HEIF 没有 IIM 容器，源里 IIM 时间后缀的
/// 偏移只能落到这些地方；都找不到，那偏移就是真丢了。
let utcOffsetKeys: [String] = {
    let names = [kCGImagePropertyExifOffsetTime, kCGImagePropertyExifOffsetTimeOriginal,
                 kCGImagePropertyExifOffsetTimeDigitized]
    return names.map(exifKey) + names.map { xmpKey("exif:\($0 as String)") }
}()

/// 源里那个 UTC 偏移在目标里是否还找得到。
///
/// README 用「时区由 `OffsetTime` 单独承载」来论证可以把偏移剥掉再比时间——
/// 但那是对**目标文件**的断言，必须真查。偏移只存在于 IIM 时间后缀、而目标
/// 既没有 OffsetTime 也没有带偏移的 XMP 时间戳时，信息确实丢了一半，
/// 剥掉就比对等于静默放过。只在相关字段里找，不扫全表：
/// 扫全表撞上一个巧合的 `+0800` 就会把真丢失吞掉，方向错反。
func offsetSurvives(_ offset: UTCOffset, in after: [String: String],
                    alternatives: [String]) -> Bool {
    for key in utcOffsetKeys + alternatives {
        if let value = after[key], UTCOffset(parsing: value) == offset { return true }
    }
    return false
}

/// 源里 `key` 这一条在目标里没了，等价字段是否确实把它承载了下来。
///
/// 判据是等价字段**带着同一个值**，不是"等价字段存在"：源里
/// `{IPTC}/DateCreated = 20240915` 丢了、目标的 DateTimeOriginal 写着 2020 年，
/// 那信息就是真丢了，只看键存在完全拦不住。
/// 带 UTC 偏移的 IIM 时间还要多一道：偏移本身也得在目标里找得到。
func equivalentCarries(key: String, value: String, in after: [String: String]) -> Bool {
    guard let alternatives = equivalentKeys[key] else { return false }
    var time = value
    var offset: UTCOffset?
    if iimTimeKeys.contains(key) { (time, offset) = splitIIMTime(value) }
    guard alternatives.contains(where: { carriesSameValue(time, after[$0] ?? "") })
    else { return false }
    guard let offset else { return true }
    return offsetSurvives(offset, in: after, alternatives: alternatives)
}

/// 等价字段是否确实承载了源里那个值。
///
/// 等价表里的值都是日期/时间，只是格式不同：IIM 写 `20240915` 和 `184207`，
/// EXIF 写 `2024:09:15 18:42:07`，XMP 写 `2024-09-15T18:42:07.42`。
/// 按位置比：等价值拆成 Timestamp，源值是 8 位的 IIM 日期就和日期位比，
/// 是 6 位的 IIM 时间就和时刻位（时、分、秒）比。两边都只认 ASCII 数字；
/// 源值不是这两种形状、或等价值拆不开，一律不算承载。
func carriesSameValue(_ sourceValue: String, _ equivalentValue: String) -> Bool {
    guard let stamp = Timestamp(parsing: equivalentValue) else { return false }
    let source = Array(sourceValue)
    if let date = numericFields(source, .ymdPlain) { return date == stamp.date }
    if let time = numericFields(source, .hhmmss) { return time == stamp.time }
    return false
}


/// {ExifAux} 里 ImageIO 正式声明过的键。它们有 XMP `aux:` 命名空间可以承载，
/// 实测全部能完好转换到 HEIF，因此**不是** MakerNote 派生数据——真丢了就是真问题，
/// 必须逐条报出来，不能折进厂商私有那一行里。
/// 直接引用 ImageIO 的常量而不是写死字符串，Apple 改了值也跟得上。
let documentedExifAuxKeys = Set([
    kCGImagePropertyExifAuxFirmware, kCGImagePropertyExifAuxFlashCompensation,
    kCGImagePropertyExifAuxImageNumber, kCGImagePropertyExifAuxLensID,
    kCGImagePropertyExifAuxLensInfo, kCGImagePropertyExifAuxLensModel,
    kCGImagePropertyExifAuxLensSerialNumber, kCGImagePropertyExifAuxOwnerName,
    kCGImagePropertyExifAuxSerialNumber,
].map { $0 as String })

/// ImageIO 会把 EXIF 的 MakerNote（厂商私有块）解析成几个伪字典。原始 MakerNote
/// 它既不作为属性暴露出来，写 HEIF 时也不会带上，所以整块必然丢失——一张佳能照片
/// 能因此刷出上百行"丢失"，看着像灾难，其实只有一个原因。这里合并成一条报告。
///
/// 但归并的判据不能只看字典前缀。{ExifAux} 是混的：ImageIO 声明过的那几个键
/// （LensModel、SerialNumber…）走 XMP `aux:` 转换得好好的，只有它顺手塞进来的
/// 未声明键（AFInfo、FocusMode、ImageStabilization）才来自 MakerNote。按整个
/// {ExifAux}/ 前缀归并，等于一旦某个标准键真的丢了也会被折进计数里看不见——
/// 要的是不刷噪声，不是掩盖真丢失。
///
/// {PictureStyle} 则整类都是：SDK 里对它零声明，实测全部丢失。
func makerNoteGroup(of key: String) -> String? {
    if let name = key.dropPrefix("{ExifAux}/") {
        // 去掉数组下标再比对：AFInfo[12] 的键名是 AFInfo。
        return documentedExifAuxKeys.contains(strippingArrayIndex(name)) ? nil : "{ExifAux}"
    }
    if key.hasPrefix("{PictureStyle}/") { return "{PictureStyle}" }
    guard key.hasPrefix("{Maker"), let slash = key.firstIndex(of: "/") else { return nil }
    return String(key[key.startIndex..<slash])
}

private extension String {
    /// 有这个前缀就返回去掉前缀后的部分，否则 nil。
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// 把 XMP 数据包里的所有标签（含嵌套结构与数组）展开成 "路径 = 值"，键的前缀按命名空间定
/// （xmpKeys）。枚举时顺手记下每个标签的前缀与命名空间 URI，就是这个文件的「前缀 → URI」表。
func xmpTags(_ md: CGImageMetadata) -> [String: String] {
    final class Box {
        var tags: [(path: String, value: String)] = []
        var namespaces: [(prefix: String, uri: String)] = []
    }
    let box = Box()
    let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
    CGImageMetadataEnumerateTagsUsingBlock(md, nil, options) { path, tag in
        if let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
           let uri = CGImageMetadataTagCopyNamespace(tag) as String? {
            box.namespaces.append((prefix, uri))
        }
        if let value = CGImageMetadataTagCopyValue(tag) as? String {
            box.tags.append((path as String, trimPadding(value)))
        } else if let value = CGImageMetadataTagCopyValue(tag) as? NSNumber {
            box.tags.append((path as String, value.stringValue))
        }
        return true
    }
    return xmpKeys(box.tags, namespaces: box.namespaces)
}

// MARK: - XMP 的键：前缀按命名空间 URI 定

// XMP 里一个命名空间由 URI 认，前缀只是文件里的简写。ImageIO 读 XMP 时标准 URI 一律用它自己的
// 标准前缀；文件声明的前缀已被别的 URI 占着时改叫 `前缀_1_`、`前缀_2_`……而要不要加、加几，
// 取决于同一进程里同时还有哪些 XMP 对象（批量并发时同一个文件读两次可能拿到不同的前缀）。
// 所以键里的前缀不用 ImageIO 给的，由 URI 定（xmpKeyPrefixes）。

/// 命名空间 URI → 键里用的标准前缀：ImageIO 公开的十个命名空间（kCGImageMetadataNamespace* 与
/// kCGImageMetadataPrefix*），加上规则里引用到而不在其中的 MicrosoftPhoto、iio（URI 是 ImageIO
/// 读 `Tests/fixture --ms-rating` 的样本时报出的命名空间）。规则里写的每个 XMP 前缀都必须在这里：
/// 不在的话那条规则认的就是「恰好叫这个名字的任何命名空间」。
let standardXMPPrefixes: [String: String] = {
    let pairs: [(CFString, CFString)] = [
        (kCGImageMetadataNamespaceExif, kCGImageMetadataPrefixExif),
        (kCGImageMetadataNamespaceExifAux, kCGImageMetadataPrefixExifAux),
        (kCGImageMetadataNamespaceExifEX, kCGImageMetadataPrefixExifEX),
        (kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore),
        (kCGImageMetadataNamespaceIPTCCore, kCGImageMetadataPrefixIPTCCore),
        (kCGImageMetadataNamespaceIPTCExtension, kCGImageMetadataPrefixIPTCExtension),
        (kCGImageMetadataNamespacePhotoshop, kCGImageMetadataPrefixPhotoshop),
        (kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF),
        (kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic),
        (kCGImageMetadataNamespaceXMPRights, kCGImageMetadataPrefixXMPRights),
    ]
    var table = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0 as String, $0.1 as String) })
    table["http://ns.microsoft.com/photo/1.0/"] = "MicrosoftPhoto"
    table["http://ns.apple.com/ImageIO/1.0/"] = "iio"
    return table
}()

/// ImageIO 给的前缀去掉末尾所有的 `_数字_`（可能叠了几层）：`photoshop_1__1_` → `photoshop`，
/// `_1_` → 空串。`_` 之间至少一位 ASCII 数字才算。
func xmpPrefixBase(_ prefix: String) -> String {
    var scalars = Array(prefix.unicodeScalars)
    while scalars.last == "_" {
        var i = scalars.count - 2
        while i >= 0, scalars[i].isASCII, ("0"..."9").contains(scalars[i]) { i -= 1 }
        guard i >= 0, i < scalars.count - 2, scalars[i] == "_" else { break }
        scalars.removeSubrange(i...)
    }
    var base = ""
    base.unicodeScalars.append(contentsOf: scalars)
    return base
}

/// 键里写 URI 时的转义：URI 的 UTF-8 字节里，ASCII 字母、数字和 `-._~` 原样，其余（含 `%`、
/// `/`、`:`、`[`、`]`、`{`、`}`、空格、控制字符、非 ASCII）一律写成 `%XX`（大写十六进制）。
/// 不同的 URI 得出不同的结果；结果里没有键的语法用到的 `/`、`:`、`[`、`]`、`{`、`}`。
func escapedXMPNamespace(_ uri: String) -> String {
    let hex = Array("0123456789ABCDEF")
    var out = ""
    for byte in uri.utf8 {
        let c = Character(Unicode.Scalar(byte))
        if byte < 0x80, c.isLetter || c.isNumber || "-._~".contains(c) {
            out.append(c)
        } else {
            out += "%\(hex[Int(byte >> 4)])\(hex[Int(byte & 0xF)])"
        }
    }
    return out
}

/// 一个文件的「ImageIO 给的前缀 → 键里用的前缀」。`namespaces` 是枚举到的每个标签的前缀与 URI。
///
/// 1. URI 在 standardXMPPrefixes 里 → 表里的标准前缀。
/// 2. 不在 → 去掉 `_N_` 的基名（xmpPrefixBase）。基名是某个标准前缀、或这个文件里还有别的不在表里
///    的 URI 落到同一个基名时，写成 `基名{转义过的 URI}`（escapedXMPNamespace），如
///    `photoshop{http%3A%2F%2Fns.adobe.com%2Fphotoshop%2F1.1%2F}`；否则就是基名。
///
/// 同一个前缀报出不止一个 URI 时，分不清路径里那个前缀指哪一个，这个前缀不进表（路径里原样保留），
/// 它的几个 URI 照样参与「同基名」的判断。
func xmpKeyPrefixes(_ namespaces: [(prefix: String, uri: String)]) -> [String: String] {
    // URI 一律按转义后的写法认：转义结果是 ASCII，不同的字节就是不同的 URI。
    var urisByPrefix: [String: Set<String>] = [:]
    var standardByEscaped: [String: String] = [:]
    for (prefix, uri) in namespaces {
        let escaped = escapedXMPNamespace(uri)
        urisByPrefix[prefix, default: []].insert(escaped)
        if let standard = standardXMPPrefixes[uri] { standardByEscaped[escaped] = standard }
    }
    let standardNames = Set(standardXMPPrefixes.values)
    var urisByBase: [String: Set<String>] = [:]
    for (prefix, uris) in urisByPrefix {
        for uri in uris where standardByEscaped[uri] == nil {
            urisByBase[xmpPrefixBase(prefix), default: []].insert(uri)
        }
    }
    var result: [String: String] = [:]
    for (prefix, uris) in urisByPrefix {
        guard uris.count == 1, let uri = uris.first else { continue }
        if let standard = standardByEscaped[uri] { result[prefix] = standard; continue }
        let base = xmpPrefixBase(prefix)
        let shared = standardNames.contains(base) || urisByBase[base, default: []].count > 1
        result[prefix] = shared ? "\(base){\(uri)}" : base
    }
    return result
}

/// 把 ImageIO 的路径里的前缀换成键里用的前缀（`prefixes`，xmpKeyPrefixes 给的）。路径的每一段
/// （开头，以及方括号外的每个 `.` 之后）如果以表里的某个前缀加 `:` 开头就换掉，几个都对得上时取最长
/// 的；对不上的段原样保留。方括号里的下标（`[0]`、`[x-default]`）不动。
func xmpKeyPath(_ path: String, prefixes: [String: String]) -> String {
    guard !prefixes.isEmpty else { return path }
    // 按 Unicode 标量逐个比，不按 String 的等价规则（那会把写法不同的两个前缀当成一个）。
    let candidates = prefixes.map { (from: Array($0.key.unicodeScalars) + [":"], to: $0.value) }
        .sorted { $0.from.count > $1.from.count }
    let scalars = Array(path.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0, depth = 0, segmentStart = true
    while i < scalars.count {
        if segmentStart {
            segmentStart = false
            if let hit = candidates.first(where: { i + $0.from.count <= scalars.count
                                                   && Array(scalars[i..<(i + $0.from.count)]) == $0.from }) {
                out.append(contentsOf: hit.to.unicodeScalars)
                out.append(":")
                i += hit.from.count
                continue
            }
        }
        let c = scalars[i]
        out.append(c)
        if c == "[" { depth += 1 } else if c == "]" { depth = max(0, depth - 1) } else if c == ".", depth == 0 { segmentStart = true }
        i += 1
    }
    return String(out)
}

/// 一组「路径 + 值」和这个文件的「前缀 → URI」→ 键空间里的 XMP 键（`XMP/` 开头）与值。纯函数，
/// 单测直接喂。两条路径改写后撞成同一个键时取路径排在前面的那条，结果不随枚举顺序变。
func xmpKeys(_ tags: [(path: String, value: String)],
             namespaces: [(prefix: String, uri: String)]) -> [String: String] {
    let prefixes = xmpKeyPrefixes(namespaces)
    var result: [String: String] = [:]
    let ordered = tags.map { (scalars: $0.path.unicodeScalars.map(\.value), tag: $0) }
        .sorted { $0.scalars.lexicographicallyPrecedes($1.scalars) }
    for (_, (path, value)) in ordered {
        let key = xmpKey(xmpKeyPath(path, prefixes: prefixes))
        if result[key] == nil { result[key] = value }
    }
    return result
}

/// 一个文件的全部元数据键空间，摊平成「键路径 → 值」。
///
/// 两层缺一不可：属性字典（含 UserComment 的修补）和 XMP 包。只摊平前者会让
/// 所有 `XMP/...` 键静默缺席——不是"查不到"，是"无条件查不到"。
///
/// `repairing: false` 只关掉 UserComment 那一处修补，XMP 层照旧——给
/// Tests/probe 的 `--no-repair` 用，那一轮的前提恰恰是"ImageIO 自己读不出来"。
/// 做成参数而不是让调用方自己拼一份：自己拼就可能漏掉某一层，而漏掉是静默的
/// ——漏了 XMP 层的探针对每个 XMP 键都答「无」。
///
/// 修补了 UserComment 时，XMP 层里与 ImageIO 原来读出的 `{Exif}/UserComment` 同值的
/// `exif:UserComment` 也换成修补后的文本：那是 ImageIO 从同一段 EXIF 字节合成的同一个误读
/// （`ASCII` 头里的 UTF-8 按 Latin-1 读出的乱码），产物里它跟着 EXIF 变对，不换就会被报成变化。
/// 值不同的（XMP 包里自己写的备注）不动。
func metadataKeySpace(of image: CGImageSource, url: URL,
                      repairing: Bool = true) -> [String: String] {
    var flat: [String: String] = [:]
    let original = imageProperties(image)
    let props = repairing ? repairedProperties(original, url: url) : original
    flatten(props, into: &flat)
    flat = keyingAuxiliaryDataByType(flat)
    if let m = CGImageSourceCopyMetadataAtIndex(image, 0, nil) {
        var xmp = xmpTags(m)
        let key = xmpKey("exif:UserComment")
        func comment(_ p: [CFString: Any]) -> String? {
            ((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String)
                .map(trimPadding)
        }
        if let seen = comment(original), let repaired = comment(props), repaired != seen, xmp[key] == seen {
            xmp[key] = repaired
        }
        flat.merge(xmp) { a, _ in a }
    }
    return flat
}

/// `{FileContents}/Images[n]/AuxiliaryData[i]/…` 里的 `[i]` 换成这张辅助图的类型：
/// `{FileContents}/Images[0]/AuxiliaryData[Depth]/Width`。辅助图在产物里的先后不由源决定
/// （增益图随主图一起写，排在别的辅助图前面），按下标比，同一组辅助图换个顺序就会被报成
/// 一串「变化」。每种类型至多一张；读不出类型、或同一张图里类型重复时那一组照旧用下标。
func keyingAuxiliaryDataByType(_ flat: [String: String]) -> [String: String] {
    let marker = "/AuxiliaryData["
    func split(_ key: String) -> (head: String, index: String, tail: String)? {
        guard key.hasPrefix("{FileContents}/Images["), let m = key.range(of: marker),
              let close = key[m.upperBound...].firstIndex(of: "]") else { return nil }
        let index = String(key[m.upperBound..<close])
        guard isAllDigits(Array(index)) else { return nil }
        return (String(key[..<m.lowerBound]), index, String(key[key.index(after: close)...]))
    }
    var names: [String: String] = [:]          // head + 下标 → 类型名
    var seen: [String: Set<String>] = [:]      // head → 已出现的类型名
    var duplicated = Set<String>()
    for (key, value) in flat {
        guard let (head, index, tail) = split(key), tail == "/AuxiliaryDataType" else { continue }
        let name = value.hasPrefix("kCGImageAuxiliaryDataType") ? String(value.dropFirst(25)) : value
        if seen[head, default: []].insert(name).inserted == false { duplicated.insert(head) }
        names[head + "#" + index] = name
    }
    var result: [String: String] = [:]
    for (key, value) in flat {
        if let (head, index, tail) = split(key), !duplicated.contains(head),
           let name = names[head + "#" + index], !name.isEmpty {
            result[head + marker + name + "]" + tail] = value
        } else {
            result[key] = value
        }
    }
    return result
}

/// --verify 的源侧键空间：属性视图加 XMP（metadataKeySpace），时间字段以原始字节为准，
/// 覆盖属性视图里被调和过的值（见 RawTimes.swift）。转换时照搬 EXIF 的自检用同一份。
func sourceKeySpace(of image: CGImageSource, url: URL, bytes: [UInt8]) -> [String: String] {
    metadataKeySpace(of: image, url: url).merging(rawTimeFields(of: bytes)) { _, raw in raw }
}

/// 比对源与目标的元数据，返回丢失/变化的条目描述。
func metadataDiff(source: URL, dest: URL) -> [String] {
    guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
          let destImage = CGImageSourceCreateWithURL(dest as CFURL, nil) else {
        return ["无法重新打开文件进行校验"]
    }
    guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else {
        return ["无法重新读取源文件进行校验"]
    }
    guard let destData = try? Data(contentsOf: dest, options: .mappedIfSafe) else {
        return ["无法重新读取产物进行校验"]
    }
    let bytes = [UInt8](data)
    let before = sourceKeySpace(of: sourceImage, url: source, bytes: bytes)
    let after = metadataKeySpace(of: destImage, url: dest)
    let destBytes = [UInt8](destData)
    var destWindowsTags: [Int: String?] = [:]
    if case .tiff(let tiff) = heifExif(destBytes) { destWindowsTags = rawWindowsTags(tiff) }
    // 原始 EXIF 清点先做：它报出的 GPS 分数变化，键空间比对里同一处的视图键不再重复报；
    // 键空间比对已经报了丢失的标签，它也不再重复报。源视图里没有的 ImageUniqueID 由它按
    // 原始字节比值。
    let raw = rawExifDiff(source: bytes, dest: destBytes,
                          viewLosses: keySpaceLosses(before: before, after: after),
                          makerNoteReported: makerNoteLost(before: before, after: after),
                          sourceViewHasImageUniqueID: before[exifKey(kCGImagePropertyExifImageUniqueID)] != nil)
    // 说明、作者、版权里 EXIF 与 IPTC 打架、产物显示 EXIF 原值的，每组合成一行，键空间比对让位。
    let sourceTIFF = TIFFStructure(jpeg: bytes)
    let conflicts = reconciledConflicts(before: before, after: after, originals: exifTextOriginals(sourceTIFF))
    // 备注与三个文字标签的原文：产物的 EXIF 读不出时原始清点已经报了「无法核对」，这里不再说。
    var originalIssues: [String] = []
    if case .tiff(let destTIFF) = heifExif(destBytes) {
        originalIssues = userCommentOriginalIssues(
            source: sourceTIFF.flatMap(rawUserCommentValue), sourceBigEndian: sourceTIFF?.bigEndian ?? true,
            product: rawUserCommentValue(destTIFF), productBigEndian: destTIFF.bigEndian,
            reportedElsewhere: userCommentReportedElsewhere(before: before, after: after, covered: raw.coveredViewKeys,
                                                            rawLostTags: raw.lostMainTags))
        for group in ReconciledGroup.allCases {
            let elsewhere = conflicts.covered.contains(group.tiffKey)
                || originalReportedElsewhere(key: group.tiffKey, tag: group.tag, before: before, after: after,
                                             covered: raw.coveredViewKeys, rawLostTags: raw.lostMainTags)
            originalIssues += exifTextOriginalIssues(group, source: sourceTIFF.flatMap { rawIFD0Value($0, tag: group.tag) },
                                                     product: rawIFD0Value(destTIFF, tag: group.tag),
                                                     reportedElsewhere: elsewhere)
        }
    }
    // 后几项都是属性视图里没有的源数据，直接读源文件字节；尾部记账另要两边的辅助图视图。
    return keySpaceDiff(before: before, after: after, covered: raw.coveredViewKeys.union(conflicts.covered))
        + conflicts.issues
        + raw.issues
        + carriedExifIssues(source: bytes, dest: destBytes,
                            comment: SourceUserComment(imageProperties(sourceImage), reading: rawExifUserComment(in: bytes)))
        + originalIssues
        + windowsTagLosses(rawWindowsTags(of: bytes), after: after, destRaw: destWindowsTags)
        + unportableSegments(in: bytes, carriedAuxiliary: carriedAuxiliarySizes(source: sourceImage, dest: destImage))
        + unportablePhotoshopResources(in: bytes)
        + extendedAttributeIssues(source: source.path, dest: dest.path)
}

// MARK: - 扩展属性

/// 一个文件上全部扩展属性的「名字 → 值」；属性列表读不出、或列出来的某个属性的值读不出是 nil。
func extendedAttributes(_ path: String) -> [String: [UInt8]]? {
    guard let names = extendedAttributeNames(path) else { return nil }
    var result: [String: [UInt8]] = [:]
    for name in names {
        guard let value = extendedAttributeValue(path, name) else { return nil }
        result[name] = value
    }
    return result
}

/// 扩展属性核对：读两边的扩展属性交给 extendedAttributeDiff。任何一边读不出是一行「无法核对扩展属性」。
func extendedAttributeIssues(source: String, dest: String) -> [String] {
    guard let s = extendedAttributes(source) else { return ["无法核对扩展属性：读不出源文件的扩展属性"] }
    guard let d = extendedAttributes(dest) else { return ["无法核对扩展属性：读不出产物的扩展属性"] }
    return extendedAttributeDiff(source: s, product: d)
}

/// 有人看得懂的名字的扩展属性：名字，和把值解成文本的办法（解不出是 nil）。
let namedXattrs: [String: (label: String, decode: ([UInt8]) -> String?)] = [
    "com.apple.assetsd.description": ("「照片」的说明", { String(validatingUTF8Bytes: $0) }),
    "com.apple.metadata:kMDItemFinderComment": ("访达备注", { plistValue($0) as? String }),
    "com.apple.metadata:_kMDItemUserTags": ("访达标签", { bytes in
        // 每个标签是「名字」或「名字\n颜色编号」，显示时去掉颜色编号。
        guard let tags = plistValue(bytes) as? [String] else { return nil }
        return tags.map { $0.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? $0 }
            .joined(separator: "、")
    }),
]

/// 扩展属性的值是二进制（或 XML）plist 时解出来的对象；解不出是 nil。
func plistValue(_ bytes: [UInt8]) -> Any? {
    try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
}

extension String {
    /// 字节是合法的 UTF-8 时的文本，否则 nil（不像 String(decoding:) 那样替换成 U+FFFD）。
    init?(validatingUTF8Bytes bytes: [UInt8]) {
        guard let s = String(bytes: bytes, encoding: .utf8) else { return nil }
        self = s
    }
}

/// 扩展属性的差异：源上的每一个属性，除了转换时本来就不拷的（skippedXattrs），产物上必须有同名、
/// 值逐字节相同的一份。产物上多出来的不报。纯函数，单测直接喂字典。
///
/// - 产物上没有：`丢失 扩展属性 <名字>（N 字节）`；
/// - 值不同：`变化 扩展属性 <名字>（N 字节 → M 字节）`，等长时加上从第几个字节（从 1 数）起不同。
/// namedXattrs 里的三种换成人看得懂的名字并显示值；值解不出时照旧只报字节数。
func extendedAttributeDiff(source: [String: [UInt8]], product: [String: [UInt8]]) -> [String] {
    var issues: [String] = []
    for (name, value) in source.sorted(by: { $0.key < $1.key }) where !skippedXattrs.contains(name) {
        let other = product[name]
        if other == value { continue }
        func sizes() -> String {
            guard let other else { return "\(value.count) 字节" }
            var text = "\(value.count) 字节 → \(other.count) 字节"
            if value.count == other.count, let k = (0..<value.count).first(where: { value[$0] != other[$0] }) {
                text += "，第 \(k + 1) 个字节起不同"
            }
            return text
        }
        let verb = other == nil ? "丢失" : "变化"
        guard let named = namedXattrs[name], let text = named.decode(value) else {
            let label = namedXattrs[name].map { "\($0.label)（扩展属性 \(name)，" } ?? "扩展属性 \(name)（"
            issues.append("\(verb) \(label)\(sizes())）")
            continue
        }
        let head = "\(verb) \(named.label)（扩展属性 \(name)）"
        guard let other else {
            issues.append("\(head)= \(truncate(text))")
            continue
        }
        guard let otherText = named.decode(other) else {
            issues.append("\(head)：\(truncate(text)) → （\(sizes())，解不出）")
            continue
        }
        var line = "\(head)：\(truncate(text)) → \(truncate(otherText))"
        if truncate(text) == truncate(otherText) { line += "（显示相同，\(sizes())）" }
        issues.append(line)
    }
    return issues
}

/// 照搬过的产物，EXIF 必须与源逐字节相同，或者恰好是源的备注改写。
///
/// 原始清点对非 GPS 标签只看在不在、不比值；照搬过来的 MakerNote、私有标签的字节对不对，
/// 视图和清点都看不见。这一条不看标签语义，只看结构：产物的 Exif 项结束在文件末尾
/// （heifExifEndsAtFileEnd；ImageIO 自己写的产物里它在 mdat 靠前的位置，永远不在末尾）就是
/// 照搬过的产物，它的 TIFF 字节（P）与源 EXIF 段（TIFFStructure(jpeg:) 认的那一段，S）之间
/// 只认两种关系（carriedTIFFMatches）：P 与 S 逐字节相同；或者 P 是 S 的备注改写。
/// 源里没有 EXIF 段时按 0 字节比。K 从 1 数起。
func carriedExifIssues(source: [UInt8], dest: [UInt8], comment: SourceUserComment) -> [String] {
    guard heifExifEndsAtFileEnd(dest) else { return [] }
    let s = TIFFStructure(jpeg: source).map { Array($0.bytes[$0.base..<($0.base + $0.length)]) } ?? []
    guard case .tiff(let t) = heifExif(dest) else {
        return ["变化 EXIF 数据块：照搬过来的 EXIF 读不出（源 \(s.count) 字节）"]
    }
    let d = Array(t.bytes[t.base..<(t.base + t.length)])
    guard !carriedTIFFMatches(source: s, product: d, comment: comment) else { return [] }
    let k = (0..<min(s.count, d.count)).first { s[$0] != d[$0] } ?? min(s.count, d.count)
    return ["变化 EXIF 数据块：照搬过来的 EXIF 与源不一致（\(s.count) 字节 → \(d.count) 字节，第 \(k + 1) 个字节起不同）"]
}

/// carriedExifIssues 认的两种关系：源 TIFF `source` 与产物 TIFF `product` 逐字节相同；或者
/// 源满足修补条件（`comment.toRepair` 不是 nil，条件见 SourceUserComment.toRepair），且 `product`
/// 是 `source` 按修补的文本做的备注改写（isUserCommentRewrite）。不满足修补条件的备注（ImageIO
/// 读得对的、猜的）被改写了，不认。
func carriedTIFFMatches(source: [UInt8], product: [UInt8], comment: SourceUserComment) -> Bool {
    if source == product { return true }
    guard let text = comment.toRepair else { return false }
    return isUserCommentRewrite(source: source, product: product, text: text)
}

/// 备注原文核对：按两边 0x9286 的原始值字节（含字符集头；没有这一条是 nil）各读一遍
/// （userCommentReadingForComparison），源里有备注时：
///
/// | 源的备注 | 产物必须 | 否则报 |
/// |---|---|---|
/// | 可靠的文本 T | 也是可靠的文本，过了 normalizedUserComment 后等于 T | 原文变化；产物没有备注是原文丢失 |
/// | 猜的 | 0x9286 的值字节与源的逐字节相同 | 换了写法、原文无法核对；产物没有备注是丢失 |
///
/// `sourceBigEndian`、`productBigEndian` 是两边各自所在 TIFF 的字节序。判定与措辞见
/// originalTextIssues；猜的那种比的是 0x9286 的全部值字节（含头）。
///
/// 键空间比对比的是 ImageIO 两边读出来的值：ImageIO 把源读错、又把读错的写进产物，两边一样，
/// 它看不见。这一条看的是原文。`reportedElsewhere`（userCommentReportedElsewhere）为真时同一处
/// 已经有一行了，不再报。纯函数，单测直接喂字节。
func userCommentOriginalIssues(source: [UInt8]?, sourceBigEndian: Bool, product: [UInt8]?, productBigEndian: Bool,
                               reportedElsewhere: Bool) -> [String] {
    guard !reportedElsewhere else { return [] }
    /// 猜的那种值为什么不可靠。
    func unreadable(_ header: UserCommentHeader) -> String {
        switch header {
        case .jis: return "按 JIS 头解不出"
        case .unicode: return "按 UNICODE 头解不出"
        case .ascii, .undefined, .none: return "不是合法的 UTF-8"
        }
    }
    func original(_ raw: [UInt8]?, bigEndian: Bool) -> OriginalText {
        switch raw.map({ userCommentReadingForComparison($0, bigEndian: bigEndian) }) ?? .absent {
        case .absent: return .absent
        case .reliable(let decoded, _): return .reliable(normalizedUserComment(decoded))
        case .guessed(_, let raw, let header): return .unreliable(size: raw.count, why: unreadable(header))
        }
    }
    return originalTextIssues("备注 UserComment", source: original(source, bigEndian: sourceBigEndian),
                              product: original(product, bigEndian: productBigEndian),
                              sameBytes: source != nil && product == source)
}

/// 原文核对里一边读出来的东西（备注、三个文字标签共用）。
enum OriginalText: Equatable {
    /// 没有，或去掉填充后是空的。
    case absent
    /// 可靠的文本，已经过各自的归一（去掉 BOM、尾部的 NUL 与空白）。
    case reliable(String)
    /// 解不出可靠的文本：值的字节数，与为什么（「不是合法的 UTF-8」之类）。
    case unreliable(size: Int, why: String)
}

/// 原文核对的判定与报告行，`label` 如「备注 UserComment」「EXIF 说明 ImageDescription」：
///
/// | 源 | 产物必须 | 否则报 |
/// |---|---|---|
/// | 可靠的文本 T | 也是可靠的文本，且等于 T | 原文变化；产物没有是原文丢失 |
/// | 不可靠 | 拿来比的字节与源的相同（`sameBytes`） | 换了写法、原文无法核对；产物没有是丢失 |
///
/// 报的时候两边显示的就是拿来比的那串文本（shownText：截断，NUL 写成 `\0`）。
func originalTextIssues(_ label: String, source: OriginalText, product: OriginalText, sameBytes: Bool) -> [String] {
    switch source {
    case .absent:
        return []
    case .reliable(let text):
        let other: String
        switch product {
        case .absent: return ["丢失 \(label) 的原文 = \(shownText(text))"]
        case .reliable(let o):
            other = o
            guard other != text else { return [] }
        case .unreliable(let size, let why):
            return ["变化 \(label) 的原文：\(shownText(text)) → （\(size) 字节，\(why)）"]
        }
        var line = "变化 \(label) 的原文：\(shownText(text)) → \(shownText(other))"
        if shownText(text) == shownText(other) {
            let a = Array(text), b = Array(other)
            let at = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
            line += "（显示相同，第 \(at + 1) 个字符起不同）"
        }
        return [line]
    case .unreliable(let size, let why):
        if sameBytes { return [] }
        if product == .absent { return ["丢失 \(label)（\(size) 字节，\(why)）"] }
        return ["变化 \(label)：源里的字节\(why)（\(size) 字节），产物里换了一种写法，原文无法核对"]
    }
}

/// 备注原文核对用的读法：同 readUserComment，只有一处不同——`UNICODE` 头、正文不以 BOM 开头的
/// 值，按它所在 TIFF 的字节序（`bigEndian`）解，不用 readUserComment 里「两种都解、取更像文本的」
/// 那一套：EXIF 里没有 BOM 的 UTF-16 约定俗成跟 TIFF 同字节序，别的读取器（exiftool）也这样读。
/// 按 TIFF 字节序解不出（如落单的代理项）是猜的。有 BOM 的照样认 BOM。
func userCommentReadingForComparison(_ raw: [UInt8], bigEndian: Bool) -> UserCommentReading {
    let reading = readUserComment(raw)
    guard raw.count >= 8, Array(raw[0..<8]) == Array("UNICODE\0".utf8) else { return reading }
    let body = Array(raw[8...])
    if body.starts(with: [0xFE, 0xFF]) || body.starts(with: [0xFF, 0xFE]) { return reading }
    guard let decoded = String(bytes: body, encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian) else {
        return .guessed(nil, raw: raw, header: .unicode)
    }
    return normalizedUserComment(decoded).isEmpty ? .absent : .reliable(decoded, header: .unicode)
}


/// 备注这一处是不是已经有一行了（originalReportedElsewhere，视图键 `{Exif}/UserComment`、标签 0x9286）。
func userCommentReportedElsewhere(before: [String: String], after: [String: String], covered: Set<String>,
                                  rawLostTags: Set<Int>) -> Bool {
    originalReportedElsewhere(key: exifKey(kCGImagePropertyExifUserComment), tag: 0x9286, before: before, after: after,
                              covered: covered, rawLostTags: rawLostTags)
}

/// 一个 EXIF 标签这一处是不是已经有一行了：键空间比对为它的视图键 `key` 报了丢失或变化（没被
/// 原始清点盖掉，`covered`），或者原始清点报了标签 `tag` 丢失（`rawLostTags`）。原文核对向它们
/// 让位：它们早就有、写的是用户在别的软件里看得到的值；原文核对只补它们看不见的那种（两边读法
/// 一样错，或 ImageIO 两边显示的是调和出的同一个值）。
func originalReportedElsewhere(key: String, tag: Int, before: [String: String], after: [String: String],
                               covered: Set<String>, rawLostTags: Set<Int>) -> Bool {
    if rawLostTags.contains(tag) { return true }
    guard !covered.contains(key), let value = before[key] else { return false }
    let verdict = keyVerdict(key, value, after: after)
    return verdict == .lost || verdict == .changed
}

/// 源和产物里都有的辅助图的宽高：同一类型、宽高与像素格式都相同才算。尾部记账
/// （carriedTrailerRanges）只认这里列出的尺寸。
func carriedAuxiliarySizes(source: CGImageSource, dest: CGImageSource) -> [(width: Int, height: Int)] {
    func shape(_ image: CGImageSource, _ type: CFString) -> [Int]? {
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(image, 0, type) as? [CFString: Any],
              let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
              let width = description[kCGImagePropertyWidth] as? Int,
              let height = description[kCGImagePropertyHeight] as? Int,
              let format = description[kCGImagePropertyPixelFormat] as? Int else { return nil }
        return [width, height, format]
    }
    return auxiliaryDataTypes.compactMap { type in
        guard let s = shape(source, type), shape(dest, type) == s else { return nil }
        return (s[0], s[1])
    }
}

/// XMP 的时间戳按时刻比（Timestamp.isCarried）：目标可以多带小数秒或偏移，
/// 不能少、不能变。源侧取的是原始 XMP 包，而目标的 XMP 是 ImageIO 合成的，
/// 一致的照片上它也会从 EXIF 补上 `.42` 这样的小数秒。
func xmpTimeCarried(key: String, _ source: String, _ target: String) -> Bool {
    guard key.hasPrefix(xmpKey("")),
          let s = Timestamp(parsing: source), let t = Timestamp(parsing: target) else { return false }
    return s.isCarried(by: t)
}

/// 尺子本来就不比的键：描述文件自身的（isVolatile）、内嵌缩略图的、编码参数的。
func isIgnoredKey(_ k: String) -> Bool {
    isVolatile(k) || isThumbnailKey(k) || isFileContentsEncodingKey(k)
}

/// 源里的一个键与另一边的键空间比，得出的结论。这是键空间比对的那把尺子：keySpaceDiff 据此
/// 出差异行，keySpaceLosses、makerNoteLost 据此告诉原始 EXIF 清点哪些已经报过，
/// inconsistentKeys 据此判「与源不一致」（转换时照搬 EXIF 的自检用它），各处不另写一份。
enum KeyVerdict: Equatable {
    /// 尺子不比的键（isIgnoredKey）。
    case skipped
    /// 另一边没有这个键，但等价字段带着同一个值（equivalentCarries）。
    case carried
    /// 另一边没有这个键，它属于 MakerNote 派生的伪字典（makerNoteGroup）。
    case makerNote(String)
    case lost
    /// 两边都有，值算作相同（valuesMatch，XMP 时间按 xmpTimeCarried）。
    case matched
    case changed
}

func keyVerdict(_ k: String, _ v: String, after: [String: String]) -> KeyVerdict {
    if isIgnoredKey(k) { return .skipped }
    guard let w = after[k] else {
        if equivalentCarries(key: k, value: v, in: after) { return .carried }
        if let group = makerNoteGroup(of: k) { return .makerNote(group) }
        return .lost
    }
    return valuesMatch(v, w) || xmpTimeCarried(key: k, v, w) ? .matched : .changed
}

/// 视图 `after` 里与源 `before` 不一致的键：源里有、按 keyVerdict 是丢失、MakerNote 丢失或
/// 值变了的；以及视图里有、源里没有的（尺子不比的键除外）。键照原样（带数组下标）。
func inconsistentKeys(before: [String: String], after: [String: String]) -> Set<String> {
    var keys = Set<String>()
    for (k, v) in before {
        switch keyVerdict(k, v, after: after) {
        case .makerNote, .lost, .changed: keys.insert(k)
        case .skipped, .carried, .matched: break
        }
    }
    for k in after.keys where before[k] == nil && !isIgnoredKey(k) { keys.insert(k) }
    return keys
}

/// keySpaceDiff 会逐条报成「丢失」的键，去掉了数组下标。
func keySpaceLosses(before: [String: String], after: [String: String]) -> Set<String> {
    Set(before.filter { k, v in keyVerdict(k, v, after: after) == .lost }.keys.map(strippingAllArrayIndices))
}

/// keySpaceDiff 会出 MakerNote 汇总行。
func makerNoteLost(before: [String: String], after: [String: String]) -> Bool {
    before.contains { k, v in if case .makerNote = keyVerdict(k, v, after: after) { return true }; return false }
}

/// 两个键空间 → 差异列表。纯函数，不碰文件：单测直接喂手搭的字典，
/// 逐分支钉住（值变化、等价字段承载、MakerNote 汇总、易变键跳过）。
///
/// `covered`：别处已经报过的视图键，这里不再报，一处变化只出一行。原始 EXIF 清点给的是去掉
/// 数组下标的键（盖住它的所有下标），打架合成的那一行（reconciledConflicts）给的是键本身。
func keySpaceDiff(before: [String: String], after: [String: String],
                  covered: Set<String> = []) -> [String] {
    var issues: [String] = []
    var makerNoteLost: [String: Int] = [:]   // 伪字典名 → 丢失条目数

    for (k, v) in before.sorted(by: { $0.key < $1.key })
    where !covered.contains(strippingAllArrayIndices(k)) && !covered.contains(k) {
        switch keyVerdict(k, v, after: after) {
        case .skipped, .carried, .matched:
            continue
        case .makerNote(let group):
            makerNoteLost[group, default: 0] += 1
        case .lost:
            issues.append("丢失 \(k) = \(truncate(v))")
        case .changed:
            issues.append("变化 \(k): \(truncate(v)) → \(truncate(after[k]!))")
        }
    }

    if !makerNoteLost.isEmpty {
        let total = makerNoteLost.values.reduce(0, +)
        let detail = makerNoteLost.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value) 项" }.joined(separator: "、")
        issues.append("丢失 厂商私有数据 MakerNote（\(total) 项：\(detail)）"
                      + "——ImageIO 读不出原始 MakerNote，也无法把它写入 HEIF")
    }
    return issues
}

/// 截断过长的值，免得一条差异刷满整屏。
func truncate(_ text: String, max limit: Int = 60) -> String {
    text.count <= limit ? text : String(text.prefix(limit)) + "…"
}
