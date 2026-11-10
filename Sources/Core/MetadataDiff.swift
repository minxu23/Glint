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
    // 不带偏移的裸 `HHMMSS` 不用单独处理：它的长度 6 本来就不在下面那组
    // 合法总长里，会和其他不该拆的值落到同一个返回点。这里曾经有一条
    // 「count == 6 且全是数字就原样返回」的快路径，实测去掉前后对任意
    // 6 字符输入的结果完全一致——纯冗余，删了。
    //
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
          numericFields(Array(chars[0..<6]), "dddddd") != nil,
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
/// 按模板从 `value` 里切出各字段的数值。模板里连续的 `d` 是一个字段（每个 `d`
/// 一位数字），`d*` 是「一位以上数字，长度不限」，`|` 表示两个字段紧挨着、
/// 中间没有分隔符，其余字符必须在同一位置原样出现。长度不符、分隔符不对、
/// 出现非 ASCII 数字（全角数字、其他数系），一律 nil。
///
/// 那个 `isASCII` 是冗余的，留着是为了读代码时意图自明：实测 `Int(String)`
/// 本身就拒掉 `１２`、`٣٤`、`३४` 等所有非 ASCII 数字写法，所以去掉它不改变
/// 任何输入的结果——也就不可能有用例钉住它。不想依赖 `Int.init?` 的这个性质，
/// 才把条件写在取字符的地方。
///
/// 抽出来是因为时刻、日期、偏移、IIM 时间四处形状解析本来各写了一遍
/// 「switch count → 查分隔符位 → 攒 digits → Int(String(...)) 验范围」，
/// 连「宽度前提在本函数内成立」那句注释都重复了三遍。现在只有这里需要那句话：
/// 下面所有下标都由 template 与 value 的长度在本函数内对齐。
func numericFields(_ value: [Character], _ template: String) -> [Int]? {
    let symbols = Array(template)
    var fields: [Int] = []
    var digits = ""
    var i = 0, k = 0

    // 把攒着的数字收成一个字段；没攒到就什么也不做。
    func close() -> Bool {
        if digits.isEmpty { return true }
        guard let n = Int(digits) else { return false }
        fields.append(n)
        digits = ""
        return true
    }

    while k < symbols.count {
        let symbol = symbols[k]
        k += 1
        switch symbol {
        case "d" where k < symbols.count && symbols[k] == "*":
            k += 1
            while i < value.count, value[i].isASCII, value[i].isNumber {
                digits.append(value[i])
                i += 1
            }
            guard !digits.isEmpty, close() else { return nil }
        case "d":
            guard i < value.count, value[i].isASCII, value[i].isNumber else { return nil }
            digits.append(value[i])
            i += 1
        case "|":
            guard !digits.isEmpty, close() else { return nil }
        default:
            guard i < value.count, value[i] == symbol, close() else { return nil }
            i += 1
        }
    }
    // 整个 value 必须被模板用尽：末尾多一个字符也不算匹配。
    guard i == value.count, close() else { return nil }
    return fields
}

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

    /// 在 `value` 的末尾找一个偏移并归一化。
    ///
    /// 三种形状共用**同一把尺子**：`Z` 和 `±` 的"前文"都必须是空（整个值就是
    /// 一个偏移字段，如 `+08:00`）或一个完整时刻（isTimestamp）。
    /// 这一条是第四轮才对称的——前三轮每次都只收紧一侧：
    ///   `±` 侧曾只查"符号前一位是数字"，于是 Z 侧明确拒掉的东西它全收（实测）：
    ///     `镜头型号RF50mm1+0800`、`ISO100+0800`、`abc1+0800`、
    ///     `+08:00 (approx)5+0800`、`9999-99-99T18:42:07+08:00`、`20240915+0800`
    ///   这是**目标侧**读取器，一松 offsetSurvives 就把"偏移其实已经丢了"
    ///   读成"还在"——读出一个合法值比读不出更坏，因为连差异都不剩。
    private static func normalizedOffset(atEndOf value: String) -> String? {
        let chars = Array(value)
        if chars.last == "Z" {
            // Z 本身不带数值，所以它要求前文必须是时刻（空值 `Z` 不算 UTC）。
            return isTimestamp(Array(chars.dropLast())) ? "+0000" : nil
        }
        // `±HHMM`（宽 5）或 `±HH:MM`（宽 6）。
        for width in [5, 6] where chars.count >= width {
            let head = Array(chars[..<(chars.count - width)])
            guard head.isEmpty || isTimestamp(head) else { continue }
            if let text = normalizedOffset(Array(chars[(chars.count - width)...])) { return text }
        }
        return nil
    }

    /// 整个 `value` 是不是一个完整的时刻。两头都锚定，不是"末尾像就算"：
    ///   `<时刻>`                 如 `184207`、`18:42`、`10:42:07`
    ///   `<日期><分隔><时刻>`      如 `2024-09-15T18:42:07`、`20240915T184207`
    /// 日期是 `YYYY-MM-DD` 或 `YYYYMMDD`，分隔是 `T` 或空格，时刻见 isTimeOfDay。
    ///
    /// 只凑形状、不验数值、前导只拒数字的那一版**两个方向同时错**（实测）：
    ///   松：`995999`（59 分 99 秒）、`99:99:99`、`拍摄于 18:42:07` 都算时刻
    ///   严：`2024-09-15T18:42`（分钟精度）、`20240915T184207`（基本格式）、
    ///       `2024-09-15T18:42:07,42`（逗号小数秒）全被误拒
    /// 松的那一半是静默放过，所以现在照 ISO 8601 对"时刻"的定义写。
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
           numericFields(Array(head[(point + 1)...]), "d*") != nil {
            head = Array(head[..<point])
        }
        for (width, template) in [(8, "dd:dd:dd"), (6, "dd|dd|dd"), (5, "dd:dd"), (4, "dd|dd")]
        where head.count >= width {
            guard isTimeOfDay(Array(head[(head.count - width)...]), template) else { continue }
            // 整个值就是时刻。4 位无分隔的与年份无法区分，不收。
            if head.count == width { return width != 4 }
            let before = Array(head[..<(head.count - width)])
            guard let separator = before.last, separator == "T" || separator == " " else { continue }
            if isDate(Array(before.dropLast())) { return true }
        }
        return false
    }

    /// 按模板核对一个时刻并验范围。秒允许 60，那是闰秒。
    private static func isTimeOfDay(_ value: [Character], _ template: String) -> Bool {
        guard let parts = numericFields(value, template), parts.count >= 2,
              parts[0] <= 23, parts[1] <= 59 else { return false }
        return parts.count == 2 || parts[2] <= 60
    }

    /// `YYYY-MM-DD` 或 `YYYYMMDD`，并验月日范围。不查某月到底有几天：
    /// 这里只是在判断「这段是不是一个日期」，不是在校验日历。
    private static func isDate(_ value: [Character]) -> Bool {
        for template in ["dddd-dd-dd", "dddd|dd|dd"] {
            guard let parts = numericFields(value, template), parts.count == 3 else { continue }
            if (1...12).contains(parts[1]), (1...31).contains(parts[2]) { return true }
        }
        return false
    }

    /// 核对一个候选 token（`±HHMM` 或 `±HH:MM`）并归一化成 `±HHMM`。
    private static func normalizedOffset(_ token: [Character]) -> String? {
        guard let sign = token.first, sign == "+" || sign == "-" else { return nil }
        let body = Array(token.dropFirst())
        // 宽度前提在本函数内成立，不寄托于调用方的 `for width in [5, 6]`。
        let template: String
        switch body.count {
        case 4: template = "dd|dd"
        case 5: template = "dd:dd"
        default: return nil
        }
        // ISO 8601 的偏移范围是 -12:00…+14:00（README「--verify」一节同此），
        // 分钟 < 60。约束的是**总偏移量**，不是时和分各自的上限：
        //   - 要求分钟为 0 会拒掉真实存在的 +05:30、+05:45、+09:30、+13:45；
        //   - 时和分各自设上限（hours <= 14 && minutes <= 59）会放过 +14:30、
        //     +14:59、-12:30、-12:59 这些不存在的偏移。
        // 前两版分别踩了"不分符号"和"分符号但按分量"，都是后一种失效：
        // 目标侧读取器一宽松，offsetSurvives 就把真丢失误判成"还在"。
        guard let parts = numericFields(body, template), parts.count == 2,
              parts[1] <= 59 else { return nil }
        let total = (sign == "-" ? -1 : 1) * (parts[0] * 60 + parts[1])
        guard total >= -12 * 60, total <= 14 * 60 else { return nil }
        return "\(sign)\(twoDigits(parts[0]))\(twoDigits(parts[1]))"
    }

    private static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
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
