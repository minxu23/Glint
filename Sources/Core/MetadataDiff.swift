// --verify 的比对规则：把元数据展开成「路径 = 值」逐条对照，并判定
// 哪些差异是真丢失、哪些只是重新编码的噪声。
//
// 从 Converter.swift 拆出来——"什么算变了"是一套独立演化的判断，
// 和怎么转码无关；它也是整个项目里最容易判错的部分，值得单独放。

import Foundation
import ImageIO

// MARK: - 展开成可比较的集合

func flatten(_ value: Any, prefix: String = "", into result: inout [String: String]) {
    switch value {
    // 一条分支接住所有字典。原先这里还有一条一模一样的 [String: Any] 分支，
    // 看着是"两种键类型都得接"，其实是死代码：String 键会桥接成 CFString，
    // 下面这个 as? 先接走了，那条永远走不到。实测把它删掉，展开结果一字不变。
    // 「桥接确实管用」由单元测试 flatten 那组守着——哪天不管用了，那条会红。
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
func trimPadding(_ s: String) -> String {
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

/// 元数据展开后的键路径形如 `{Exif}/DateTimeOriginal`。下面几张表都要拼它，
/// 以前每张表各自 `let exif = kCGImagePropertyExifDictionary as String` 再手拼
/// 一遍，四张表重复了四次——拼法真要动（比如换分隔符）得记得改四处。
/// 字典名与字段名能用 ImageIO 常量就用常量，Apple 改了值也跟得上。
func metadataKey(_ dictionary: CFString, _ name: CFString) -> String {
    "\(dictionary as String)/\(name as String)"
}

func exifKey(_ name: CFString) -> String { metadataKey(kCGImagePropertyExifDictionary, name) }
func iptcKey(_ name: CFString) -> String { metadataKey(kCGImagePropertyIPTCDictionary, name) }

/// XMP 侧没有 ImageIO 常量，键路径是「命名空间前缀 + 标签名」，再由展开时统一
/// 冠上 `XMP/` 这一层。`path` 形如 `photoshop:DateCreated`。
/// 这一层前缀以前在五处手写（三张表、volatileKeyPrefixes、xmpTags），
/// 是那几张表里最后一个手拼的字符串——真要改层名得记得改五处。
func xmpKey(_ path: String) -> String { "XMP/\(path)" }

/// 描述文件本身（编码方式、体积、色深）而非照片内容的键——转换后变化属正常，
/// 不该报成元数据丢失。
///
/// 用**完整键路径**精确匹配，不用子串。子串匹配看着省事，但 "Depth"、
/// "Compression"、"ProfileName" 这类片段太短：任何名字里含这几个字的真实字段
/// （厂商的 FocusDepth、XMP 的 DepthMapInfo 之类）都会被整条跳过，而且悄无声息。
/// 这和 makerNoteGroup 曾经按字典前缀整类归并是同一类错误——噪声是降了，
/// 真丢失也一并藏了。
///
/// 有常量的直接引用常量，Apple 改了值也跟得上；XMP 侧没有常量，只能写路径。
let volatileKeys: Set<String> = {
    let topLevel: [CFString] = [
        kCGImagePropertyDepth, kCGImagePropertyProfileName, kCGImagePropertyPrimaryImage,
        kCGImagePropertyColorModel, kCGImagePropertyHasAlpha,
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

/// IIM 里会带 UTC 偏移的那两个键。只有 Time 能带（`HHMMSS±HHMM`），
/// Date 不能——所以要不要拆偏移是**按键**决定的，不是看值的长相。
///
/// 这件事上一版栽过：按长相拆（「全数字 + 号 + 4 位偏移」）会把不合规范的
/// `2024-0915` 从减号处砍成 `2024`，而 `2024` 几乎出现在任何日期里，
/// 于是「9 月 15 日丢了、目标写着 1 月 1 日」会被判成承载、一声不响地放过。
/// 按键拆就不存在这个口子：Date 键根本不进拆分。
let iimTimeKeys: Set<String> = Set([kCGImagePropertyIPTCTimeCreated,
                                    kCGImagePropertyIPTCDigitalCreationTime].map(iptcKey))

/// 把 IIM 的时间拆成「时间」与「UTC 偏移」：`184207+0800` → (`184207`, `+0800`)。
/// 只认 IIM 规范的确切形状——`HHMMSS`（6 位）、`HHMMSSZ`（7 位）、
/// `HHMMSS±HHMM`（11 位）、`HHMMSS±HH:MM`（12 位），且偏移必须从第 6 位开始。
/// 别的一律原样返回、偏移为 nil——宽松的形状判断就是上面注释里说的那个口子。
func splitIIMTime(_ value: String) -> (time: String, offset: UTCOffset?) {
    let chars = Array(value)
    if chars.count == 6, chars.allSatisfy(\.isNumber) { return (value, nil) }
    // `HHMMSS` 后面紧跟一个合规偏移才拆。偏移的形状与范围交给 UTCOffset 判断，
    // 源侧与目标侧用同一把尺子——"一侧严一侧松"是上一轮漏掉的那条。
    //
    // 三个条件缺一不可：
    //   总长 ∈ {7, 11, 12}  —— 否则 `184207+12+0800` 也能过：第 6 位是加号、
    //                           尾巴那段偏移也合规，中间的 `+12` 被悄悄丢掉
    //   第 6 位是 `+`/`-`/`Z` 之一（偏移能有的三种起头，就地写出来：曾经抽成
    //                           UTCOffset.canBegin，但解析路径本身并不走它，
    //                           抽出去并没有换来单一事实来源，只多一跳）
    //                        —— 否则 `1842071+0800`（12 位，与 HHMMSS±HH:MM 同长）
    //                           也能过，中间多出来的 `1` 被悄悄丢掉
    //   UTCOffset 认这个偏移   —— 否则 `184207+1+080` 也能过
    // 三个证人各自只被其中一道拦住，缺一道就有一条能溜过去。
    // 为什么非要堵严：把源值截短**总是**让 carriesSameValue 更容易匹配上，
    // 所以这里每一个漏洞都朝着静默放过的方向。上一轮改成按键拆，解决的是
    // `2024-0915` 被砍成 `2024` 那一半；这是同一个失效族的另一半。
    guard chars.count == 7 || chars.count == 11 || chars.count == 12,
          chars[0..<6].allSatisfy(\.isNumber),
          chars[6] == "+" || chars[6] == "-" || chars[6] == "Z",
          let offset = UTCOffset(parsing: value) else { return (value, nil) }
    return (String(chars[0..<6]), offset)
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
    /// 三种形状都**锚定在末尾**、逐字符核对、再验范围；不是"取最后一个加减号、
    /// 把后面的数字滤出来数够 4 位"。上一版是后者，于是：
    ///   `2024-09-15T18`    → `-1518`   从日期里读出个时区
    ///   `184207 -0800mm`   → `-0800`   尾巴是垃圾也收
    ///   `+9999`            → `+9999`   越界不拦
    ///   `abc0Z`、`20240915Z` → `+0000`  Z 分支只查前一位是不是数字
    /// 这是**目标侧**的读取器：它一松，offsetSurvives 就会把"偏移其实已经丢了"
    /// 误判成"还在"，方向上正是静默放过。源侧的 splitIIMTime 用的是同一个
    /// 解析器，两侧不可能再一严一松——`±` 两种形状和 Z 分支分两轮才都锚住。
    init?(parsing value: String) {
        guard let text = UTCOffset.normalizedOffset(atEndOf: value) else { return nil }
        self.text = text
    }

    /// 在 `value` 的末尾找一个偏移并归一化。三种形状各自锚定在末尾，
    /// 候选 token 交给 normalizedOffset(token:precededBy:) 逐字符核对。
    private static func normalizedOffset(atEndOf value: String) -> String? {
        let chars = Array(value)
        // `…Z` 就是 UTC——但 Z 必须真的终结一个时刻，不能只查"前一位是数字"。
        // 只查前一位时，目标侧会把垃圾当 UTC 承载收下（实测）：
        //   `abc0Z`、`0Z`、`镜头型号RF50mm1Z`、`+08:00 (approx)5Z` 一律读成 +0000
        //   `184207+0800Z` 更糟：splitIIMTime 三道守卫全过，中间的 `+0800` 被丢掉，
        //   偏移还被**改读**成 +0000——丢还有机会被报出来，改读成一个合法值
        //   连差异都不剩。这是 Z 门上的同一个失效族，`±` 两种形状上一轮已堵。
        if chars.last == "Z" {
            return terminatesTime(Array(chars.dropLast())) ? "+0000" : nil
        }
        // `±HHMM`（宽 5）或 `±HH:MM`（宽 6）。
        for width in [5, 6] where chars.count >= width {
            let token = Array(chars[(chars.count - width)...])
            let previous = chars.count > width ? chars[chars.count - width - 1] : nil
            if let text = normalizedOffset(token: token, precededBy: previous) { return text }
        }
        return nil
    }

    /// `head` 后面紧跟的那个 `Z` 是不是时区标记（而不是碰巧落在文本末尾的字母 Z）。
    ///
    /// 整个值必须是下面两种形状之一——**两头都锚定**，不是"末尾像就算"：
    ///   `<时刻>Z`                 如 `184207Z`、`18:42Z`、`10:42:07Z`
    ///   `<日期><分隔><时刻>Z`      如 `2024-09-15T18:42:07Z`、`20240915T184207Z`
    /// 日期是 `YYYY-MM-DD` 或 `YYYYMMDD`，分隔是 `T` 或空格，时刻见 isTimeOfDay。
    ///
    /// 上一版只凑了两条形状、不验数值、前导只拒数字，于是**两个方向同时错**（实测）：
    ///   松：`995999Z`（59 分 99 秒）、`99:99:99Z`、`拍摄于 18:42:07Z` → 读成 `+0000`
    ///   严：`2024-09-15T18:42Z`（分钟精度）、`20240915T184207Z`（基本格式）、
    ///       `2024-09-15T18:42:07,42Z`（逗号小数秒）→ 全被误拒
    /// 松的那一半是静默放过，所以现在照 ISO 8601 对"时刻"的定义写，不再凑形状。
    ///
    /// 一个不可消除的歧义：`202409Z` 既像年月、也像 20:24:09，按形状分不开，
    /// 只能当时刻收下。前提是它必须是**整个值**——没有哪个元数据字段会把年月
    /// 单独写成 6 位再缀一个 Z。同理 4 位无分隔的 `hhmm` 不接受单独成值
    /// （`2024Z` 会被读成 20:24），只在日期后面出现时才算（`…T1842Z`）。
    private static func terminatesTime(_ value: [Character]) -> Bool {
        var head = value
        // 可选小数秒：ISO 8601 的小数点可以是 `.` 也可以是 `,`。
        if let point = head.lastIndex(where: { $0 == "." || $0 == "," }),
           point < head.count - 1, head[(point + 1)...].allSatisfy(\.isNumber) {
            head = Array(head[..<point])
        }
        for width in [8, 6, 5, 4] where head.count >= width {
            guard isTimeOfDay(Array(head[(head.count - width)...])) else { continue }
            // 整个值就是时刻。4 位无分隔的与年份无法区分，不收。
            if head.count == width { return width != 4 }
            let before = Array(head[..<(head.count - width)])
            guard let separator = before.last, separator == "T" || separator == " " else { continue }
            if isDate(Array(before.dropLast())) { return true }
        }
        return false
    }

    /// `hh:mm:ss`（宽 8）/ `hhmmss`（6）/ `hh:mm`（5）/ `hhmm`（4），并验数值范围。
    /// 宽度前提在本函数内成立：下面的下标都按 `t.count` 分支写死，
    /// 不依赖调用方那个 `for width in [8, 6, 5, 4]`。秒允许 60，那是闰秒。
    private static func isTimeOfDay(_ t: [Character]) -> Bool {
        let digits: [Character]
        switch t.count {
        case 8:
            guard t[2] == ":", t[5] == ":" else { return false }
            digits = [t[0], t[1], t[3], t[4], t[6], t[7]]
        case 6:
            digits = t
        case 5:
            guard t[2] == ":" else { return false }
            digits = [t[0], t[1], t[3], t[4]]
        case 4:
            digits = t
        default:
            return false
        }
        guard digits.allSatisfy(\.isNumber),
              let hours = Int(String(digits[0...1])), hours <= 23,
              let minutes = Int(String(digits[2...3])), minutes <= 59 else { return false }
        if digits.count == 4 { return true }
        guard let seconds = Int(String(digits[4...5])), seconds <= 60 else { return false }
        return true
    }

    /// `YYYY-MM-DD`（宽 10）或 `YYYYMMDD`（8），并验月日范围。
    /// 宽度前提同样在本函数内成立。不查某月到底有几天：这里只是在判断
    /// 「Z 前面那段是不是一个日期」，不是在校验日历。
    private static func isDate(_ d: [Character]) -> Bool {
        let digits: [Character]
        switch d.count {
        case 10:
            guard d[4] == "-", d[7] == "-" else { return false }
            digits = [d[0], d[1], d[2], d[3], d[5], d[6], d[8], d[9]]
        case 8:
            digits = d
        default:
            return false
        }
        guard digits.allSatisfy(\.isNumber),
              let month = Int(String(digits[4...5])), (1...12).contains(month),
              let day = Int(String(digits[6...7])), (1...31).contains(day) else { return false }
        return true
    }

    /// 核对一个候选 token（`±HHMM` 或 `±HH:MM`）并归一化成 `±HHMM`。
    ///
    /// `previous` 是它前面那个字符：要么是时间戳的秒（数字），要么不存在
    /// （整个值就是一个偏移字段）。不查这一条，`abc+0800` 也会算数。
    private static func normalizedOffset(token: [Character],
                                         precededBy previous: Character?) -> String? {
        // 形状只有 `±HHMM`（宽 5）和 `±HH:MM`（宽 6）两种。下面的下标是照着
        // 宽度写死的（else 分支直接取 token[3...5]），所以这一条必须在本函数
        // 里成立，不能寄托在唯一调用方的 `for width in [5, 6]` 上——同一轮里
        // splitIIMTime 恰恰为这个失效形状补了长度检查，这里却留成了隐含前提。
        guard token.count == 5 || token.count == 6 else { return nil }
        guard token[0] == "+" || token[0] == "-" else { return nil }
        if let previous, !previous.isNumber { return nil }
        let digits: [Character]
        if token.count == 5 {
            guard token[1...].allSatisfy(\.isNumber) else { return nil }
            digits = Array(token[1...])
        } else {
            guard token[3] == ":", token[1].isNumber, token[2].isNumber,
                  token[4].isNumber, token[5].isNumber else { return nil }
            digits = [token[1], token[2], token[4], token[5]]
        }
        // ISO 8601 的偏移范围是 -12:00…+14:00（README「--verify」一节同此），
        // 分钟 < 60。约束的是**总偏移量**，不是时和分各自的上限：
        //   - 要求分钟为 0 会拒掉真实存在的 +05:30、+05:45、+09:30、+13:45；
        //   - 时和分各自设上限（hours <= 14 && minutes <= 59）会放过 +14:30、
        //     +14:59、-12:30、-12:59 这些不存在的偏移。
        // 前两版分别踩了"不分符号"和"分符号但按分量"，都是后一种失效：
        // 目标侧读取器一宽松，offsetSurvives 就把真丢失误判成"还在"。
        guard let hours = Int(String(digits[0...1])),
              let minutes = Int(String(digits[2...3])), minutes <= 59 else { return nil }
        let total = (token[0] == "-" ? -1 : 1) * (hours * 60 + minutes)
        guard total >= -12 * 60, total <= 14 * 60 else { return nil }
        return "\(token[0])\(String(digits))"
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
/// 这四组都是日期/时间，只是格式不同：IIM 写 `20240915` 和 `184207`，
/// EXIF 写 `2024:09:15 18:42:07`，XMP 写 `2024-09-15T18:42:07.42`。
/// 两边都只留数字再看包含关系，就能跨格式比较。
///
/// 这不是严格的语义比较——纯数字的巧合匹配理论上存在。但它能拦住
/// "等价字段在、值却是另一个时间" 这种真丢失，而只判断键存在完全拦不住。
/// 宁可偶尔多报一条，也不要静默放过。
///
/// 比较方向是单向的（源值出现在等价值里），因为等价字段总比 IIM 更长：
/// IIM 只写日期或只写时间，EXIF/XMP 两样都写。反过来包含没有意义。
func carriesSameValue(_ sourceValue: String, _ equivalentValue: String) -> Bool {
    let source = sourceValue.filter(\.isNumber)
    let equivalent = equivalentValue.filter(\.isNumber)
    guard !source.isEmpty, !equivalent.isEmpty else { return false }
    return equivalent.contains(source)
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

/// 把 XMP 数据包里的所有标签（含嵌套结构与数组）展开成 "路径 = 值"。
func xmpTags(_ md: CGImageMetadata) -> [String: String] {
    final class Box { var dict: [String: String] = [:] }
    let box = Box()
    let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
    CGImageMetadataEnumerateTagsUsingBlock(md, nil, options) { path, tag in
        if let value = CGImageMetadataTagCopyValue(tag) as? String {
            box.dict[xmpKey(path as String)] = trimPadding(value)
        } else if let value = CGImageMetadataTagCopyValue(tag) as? NSNumber {
            box.dict[xmpKey(path as String)] = value.stringValue
        }
        return true
    }
    return box.dict
}

/// 一个文件的全部元数据键空间，摊平成「键路径 → 值」。
///
/// 两层缺一不可：属性字典（含 UserComment 的修补）和 XMP 包。只摊平前者会让
/// 所有 `XMP/...` 键静默缺席——不是"查不到"，是"无条件查不到"。
///
/// `repairing: false` 只关掉 UserComment 那一处修补，XMP 层照旧——给
/// Tests/probe 的 `--no-repair` 用，那一轮的前提恰恰是"ImageIO 自己读不出来"。
/// 做成参数而不是让调用方自己拼一份：自己拼就会再次漏掉某一层，而漏掉是静默的。
/// 抽成函数是因为 Tests/probe 原先自己拼了一份、只摊平了属性字典，于是它对
/// 每个 XMP 键都答「无」，而它的文件头偏偏写着"要和校验本身理解一致"。
/// 任何拿 probe 写的 XMP 断言都会恒真，没人会发现。
func metadataKeySpace(of image: CGImageSource, url: URL,
                      repairing: Bool = true) -> [String: String] {
    var flat: [String: String] = [:]
    flatten(repairing ? repairedProperties(image, url: url) : imageProperties(image), into: &flat)
    if let m = CGImageSourceCopyMetadataAtIndex(image, 0, nil) {
        flat.merge(xmpTags(m)) { a, _ in a }
    }
    return flat
}

/// 比对源与目标的元数据，返回丢失/变化的条目描述。
func metadataDiff(source: URL, dest: URL) -> [String] {
    guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
          let destImage = CGImageSourceCreateWithURL(dest as CFURL, nil) else {
        return ["无法重新打开文件进行校验"]
    }

    let before = metadataKeySpace(of: sourceImage, url: source)
    let after = metadataKeySpace(of: destImage, url: dest)

    var issues: [String] = []
    var makerNoteLost: [String: Int] = [:]   // 伪字典名 → 丢失条目数

    for (k, v) in before.sorted(by: { $0.key < $1.key }) where !isVolatile(k) {
        if after[k] == nil {
            if equivalentCarries(key: k, value: v, in: after) { continue }
            if let group = makerNoteGroup(of: k) {
                makerNoteLost[group, default: 0] += 1
                continue
            }
            issues.append("丢失 \(k) = \(truncate(v))")
        } else if !valuesMatch(v, after[k]!) {
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
