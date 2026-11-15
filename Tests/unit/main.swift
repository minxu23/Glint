// 纯逻辑单元测试：校验器判定两个元数据值"是否算变化"的规则。
// 这块规则很容易在两个方向上出错——太严就刷出一堆假差异，太松就把真的丢失藏起来，
// 所以正反两类用例都要有。

@testable import Eclose
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 下面这些 expectXxx 都是同一个形状：喂一组输入给某条判定规则，比对结果。
// 打印与失败计数一律交给 harness 的 checkRule：自己写 print + failedChecks
// 的话，漏掉一处 failedChecks 就会让失败悄悄变成通过。
/// 这个扩展名在 UTType 里是不是相机 RAW。
func utTypeIsRAW(_ ext: String) -> Bool {
    UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false
}

func expect(_ a: String, _ b: String, same expected: Bool, _ why: String) {
    checkRule("\(a) vs \(b)", valuesMatch(a, b), expected, why)
}

print("flatten：两种键类型都要能下钻")
// flatten 只有一条字典分支：String 键会桥接成 CFString，被同一个 as? 接走。
// 这组用例守的正是这件事——桥接哪天不管用了，下面「String 键」那条会红。
// 也守着 flatten 整个别哑掉：它一哑，元数据集合会整块变空，而「校验无差异」
// 照样通过——比较的两边一起空了，差异自然是零。
func flattened(_ value: Any) -> [String: String] {
    var out: [String: String] = [:]
    flatten(value, into: &out)
    return out
}
let cfKeyed = flattened([kCGImagePropertyExifDictionary:
                         [kCGImagePropertyExifUserComment: "备注\0\0"]] as [CFString: Any])
check("CFString 键的字典下钻到叶子", cfKeyed["{Exif}/UserComment"], "备注")
check("不多出别的键", cfKeyed.count, 1)
let nsKeyed = flattened(NSDictionary(dictionary: ["XMP": ["dc:title": "标题"]]) as! [String: Any])
check("String 键的字典下钻到叶子", nsKeyed["XMP/dc:title"], "标题")
check("数组带上下标", flattened(["{GPS}": ["Latitude": [1, 2]]])["{GPS}/Latitude[1]"], "2")

print("数值比较：应当忽略的重编码噪声")
// 佳能 R5 Mark II 的真实数据：ImageIO 写入时把有理数逼近成了另一个分母。
expect("8192000/1419", "3769821/653", same: true, "R5 II 的 FocalPlaneXResolution 重新逼近")
expect("5464000/947", "1811717/314", same: true, "R5 II 的 FocalPlaneYResolution 重新逼近")
expect("5773.079633544749", "5773.079632465544", same: true, "同一个值的浮点表示")
expect("-15/10", "-3/2", same: true, "同值不同约分程度")
expect("0", "0.0", same: true, "整数与小数写法")
expect("1/25", "0.04", same: true, "分数与小数写法")

print("数值比较：必须报出来的真实变化")
expect("400", "401", same: false, "ISO 变了")
expect("1/25", "1/26", same: false, "快门速度变了")
expect("50.879288", "50.879289", same: false, "GPS 纬度差约 10 厘米也要报")
expect("5773.08", "5774.08", same: false, "焦平面分辨率真的变了")

print("非数值一律逐字符比较")
expect("N", "N", same: true, "相同的方位标识")
expect("N", "S", same: false, "方位标识变了")
expect("2024:09:15 18:42:07", "2024:09:15 18:42:07", same: true, "相同的拍摄时间")
expect("2024:09:15 18:42:07", "2024:09:15 18:42:08", same: false, "拍摄时间差一秒")
expect("Canon EOS R5m2", "Canon EOS R5", same: false, "机型变了")

print("尾部填充不算差异")
expect(trimPadding("备注\0\0\0"), trimPadding("备注\0\0\0\0\0"), same: true, "NUL 填充长度不同")
expect(trimPadding("备注   "), trimPadding("备注"), same: true, "尾部空格")

print("等价字段必须真的带着同一个值")
// 只判断"等价键存在"的话，源里 {IPTC}/DateCreated 丢了、目标有个写着另一个
// 年份的 DateTimeOriginal 也会被放过。这组用例守的就是"值也得对上"。
func expectCarried(_ source: String, _ equivalent: String, _ want: Bool, _ why: String) {
    checkRule("\(source) vs \(equivalent)", carriesSameValue(source, equivalent), want, why)
}
expectCarried("20240915", "2024:09:15 18:42:07", true, "IIM 日期被 EXIF 时间戳承载")
expectCarried("184207", "2024:09:15 18:42:07", true, "IIM 时间被 EXIF 时间戳承载")
expectCarried("20240915", "2024-09-15T18:42:07.42", true, "跨到 XMP 的格式也认")
expectCarried("20240915", "2020-01-01T00:00:00", false, "等价字段存在但是另一个年份——必须报")
expectCarried("184207", "2024:09:15 09:00:00", false, "日期对但时间不对——必须报")
expectCarried("", "2024:09:15 18:42:07", false, "源值没有数字")
expectCarried("20240915", "", false, "等价字段是空的")
expectCarried("20240915", "<无>", false, "等价字段没有数字")
// 按位置比：日期只和日期位比、时间只和时刻位比，只认 ASCII 数字。
expectCarried("091518", "2024:09:15 18:42:07", false, "跨日期和时间凑出来的数字串不算")
expectCarried("074208", "2024-09-15T18:42:07.42+08:00", false, "靠小数秒和偏移的数字凑出来的不算")
expectCarried("٢٣", "x٢٣", false, "非 ASCII 数字不算数字")
expectCarried("184207", "2024-09-15T18:42:07+08:00", true, "带偏移的 XMP 时间戳，时刻位照样比得上")

print("带时区的 IIM 时间：偏移本身也得在目标里找得到")
// IIM 的 TimeCreated 可以带 UTC 偏移（HHMMSS±HHMM）。只把偏移剥掉再比时间，
// 会在「偏移只存在于 IIM 后缀、目标又没有 OffsetTime」时把真丢失吞掉——
// README 里「时区由 OffsetTime 单独承载」是对目标文件的断言，必须真查。
let shotAt = "{Exif}/DateTimeOriginal"
let offsetAt = "{Exif}/OffsetTimeOriginal"
func expectEquivalent(_ key: String, _ value: String,
                      _ after: [String: String], _ want: Bool, _ why: String) {
    checkRule("\(key) = \(value)", equivalentCarries(key: key, value: value, in: after), want, why)
}
let timeKey = "{IPTC}/TimeCreated"
let dateKey = "{IPTC}/DateCreated"
let withOffset = [shotAt: "2024:09:15 18:42:07", offsetAt: "+08:00"]
let noOffset = [shotAt: "2024:09:15 18:42:07"]

expectEquivalent(timeKey, "184207+0800", withOffset, true, "时间与偏移目标都有，才算承载")
expectEquivalent(timeKey, "184207+0800", noOffset, false,
                 "目标没有 OffsetTime，偏移是真丢了——必须报")
expectEquivalent(timeKey, "184207+0800", [shotAt: "2024:09:15 18:42:07", offsetAt: "+09:00"],
                 false, "目标的偏移是另一个值——必须报")
expectEquivalent(timeKey, "184207Z", [shotAt: "2024:09:15 18:42:07", offsetAt: "+00:00"],
                 true, "Z 等于 +0000")
expectEquivalent(timeKey, "184207", noOffset, true, "不带偏移的时间，目标有时间就够了")
// XMP 这条承载腿有一半是端到端可达的，这里只是把两半都钉住。
//   时间那一半：ImageIO 只要看见 IIM 日期，写 JPEG 时就会自己补一个
//     {Exif}/DateTimeOriginal（实测过），于是 EXIF 腿永远在场，XMP 腿
//     在"谁承载了时间"上确实抢不到决定权，只能在这里单独验。
//   偏移那一半：ImageIO 同时还会合成
//     XMP/photoshop:DateCreated = 2024-09-15T18:42:07.42+08:00（带偏移），
//     而 OffsetTime* 它不会自己补。所以源里不写 EXIF OffsetTime* 时，
//     XMP 就是目标里唯一的偏移承载——selftest.sh 的「偏移只靠 XMP 承载」
//     一轮走的正是这条路（夹具的 --no-exif-offset）。
// 键的拼法已对着两张真实的相机照片（佳能、松下）核过：ImageIO 输出里
// 确实是 `XMP/photoshop:DateCreated` 与 `XMP/xmp:CreateDate`（形如
// `2011-01-19T22:01:00.00`），转成 HEIC 后两者都还在。
expectEquivalent(timeKey, "184207+0800", ["XMP/photoshop:DateCreated": "2024-09-15T18:42:07+08:00"],
                 true, "偏移长在 XMP 时间戳里也算承载")
expectEquivalent(dateKey, "20240915", ["XMP/photoshop:DateCreated": "2024-09-15T18:42:07.00"],
                 true, "IIM 日期由 XMP 腿承载（真实照片里就是这个形状）")
expectEquivalent("{IPTC}/DigitalCreationDate", "20240915", ["XMP/xmp:CreateDate": "2024-09-15T18:42:07"],
                 true, "数字化日期走 xmp:CreateDate 这条腿")
expectEquivalent(timeKey, "184207+0800", [shotAt: "2024:09:15 09:00:00"], false,
                 "时间本身就不对，偏移再对也是丢失")
expectEquivalent(timeKey, "184207-12345", withOffset, false,
                 "尾巴不是合规偏移就不拆，整串拿去比，对不上就报")
// 只在该带偏移的字段里找，不扫全表：扫全表撞上一个巧合的 +0800
// （这里是镜头型号）就会把真丢失吞掉，方向错反。
expectEquivalent(timeKey, "184207+0800",
                 [shotAt: "2024:09:15 18:42:07", "{ExifAux}/LensModel": "RF24-70 +0800"],
                 false, "无关字段里巧合出现的偏移不算承载")
// Date 键根本不进拆分——按长相拆会把 2024-0915 砍成 2024，
// 而 2024 几乎出现在任何日期里，于是「9 月 15 日丢了」会被静默放过。
expectEquivalent(dateKey, "20240915", noOffset, true, "IIM 日期被 EXIF 时间戳承载")
expectEquivalent(dateKey, "2024-0915", [shotAt: "2024:01:01 00:00:00"], false,
                 "不合规范的日期不按长相去砍，整串拿去比")
expectEquivalent("{Exif}/DateTimeOriginal", "2024:09:15 18:42:07", noOffset, false,
                 "不在等价表里的键一律不算承载")

print("UTCOffset：形状锚定在末尾，再验范围")
// 形状锚定在末尾、逐字符核对：不能从日期里读出时区，尾巴带垃圾、越界、
// 随便什么以 Z 结尾的文本都不算。它是**目标侧**的读取器，松了就是静默放过。
for (text, want) in [// 该认出来的
                     ("+08:00", "+0800"), ("+0800", "+0800"), ("-05:00", "-0500"),
                     ("2024-09-15T18:42:07+08:00", "+0800"),
                     ("2024-09-15T18:42:07-0800", "-0800"),
                     // `…Z`：整个值必须是 <时刻> 或 <日期><分隔><时刻>，两头都锚定。
                     // 下面这些是真实写入器会产出的形状，一条都不能误拒。
                     ("184207Z", "+0000"),                    // IIM 的 HHMMSS
                     ("18:42Z", "+0000"),                     // 分钟精度
                     ("10:42:07Z", "+0000"),                  // 整个值就是时刻
                     ("2024-09-15T18:42:07Z", "+0000"),       // ISO 8601 扩展格式
                     ("2024-09-15T18:42Z", "+0000"),          // 扩展格式、分钟精度
                     ("20240915T184207Z", "+0000"),           // ISO 8601 基本格式
                     ("20240915T1842Z", "+0000"),             // 基本格式、分钟精度
                     ("2024-09-15T18:42:07.42Z", "+0000"),    // 小数秒（ImageIO 就写这个）
                     ("2024-09-15T18:42:07,42Z", "+0000"),    // 逗号小数点，ISO 也合法
                     ("2024-09-15 18:42:07Z", "+0000"),       // 空格代替 T
                     // EXIF 自己的日期是冒号分隔的，而 README 把
                     // {Exif}/DateTimeOriginal 点名为等价承载键之一。
                     // EXIF 的日期不属于 ISO 8601，按 ISO 8601 列形状会漏掉它。
                     ("2024:09:15 18:42:07Z", "+0000"),
                     ("2024:09:15 18:42:07.42Z", "+0000"),
                     ("23:59:60Z", "+0000"),                  // 闰秒
                     // 边界本身合法
                     ("+14:00", "+1400"), ("-12:00", "-1200"),
                     // 真实存在的非零分钟，必须继续认
                     ("+05:30", "+0530"), ("+0545", "+0545"),
                     ("+09:30", "+0930"), ("+13:45", "+1345"),
                     // 上下界不对称：负向最多 -12:00，正向最多 +14:00。
                     ("-13:00", ""), ("-1400", ""), ("+1500", ""),
                     // 约束的是总偏移量，不是时和分各自的上限（时 <= 14、分 <= 59）：
                     // 越过边界一点的偏移也要拒。
                     ("+1430", ""), ("+14:59", ""), ("-1230", ""), ("-12:59", ""),
                     // 分钟本身仍要 < 60：+00:70 折算后落在范围内，
                     // 但它不是一个合规的偏移拼法。
                     ("+0070", ""),
                     // 本来就没有时区
                     ("2024-09-15T18:42:07", ""), ("2024-09-15", ""),
                     ("2024:09:15 18:42:07", ""),
                     ("2024-09-15T18:42:07.4200", ""),
                     // 宽松的读法会把下面几条读出偏移
                     ("2024-09-15T18", ""),      // 日期里的减号不是偏移
                     ("184207 -0800mm", ""),     // 垃圾尾巴
                     ("+9999", ""),              // 越界
                     ("随便什么Z", ""),
                     // 只查「Z 前一位是数字」会把下面这些读成 +0000：
                     // Z 前面必须是一个完整时刻。
                     ("abc0Z", ""),
                     ("0Z", ""),
                     ("未知9Z", ""),
                     ("镜头型号RF50mm1Z", ""),     // 镜头型号被读成 UTC
                     ("+08:00 (approx)5Z", ""),   // 给畸形偏移补个 5Z 就被收
                     ("1234518:42:07Z", ""),      // 时刻前面是数字，是拼接不是时刻
                     // 时刻必须是整个值，不能只看末尾几位数字：
                     ("20240915Z", ""),           // 这是个日期，不是时刻
                     ("99184207Z", ""),           // 末六位恰好像时刻，整体不是
                     ("2024Z", ""),               // 4 位无分隔与年份分不开，不收
                     // 数值范围：时、分、秒各有一条只越界一个分量的证人。
                     // 只放 `995999Z` 不够——它的秒也越界，时和分的上限就没人守。
                     ("240000Z", ""),             // 24 时，只有「时」越界
                     ("186000Z", ""),             // 60 分，只有「分」越界
                     ("184299Z", ""),             // 99 秒，只有「秒」越界
                     ("24:00:00Z", ""),           // 带冒号的同一组
                     ("18:60Z", ""),              // 分钟精度也要验
                     ("995999Z", ""),             // 多个分量同时越界
                     ("99:99:99Z", ""),
                     ("拍摄于 18:42:07Z", ""),     // 空格前面不是日期，是散文
                     ("9999-99-99T18:42:07Z", ""),// 时刻合法但日期不是日期
                     // 偏移的前文必须是空或一个完整时刻——和 Z 侧同一把尺子。
                     // 下面每一条都和 Z 侧的孪生反例一一对应。
                     ("abc+0800", ""),            // 符号前一位不是数字
                     ("abc1+0800", ""),           // 符号前一位是数字，前文仍不是时刻
                     ("镜头型号RF50mm1+0800", ""),
                     ("ISO100+0800", ""),
                     ("+08:00 (approx)5+0800", ""),
                     ("9999-99-99T18:42:07+08:00", ""),   // 时刻合法、日期不是日期
                     ("20240915+0800", ""),       // 日期不是时刻
                     ("2024-0915+0800", ""),
                     ("拍摄于 18:42:07+08:00", ""), // 空格前面是散文不是日期
                     ("995999+0800", ""),         // 前文的"时刻"越界
                     ("2024+0800", ""),           // 4 位无分隔不单独成时刻
                     ("+999-09-15T18:42:07+08:00", ""),   // `Int("+999")` 是 999，
                     // 所以字段里的前导符号必须由 isAllDigits 拦，否则这个值
                     // 会读出 `+0800`——目标侧一松就是静默放过。
                     // 真实写法必须继续认：
                     ("184207+08:00", "+0800"),
                     ("2024-09-15T18:42:07.42+08:00", "+0800"),   // ImageIO 实际写的
                     ("2024-09-15T18:42+08:00", "+0800"),         // 分钟精度
                     ("20240915T184207+0800", "+0800"),           // 基本格式
                     ("2024:09:15 18:42:07+08:00", "+0800"),      // EXIF 的冒号日期
                     ("2024:09:15 18:42:07-0800", "-0800"),
                     // 闰秒：± 侧和 Z 侧一样认
                     ("23:59:60+08:00", "+0800"),
                     ("235960+0800", "+0800"),
                     ("2024-09-15T23:59:60+08:00", "+0800"),
                     // 冒号日期同样要验月日范围
                     ("9999:99:99 18:42:07+08:00", ""),
                     // 裸 Z 不算（前面没有时刻）
                     ("Z", "")] {
    checkRule(text, UTCOffset(parsing: text)?.text ?? "", want,
              want.isEmpty ? "\(text) 里没有时区" : "\(text) → \(want)")
}

print("目标侧读松了就会静默放过：拿畸形值当承载")
// 源里偏移确实丢了，但目标某个字段里有一段能被宽松读法读成同一个偏移的垃圾：
// 读取器一松，整条差异就被吞掉。
expectEquivalent(timeKey, "184207+0800",
                 [shotAt: "2024:09:15 18:42:07", offsetAt: "+08:00 (approx)"],
                 false, "目标的偏移字段带垃圾尾巴，不算承载")
expectEquivalent(timeKey, "184207Z",
                 [shotAt: "2024:09:15 18:42:07", offsetAt: "未知Z"],
                 false, "目标写着「未知Z」不算 UTC")
expectEquivalent(timeKey, "184207Z",
                 [shotAt: "2024:09:15 18:42:07", offsetAt: "未知9Z"],
                 false, "结尾是「数字+Z」也不算 UTC——Z 必须终结一个时刻")

print("numericFields：各处形状解析共用的那把尺子")
// 时刻、日期、偏移的形状解析共用它。它是单点故障，所以直接钉住，
// 而不只是透过上面那些间接验。
// 用生产代码里那套命名常量，不另起一套：这样用例同时也钉住了常量本身——
// 把 ymdDash 的分隔符改掉，下面「带连字符的日期」就会红。
let hhmmssColon = DigitShape.hhmmssColon
let hhmmss = DigitShape.hhmmss
let ymdDash = DigitShape.ymdDash
let ymdPlain = DigitShape.ymdPlain
let ymdColon = DigitShape.ymdColon
let hhmm = DigitShape.hhmm

// length 是切片位置的来源，错一位整个锚定就偏了。
checkRule("hhmmssColon.length", hhmmssColon.length, 8, "三个两位字段加两个分隔符")
checkRule("hhmmss.length", hhmmss.length, 6, "无分隔符就不加")
checkRule("ymdDash.length", ymdDash.length, 10, "4+2+2 加两个分隔符")

func expectFields(_ value: String, _ shape: DigitShape, _ want: [Int]?, _ why: String) {
    let got = numericFields(Array(value), shape)
    checkRule("\(value) / \(shape.widths)\(shape.separator.map { "\($0)" } ?? "")",
              got?.description ?? "nil", want?.description ?? "nil", why)
}
expectFields("18:42:07", hhmmssColon, [18, 42, 7], "带冒号的时刻")
expectFields("184207", hhmmss, [18, 42, 7], "无分隔的时刻")
expectFields("2024-09-15", ymdDash, [2024, 9, 15], "带连字符的日期")
expectFields("20240915", ymdPlain, [2024, 9, 15], "无分隔的日期")
expectFields("2024:09:15", ymdColon, [2024, 9, 15], "EXIF 的冒号日期")
expectFields("0800", hhmm, [8, 0], "偏移的四位（前导零归一化成数值）")
// 必须拒的：
expectFields("18:42:0", hhmmssColon, nil, "短一位")
expectFields("18:42:077", hhmmssColon, nil, "长一位——末尾多出的字符不能被忽略")
expectFields("18-42-07", hhmmssColon, nil, "分隔符不对")
expectFields("184207", hhmmssColon, nil, "该有分隔符却没有")
expectFields("18:42:07", hhmmss, nil, "不该有分隔符却有")
expectFields("+999-09-15", ymdDash, nil, "字段里不能有前导符号——Int 认 +999，isAllDigits 不认")
// 这一条钉的是"全角数字不算数字"：numericFields 用 isAllDigits 判数字。
expectFields("1８4207", hhmmss, nil, "全角数字不算数字")

print("isAllDigits：数字字段与小数秒的 ASCII 数字判定")
func expectAllDigits(_ value: String, _ want: Bool, _ why: String) {
    checkRule(value, isAllDigits(Array(value)), want, why)
}
expectAllDigits("184207", true, "六位数字")
expectAllDigits("42", true, "小数秒")
expectAllDigits("", false, "空串不算")
expectAllDigits("abc", false, "不是数字")
expectAllDigits("1８4207", false, "全角数字不算——这里没有 Int 兜着，isASCII 是真守卫")
expectAllDigits("18:42", false, "带分隔符不算")

print("源侧与目标侧用同一把尺子")
for (text, time, offset) in [("184207+0800", "184207", "+0800"),
                             ("184207Z", "184207", "+0000"),
                             ("184207+08:00", "184207", "+0800"),
                             // 越界、垃圾尾巴一律不拆：整串拿去比，对不上就报
                             ("184207+9999", "184207+9999", ""),
                             ("184207-12345", "184207-12345", ""),
                             // 只被「第 7 个字符」那一道拦住：UTCOffset 认得
                             // `184207.555Z`（带小数秒的时刻 + Z），不拦就拆成
                             // (184207, +0000)，小数秒被悄悄丢掉。
                             ("184207.555Z", "184207.555Z", ""),
                             ("184207,555Z", "184207,555Z", ""),
                             // UTCOffset 解析不出偏移，不拆。
                             ("184207+12+0800", "184207+12+0800", ""),
                             ("1842071+0800", "1842071+0800", ""),
                             ("184207+1+080", "184207+1+080", ""),
                             // 走 Z 门的同族：第 7 个字符是 `+`，UTCOffset 的 Z 分支
                             // 一松就会认，`+0800` 被丢掉且偏移被**改读**成 +0000
                             // ——改读成合法值连差异都不剩。
                             ("184207+0800Z", "184207+0800Z", ""),
                             // 回归样本。
                             ("184207123+0800", "184207123+0800", ""),
                             ("1842071Z", "1842071Z", ""),
                             ("184207", "184207", "")] {
    let parts = splitIIMTime(text)
    checkRule(text, "\(parts.time)|\(parts.offset?.text ?? "")", "\(time)|\(offset)",
              "splitIIMTime(\(text))")
}

print("isVolatile：只跳过描述文件自身的键")
// 按完整键路径匹配，不用子串："Depth"/"Compression"/"ProfileName" 这类片段太短，
// 子串匹配会让名字里含这几个字的真实字段被整条跳过且悄无声息。下面后半组用例
// 守这件事——它们必须**不**被跳过。
func expectVolatile(_ key: String, _ want: Bool, _ why: String) {
    checkRule(key, isVolatile(key), want, why)
}
// 该跳过的：文件自身的物理描述
for k in ["Depth", "PrimaryImage",
          "FileSize", "PixelWidth", "PixelHeight", "HasAlpha", "IsFloat", "IsIndexed"] {
    expectVolatile(k, true, "顶层 \(k)")
}
// 色彩描述文件与色彩模型描述的是像素怎么解读：CMYK 转成 sRGB 必须报出来。
expectVolatile("ProfileName", false, "ICC 描述文件名不是编码噪声")
expectVolatile("ColorModel", false, "色彩模型不是编码噪声")
expectVolatile("{JFIF}/XDensity", true, "JFIF 段整类（HEIF 没有这个段）")
expectVolatile("XMP/iio:hasIIM", true, "ImageIO 内部标记")
expectVolatile("{Exif}/ComponentsConfiguration", true, "EXIF 的分量配置")
expectVolatile("XMP/exif:ComponentsConfiguration[2]", true, "带下标的同一字段")
expectVolatile("{TIFF}/Compression", true, "TIFF 压缩方式")

// 绝不能跳过的：名字里恰好含上述片段的真实字段
expectVolatile("{MakerCanon}/FocusDepth", false, "厂商的 FocusDepth 不是文件描述")
expectVolatile("{Exif}/SubjectDepth", false, "EXIF 的 SubjectDepth 是照片内容")
expectVolatile("XMP/crs:DepthMapInfo", false, "XMP 的 DepthMapInfo 是照片内容")
expectVolatile("{ExifAux}/LensProfileName", false, "镜头配置文件名不是色彩描述文件名")
expectVolatile("{TIFF}/CompressionScheme", false, "名字含 Compression 但不是它")
expectVolatile("{Exif}/DateTimeOriginal", false, "拍摄时间")
expectVolatile("{GPS}/Latitude", false, "拍摄位置")
// 键名取自 ImageIO 常量，大小写写错的键名不会被当成易变键。
expectVolatile("hasAlpha", false, "小写 hasAlpha 不是真实键名")

print("MakerNote 派生字典的归类")
// {ExifAux} 是混的：ImageIO 声明过的键走 XMP aux: 能完好转换，实测全部存活，
// 它们真丢了必须逐条报出来；未声明的键才是 MakerNote 派生，可以归并。
// 按整个 {ExifAux}/ 前缀归并会把标准键的真丢失藏进计数里——这组用例守住这一点。
for (key, want) in [// 未声明 → 归并
                    ("{ExifAux}/AFInfo[0]", "{ExifAux}"),
                    ("{ExifAux}/FocusMode", "{ExifAux}"),
                    ("{ExifAux}/ImageStabilization", "{ExifAux}"),
                    // 已声明 → 绝不归并，丢了要单独报
                    ("{ExifAux}/LensModel", ""),
                    ("{ExifAux}/SerialNumber", ""),
                    ("{ExifAux}/LensInfo", ""),
                    ("{ExifAux}/Firmware", ""),
                    ("{ExifAux}/LensID", ""),
                    ("{ExifAux}/FlashCompensation", ""),
                    ("{ExifAux}/OwnerName", ""),
                    ("{ExifAux}/LensSerialNumber", ""),
                    ("{ExifAux}/ImageNumber", ""),
                    // 带下标的已声明键同样不归并
                    ("{ExifAux}/LensInfo[2]", ""),
                    // SDK 对 {PictureStyle} 零声明，整类归并
                    ("{PictureStyle}/Monochrome[1]", "{PictureStyle}"),
                    ("{MakerCanon}/LensModel", "{MakerCanon}"),
                    ("{MakerNikon}/ColorMode", "{MakerNikon}"),
                    ("{Exif}/DateTimeOriginal", ""),
                    ("{GPS}/Latitude", "")] {
    checkRule(key, makerNoteGroup(of: key) ?? "", want,
              "\(key) → \(want.isEmpty ? "不归类" : want)")
}

print("keySpaceDiff：两个键空间 → 差异列表")
// 主循环的每条分支各一个用例：删掉或架空任何一条分支，对应那条会红。
check("值变化被报出", keySpaceDiff(before: ["{TIFF}/Model": "Canon"],
                                   after: ["{TIFF}/Model": "Nikon"]),
      ["变化 {TIFF}/Model: Canon → Nikon"])
check("数值重编码不算变化", keySpaceDiff(before: ["{GPS}/Altitude": "-15/10"],
                                     after: ["{GPS}/Altitude": "-3/2"]), [])
check("普通键丢失被报出", keySpaceDiff(before: ["{GPS}/Latitude": "50.87"], after: [:]),
      ["丢失 {GPS}/Latitude = 50.87"])
// IIM 键在目标里没有对应容器：等价字段在、值也对上才放过；等价字段在而值不同必须报。
let iimDate = iptcKey(kCGImagePropertyIPTCDateCreated)
let exifShot = exifKey(kCGImagePropertyExifDateTimeOriginal)
check("IIM 日期由等价字段同值承载，不报",
      keySpaceDiff(before: [iimDate: "20240915"], after: [exifShot: "2024:09:15 18:42:07"]), [])
check("IIM 日期的等价字段在、值不同，必须报",
      keySpaceDiff(before: [iimDate: "20240915"], after: [exifShot: "2020:01:01 00:00:00"]),
      ["丢失 \(iimDate) = 20240915"])
check("MakerNote 派生键丢失合并成一条汇总",
      keySpaceDiff(before: ["{MakerCanon}/x": "1"], after: [:]),
      ["丢失 厂商私有数据 MakerNote（1 项：{MakerCanon} 1 项）"
       + "——ImageIO 读不出原始 MakerNote，也无法把它写入 HEIF"])
// XMP 时间戳按时刻比：源侧取原始 XMP 包，目标的 XMP 是 ImageIO 合成的，会补小数秒。
let xmpShot = "XMP/photoshop:DateCreated"
check("XMP 时间目标多带小数秒不算变化",
      keySpaceDiff(before: [xmpShot: "2024-09-15T18:42:07+08:00"],
                   after: [xmpShot: "2024-09-15T18:42:07.42+08:00"]), [])
check("XMP 时间的偏移丢了要报",
      keySpaceDiff(before: [xmpShot: "2024-09-15T18:42:07+08:00"],
                   after: [xmpShot: "2024-09-15T18:42:07.42"]),
      ["变化 \(xmpShot): 2024-09-15T18:42:07+08:00 → 2024-09-15T18:42:07.42"])
check("XMP 时间的秒变了要报",
      keySpaceDiff(before: [xmpShot: "2024-09-15T18:42:07+08:00"],
                   after: [xmpShot: "2024-09-15T18:42:08.42+08:00"]),
      ["变化 \(xmpShot): 2024-09-15T18:42:07+08:00 → 2024-09-15T18:42:08.42+08:00"])
check("非 XMP 键不放宽：EXIF 时间多出小数也算变化",
      keySpaceDiff(before: [exifShot: "2024:09:15 18:42:07"], after: [exifShot: "2024:09:15 18:42:07.42"]),
      ["变化 \(exifShot): 2024:09:15 18:42:07 → 2024:09:15 18:42:07.42"])
check("易变键丢失或变化都跳过",
      keySpaceDiff(before: ["PixelWidth": "100", "{JFIF}/XDensity": "72"],
                   after: ["{JFIF}/XDensity": "96"]), [])

print("Windows 标签：等价字段带着同一个值才算承载")
func expectWindows(_ raw: [Int: String?], _ after: [String: String], _ want: [String], _ why: String) {
    checkRule("\(raw) / \(after)", windowsTagLosses(raw, after: after), want, why)
}
let tiffDescription = "{TIFF}/ImageDescription", tiffArtist = "{TIFF}/Artist"
let lostTitle = "丢失 Windows 标题 XPTitle（IFD0 0x9C9B） = "
let lostAuthor = "丢失 Windows 作者 XPAuthor（IFD0 0x9C9D） = "
let lostKeywords = "丢失 Windows 关键词 XPKeywords（IFD0 0x9C9E） = "
let lostRating = "丢失 Windows 评级 Rating（IFD0 0x4746） = "
expectWindows([0x9C9B: "西湖"], [tiffDescription: "西湖"], [], "XPTitle 由 ImageDescription 承载")
expectWindows([0x9C9B: "西湖"], ["XMP/dc:title[en-US]": "西湖"], [], "dc:title 的任一语言都算")
expectWindows([0x9C9B: "西湖"], ["XMP/dc:description[x-default]": "西湖"], [], "dc:description 也算")
expectWindows([0x9C9B: "西湖"], [tiffDescription: "别的"], [lostTitle + "西湖"], "等价字段在、值不同——必须报")
expectWindows([0x9C9B: "西湖"], [:], [lostTitle + "西湖"], "目标里没有等价字段——必须报")
expectWindows([0x9C9C: "备注"], ["XMP/exif:UserComment": "备注"], [], "XPComment 由 exif:UserComment 承载")
expectWindows([0x9C9D: "甲;乙"], [tiffArtist: "甲;乙"], [], "XPAuthor 与 Artist 同值（ImageIO 不拆分号）")
expectWindows([0x9C9D: "甲;乙"], ["XMP/dc:creator[0]": "甲", "XMP/dc:creator[1]": "乙"], [],
              "dc:creator 拆成两项也算")
expectWindows([0x9C9D: "甲;乙"], [tiffArtist: "甲; 乙"], [], "分号两边的空白不算差异")
expectWindows([0x9C9D: "甲;乙"], ["XMP/dc:creator[0]": "甲"], [lostAuthor + "甲;乙"], "少了一个作者——必须报")
expectWindows([0x9C9D: "甲;乙"], [tiffArtist: "乙;甲"], [lostAuthor + "甲;乙"], "作者顺序变了——必须报")
expectWindows([0x9C9E: "a;b"], ["{IPTC}/Keywords[0]": "a", "{IPTC}/Keywords[1]": "b"], [],
              "XPKeywords 由 IPTC 关键词数组承载")
expectWindows([0x9C9E: "a;b"], ["XMP/dc:subject[0]": "a", "XMP/dc:subject[1]": "b", "XMP/dc:subject[2]": "c"],
              [lostKeywords + "a;b"], "目标多出一个关键词也不算同一个值——必须报")
expectWindows([0x9C9F: "主题"], [tiffDescription: "主题", "XMP/dc:title[x-default]": "主题"],
              ["丢失 Windows 主题 XPSubject（IFD0 0x9C9F） = 主题"], "XPSubject 没有等价字段，出现就报")
expectWindows([0x4746: "5"], ["XMP/xmp:Rating": "5"], [], "Rating 由 xmp:Rating 承载")
expectWindows([0x4746: "3"], ["XMP/xmp:Rating": "5"], [lostRating + "3"], "评级不同——必须报")
expectWindows([0x4746: "5"], ["{IPTC}/StarRating": "5"], [lostRating + "5"], "IPTC 星级不在等价表里")
expectWindows([0x4749: "99"], ["XMP/MicrosoftPhoto:Rating": "99"], [], "RatingPercent 由 MicrosoftPhoto:Rating 承载")
expectWindows([0x9C9C: String?.none], ["{Exif}/UserComment": "备注"],
              ["丢失 Windows 备注 XPComment（IFD0 0x9C9C）：值读不出（越界或类型不对）"], "值读不出的照样报")
check("产物原始 IFD0 里同一个标签、同值：算承载",
      windowsTagLosses([0x9C9B: "西湖", 0x4746: "5"], after: [:], destRaw: [0x9C9B: "西湖", 0x4746: "5"]), [])
check("产物原始 IFD0 里同一个标签、值不同：照报",
      windowsTagLosses([0x9C9B: "西湖"], after: [:], destRaw: [0x9C9B: "别的"]), [lostTitle + "西湖"])
check("产物原始 IFD0 里是别的标签：照报",
      windowsTagLosses([0x9C9B: "西湖"], after: [:], destRaw: [0x9C9F: "西湖"]), [lostTitle + "西湖"])
check("源里值读不出，产物里同样读不出：照报，不靠原始 IFD0 放过",
      windowsTagLosses([0x9C9C: String?.none], after: [:], destRaw: [0x9C9C: String?.none]),
      ["丢失 Windows 备注 XPComment（IFD0 0x9C9C）：值读不出（越界或类型不对）"])
check("承载字段的下标按数字排", carrierValues("XMP/dc:subject",
      in: ["XMP/dc:subject[10]": "k", "XMP/dc:subject[2]": "c", "XMP/dc:subject[0]": "a"]), ["a", "c", "k"])
check("嵌套的子字段不算这个字段的值", carrierValues("XMP/dc:subject",
      in: ["XMP/dc:subject[0]/x": "a"]), [])

print("XMP 的键：前缀按命名空间 URI 定，不按 ImageIO 临时给的前缀")
// ImageIO 给的前缀（要不要加 `_N_`、N 是几）同一个文件读两次可能不同；键由 URI 定才对得上。
let psURI = "http://ns.adobe.com/photoshop/1.0/"
let ps11 = "http://ns.adobe.com/photoshop/1.1/", ps12 = "http://ns.adobe.com/photoshop/1.2/"
let jt1 = "http://example.com/glint/test/1.0/", jt2 = "http://example.com/glint/test/2.0/"
let dcURI = "http://purl.org/dc/elements/1.1/"
func xmpKeySpace(_ tags: [(String, String)], _ ns: [(String, String)]) -> [String: String] {
    xmpKeys(tags.map { (path: $0.0, value: $0.1) }, namespaces: ns.map { (prefix: $0.0, uri: $0.1) })
}
/// 单个路径改写后的键；`ns` 是这个文件的「ImageIO 给的前缀 → URI」。
func xmpKeyOf(_ path: String, _ ns: [(String, String)]) -> String {
    let space = xmpKeySpace([(path, "值")], ns)
    return space.count == 1 ? space.keys.first! : "<\(space.count) 个键>"
}
// 标准命名空间
check("标准 URI 配标准前缀：键不变", xmpKeyOf("photoshop:City", [("photoshop", psURI)]), "XMP/photoshop:City")
check("标准 URI 配别的前缀（photoshoq）：用标准前缀", xmpKeyOf("photoshoq:City", [("photoshoq", psURI)]), "XMP/photoshop:City")
check("标准 URI 配加了 _N_ 的前缀：用标准前缀", xmpKeyOf("dc_1_:title[x-default]", [("dc_1_", dcURI)]),
      "XMP/dc:title[x-default]")
// 自定义前缀：几种 _N_ 配同一个 URI 是同一个键
for p in ["jt", "jt_1_", "jt_2_", "jt_1__1_"] {
    check("自定义前缀 \(p) 配同一个 URI → XMP/jt:Custom", xmpKeyOf("\(p):Custom", [(p, jt1)]), "XMP/jt:Custom")
}
check("自定义前缀：同一文件里别的命名空间不影响它", xmpKeyOf("jt_1_:Custom", [("jt_1_", jt1), ("lr", "http://ns.adobe.com/lightroom/1.0/")]),
      "XMP/jt:Custom")
// 非标准 URI 借用标准前缀：带 URI，且不等于标准字段的键
let borrowed11 = "XMP/photoshop{http%3A%2F%2Fns.adobe.com%2Fphotoshop%2F1.1%2F}:City"
for p in ["photoshop", "photoshop_1_", "photoshop_2_", "photoshop_1__1_"] {
    check("非标准 URI 借用标准前缀（\(p)）→ 带 URI 的同一个键",
          xmpKeyOf("\(p):City", p == "photoshop" ? [(p, ps11)] : [("photoshop", psURI), (p, ps11)]), borrowed11)
}
let borrowed12 = xmpKeyOf("photoshop_1_:City", [("photoshop", psURI), ("photoshop_1_", ps12)])
check(borrowed12 != borrowed11, "借用标准前缀的两个不同 URI → 不同的键（\(borrowed12)）")
check(![borrowed11, borrowed12].contains("XMP/photoshop:City"), "借用标准前缀的键都不等于 XMP/photoshop:City")
// 同一文件里两个不在表里的 URI 同基名：都带 URI，互不相同
let twoJT = xmpKeySpace([("jt:Custom", "甲"), ("jt_1_:Custom", "乙")], [("jt", jt1), ("jt_1_", jt2)])
check("同基名的两个 URI 都带上 URI", twoJT,
      ["XMP/jt{http%3A%2F%2Fexample.com%2Fglint%2Ftest%2F1.0%2F}:Custom": "甲",
       "XMP/jt{http%3A%2F%2Fexample.com%2Fglint%2Ftest%2F2.0%2F}:Custom": "乙"])
// 嵌套路径、数组下标、语言下标
let mwgURI = "http://www.metadataworkinggroup.com/schemas/regions/", areaURI = "http://ns.adobe.com/xmp/sType/Area#"
check("嵌套路径的每一段都换（其中两层的前缀被改名）",
      xmpKeyOf("mwg-rs:Regions.mwg-rs_1_:RegionList[0].mwg-rs:Area.stArea_1_:x",
               [("mwg-rs", mwgURI), ("mwg-rs_1_", mwgURI), ("stArea_1_", areaURI)]),
      "XMP/mwg-rs:Regions.mwg-rs:RegionList[0].mwg-rs:Area.stArea:x")
check("ImageIO 实际的嵌套写法（只有第一段带前缀）",
      xmpKeyOf("mwg-rs_2_:Regions.RegionList[0].Name", [("mwg-rs_2_", mwgURI)]), "XMP/mwg-rs:Regions.RegionList[0].Name")
check("方括号里的东西不动", xmpKeyOf("jt_1_:Bag[jt_1_:x.jt_1_:y]", [("jt_1_", jt1)]), "XMP/jt:Bag[jt_1_:x.jt_1_:y]")
check("路径里的前缀不在表里：原样保留", xmpKeyOf("zz_1_:x", [("jt_1_", jt1)]), "XMP/zz_1_:x")
check("同一个前缀报出两个 URI：分不清，原样保留", xmpKeyOf("jt_1_:x", [("jt_1_", jt1), ("jt_1_", jt2)]), "XMP/jt_1_:x")
check("前缀里带点：整个前缀一起换", xmpKeyOf("a.b_1_:x", [("a", jt1), ("a.b_1_", jt2)]), "XMP/a.b:x")
check("几个前缀都对得上时取最长的", xmpKeyOf("a_1_:b_1_:x", [("a_1_", jt1), ("a_1_:b_1_", jt2)]), "XMP/a_1_:b:x")
// URI 里有键的语法字符、空格、控制字符、非 ASCII：单射，键处理函数照常工作
let oddURIs = ["u/a", "u%2Fa", "u:a", "u%3Aa", "u.a", "u[a]", "u{a}", "u a", "u\na", "u\u{1}a", "u\u{FF}a",
               "u\u{FFFD}a", "u%25a", "u%a", "", "u]a[", "u}a{", "u[1]/a", "u[1]"]
let oddKeys = oddURIs.map { xmpKeyOf("photoshop_1_:City[3]", [("photoshop", psURI), ("photoshop_1_", $0)]) }
check("URI 里的特殊字符：\(oddURIs.count) 个 URI 写成 \(oddURIs.count) 个不同的键", Set(oddKeys).count, oddURIs.count)
check("URI 里的特殊字符：去掉下标之后仍是 \(oddURIs.count) 个不同的键",
      Set(oddKeys.map(strippingAllArrayIndices)).count, oddURIs.count)
let syntaxFree = oddKeys.allSatisfy { key in
    guard let open = key.firstIndex(of: "{"), let close = key.lastIndex(of: "}"), open < close else { return false }
    return !key[key.index(after: open)..<close].unicodeScalars.contains { !$0.isASCII || $0.value < 0x21 || "/:[]{}".unicodeScalars.contains($0) }
}
check(syntaxFree, "转义过的 URI 里没有 / : [ ] { }、空白、控制字符、非 ASCII")
for (uri, key) in zip(oddURIs, oddKeys) {
    let base = xmpKeyOf("photoshop_1_:City", [("photoshop", psURI), ("photoshop_1_", uri)])
    let shown = uri.debugDescription
    check(strippingAllArrayIndices(key) == base && strippingArrayIndex(key) == base,
          "URI \(shown)：去掉下标得到同一字段的键")
    check("URI \(shown)：carrierValues 认得出这个字段的各个值", carrierValues(base, in: [key: "杭州"]), ["杭州"])
    check(makerNoteGroup(of: key) == nil && !isIgnoredKey(key) && ReconciledGroup(viewKey: key) == nil,
          "URI \(shown)：不是 MakerNote、不被忽略、不属于说明作者版权三组")
}
check("标准 dc 配别的前缀：仍属于说明那一组",
      ReconciledGroup(viewKey: xmpKeyOf("dcx:description[x-default]", [("dcx", dcURI)])), .description)
check("非标准 URI 借用 dc 前缀：不属于说明那一组",
      ReconciledGroup(viewKey: xmpKeyOf("dc_1_:description[x-default]", [("dc", dcURI), ("dc_1_", jt1)])), nil)
let iioURI = "http://ns.apple.com/ImageIO/1.0/"
check(isIgnoredKey(xmpKeyOf("iio_1_:hasIIM", [("iio_1_", iioURI)])), "ImageIO 的标记配了别的前缀：照样不比")
check(!isIgnoredKey(xmpKeyOf("iio:hasIIM", [("iio", jt1)])), "非标准 URI 借用 iio 前缀：要比，不当 ImageIO 的标记")
check("非标准 URI 借用 MicrosoftPhoto 前缀：承载不了 RatingPercent",
      windowsTagLosses([0x4749: "99"], after: xmpKeySpace([("MicrosoftPhoto:Rating", "99")], [("MicrosoftPhoto", jt1)]), destRaw: [:]),
      ["丢失 Windows 评级百分比 RatingPercent（IFD0 0x4749） = 99"])
// 表：规则里引用到的每个前缀都在表里，认的是它的 URI
for (prefix, uri) in [("dc", dcURI), ("exif", "http://ns.adobe.com/exif/1.0/"), ("photoshop", psURI),
                      ("tiff", "http://ns.adobe.com/tiff/1.0/"), ("xmp", "http://ns.adobe.com/xap/1.0/"),
                      ("MicrosoftPhoto", "http://ns.microsoft.com/photo/1.0/"), ("iio", iioURI)] {
    check("标准表：规则里的前缀 \(prefix) 认 \(uri)", standardXMPPrefixes[uri], prefix)
}
check("标准表：ImageIO 公开的十个命名空间都在", [kCGImageMetadataNamespaceExif, kCGImageMetadataNamespaceExifAux,
      kCGImageMetadataNamespaceExifEX, kCGImageMetadataNamespaceDublinCore, kCGImageMetadataNamespaceIPTCCore,
      kCGImageMetadataNamespaceIPTCExtension, kCGImageMetadataNamespacePhotoshop, kCGImageMetadataNamespaceTIFF,
      kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataNamespaceXMPRights].filter { standardXMPPrefixes[$0 as String] == nil }.count, 0)
// 键空间比对：同 URI、前缀不同 → 无差异；URI 不同 → 报丢失
check("键空间比对：源 jt:、产物 jt_1_:（同 URI）→ 无差异",
      keySpaceDiff(before: xmpKeySpace([("jt:Custom", "值")], [("jt", jt1)]),
                   after: xmpKeySpace([("jt_1_:Custom", "值")], [("jt_1_", jt1)])), [])
check("键空间比对：源 photoshop_1_:、产物 photoshop_2_:（同 URI）→ 无差异",
      keySpaceDiff(before: xmpKeySpace([("photoshop_1_:City", "杭州")], [("photoshop", psURI), ("photoshop_1_", ps11)]),
                   after: xmpKeySpace([("photoshop_2_:City", "杭州")], [("photoshop", psURI), ("photoshop_2_", ps11)])), [])
check("键空间比对：URI 不同 → 报丢失",
      keySpaceDiff(before: xmpKeySpace([("photoshop_1_:City", "杭州")], [("photoshop", psURI), ("photoshop_1_", ps11)]),
                   after: xmpKeySpace([("photoshop_1_:City", "杭州")], [("photoshop", psURI), ("photoshop_1_", ps12)])),
      ["丢失 \(borrowed11) = 杭州"])
check("键空间比对：借用标准前缀的不能由真正的 photoshop:City 承载",
      keySpaceDiff(before: xmpKeySpace([("photoshop:City", "杭州")], [("photoshop", ps11)]),
                   after: xmpKeySpace([("photoshop:City", "杭州")], [("photoshop", psURI)])), ["丢失 \(borrowed11) = 杭州"])
// 健壮性：任意前缀、URI、路径不崩
for (input, want) in [("", ""), ("_", "_"), ("_1_", ""), ("_1__1__1_", ""), ("jt__", "jt__"), ("jt_x_", "jt_x_"),
                      ("jt_１_", "jt_１_"), ("jt_12_", "jt"), ("jt_1", "jt_1")] {
    checkRule(input, xmpPrefixBase(input), want, "基名去掉末尾的 _数字_")
}
let long = String(repeating: "_1_", count: 3000), longURI = String(repeating: "\u{FF}/", count: 3000)
let messy = xmpKeySpace([("", "空"), (":", "冒号"), ("[[[", "括号"), ("]].", "反括号"), ("\(long):x", "长"),
                         ("..", "点"), (":x", "空前缀")],
                        [("", ""), (long, longURI), ("", jt1), ("x", ""), ("y", longURI)])
check("畸形的前缀、URI、路径：不崩，每条路径一个键", messy.count, 7)

print("原始字节读取器：残缺、越界的输入不崩，读不出就照实说")
func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
/// 小端 TIFF：IFD0 在偏移 8，条目是（标签, 类型, 个数, 4 字节值域），表后接 `tail`。
func tiffLE(_ entries: [(Int, Int, Int, [UInt8])], tail: [UInt8] = []) -> [UInt8] {
    var t: [UInt8] = [0x49, 0x49, 42, 0] + le32(8) + le16(entries.count)
    for (tag, type, count, value) in entries { t += le16(tag) + le16(type) + le32(count) + value }
    return t + le32(0) + tail
}
func jpegWithExif(_ tiff: [UInt8]) -> [UInt8] {
    let payload = Array("Exif".utf8) + [0, 0] + tiff
    let n = payload.count + 2
    return [0xFF, 0xD8, 0xFF, 0xE1, UInt8(n >> 8), UInt8(n & 0xFF)] + payload + [0xFF, 0xD9]
}
let xpNote: [UInt8] = [0x07, 0x59, 0xE8, 0x6C, 0, 0]   // "备注" 的 UTF-16LE 加 NUL
let afterOneEntry = 8 + 2 + 12 + 4
check("读出 XP 文本", rawWindowsTags(of: jpegWithExif(tiffLE([(0x9C9C, 1, 6, le32(afterOneEntry))], tail: xpNote))),
      [0x9C9C: "备注"])
check("读出 SHORT 评级", rawWindowsTags(of: jpegWithExif(tiffLE([(0x4746, 3, 1, le16(4) + [0, 0])]))), [0x4746: "4"])
check("大端文件的评级按大端读",
      rawWindowsTags(of: jpegWithExif([0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x47, 0x46, 0, 3, 0, 0, 0, 1, 0, 3, 0, 0,
                                       0, 0, 0, 0])), [0x4746: "3"])
check("值的偏移越界：条目照样列出、值是 nil",
      rawWindowsTags(of: jpegWithExif(tiffLE([(0x9C9C, 1, 6, le32(0xFFFF00))], tail: xpNote))), [0x9C9C: String?.none])
check("个数大得离谱：值是 nil",
      rawWindowsTags(of: jpegWithExif(tiffLE([(0x9C9C, 1, 0x7FFF_FFFF, le32(afterOneEntry))]))), [0x9C9C: String?.none])
check("评级的类型不对：值是 nil", rawWindowsTags(of: jpegWithExif(tiffLE([(0x4746, 2, 2, [0x35, 0, 0, 0])]))),
      [0x4746: String?.none])
let lyingCount = jpegWithExif([0x49, 0x49, 42, 0] + le32(8) + le16(200) + le16(0x4746) + le16(3) + le32(1) + le16(2))
check("IFD 条目数比实际多、文件在表中间就完了：读到哪算哪", rawWindowsTags(of: lyingCount), [0x4746: "2"])
let whole = jpegWithExif(tiffLE([(0x9C9C, 1, 6, le32(afterOneEntry))], tail: xpNote))
let cuts = (0..<whole.count).map { rawWindowsTags(of: Array(whole.prefix($0))).count }
check("逐字节截短的文件都不崩", cuts.count, whole.count)
check("XP 文本没有 NUL 结尾、长度是奇数", decodeXPText([0x41, 0, 0x42, 0, 0x43]), "AB")
check("XP 文本里不成对的代理项解成替换字符", decodeXPText([0x00, 0xD8, 0x41, 0]), "\u{FFFD}A")
check("XP 文本是空的", decodeXPText([0, 0, 0x41, 0]), "")
check("空的 XP 标签不列", rawWindowsTags(of: jpegWithExif(tiffLE([(0x9C9B, 1, 2, [0, 0, 0, 0])]))), [:])

print("APP13 的 Photoshop 资源：解析不了的部分算进来，不当作没有")
func resource(_ id: Int, name: [UInt8] = [], _ content: [UInt8]) -> [UInt8] {
    var r = Array("8BIM".utf8) + [UInt8(id >> 8), UInt8(id & 0xFF), UInt8(name.count)] + name
    if (name.count + 1) % 2 == 1 { r.append(0) }
    return r + [0, 0, UInt8(content.count >> 8), UInt8(content.count & 0xFF)] + content
        + (content.count % 2 == 1 ? [0] : [])
}
func expectResources(_ block: [UInt8], _ ids: [Int], _ unparsed: Int, _ why: String) {
    let parsed = photoshopResources(in: block)
    checkRule("\(block.count) 字节", "\(parsed.resources.map(\.id)) \(parsed.unparsed)", "\(ids) \(unparsed)", why)
}
expectResources(resource(0x0404, [1, 2, 3]) + resource(0x0425, Array(repeating: 9, count: 16)), [0x0404, 0x0425], 0,
                "IPTC 与它的摘要")
expectResources(resource(0x0BB7, name: Array("abc".utf8), [1, 2]), [0x0BB7], 0, "资源名长度加长度字节是偶数，不补齐")
expectResources(resource(0x0404, [1, 2]) + [0, 0, 0, 0], [0x0404], 0, "末尾的 0 填充不算解析不了")
expectResources(Array(resource(0x0BB7, [1, 2, 3]).dropLast()), [0x0BB7], 0, "最后一个资源缺了补齐字节照收")
expectResources(Array(resource(0x0BB7, Array(repeating: 7, count: 40)).prefix(20)), [], 15,
                "资源长度越界：一个都收不下，剩下的非零字节全算解析不了")
expectResources(resource(0x0404, [1, 2]) + Array("PHUT".utf8) + [0, 1, 0, 0], [0x0404], 5,
                "不是 8BIM 开头的旧式资源算解析不了")
expectResources(Array(resource(0x0404, [1, 2]).prefix(11)), [], 6, "不到一个资源头长")

print("缩略图键：按去掉下标后的完整键路径认，只认实测见过的子键")
for key in ["{FileContents}/Images[0]/ThumbnailImages[0]/Width",
            "{FileContents}/Images[0]/ThumbnailImages[0]/Height",
            "{FileContents}/Images[0]/ThumbnailImages[0]/Orientation",
            "{FileContents}/Images[0]/ThumbnailImages[0]/ThumbnailOffset",
            "{FileContents}/Images[3]/ThumbnailImages[12]/ThumbnailSize"] {
    checkRule(key, isThumbnailKey(key), true, "缩略图的 \(key.split(separator: "/").last!)")
}
for (key, why) in [("{FileContents}/Images[0]/ThumbnailImages[0]/HDRHeadroom", "没见过的子键照常报"),
                   ("{FileContents}/Images[0]/Width", "主图的宽不是缩略图"),
                   ("{FileContents}/Images[0]/AuxiliaryData[0]/Width", "辅助图的宽不是缩略图"),
                   ("{Exif}/ThumbnailImages[0]/Width", "别的字典里同名的键不算"),
                   ("{FileContents}/Images[0]/MyThumbnailImages[0]/Width", "名字里含 ThumbnailImages 不算"),
                   ("{FileContents}/Images[0]/ThumbnailImages[x]/Width", "下标不是数字不算"),
                   ("{FileContents}/Images[0]/ThumbnailImages[0]/Width/x", "更深一层不算")] {
    checkRule(key, isThumbnailKey(key), false, why)
}
check("keySpaceDiff 跳过缩略图键、照报主图的键",
      keySpaceDiff(before: ["{FileContents}/Images[0]/ThumbnailImages[0]/ThumbnailSize": "27774",
                            "{FileContents}/Images[0]/Width": "4080"], after: [:]),
      ["丢失 {FileContents}/Images[0]/Width = 4080"])

print("尾部记账：MPF 登记的辅助图搬进产物才不报，偏移、长度、条目数都不信")
func jpegSegment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let n = payload.count + 2
    return [0xFF, marker, UInt8(n >> 8), UInt8(n & 0xFF)] + payload
}
/// 一张只有 SOF0 的完整小 JPEG（JPEGLayout 与 standaloneJPEGSize 只看段结构）。
func tinyJPEG(_ width: Int, _ height: Int) -> [UInt8] {
    [0xFF, 0xD8] + jpegSegment(0xC0, [8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8),
                                      UInt8(width & 0xFF), 1, 1, 0x11, 0]) + [0xFF, 0xD9]
}
typealias MPFEntry = (type: Int, size: Int, offset: Int)
/// 主图（SOI + MPF 段 + EOI）后面依次接 `gap`、各张附加图像、`tail`。MP 索引按实际
/// 位置填好，`edit` 再改条目或 MPEntry 的长度字段，造各种说谎的索引。偏移从 MPF 段里
/// TIFF 头的起点（文件第 10 字节）算。
func mpfJPEG(_ images: [(type: Int, data: [UInt8])], gap: [UInt8] = [], tail: [UInt8] = [], bigEndian: Bool = false,
             entryBytes: Int? = nil, edit: (inout [MPFEntry]) -> Void = { _ in }) -> [UInt8] {
    let base = 10
    func u16(_ v: Int) -> [UInt8] { bigEndian ? [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] : le16(v) }
    func u32(_ v: Int) -> [UInt8] { bigEndian ? u16(v >> 16 & 0xFFFF) + u16(v & 0xFFFF) : le32(v) }
    let header = 2 + 4 + 4 + 26 + 16 * (images.count + 1) + 2
    var entries: [MPFEntry] = [(0x030000, header, 0)]
    var at = header + gap.count
    for image in images {
        entries.append((image.type, image.data.count, at - base))
        at += image.data.count
    }
    edit(&entries)
    var tiff: [UInt8] = (bigEndian ? [0x4D, 0x4D, 0, 0x2A] : [0x49, 0x49, 0x2A, 0]) + u32(8) + u16(1)
    tiff += u16(0xB002) + u16(7) + u32(entryBytes ?? entries.count * 16) + u32(26) + u32(0)
    for e in entries { tiff += u32(e.type) + u32(e.size) + u32(e.offset) + u16(0) + u16(0) }
    return [0xFF, 0xD8] + jpegSegment(0xE2, Array("MPF".utf8) + [0] + tiff) + [0xFF, 0xD9]
        + gap + images.flatMap(\.data) + tail
}
let gainMap = tinyJPEG(40, 30), depthMap = tinyJPEG(20, 15)
func expectTrailer(_ bytes: [UInt8], carried: [(width: Int, height: Int)], _ want: [String], _ why: String) {
    checkRule("\(bytes.count) 字节，搬走 \(carried)", unportableSegments(in: bytes, carriedAuxiliary: carried), want, why)
}
let mpfNote = "（MPF 多图格式的附加图像）"
let one = mpfJPEG([(0, gainMap)])
let oneTrailer = gainMap.count
expectTrailer(one, carried: [(40, 30)], [], "唯一的附加图像是搬走了的辅助图：不报")
expectTrailer(one, carried: [], ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "产物里没有这张辅助图：照报")
expectTrailer(one, carried: [(41, 30)], ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "尺寸对不上：照报")
expectTrailer(mpfJPEG([(0x040000, gainMap)]), carried: [(40, 30)], ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"],
              "MP 类型是编辑前的原图（0x040000）：尺寸碰巧对上也照报")
expectTrailer(mpfJPEG([(0x020002, gainMap)]), carried: [(40, 30)], ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"],
              "MP 类型是多视角图（0x020002）：尺寸碰巧对上也照报")
expectTrailer(mpfJPEG([(0x050000, gainMap)]), carried: [(40, 30)], [], "新版 MPF 的增益图类型码（0x050000）搬走了：不报")
expectTrailer(mpfJPEG([(0x050000, gainMap)]), carried: [(41, 30)], ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"],
              "类型码 0x050000、尺寸对不上：照报")
expectTrailer(mpfJPEG([(0x050000, gainMap)], tail: Array("xyz".utf8)), carried: [(40, 30)],
              ["丢失 EOI 之后的 3 字节（尾部共 \(oneTrailer + 3) 字节，其中 \(oneTrailer) 字节是已搬进产物的辅助图像）"],
              "类型码 0x050000 的增益图后面另有数据：只报剩下的字节")
expectTrailer(mpfJPEG([(0, gainMap)], bigEndian: true), carried: [(40, 30)], [], "大端的 MP 索引照样读")
expectTrailer(mpfJPEG([(0, gainMap)], tail: Array("xyz".utf8)), carried: [(40, 30)],
              ["丢失 EOI 之后的 3 字节（尾部共 \(oneTrailer + 3) 字节，其中 \(oneTrailer) 字节是已搬进产物的辅助图像）"],
              "辅助图后面另有数据：报剩下的字节")
expectTrailer(mpfJPEG([(0, gainMap)], gap: [0xAB, 0xCD]), carried: [(40, 30)],
              ["丢失 EOI 之后的 2 字节（尾部共 \(oneTrailer + 2) 字节，其中 \(oneTrailer) 字节是已搬进产物的辅助图像）"],
              "EOI 与辅助图之间夹着数据：报夹着的字节")
expectTrailer(mpfJPEG([(0, gainMap)], gap: [0, 0xFF, 0], tail: [0, 0]), carried: [(40, 30)], [],
              "剩下的全是 0x00/0xFF 填充：不报")
expectTrailer(mpfJPEG([(0, gainMap), (0, depthMap)]), carried: [(40, 30), (20, 15)], [], "两张辅助图都搬走了：不报")
expectTrailer(mpfJPEG([(0, gainMap), (0, gainMap)]), carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节（尾部共 \(2 * oneTrailer) 字节，其中 \(oneTrailer) 字节是已搬进产物的辅助图像）"],
              "一张辅助图只能认领一个条目")
// 索引说谎时条目不收，尾部的字节不落在任何登记的范围里，所以也不注明是 MPF 的附加图像。
expectTrailer(mpfJPEG([(0, gainMap)]) { $0[1].offset = 0x7FFF_FFF0 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节"], "条目偏移指到文件外：照报，不崩")
expectTrailer(mpfJPEG([(0, gainMap)]) { $0[1].size += 1 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节"], "条目长度越过文件末尾：照报")
expectTrailer(mpfJPEG([(0, gainMap)], tail: [1]) { $0[1].size += 1 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer + 1) 字节\(mpfNote)"], "条目范围里不只一张 JPEG：照报")
expectTrailer(mpfJPEG([(0, Array(gainMap.dropLast(2)) + [0x12, 0x34])]), carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "登记的图像没有 EOI：照报")
expectTrailer(mpfJPEG([(0, gainMap)]) { $0[1].offset = 0 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节"], "偏移 0 指回主图自己：照报")
expectTrailer(mpfJPEG([(0, gainMap)]) { $0[1].offset -= 4 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节"], "条目范围伸进主图里：照报（末尾 4 字节不在登记范围内，不注明 MPF）")
expectTrailer(mpfJPEG([(0, gainMap)], entryBytes: 0xFFFF_FFF0), carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节"], "MPEntry 声称的条目数离谱：照报，不崩")
expectTrailer(mpfJPEG([(0, gainMap)], entryBytes: 40), carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节"], "MPEntry 长度不是 16 的倍数：照报")
check("条目数离谱时一个条目都不收", mpfImages(in: mpfJPEG([(0, gainMap)], entryBytes: 0xFFFF_FFF0),
                                      JPEGLayout(mpfJPEG([(0, gainMap)]))!).count, 0)
// 逐字节截短：不崩；截在辅助图中间（尾部至少还有一个非填充字节）时必须照报。
let eoiEnd = one.count - oneTrailer
let truncations = (0..<one.count).map { unportableSegments(in: Array(one.prefix($0)), carriedAuxiliary: [(40, 30)]) }
check("逐字节截短的文件都不崩", truncations.count, one.count)
check("截在辅助图中间的每一种都照报尾部丢失",
      (eoiEnd + 2..<one.count).filter { truncations[$0].isEmpty }, [])
// MPF 段本身被截短（段长度字段跟着改，后面的字节整体前移）：不崩，附加图像一律照报。
// 截掉的部分不含条目表时，条目偏移也因前移而对不上，这几种照报的原因不只是索引读不出。
let mpfStart = 2, mpfEnd = 2 + 4 + 4 + 26 + 32
let segmentCuts = (mpfStart + 4 + 4 + 1..<mpfEnd).filter { cut in
    var bytes = one
    let n = cut - mpfStart - 2
    bytes[mpfStart + 2] = UInt8(n >> 8); bytes[mpfStart + 3] = UInt8(n & 0xFF)
    bytes.removeSubrange(cut..<mpfEnd)
    return unportableSegments(in: bytes, carriedAuxiliary: [(40, 30)]).isEmpty
}
check("MPF 段截短到任何长度，附加图像都照报", segmentCuts, [])

print("MPF 登记的图不在文件里（编辑后留下的旧索引）：写进状态说明，不算校验差异")
// 实例：编辑软件重存了主图，增益图没带上，MP 索引原样留着，增益图的偏移指到文件末尾之后。
let staleMPF = mpfJPEG([(0x050000, gainMap)]) { $0[1].offset = 0x10_0000 }
check("登记到文件末尾之后的增益图：列出类型码与长度",
      mpfMissingImages(in: staleMPF, JPEGLayout(staleMPF)!).map { "\($0.typeCode) \($0.size)" }, ["\(0x050000) \(oneTrailer)"])
check("登记的图都在文件里：不列", mpfMissingImages(in: one, JPEGLayout(one)!).count, 0)
let stalePreview = mpfJPEG([(0x010002, gainMap)]) { $0[1].offset = 0x10_0000 }
check("不在文件里的是大尺寸预览图：不列（派生物，在也不带）",
      mpfMissingImages(in: stalePreview, JPEGLayout(stalePreview)!).count, 0)
let staleOnly = Array(staleMPF.prefix(staleMPF.count - oneTrailer))
check("增益图本来就不在：不算校验差异（源里本来就没有）", unportableSegments(in: staleOnly, carriedAuxiliary: []), [])
check("增益图本来就不在：状态说明写明类型、长度",
      staleMPFNotice(staleOnly), "原图的 MPF 索引登记的附加图像（增益图，类型码 0x050000，\(oneTrailer) 字节）不在文件里："
        + "原图被编辑或截短过，这张图转换前就没了，HEIF 里也没有")
check("登记的图都在：没有说明", staleMPFNotice(one), nil)

print("多份 EXIF：第二份里有第一份之外的信息才报，列出字段")
func twoExif(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    let id = Array("Exif".utf8) + [0, 0]
    return [0xFF, 0xD8] + jpegSegment(0xE1, id + a) + jpegSegment(0xE1, id + b) + [0xFF, 0xD9]
}
let modelA = tiffLE([(0x0110, 2, 2, [0x41, 0, 0, 0]), (0x0112, 3, 1, le16(6) + [0, 0])])
let modelB = tiffLE([(0x0110, 2, 2, [0x42, 0, 0, 0]), (0x0112, 3, 1, le16(6) + [0, 0])])
let onlyOrientation = tiffLE([(0x0112, 3, 1, le16(6) + [0, 0])])
// 同样的方向（6），大端写法：按值比，不算不同。
let orientationBE: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0]
func extra(_ copy: [UInt8], _ rest: String) -> String {
    "丢失 第 2 份 EXIF（APP1，\(copy.count + 6) 字节）：产物只带第 1 份" + rest
}
check("两份一样：不报", extraExifIssues(in: twoExif(modelA, modelA), JPEGLayout(twoExif(modelA, modelA))!), [])
check("第二份是第一份的子集、值相同：不报",
      extraExifIssues(in: twoExif(modelA, onlyOrientation), JPEGLayout(twoExif(modelA, onlyOrientation))!), [])
check("字节序不同、值相同：不报",
      extraExifIssues(in: twoExif(modelA, orientationBE), JPEGLayout(twoExif(modelA, orientationBE))!), [])
check("第二份的 Model 不同：报出字段",
      extraExifIssues(in: twoExif(modelA, modelB), JPEGLayout(twoExif(modelA, modelB))!),
      [extra(modelB, "，这份里 1 个字段与第 1 份不同或第 1 份没有：{TIFF}/Model（0x0110）")])
check("第一份没有的字段：报",
      extraExifIssues(in: twoExif(onlyOrientation, modelA), JPEGLayout(twoExif(onlyOrientation, modelA))!),
      [extra(modelA, "，这份里 1 个字段与第 1 份不同或第 1 份没有：{TIFF}/Model（0x0110）")])
let garbage: [UInt8] = Array("not a tiff".utf8)
check("第二份读不出结构：整份报", extraExifIssues(in: twoExif(modelA, garbage), JPEGLayout(twoExif(modelA, garbage))!),
      [extra(garbage, "，这份读不出结构")])
let many = tiffLE((0..<10).map { (0x0300 + $0, 3, 1, le16($0) + [0, 0]) })
let manyIssue = extraExifIssues(in: twoExif(onlyOrientation, many), JPEGLayout(twoExif(onlyOrientation, many))!)
check("超过 8 个字段：列 8 个加「等」，按标签号排",
      manyIssue.map { [$0.contains("10 个字段"), $0.hasSuffix(" 等"), $0.contains("0x0300"), !$0.contains("0x0308")] },
      [[true, true, true, true]])
// 标签 9 与 0x0110（272）：按文本排「272」在前，按标签号 9 在前。
let ordered = tiffLE([(0x0009, 3, 1, le16(1) + [0, 0]), (0x0110, 2, 2, [0x43, 0, 0, 0])])
check("字段按标签号排，不按文本",
      extraExifIssues(in: twoExif(onlyOrientation, ordered), JPEGLayout(twoExif(onlyOrientation, ordered))!)
        .map { $0.range(of: "0x0009")!.lowerBound < $0.range(of: "0x0110")!.lowerBound }, [true])
check("只有一份：不报", extraExifIssues(in: jpegWithExif(modelA), JPEGLayout(jpegWithExif(modelA))!), [])
check("unportableSegments 带上多份 EXIF 那一条",
      unportableSegments(in: twoExif(modelA, modelB), carriedAuxiliary: []).contains { $0.hasPrefix("丢失 第 2 份 EXIF") }, true)

print("尾部记账：MPF 登记的大尺寸预览图不报，前后的数据照报")
let preview = tinyJPEG(160, 120)
let xyz = Array("xyz".utf8)
expectTrailer(mpfJPEG([(0x010002, preview)]), carried: [], [], "类型码 0x010002 的完整 JPEG 预览图：不报")
expectTrailer(mpfJPEG([(0x010001, preview)]), carried: [], [], "类型码 0x010001 的完整 JPEG 预览图：不报")
expectTrailer(mpfJPEG([(0x010002, preview)], gap: [0xFF, 0xFF], tail: [0, 0]), carried: [], [],
              "预览图前后只有 0x00/0xFF 填充：不报")
expectTrailer(mpfJPEG([(0x010002, preview)], tail: xyz), carried: [],
              ["丢失 EOI 之后的 3 字节（尾部共 \(preview.count + 3) 字节，其中 \(preview.count) 字节是 MPF 登记的预览图，不需要带）"],
              "预览图后面另有非填充数据：报剩下的字节，注明预览图的字节数")
expectTrailer(mpfJPEG([(0x010002, preview)], gap: [0xFF, 0x12], tail: [0xFF]), carried: [],
              ["丢失 EOI 之后的 3 字节（尾部共 \(preview.count + 3) 字节，其中 \(preview.count) 字节是 MPF 登记的预览图，不需要带）"],
              "预览图前面夹着非填充数据：剩下的字节连填充一起算")
expectTrailer(mpfJPEG([(0x010002, Array(preview.dropLast(2)) + [0x12, 0x34])]), carried: [],
              ["丢失 EOI 之后的 \(preview.count) 字节\(mpfNote)"], "登记的预览图没有 EOI：照报")
expectTrailer(mpfJPEG([(0x010002, preview)], tail: [1]) { $0[1].size += 1 }, carried: [],
              ["丢失 EOI 之后的 \(preview.count + 1) 字节\(mpfNote)"], "预览图的条目范围里不只一张 JPEG：照报")
expectTrailer(mpfJPEG([(0x010002, preview)]) { $0[1].offset -= 4 }, carried: [],
              ["丢失 EOI 之后的 \(preview.count) 字节"], "预览图的条目范围伸进主图里：照报")
expectTrailer(mpfJPEG([(0x010003, preview)]), carried: [], ["丢失 EOI 之后的 \(preview.count) 字节\(mpfNote)"],
              "类型码 0x010003 不是预览图：照报")
expectTrailer(mpfJPEG([(0, gainMap), (0x010002, gainMap)]) { $0[2].offset = $0[1].offset }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节（尾部共 \(2 * oneTrailer) 字节，其中 \(oneTrailer) 字节是已搬进产物的辅助图像）"],
              "预览图条目与已搬走的辅助图重叠：不认，没人认领的那份照报")
expectTrailer(mpfJPEG([(0x010002, preview), (0x010002, preview)]) { $0[2].offset = $0[1].offset }, carried: [],
              ["丢失 EOI 之后的 \(preview.count) 字节（尾部共 \(2 * preview.count) 字节，其中 \(preview.count) 字节是 MPF 登记的预览图，不需要带）"],
              "两个预览图条目指向同一处：只认一个，没人认领的那份照报")
// 预览图条目指向 EOI 之前、主图 APP1 里的一张完整 JPEG（EXIF 缩略图那样）：不认，尾部那张
// 没人登记的照报。mpfJPEG 的主图 EOI 在第 68 字节（SOI 2 + 段头 4 + MPF\0 4 + TIFF 58），
// 在它前面插一个 APP1 段，里面的 JPEG 从 68 + 4 + 6 起，相对 MPF 头（第 10 字节）的偏移是 68。
let embeddedThumb = tinyJPEG(16, 12)
var thumbInMain = mpfJPEG([(0x010002, preview)]) { $0[1] = (0x010002, embeddedThumb.count, 68) }
thumbInMain.insert(contentsOf: jpegSegment(0xE1, Array("Exif".utf8) + [0, 0] + embeddedThumb), at: 68)
check("前提：插段后预览图条目落在 EOI 之前、恰好是一张完整 JPEG",
      mpfImages(in: thumbInMain, JPEGLayout(thumbInMain)!).map { "\($0.range) \(standaloneJPEGSize(thumbInMain[$0.range]).map { "\($0)" } ?? "nil")" },
      ["78..<\(78 + embeddedThumb.count) (width: 16, height: 12)"])
expectTrailer(thumbInMain, carried: [], ["丢失 EOI 之后的 \(preview.count) 字节"],
              "预览图条目指向 EOI 之前主图里的一张完整 JPEG：不认，尾部照报")
expectTrailer(mpfJPEG([(0, gainMap), (0x010002, preview)], tail: xyz), carried: [(40, 30)],
              ["丢失 EOI 之后的 3 字节（尾部共 \(oneTrailer + preview.count + 3) 字节，其中 \(oneTrailer) 字节是已搬进产物的辅助图像，"
               + "\(preview.count) 字节是 MPF 登记的预览图，不需要带）"],
              "辅助图、预览图都有，另有数据：两项都列")
expectTrailer(mpfJPEG([(0, gainMap), (0x010002, preview)]), carried: [(40, 30)], [], "辅助图搬走了、另有预览图：不报")

print("尾部那一行：K、P 都是 0 时，按非填充字节是否全在 MPF 登记的范围内决定注不注明")
expectTrailer(tinyJPEG(8, 8) + xyz, carried: [], ["丢失 EOI 之后的 3 字节"], "没有 MPF：不注明")
expectTrailer(mpfJPEG([(0, gainMap)], tail: xyz), carried: [], ["丢失 EOI 之后的 \(oneTrailer + 3) 字节"],
              "有 MPF，但另有登记范围外的数据：不注明")
expectTrailer(mpfJPEG([(0, gainMap)], gap: [0xFF], tail: [0, 0]), carried: [], ["丢失 EOI 之后的 \(oneTrailer + 3) 字节\(mpfNote)"],
              "登记范围外只有填充：注明 MPF")

print("尾部记账：微信的 tyf- 标记不报，差一点就照报")
let weChat = Array("tyf-".utf8) + [0, 0, 0, 0]
expectTrailer(tinyJPEG(8, 8) + weChat, carried: [], [], "EOI 之后恰好是 tyf- 加 4 个 0：不报")
expectTrailer(mpfJPEG([(0, gainMap)], tail: weChat), carried: [(40, 30)], [], "辅助图搬走后剩下的恰好是 tyf- 标记：不报")
expectTrailer(tinyJPEG(8, 8) + Array("tyf-".utf8) + [0, 0, 0, 1], carried: [], ["丢失 EOI 之后的 8 字节"],
              "tyf- 后面 4 字节有非 0：照报")
expectTrailer(tinyJPEG(8, 8) + weChat + [0], carried: [], ["丢失 EOI 之后的 9 字节"], "tyf- 标记后面多 1 字节（填充）：照报")
expectTrailer(tinyJPEG(8, 8) + [0xFF] + weChat, carried: [], ["丢失 EOI 之后的 9 字节"], "tyf- 标记前面多 1 字节（填充）：照报")
expectTrailer(tinyJPEG(8, 8) + Array(weChat.dropLast()), carried: [], ["丢失 EOI 之后的 7 字节"], "少 1 字节：照报")
expectTrailer(tinyJPEG(8, 8) + Array("tyg-".utf8) + [0, 0, 0, 0], carried: [], ["丢失 EOI 之后的 8 字节"], "标识差一个字母：照报")

print("不报的段：FlashPix 扩展、只有保存质量的 Ducky 段，差一点就照报")
/// 只有一个标记段的 JPEG。
func oneSegmentJPEG(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] { [0xFF, 0xD8] + jpegSegment(marker, payload) + [0xFF, 0xD9] }
func expectSegments(_ bytes: [UInt8], _ want: [String], _ why: String) {
    checkRule("\(bytes.count) 字节", unportableSegments(in: bytes, carriedAuxiliary: []), want, why)
}
let fpxrDirectory = Array("FPXR".utf8) + [0, 1, 0, 2] + Array(repeating: 0x41, count: 40)
let fpxrData = Array("FPXR".utf8) + [0, 2] + [0xFF, 0xD8, 0xFF, 0xDB] + Array(repeating: 0x55, count: 200)
expectSegments(oneSegmentJPEG(0xE2, fpxrDirectory), [], "APP2 FPXR 目录段：不报")
expectSegments([0xFF, 0xD8] + jpegSegment(0xE2, fpxrDirectory) + jpegSegment(0xE2, fpxrData) + [0xFF, 0xD9], [],
               "APP2 FPXR 目录段加数据段：都不报")
let fpxq = Array("FPXQ".utf8) + Array(fpxrDirectory.dropFirst(4))
expectSegments(oneSegmentJPEG(0xE2, fpxq), ["丢失 APP2 段（FPXQ，\(fpxq.count) 字节）"], "APP2 FPXQ：照报")
expectSegments(oneSegmentJPEG(0xE3, fpxrDirectory), ["丢失 APP3 段（FPXR，\(fpxrDirectory.count) 字节）"], "APP3 FPXR：照报")
let fpxrNoNul = Array("FPXRx".utf8) + Array(repeating: 0x41, count: 4)
expectSegments(oneSegmentJPEG(0xE2, fpxrNoNul), ["丢失 APP2 段（FPXRxAAAA，9 字节）"], "FPXR 后面不是 NUL：照报")

let ducky = Array("Ducky".utf8)
let quality: [UInt8] = [0, 1, 0, 4, 0, 0, 0, 80]
expectSegments(oneSegmentJPEG(0xEC, ducky + quality + [0, 0]), [], "Ducky 只有保存质量、以标签 0 结束：不报")
expectSegments(oneSegmentJPEG(0xEC, ducky + quality), [], "Ducky 只有保存质量、到段尾结束：不报")
func lostDucky(_ payload: [UInt8]) -> [String] { ["丢失 APP12 段（Ducky，\(payload.count) 字节）"] }
let withComment = ducky + quality + [0, 2, 0, 9, 0, 0, 0, 5] + Array("hello".utf8) + [0, 0]
expectSegments(oneSegmentJPEG(0xEC, withComment), lostDucky(withComment), "Ducky 带注释记录（标签 2）：照报")
let withCopyright = ducky + quality + [0, 3, 0, 7, 0, 0, 0, 3] + Array("abc".utf8) + [0, 0]
expectSegments(oneSegmentJPEG(0xEC, withCopyright), lostDucky(withCopyright), "Ducky 带版权记录（标签 3）：照报")
let shortComment = ducky + quality + [0, 2, 0, 4] + Array("abcd".utf8)
expectSegments(oneSegmentJPEG(0xEC, shortComment), lostDucky(shortComment), "Ducky 带一条长度也是 4 的注释记录：照报")
let commentOnly = ducky + [0, 2, 0, 4] + Array("abcd".utf8) + [0, 0]
expectSegments(oneSegmentJPEG(0xEC, commentOnly), lostDucky(commentOnly), "Ducky 只有注释记录、没有保存质量：照报")
let overrun = ducky + [0, 1, 0, 4, 0, 0]
expectSegments(oneSegmentJPEG(0xEC, overrun), lostDucky(overrun), "Ducky 记录长度越过段尾：照报")
let oddLength = ducky + [0, 1, 0, 2, 0, 80, 0, 0]
expectSegments(oneSegmentJPEG(0xEC, oddLength), lostDucky(oddLength), "Ducky 保存质量的长度不是 4：照报")
let afterEnd = ducky + quality + [0, 0, 7]
expectSegments(oneSegmentJPEG(0xEC, afterEnd), lostDucky(afterEnd), "Ducky 标签 0 后面还有字节：照报")
let halfTag = ducky + quality + [0]
expectSegments(oneSegmentJPEG(0xEC, halfTag), lostDucky(halfTag), "Ducky 末尾剩半个标签：照报")
expectSegments(oneSegmentJPEG(0xEC, ducky + [0, 0]), lostDucky(ducky + [0, 0]), "Ducky 一条记录都没有：照报")
expectSegments(oneSegmentJPEG(0xED, ducky + quality + [0, 0]), ["丢失 APP13 段（Ducky，15 字节）"], "APP13 里的 Ducky：照报")

print("UserComment：经 encodeHEIF 写进 HEIC，读回与原文一致、字段里没有多余内容")
// 这一组真的走 ImageIO 的 HEIC 写入器：userCommentForHEIFWriter 依据的是量出来的
// 写入规则，只断言它自己的输出证明不了产物对。夹具的字段只有 48 字节，长备注
// 端到端造不出来，在这里测。两条分支（有无 XMP）各写一遍。
func tinyJPEGSource() -> CGImageSource? {
    guard let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let jpeg = NSMutableData()
    guard let image = ctx.makeImage(),
          let out = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(out, image, nil)
    return CGImageDestinationFinalize(out) ? CGImageSourceCreateWithData(jpeg, nil) : nil
}
/// HEIC 里 UserComment 字段的原始字节和 TIFF 字节序：找到 `Exif\0\0` 后的 TIFF 头，
/// 包成 JPEG 交给 exifUserCommentRange，不另写一份 TIFF 解析。
func heicUserCommentField(_ heic: [UInt8]) -> (bytes: [UInt8], bigEndian: Bool)? {
    let marker = Array("Exif".utf8) + [0, 0]
    for i in 0..<max(0, heic.count - marker.count) where Array(heic[i..<(i + marker.count)]) == marker {
        let jpeg = jpegWithExif(Array(heic[(i + marker.count)...].prefix(0xFFF0)))
        if let tiff = TIFFStructure(jpeg: jpeg), let r = exifUserCommentRange(in: Data(jpeg)) {
            return (Array(jpeg[r]), tiff.bigEndian)
        }
    }
    return nil
}
func withoutTrailingNUL(_ s: String) -> String {
    var scalars = Array(s.unicodeScalars)
    while scalars.last == "\0" { scalars.removeLast() }
    return String(String.UnicodeScalarView(scalars))
}
let commentSamples: [(String, String)] = [
    ("420 个汉字的长备注", String(repeating: "长备注的内容，", count: 60)),
    ("ASCII 打头、混排汉字与 emoji 的长备注", String(repeating: "abc中文🎉", count: 50)),
    ("BMP 之外的字符打头（旗帜、组合字符）", "🇧🇪比利时 e\u{301}"),
    ("ASCII 打头的中英混排", "Leuven 鲁汶 City Hall 市政厅"),
    ("ImageIO 从源读出来就带着尾部 NUL", "备注：这是拍摄当时写下的\0\0\0\0\0"),
    ("纯 ASCII", "Plain ASCII comment, 42 chars long......."),
]
let xmpForSecondPass = CGImageMetadataCreateMutable()
CGImageMetadataSetValueWithPath(xmpForSecondPass, nil, "xmp:Label" as CFString, "第二遍" as CFString)
if let jpegSource = tinyJPEGSource() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-unit-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (label, comment) in commentSamples {
        let text = withoutTrailingNUL(comment)
        let ascii = text.utf16.allSatisfy { $0 <= 0x7F }
        // 产物字段应是：前缀 + 文本（非 ASCII 文本前面一律加 BOM）的编码，后面只有 NUL。
        let units = (ascii ? [] : [0xFEFF]) + Array(text.utf16)
        for (branch, xmp) in [("单遍", nil), ("两遍", xmpForSecondPass)] as [(String, CGImageMetadata?)] {
            let url = dir.appendingPathComponent("\(label)-\(branch).heic")
            let props = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: comment]] as [CFString: Any]
            guard encodeHEIF(jpegSource, properties: props, xmp: xmp, to: url),
                  let heic = try? [UInt8](Data(contentsOf: url)),
                  let back = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let field = heicUserCommentField(heic) else {
                fail("\(label)（\(branch)）：写不出或读不回 HEIC 的 UserComment"); continue
            }
            let exif = (CGImageSourceCopyPropertiesAtIndex(back, 0, nil) as? [CFString: Any])?[kCGImagePropertyExifDictionary]
            let read = ((exif as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String) ?? "<无>"
            check("\(label)（\(branch)）：读回去掉尾部 NUL 后等于原文", withoutTrailingNUL(read), text)
            let body = ascii ? Array(text.utf8) : units.flatMap { (u: UInt16) -> [UInt8] in
                field.bigEndian ? [UInt8(u >> 8), UInt8(u & 0xFF)] : [UInt8(u & 0xFF), UInt8(u >> 8)]
            }
            let expected = Array((ascii ? "ASCII\0\0\0" : "UNICODE\0").utf8) + body
            let rest = field.bytes.dropFirst(expected.count)
            check(field.bytes.starts(with: expected) && rest.allSatisfy { $0 == 0 },
                  "\(label)（\(branch)）：原始字段是前缀加完整文本，其后只有 NUL（\(field.bytes.count) 字节）")
        }
    }
    try? FileManager.default.removeItem(at: dir)
} else {
    fail("造不出作为 encodeHEIF 源的 JPEG")
}
let asciiProps = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "ASCII\0\0"]] as [CFString: Any]
check("纯 ASCII 的备注原样交给写入器（连尾部 NUL 也不动）",
      (propertiesForHEIFWriter(asciiProps)[kCGImagePropertyExifDictionary] as? [CFString: Any])?[
          kCGImagePropertyExifUserComment] as? String, "ASCII\0\0")
check("没有 EXIF 字典时原样交给写入器",
      propertiesForHEIFWriter([kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "X"]]).count, 1)

print("原始 EXIF 清点：源里有、产物里没有的标签报丢失，没有数据的和结构标签不报")
/// 一个小端条目；个数按类型的单位长度从值的字节数推出来，`count` 给了就用它。
func rawEntry(_ space: ExifSpace, _ ifd: String, _ tag: Int, _ type: Int, _ value: [UInt8]?, count: Int? = nil) -> RawExifEntry {
    let unit = type < TIFFStructure.unitSize.count ? max(TIFFStructure.unitSize[type], 1) : 1
    return RawExifEntry(space: space, ifd: ifd, tag: tag, type: type, count: count ?? (value?.count ?? 0) / unit,
                        value: value, bigEndian: false)
}
func rationalBytes(_ parts: [(Int, Int)]) -> [UInt8] { parts.flatMap { le32($0.0) + le32($0.1) } }
func rawIssues(_ source: [RawExifEntry], _ dest: [RawExifEntry]?, viewLosses: Set<String> = [],
               makerNote: Bool = false, idInView: Bool = false) -> [String] {
    compareRawExif(source: source, dest: dest, viewLosses: viewLosses, makerNoteReported: makerNote,
                   sourceViewHasImageUniqueID: idInView).issues
}
let lightSourceLong = rawEntry(.main, "ExifIFD", 0x9208, 4, le32(0))
let lostLightSource = "丢失 EXIF 标签 LightSource（ExifIFD 0x9208，LONG，0）——类型不合规范（规范是 SHORT），ImageIO 读不出这种写法"
check("产物里没有的标签报丢失，数值 0 也算数据", rawIssues([lightSourceLong], []), [lostLightSource])
check("产物里有同号标签（类型不同也算）就不报",
      rawIssues([lightSourceLong], [rawEntry(.main, "ExifIFD", 0x9208, 3, le16(0) + [0, 0])]), [])
check("IFD0 与 Exif 子 IFD 是同一个命名空间：放错 IFD 的标签在产物的规范位置就不报",
      rawIssues([rawEntry(.main, "ExifIFD", 0x010D, 2, Array("文档".utf8) + [0])],
                [rawEntry(.main, "IFD0", 0x010D, 2, Array("文档".utf8) + [0])]), [])
check("放错 IFD 的标签产物里没有：报，并说明放错了",
      rawIssues([rawEntry(.main, "ExifIFD", 0x010D, 2, Array("doc".utf8) + [0])], []),
      ["丢失 EXIF 标签 DocumentName（ExifIFD 0x010D，ASCII，\"doc\"）——放错了 IFD（规范在 IFD0），ImageIO 读不出"])
check("GPS 是另一个命名空间：主命名空间里的同号标签不算",
      rawIssues([rawEntry(.gps, "GPS", 0x001B, 2, Array("CELLID".utf8) + [0])],
                [rawEntry(.main, "IFD0", 0x001B, 2, Array("x".utf8) + [0])]),
      ["丢失 EXIF 标签 GPSProcessingMethod（GPS 0x001B，ASCII，\"CELLID\"）——类型不合规范（规范是 UNDEFINED），ImageIO 读不出这种写法"])
check("不认识的私有标签照报",
      rawIssues([rawEntry(.main, "ExifIFD", 0xC000, 7, Array("abc".utf8))], []),
      ["丢失 EXIF 标签 未知标签（ExifIFD 0xC000，UNDEFINED，\"abc\"）——ImageIO 不认识这个标签，不搬"])
let blankComment = [UInt8](repeating: 0, count: 8) + [UInt8](repeating: 0x20, count: 248)
for (e, why) in [
    (rawEntry(.main, "ExifIFD", 0x010D, 2, nil, count: 0), "长度 0"),
    (rawEntry(.main, "ExifIFD", 0, 0, nil, count: 0), "标签 0、类型 0、长度 0 的空条目"),
    (rawEntry(.main, "IFD0", 0x8298, 2, [0]), "只有一个 NUL 的 ASCII"),
    (rawEntry(.main, "ExifIFD", 0xC000, 7, [0x20, 0, 0x20]), "只有空格和 NUL 的 UNDEFINED"),
    (rawEntry(.main, "ExifIFD", 0x9286, 7, blankComment), "全 0 字符集头加 248 个空格的 UserComment"),
    (rawEntry(.main, "ExifIFD", 0x9286, 7, Array("ASCII\0\0\0".utf8) + [0x20, 0x20]), "ASCII 字符集头加空格的 UserComment"),
] {
    check("没有数据的条目不报：\(why)", rawIssues([e], []), [])
}
check("没有字符集头的 UserComment 不去掉前 8 字节（裸文本也是数据）",
      rawIssues([rawEntry(.main, "ExifIFD", 0x9286, 7, Array("ab".utf8))], []).count, 1)
check("值读不出（类型不认识）的条目算有数据，照报",
      rawIssues([rawEntry(.main, "ExifIFD", 0xC001, 99, nil, count: 3)], []),
      ["丢失 EXIF 标签 未知标签（ExifIFD 0xC001，类型 99，值读不出）——ImageIO 不认识这个标签，不搬"])
for (e, why) in [
    (rawEntry(.main, "IFD0", 0x0100, 3, le16(1200)), "ImageWidth"),
    (rawEntry(.main, "ExifIFD", 0xA002, 4, le32(1200)), "PixelXDimension"),
    (rawEntry(.main, "IFD0", 0x0213, 3, le16(1)), "YCbCrPositioning"),
    (rawEntry(.main, "ExifIFD", 0xA005, 4, le32(100)), "Interop 指针"),
    (rawEntry(.interop, "Interop", 0x0001, 2, Array("R98".utf8) + [0]), "InteroperabilityIndex"),
    (rawEntry(.main, "IFD0", 0xEA1C, 7, [0x1C, 0xEA, 0, 0]), "Windows 的 Padding"),
    (rawEntry(.main, "IFD0", 0x9C9D, 1, [0x41, 0, 0, 0]), "XPAuthor（由 Windows 标签规则管）"),
    (rawEntry(.main, "ExifIFD", 0x9003, 2, Array("2024:09:15 18:42:07".utf8) + [0]), "DateTimeOriginal（由原始时间规则管）"),
] {
    check("不报：\(why)", rawIssues([e], []), [])
}
check("Interop 里不认识的标签照报",
      rawIssues([rawEntry(.interop, "Interop", 0x1234, 2, Array("x".utf8) + [0])], []).count, 1)
let shortMakerNotes = ["J", "##**N4206_vivi", "Auto"].map { rawEntry(.main, "ExifIFD", 0x927C, 7, Array($0.utf8)) }
check("重复出现的同号标签合成一行，注明个数", rawIssues(shortMakerNotes, []),
      ["丢失 EXIF 标签 MakerNote（ExifIFD 0x927C，UNDEFINED，\"J\"、\"##**N4206_vivi\"、\"Auto\"，同号条目 3 个）——ImageIO 没有把它写进产物"])
check("MakerNote 已经由视图那条汇总行报过：不再报 0x927C", rawIssues(shortMakerNotes, [], makerNote: true), [])
check("视图已经报了同一个字段的丢失：不再重复",
      rawIssues([rawEntry(.main, "ExifIFD", 0x9208, 3, le16(1) + [0, 0])], [], viewLosses: ["{Exif}/LightSource"]), [])
check("视图报的是别的字段：照报",
      rawIssues([rawEntry(.main, "ExifIFD", 0x9208, 3, le16(1) + [0, 0])], [], viewLosses: ["{Exif}/Flash"]).count, 1)
check("产物的 EXIF 读不出：报一行无法核对，不当作没有差异", rawIssues([lightSourceLong], nil),
      ["无法核对原始 EXIF 标签：产物里的 EXIF 读不出，源里有 1 个标签没法确认带过去了"])
check("源里没有要核对的标签时，产物读不出也不出声",
      rawIssues([rawEntry(.main, "IFD0", 0x0100, 3, le16(1))], nil), [])
// 接到文件上的那一层：产物的字节读不通时同样是「无法核对」，没有 Exif 项时源里的标签全算丢失。
let sourceWithLightSource = jpegWithExif(tiffLE([(0x8769, 4, 1, le32(afterOneEntry))],
                                                tail: le16(1) + le16(0x9208) + le16(4) + le32(1) + le32(0) + le32(0)))
check("前提：手搭的源里读得出 Exif 子 IFD 的 LightSource",
      TIFFStructure(jpeg: sourceWithLightSource).map { rawExifEntries($0).map(\.tag) }, [0x8769, 0x9208])
check("产物不是读得通的 HEIF：报无法核对",
      rawExifDiff(source: sourceWithLightSource, dest: Array("garbage".utf8), viewLosses: [], makerNoteReported: false,
                  sourceViewHasImageUniqueID: false).issues,
      ["无法核对原始 EXIF 标签：产物里的 EXIF 读不出，源里有 1 个标签没法确认带过去了"])

print("ImageUniqueID：能原样写回才补写，两边的值按原始字节比")
func uniqueID(_ value: [UInt8]?, type: Int = 2, ifd: String = "ExifIFD", count: Int? = nil) -> RawExifEntry {
    rawEntry(.main, ifd, 0xA420, type, value, count: count)
}
let j12 = Array("J12LLKF00SM J12LLKL01GM".utf8)
for (entries, want, why) in [
    ([uniqueID(j12 + [0])], "J12LLKF00SM J12LLKL01GM", "24 字节的 ASCII"),
    ([uniqueID(Array("唯一标识".utf8) + [0])], "唯一标识", "非 ASCII 的 UTF-8"),
    ([uniqueID(Array("abc".utf8))], "abc", "没有 NUL：取满个数"),
    ([uniqueID(Array("ab\0cd\0".utf8))], "ab", "取到第一个 NUL 为止"),
    ([uniqueID([0xEF, 0xBB, 0xBF] + Array("abc".utf8) + [0])], "\u{FEFF}abc", "开头的 BOM 原样保留"),
] as [([RawExifEntry], String, String)] {
    check("补写：\(why)", restorableImageUniqueID(entries), want)
}
for (entries, why) in [
    ([uniqueID(Array("J12".utf8) + [0xFF] + Array("J12".utf8) + [0])], "不是合法 UTF-8"),
    ([uniqueID(j12, type: 7)], "UNDEFINED 类型"),
    ([uniqueID(Array("abc".utf8) + [0]), uniqueID(Array("def".utf8) + [0])], "同号条目两个"),
    ([uniqueID(j12 + [0], ifd: "IFD0")], "放在 IFD0"),
    ([uniqueID(nil, count: 99999)], "值越界读不出"),
    ([uniqueID(nil, count: 0)], "长度 0"),
    ([uniqueID([0x20, 0x20, 0])], "只有空格和 NUL"),
    ([uniqueID([0] + Array("abc".utf8) + [0])], "第一个字节就是 NUL"),
    ([rawEntry(.gps, "GPS", 0xA420, 2, j12 + [0])], "GPS 命名空间里的同号标签"),
] as [([RawExifEntry], String)] {
    check("不补：\(why)", restorableImageUniqueID(entries), String?.none)
}
let j12Entry = uniqueID(j12 + [0])
check("两边的值相同（补齐长度不同也算）：不报",
      rawIssues([j12Entry], [uniqueID(j12 + [0, 0, 0, 0])]), [])
check("产物的值末尾多一个空格：报变化",
      rawIssues([j12Entry], [uniqueID(j12 + [0x20, 0])]),
      ["变化 EXIF 标签 ImageUniqueID：\"J12LLKF00SM J12LLKL01GM\" → \"J12LLKF00SM J12LLKL01GM \""])
check("源的视图里读得到 ImageUniqueID：值由键空间比对管，这里不比",
      rawIssues([j12Entry], [uniqueID(j12 + [0x20, 0])], idInView: true), [])
check("产物的值读不出：报变化",
      rawIssues([j12Entry], [uniqueID(nil, count: 99999)]),
      ["变化 EXIF 标签 ImageUniqueID：\"J12LLKF00SM J12LLKL01GM\" → 值读不出"])
check("两边都不是合法 UTF-8、长度相同：注明原始字节从哪里开始不同",
      rawIssues([uniqueID([0x41, 0xFF, 0x42, 0])], [uniqueID([0x41, 0xFE, 0x42, 0])]),
      ["变化 EXIF 标签 ImageUniqueID：3 字节（不是合法的 UTF-8） → 3 字节（不是合法的 UTF-8）（显示相同，原始字节从第 2 个起不同）"])
let longID = [UInt8](repeating: 0x61, count: 70)
check("显示截断后相同：注明原始字节从哪里开始不同",
      rawIssues([uniqueID(longID + [0])], [uniqueID(longID + [0x62, 0])]).first?.hasSuffix("（显示相同，原始字节从第 71 个起不同）"),
      true)
check("产物里没有：照报丢失，不报变化", rawIssues([j12Entry], []),
      ["丢失 EXIF 标签 ImageUniqueID（ExifIFD 0xA420，ASCII，\"J12LLKF00SM J12LLKL01GM\"）——ImageIO 没有把它写进产物"])
check("源里没有数据的条目不比：产物里有别的值也不报",
      rawIssues([uniqueID([0x20, 0])], [uniqueID(j12 + [0])]), [])
// 接到文件上：手搭的 JPEG，Exif 子 IFD 里只有一个 0xA420。超过 4 字节的值放在子 IFD 后面。
func jpegWithUniqueID(type: Int = 2, count: Int? = nil, value: [UInt8]) -> [UInt8] {
    let field = value.count <= 4 ? value + [UInt8](repeating: 0, count: 4 - value.count) : le32(afterOneEntry + 18)
    return jpegWithExif(tiffLE([(0x8769, 4, 1, le32(afterOneEntry))],
                               tail: le16(1) + le16(0xA420) + le16(type) + le32(count ?? value.count) + field + le32(0)
                                   + (value.count <= 4 ? [] : value)))
}
let uidDir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-uid-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: uidDir, withIntermediateDirectories: true)
func writtenUniqueID(_ jpeg: [UInt8], props: [CFString: Any] = [:]) -> String? {
    let url = uidDir.appendingPathComponent("\(UUID().uuidString).jpg")
    guard (try? Data(jpeg).write(to: url)) != nil else { return "<写不出样本>" }
    let exif = propertiesToWrite(props, source: url)[kCGImagePropertyExifDictionary] as? [CFString: Any]
    return exif?[kCGImagePropertyExifImageUniqueID] as? String
}
check("前提：手搭的 JPEG 里读得出 Exif 子 IFD 的 0xA420",
      TIFFStructure(jpeg: jpegWithUniqueID(value: j12 + [0])).map { rawExifEntries($0).map(\.tag) }, [0x8769, 0xA420])
check("写入用的属性补上源里的 ImageUniqueID", writtenUniqueID(jpegWithUniqueID(value: j12 + [0])), "J12LLKF00SM J12LLKL01GM")
check("视图里已经有 ImageUniqueID：不动它",
      writtenUniqueID(jpegWithUniqueID(value: j12 + [0]),
                      props: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifImageUniqueID: "视图里的值"]]),
      "视图里的值")
for (jpeg, why) in [
    (jpegWithUniqueID(count: 0x7FFF_FFFF, value: j12 + [0]), "个数离谱"),
    (jpegWithUniqueID(count: 200, value: j12 + [0]), "值越出 EXIF"),
    (jpegWithUniqueID(count: 0, value: []), "长度 0"),
    (Array(jpegWithUniqueID(value: j12 + [0]).dropLast(12)), "EXIF 段被截短"),
] {
    check("不补、不崩：\(why)", writtenUniqueID(jpeg), String?.none)
}
try? FileManager.default.removeItem(at: uidDir)

print("GPS 按原始分数比：值不等就报，不加容差")
let srcLatitude = rawEntry(.gps, "GPS", 0x0002, 5, rationalBytes([(22, 1), (38, 1), (53743286, 1000000)]))
let gps = compareRawExif(source: [srcLatitude],
                         dest: [rawEntry(.gps, "GPS", 0x0002, 5, rationalBytes([(22, 1), (38, 1), (5374, 100)]))],
                         viewLosses: [], makerNoteReported: false, sourceViewHasImageUniqueID: false)
check("秒被截到 1/100：报一行，注明原因", gps.issues,
      ["变化 GPS 纬度：22°38′53.743286″ → 22°38′53.74″（HEIF 写入器只保留到 1/100 秒）"])
check("同一处的视图键交给键空间比对跳过", gps.coveredViewKeys, ["{GPS}/Latitude", "XMP/exif:GPSLatitude"])
check("约分程度不同、值相同：不报",
      rawIssues([rawEntry(.gps, "GPS", 0x0002, 5, rationalBytes([(30, 1), (14, 1), (3250, 100)]))],
                [rawEntry(.gps, "GPS", 0x0002, 5, rationalBytes([(30, 1), (14, 1), (65, 2)]))]), [])
check("海拔重新逼近、相对误差只有 2e-9 也报",
      rawIssues([rawEntry(.gps, "GPS", 0x0006, 5, rationalBytes([(1250001, 100000)]))],
                [rawEntry(.gps, "GPS", 0x0006, 5, rationalBytes([(624988, 49999)]))]),
      ["变化 GPS 海拔：12.50001 → 624988/49999（≈12.5000100002）"])
check("时间戳按时:分:秒显示",
      rawIssues([rawEntry(.gps, "GPS", 0x0007, 5, rationalBytes([(10, 1), (42, 1), (75, 10)]))],
                [rawEntry(.gps, "GPS", 0x0007, 5, rationalBytes([(10, 1), (42, 1), (7, 1)]))]),
      ["变化 GPS 时间戳：10:42:7.5 → 10:42:7"])
check("keySpaceDiff 跳过已由原始分数报过的键（含数组下标）",
      keySpaceDiff(before: ["{GPS}/Latitude": "22.6", "XMP/exif:GPSLatitude[0]": "a", "{GPS}/Altitude": "1"],
                   after: ["{GPS}/Latitude": "22.7", "XMP/exif:GPSLatitude[0]": "b", "{GPS}/Altitude": "2"],
                   covered: gps.coveredViewKeys),
      ["变化 {GPS}/Altitude: 1 → 2"])
for (n, d, want) in [(53743286, 1000000, "53.743286"), (5374, 100, "53.74"), (22, 1, "22"), (5, 2, "2.5"),
                     (-3, 4, "-0.75"), (1, 3, "1/3（≈0.333333333333）"), (7, 0, "7/0")] {
    checkRule("\(n)/\(d)", describeRational(n, d), want, "分数显示：\(n)/\(d)")
}

print("原始 TIFF 条目：IFD 互相指向、指针越界都不卡住、不崩")
// IFD0 里的 Exif 指针指回 IFD0 自己：每个 IFD 只读一次。
let cyclic = jpegWithExif(tiffLE([(0x8769, 4, 1, le32(8)), (0x0110, 2, 4, Array("ab\0\0".utf8))]))
if let tiff = TIFFStructure(jpeg: cyclic) {
    check("Exif 指针指回 IFD0：条目各列一次", rawExifEntries(tiff).map(\.tag), [0x8769, 0x0110])
} else { fail("造不出循环指针的 TIFF") }
let wild = jpegWithExif(tiffLE([(0x8769, 4, 1, le32(0x7FFF_FFF0)), (0x8825, 4, 1, le32(9999))]))
if let tiff = TIFFStructure(jpeg: wild) {
    check("指针越界：只列读得到的", rawExifEntries(tiff).map(\.ifd), ["IFD0", "IFD0"])
} else { fail("造不出越界指针的 TIFF") }
let lyingTIFF = jpegWithExif([0x49, 0x49, 42, 0] + le32(8) + le16(4000) + le16(0x9208) + le16(4) + le32(1) + le32(0))
check("条目数比实际多：读到哪算哪", TIFFStructure(jpeg: lyingTIFF).map { rawExifEntries($0).map(\.tag) }, [0x9208])
let tiffCuts = (0..<cyclic.count).map { TIFFStructure(jpeg: Array(cyclic.prefix($0))).map(rawExifEntries)?.count ?? 0 }
check("逐字节截短的 TIFF 都不崩", tiffCuts.count, cyclic.count)

print("HEIF 的 Exif 项：只认 ImageIO 写出来的形态，读不出就照实说")
if let jpegSource = tinyJPEGSource() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-unit-\(UUID().uuidString).heic")
    let props = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "RF50mm"],
                 kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 30.5, kCGImagePropertyGPSLatitudeRef: "N"]]
        as [CFString: Any]
    if encodeHEIF(jpegSource, properties: props, xmp: nil, to: url), let heic = try? [UInt8](Data(contentsOf: url)) {
        if case .tiff(let tiff) = heifExif(heic) {
            let entries = rawExifEntries(tiff)
            check(entries.contains { $0.space == .main && $0.tag == 0xA434 }, "读出 ImageIO 写进 HEIC 的 LensModel")
            check(entries.contains { $0.space == .gps && $0.tag == 0x0002 }, "读出 GPS IFD 里的纬度")
        } else {
            fail("ImageIO 写的 HEIC 里读不出 Exif 项"); fail("（同上，GPS 那条没测到）")
        }
        // 逐字节截短：每一种都不崩，结果只能是「读得出」或「读不出」——截掉了 Exif 项
        // 所在的数据还说「没有 Exif 项」就是把丢失当成了没有。
        var absentCuts: [Int] = []
        for cut in stride(from: 0, to: heic.count, by: max(1, heic.count / 400)) {
            if case .absent = heifExif(Array(heic.prefix(cut))) { absentCuts.append(cut) }
        }
        check("截短的 HEIC 不崩，也不被说成没有 Exif 项", absentCuts, [])
        // 逐字节改成 0xFF（前 2 KB，盒子头和 meta 都在里面）：不崩。
        var survived = 0
        for i in 0..<min(heic.count, 2048) {
            var bad = heic
            bad[i] = 0xFF
            _ = heifExif(bad)
            survived += 1
        }
        check("前 2 KB 任一字节改坏都不崩", survived, min(heic.count, 2048))
        // 随机改坏几个字节（种子固定）：单个字节改成 0xFF 碰不到的形状（比如某个盒子的
        // 长度刚好只够装下一两个字节）靠它撞出来。
        var seed: UInt64 = 2026
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % n
        }
        var fuzzed = 0
        for _ in 0..<5000 {
            var bad = heic
            for _ in 0...random(4) { bad[random(min(heic.count, 2048))] = UInt8(random(256)) }
            if random(4) == 0 { bad = Array(bad.prefix(random(bad.count))) }
            _ = heifExif(bad)
            fuzzed += 1
        }
        check("随机改坏 5000 次都不崩", fuzzed, 5000)
    } else {
        fail("写不出作为 heifExif 输入的 HEIC"); fail("（同上）"); fail("（同上）"); fail("（同上）"); fail("（同上）")
    }
    try? FileManager.default.removeItem(at: url)
} else {
    fail("造不出作为 encodeHEIF 源的 JPEG"); fail("（同上）"); fail("（同上）"); fail("（同上）"); fail("（同上）")
}
for (bytes, why) in [([UInt8](), "空文件"), (Array("not a heif file at all".utf8), "垃圾"),
                     ([0, 0, 0, 1] + Array("ftyp".utf8) + [UInt8](repeating: 0xFF, count: 8), "64 位盒子长度离谱"),
                     ([0, 0, 0, 0x10] + Array("meta".utf8) + [0, 0, 0, 0] + [0, 0, 0, 0x30], "meta 里的子盒子越界"),
                     // 下面两个 iinf 后面都紧跟一个 free 盒子：越过 iinf 读字段时读得到字节，
                     // 不会因为到了文件末尾而碰巧停下。
                     ([0, 0, 0, 0x1D] + Array("meta".utf8) + [0, 0, 0, 0] + [0, 0, 0, 9] + Array("iinf".utf8) + [0]
                      + [0, 0, 0, 8] + Array("free".utf8),
                      "iinf 只有 1 字节内容"),
                     ([0, 0, 0, 0x21] + Array("meta".utf8) + [0, 0, 0, 0] + [0, 0, 0, 13] + Array("iinf".utf8)
                      + [0, 0, 0, 0, 0] + [0, 0, 0, 8] + Array("free".utf8),
                      "iinf 装得下版本、装不下条目数")] {
    if case .unreadable = heifExif(bytes) { pass("读不出：\(why)") } else { fail("\(why) 没被判成读不出") }
}

print("EXIF 整块照搬：源一侧的闸门")
// 源 TIFF 与下面手搭产物里的 TIFF 长度不同：iloc 的长度字段不改的话，读回会对不上。
let carryTIFF: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0] + Array("源里的 EXIF，比产物里的长".utf8)
check("恰好一个 EXIF 段：取出 Exif\\0\\0 之后的全部字节",
      try? sourceExifTIFF(jpegWithExif(carryTIFF)).get(), carryTIFF)
func sourceSkip(_ jpeg: [UInt8]) -> String? {
    if case .failure(let skip) = sourceExifTIFF(jpeg) { return skip.reason }
    return nil
}
check("源里没有 EXIF 段：不换", sourceSkip([0xFF, 0xD8, 0xFF, 0xD9]), "源里没有 EXIF 段")
check("两个 EXIF 段：不换", sourceSkip(Array(jpegWithExif(carryTIFF).dropLast(2)) + Array(jpegWithExif(carryTIFF).dropFirst(2))),
      "源里的 EXIF 段不止一个")
check("EXIF 段里不是合法的 TIFF：不换", sourceSkip(jpegWithExif(Array("not a tiff header".utf8))),
      "源里的 EXIF 段不是合法的 TIFF")
check("不是 JPEG：不换", sourceSkip(Array("garbage".utf8)), "源文件的 JPEG 结构读不通")

print("EXIF 整块照搬：手搭的 HEIF，闸门每条一个反例，改写只动该动的字节")
func be(_ v: Int, _ width: Int) -> [UInt8] { (0..<width).map { UInt8(truncatingIfNeeded: v >> (8 * (width - 1 - $0))) } }
func box(_ type: String, _ content: [UInt8]) -> [UInt8] { be(content.count + 8, 4) + Array(type.utf8) + content }
/// 手搭一个 ImageIO 那种布局的 HEIF：ftyp、meta（iinf、iloc）、mdat。mdat 里先是 Exif 项的内容，
/// 后是 64 字节的「图像数据」（项号 100）。各个开关造闸门的反例。
struct HEIFSpec {
    var ilocVersion = 1, offsetSize = 4, lengthSize = 4, baseOffsetSize = 0
    /// mdat 的长度字段：32、64（size == 1）、0（到文件末尾）。
    var mdatHeader = 32
    var exifCount = 1, exifExtents = 1, exifMethod = 0, exifDataRef = 0
    var exifListedTwice = false
    var prefixSkip = 6
    var imageOverlapsExif = false, imageLengthZero = false, imageMethod = 0
    /// mdat 后面再接一个 free 盒子。
    var trailingBox = false
    /// Exif 项的内容放在 mdat 前面的一个 free 盒子里。
    var exifOutsideMdat = false
}
let productTIFF: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0] + Array("ImageIO 写的".utf8)
let imageData = [UInt8](repeating: 0xAB, count: 64)
func buildHEIF(_ spec: HEIFSpec) -> (bytes: [UInt8], exif: Range<Int>, mdatStart: Int) {
    let prefixFill = spec.prefixSkip == 6 ? Array("Exif".utf8) + [0, 0]
                                          : [UInt8](repeating: 0, count: min(spec.prefixSkip, 300))
    let exifContent = be(spec.prefixSkip, 4) + prefixFill + productTIFF
    let ftyp = box("ftyp", Array("heic".utf8) + be(0, 4))
    func meta(exifAt: Int, imageAt: Int, base: Int) -> [UInt8] {
        var infes: [UInt8] = []
        for id in 0..<spec.exifCount { infes += box("infe", [2, 0, 0, 0] + be(id + 1, 2) + be(0, 2) + Array("Exif".utf8) + [0]) }
        infes += box("infe", [2, 0, 0, 0] + be(100, 2) + be(0, 2) + Array("hvc1".utf8) + [0])
        let iinf = box("iinf", [0, 0, 0, 0] + be(spec.exifCount + 1, 2) + infes)
        let idWidth = spec.ilocVersion < 2 ? 2 : 4
        var entries: [[UInt8]] = []
        func entry(_ id: Int, method: Int, dataRef: Int, _ extents: [(Int, Int)]) -> [UInt8] {
            var e = be(id, idWidth)
            if spec.ilocVersion >= 1 { e += be(method, 2) }
            e += be(dataRef, 2) + be(base, spec.baseOffsetSize) + be(extents.count, 2)
            for (offset, length) in extents { e += be(offset - base, spec.offsetSize) + be(length, spec.lengthSize) }
            return e
        }
        var exifExtents = [(exifAt, exifContent.count)]
        if spec.exifExtents == 2 {
            let half = exifContent.count / 2
            exifExtents = [(exifAt, half), (exifAt + half, exifContent.count - half)]
        }
        for id in 0..<spec.exifCount {
            entries.append(entry(id + 1, method: spec.exifMethod, dataRef: spec.exifDataRef, exifExtents))
        }
        if spec.exifListedTwice { entries.append(entry(1, method: 0, dataRef: 0, exifExtents)) }
        let imageStart = spec.imageOverlapsExif ? imageAt - 4 : imageAt
        let imageLength = spec.imageLengthZero ? 0 : imageAt + imageData.count - imageStart
        entries.append(entry(100, method: spec.imageMethod, dataRef: 0, [(imageStart, imageLength)]))
        let iloc = box("iloc", [UInt8(spec.ilocVersion), 0, 0, 0,
                                UInt8(spec.offsetSize << 4 | spec.lengthSize), UInt8(spec.baseOffsetSize << 4)]
                               + be(entries.count, spec.ilocVersion < 2 ? 2 : 4) + entries.flatMap { $0 })
        return box("meta", [0, 0, 0, 0] + iinf + iloc)
    }
    let header = spec.mdatHeader == 64 ? 16 : 8
    let free = spec.exifOutsideMdat ? box("free", exifContent) : []
    let metaLength = meta(exifAt: 0, imageAt: 0, base: 0).count
    let freeContent = ftyp.count + metaLength + 8
    let mdatStart = ftyp.count + metaLength + free.count
    let mdatContent = (spec.exifOutsideMdat ? [] : exifContent) + imageData
    let exifAt = spec.exifOutsideMdat ? freeContent : mdatStart + header
    let imageAt = mdatStart + header + (spec.exifOutsideMdat ? 0 : exifContent.count)
    let base = spec.baseOffsetSize == 0 ? 0 : mdatStart + header
    var mdat: [UInt8]
    switch spec.mdatHeader {
    case 64: mdat = be(1, 4) + Array("mdat".utf8) + be(mdatContent.count + 16, 8)
    case 0: mdat = be(0, 4) + Array("mdat".utf8)
    default: mdat = be(mdatContent.count + 8, 4) + Array("mdat".utf8)
    }
    mdat += mdatContent
    let bytes = ftyp + meta(exifAt: exifAt, imageAt: imageAt, base: base) + free + mdat
        + (spec.trailingBox ? box("free", [1, 2, 3]) : [])
    return (bytes, exifAt..<(exifAt + exifContent.count), mdatStart)
}
func carrySkip(_ spec: HEIFSpec, limit32: Int = 0xFFFF_FFFF) -> String? {
    let built = buildHEIF(spec).bytes
    if case .failure(let skip) = carryingExif(carryTIFF, into: built, limit32: limit32) { return skip.reason }
    return nil
}
check("前提：默认的手搭 HEIF 读得出 Exif 项，内容是 ImageIO 那种 TIFF",
      { if case .tiff(let t) = heifExif(buildHEIF(HEIFSpec()).bytes) { return Array(t.bytes[t.base...]).prefix(productTIFF.count).elementsEqual(productTIFF) }; return false }(), true)
/// 正例：只有 mdat 长度字段、Exif 项的 iloc 偏移与长度、清零的旧范围变了，末尾接上「原前缀 + 源 TIFF」。
func expectCarried(_ spec: HEIFSpec, _ why: String) {
    let (old, exifRange, mdatStart) = buildHEIF(spec)
    guard case .success(let new) = carryingExif(carryTIFF, into: old) else {
        fail("\(why)：本该照搬却没换（\(carrySkip(spec) ?? "?")）"); return
    }
    let prefix = Array(old[exifRange.lowerBound..<(exifRange.lowerBound + 4 + spec.prefixSkip)])
    let content = prefix + carryTIFF
    var allowed = Set(exifRange)
    let sizeAt = spec.mdatHeader == 64 ? mdatStart + 8 : mdatStart
    if spec.mdatHeader != 0 { allowed.formUnion(sizeAt..<(sizeAt + (spec.mdatHeader == 64 ? 8 : 4))) }
    // iloc 里 Exif 项那两个字段：在旧文件里找「旧偏移、旧长度」紧挨着的那一处。
    let base = spec.baseOffsetSize == 0 ? 0 : mdatStart + (spec.mdatHeader == 64 ? 16 : 8)
    let fields = be(exifRange.lowerBound - base, spec.offsetSize) + be(exifRange.count, spec.lengthSize)
    let fieldAt = (0...(old.count - fields.count)).first { Array(old[$0..<($0 + fields.count)]) == fields }
    let newFields = be(old.count - base, spec.offsetSize) + be(content.count, spec.lengthSize)
    let fieldsOK = fieldAt.map { Array(new[$0..<($0 + newFields.count)]) == newFields } ?? false
    if let fieldAt { allowed.formUnion(fieldAt..<(fieldAt + fields.count)) }
    let untouched = (0..<old.count).allSatisfy { allowed.contains($0) || old[$0] == new[$0] }
    let zeroed = exifRange.allSatisfy { new[$0] == 0 }
    let tail = Array(new[old.count...]) == content
    var readBack = false
    if case .tiff(let t) = heifExif(new) { readBack = Array(t.bytes[t.base..<(t.base + t.length)]) == carryTIFF }
    var mdatOK = true
    if spec.mdatHeader == 32 { mdatOK = bigEndianInt(new, mdatStart, 4) == bigEndianInt(old, mdatStart, 4)! + content.count }
    if spec.mdatHeader == 64 { mdatOK = bigEndianInt(new, mdatStart + 8, 8) == bigEndianInt(old, mdatStart + 8, 8)! + content.count }
    if spec.mdatHeader == 0 { mdatOK = Array(new[mdatStart..<(mdatStart + 8)]) == Array(old[mdatStart..<(mdatStart + 8)]) }
    let ok = fieldsOK && untouched && zeroed && tail && new.count == old.count + content.count && readBack && mdatOK
        && heifExifEndsAtFileEnd(new)
    check(ok, "\(why)：只动了该动的字节，旧范围清零，末尾是原前缀 + 源 TIFF，读回是源 TIFF"
          + (ok ? "" : "（iloc 字段 \(fieldsOK) 其余不动 \(untouched) 清零 \(zeroed) 末尾 \(tail) 读回 \(readBack) mdat \(mdatOK)）"))
}
expectCarried(HEIFSpec(), "mdat 32 位长度、iloc 版本 1、4 字节偏移")
expectCarried(HEIFSpec(mdatHeader: 64), "mdat 64 位长度")
expectCarried(HEIFSpec(mdatHeader: 0), "mdat 长度写成到文件末尾")
for version in [0, 1, 2] {
    for width in [4, 8] {
        expectCarried(HEIFSpec(ilocVersion: version, offsetSize: width, lengthSize: width),
                      "iloc 版本 \(version)、偏移与长度 \(width) 字节")
    }
}
expectCarried(HEIFSpec(baseOffsetSize: 4), "iloc 带 4 字节基址")
expectCarried(HEIFSpec(prefixSkip: 64), "TIFF 头偏移等于上限 64，前缀原样保留")
func expectSkip(_ spec: HEIFSpec, limit32: Int = 0xFFFF_FFFF, _ want: String, _ why: String) {
    checkRule(why, carrySkip(spec, limit32: limit32), want, "不换：\(why)")
}
expectSkip(HEIFSpec(exifCount: 2), "产物里的 Exif 项不止一个", "两个 Exif 项")
expectSkip(HEIFSpec(exifListedTwice: true), "Exif 项在 iloc 里不是恰好出现一次", "Exif 项在 iloc 里出现两次")
expectSkip(HEIFSpec(exifExtents: 2), "Exif 项不是恰好一段", "Exif 项分两段")
expectSkip(HEIFSpec(exifMethod: 1), "Exif 项不是按文件偏移存放的", "构造方式 1")
expectSkip(HEIFSpec(exifDataRef: 1), "Exif 项不是按文件偏移存放的", "data_reference_index 不是 0")
expectSkip(HEIFSpec(trailingBox: true), "产物的最后一个盒子不是 mdat", "最后一个盒子不是 mdat")
expectSkip(HEIFSpec(imageOverlapsExif: true), "Exif 项与别的项重叠", "旧范围与别的项重叠")
expectSkip(HEIFSpec(imageLengthZero: true), "产物里有长度写成「到文件末尾」的项", "别的项长度写成 0（到文件末尾）")
expectSkip(HEIFSpec(imageMethod: 2), "产物里有按项偏移构造的项", "别的项是构造方式 2")
expectSkip(HEIFSpec(exifOutsideMdat: true), "Exif 项不在顶层 mdat 里", "旧范围不在 mdat 里")
expectSkip(HEIFSpec(prefixSkip: 65), "Exif 项开头的 TIFF 头偏移不对", "TIFF 头偏移超过上限")
expectSkip(HEIFSpec(prefixSkip: 0x7FFF_FFFF), "Exif 项开头的 TIFF 头偏移不对", "TIFF 头偏移离谱")
let carriedLength = 10 + carryTIFF.count
let plain = buildHEIF(HEIFSpec())
let mdatSize32 = bigEndianInt(plain.bytes, plain.mdatStart, 4)!
expectSkip(HEIFSpec(), limit32: mdatSize32 + carriedLength - 1, "产物的 mdat 是 32 位长度，放不下照搬后的长度",
           "32 位 mdat 长度放不下")
expectSkip(HEIFSpec(mdatHeader: 64), limit32: buildHEIF(HEIFSpec(mdatHeader: 64)).bytes.count - 1,
           "iloc 的偏移字段放不下新位置", "iloc 的 4 字节偏移放不下")
expectSkip(HEIFSpec(offsetSize: 8, mdatHeader: 64), limit32: carriedLength - 1, "iloc 的长度字段放不下新长度",
           "iloc 的 4 字节长度放不下")
expectSkip(HEIFSpec(exifCount: 0), "产物里没有 Exif 项", "没有 Exif 项")
check("产物里的 EXIF 已与源相同：无事可做",
      { () -> String? in
          if case .failure(let s) = carryingExif(productTIFF, into: buildHEIF(HEIFSpec()).bytes) { return s.reason }
          return nil }(),
      "产物里的 EXIF 已与源逐字节相同")
// 截断在任意位置：顶层盒子都会越界，一律不换。逐字节改坏、随机改坏：不崩；换了的话读回必须是源 TIFF。
let sample = buildHEIF(HEIFSpec()).bytes
check("截断在每一个位置都不换", (0..<sample.count).filter {
    if case .success = carryingExif(carryTIFF, into: Array(sample.prefix($0))) { return true }; return false
}, [])
func carriedBadly(_ bytes: [UInt8]) -> Bool {
    guard case .success(let new) = carryingExif(carryTIFF, into: bytes) else { return false }
    guard case .tiff(let t) = heifExif(new) else { return true }
    return Array(t.bytes[t.base..<(t.base + t.length)]) != carryTIFF || new.count != bytes.count + carriedLength
}
var badFlips: [Int] = []
for i in 0..<sample.count {
    for value: UInt8 in [0x00, 0xFF, sample[i] ^ 0x01] {
        var bad = sample
        bad[i] = value
        if carriedBadly(bad) { badFlips.append(i) }
    }
}
check("每个字节改成 00、FF、翻最低位都不崩，换了的读回都是源 TIFF", badFlips, [])
var carrySeed: UInt64 = 18
func carryRandom(_ n: Int) -> Int {
    carrySeed = carrySeed &* 6364136223846793005 &+ 1442695040888963407
    return Int(carrySeed >> 33) % n
}
var randomBad = 0
for _ in 0..<5000 {
    var bad = sample
    for _ in 0...carryRandom(4) { bad[carryRandom(bad.count)] = UInt8(carryRandom(256)) }
    if carriedBadly(bad) { randomBad += 1 }
}
check("随机改坏 5000 次都不崩，换了的读回都是源 TIFF", randomBad, 0)

print("EXIF 整块照搬：ImageIO 写的 HEIC，截断与改坏 meta 都不崩")
if let jpegSource = tinyJPEGSource() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-carry-\(UUID().uuidString).heic")
    let props = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "RF50mm"]] as [CFString: Any]
    if encodeHEIF(jpegSource, properties: props, xmp: nil, to: url), let heic = try? [UInt8](Data(contentsOf: url)),
       case .success(let children) = heifMetaChildren(heic), let top = heifBoxes(heic, in: 0..<heic.count),
       let meta = top.first(where: { $0.type == "meta" }) {
        check(children.contains { $0.type == "iloc" } && { if case .success = carryingExif(carryTIFF, into: heic) { return true }; return false }(),
              "前提：ImageIO 写的 HEIC 过得了闸门")
        let cuts = (0..<heic.count).filter { if case .success = carryingExif(carryTIFF, into: Array(heic.prefix($0))) { return true }; return false }
        check("截断到每一个长度都不换", cuts, [])
        var bad: [Int] = []
        for i in meta.start..<meta.content.upperBound {
            for value: UInt8 in [0x00, 0xFF, heic[i] ^ 0x80] {
                var mutated = heic
                mutated[i] = value
                if carriedBadly(mutated) { bad.append(i) }
            }
        }
        check("meta 盒的每个字节改成 00、FF、翻最高位都不崩，换了的读回都是源 TIFF", bad, [])
    } else {
        fail("写不出作为照搬输入的 HEIC"); fail("（同上）"); fail("（同上）"); fail("（同上）")
    }
    try? FileManager.default.removeItem(at: url)
} else {
    fail("造不出作为 encodeHEIF 源的 JPEG"); fail("（同上）"); fail("（同上）"); fail("（同上）")
}

print("照搬过的产物：Exif 项结束在文件末尾，TIFF 必须与源逐字节相同")
let carriedSample = try! carryingExif(carryTIFF, into: buildHEIF(HEIFSpec()).bytes).get()
check("照搬过、与源相同：不报", carriedExifIssues(source: jpegWithExif(carryTIFF), dest: carriedSample, comment: noComment), [])
var alteredTIFF = carryTIFF
alteredTIFF[alteredTIFF.count - 1] ^= 0x01
check("照搬过、最后一个字节不同：报出长度与位置",
      carriedExifIssues(source: jpegWithExif(alteredTIFF), dest: carriedSample, comment: noComment),
      ["变化 EXIF 数据块：照搬过来的 EXIF 与源不一致（\(carryTIFF.count) 字节 → \(carryTIFF.count) 字节，第 \(carryTIFF.count) 个字节起不同）"])
check("照搬过、源比产物多几个字节：从产物结束处算起不同",
      carriedExifIssues(source: jpegWithExif(carryTIFF + [1, 2, 3]), dest: carriedSample, comment: noComment),
      ["变化 EXIF 数据块：照搬过来的 EXIF 与源不一致（\(carryTIFF.count + 3) 字节 → \(carryTIFF.count) 字节，第 \(carryTIFF.count + 1) 个字节起不同）"])
check("照搬过、源里没有 EXIF 段：按 0 字节比，照报",
      carriedExifIssues(source: [0xFF, 0xD8, 0xFF, 0xD9], dest: carriedSample, comment: noComment),
      ["变化 EXIF 数据块：照搬过来的 EXIF 与源不一致（0 字节 → \(carryTIFF.count) 字节，第 1 个字节起不同）"])
check("ImageIO 那种布局（Exif 项在 mdat 靠前）：不管与源同不同都不报",
      carriedExifIssues(source: jpegWithExif(carryTIFF), dest: buildHEIF(HEIFSpec()).bytes, comment: noComment), [])
check("Exif 项结束在文件末尾的判定：照搬过的是，ImageIO 那种布局不是",
      [heifExifEndsAtFileEnd(carriedSample), heifExifEndsAtFileEnd(buildHEIF(HEIFSpec()).bytes)], [true, false])

print("备注的读法：可靠的文本与猜的分开")
let gbkXiHu: [UInt8] = [0xCE, 0xF7, 0xBA, 0xFE]   // 「西湖」的 GBK 字节，不是合法的 UTF-8
let gbkGuess = "\u{CE}\u{F7}\u{BA}\u{FE}"          // 它的 Latin-1 解读
let utf8LuWen = Array("鲁汶".utf8)
for (name, head, header) in [("ASCII 头", Array("ASCII\0\0\0".utf8), UserCommentHeader.ascii),
                             ("8 个 0 的头", [UInt8](repeating: 0, count: 8), .undefined),
                             ("没有头", [], .none)] as [(String, [UInt8], UserCommentHeader)] {
    check("\(name)：ASCII 是可靠的文本，照解码原样（尾部填充还在）",
          readUserComment(head + Array("Leuven\0 ".utf8)), .reliable("Leuven\0 ", header: header))
    check("\(name)：合法的 UTF-8 是可靠的文本", readUserComment(head + utf8LuWen), .reliable("鲁汶", header: header))
    check("\(name)：含高位字节又不是合法 UTF-8 的是猜的，带 Latin-1 猜测串和全部值字节",
          readUserComment(head + gbkXiHu + [0, 0x20]), .guessed(gbkGuess, raw: head + gbkXiHu + [0, 0x20], header: header))
    check("\(name)：正文是空的算没有", readUserComment(head), .absent)
    check("\(name)：只有填充算没有", readUserComment(head + [0, 0x20, 0, 0x0A]), .absent)
}
check("值不足 8 字节时没有头，按正文读", readUserComment(Array("ASCII".utf8)), .reliable("ASCII", header: .none))
let unicodeHeadBytes = Array("UNICODE\0".utf8)
check("UNICODE 头、大端 BOM：按大端解，BOM 和尾部 NUL 照原样留在文本里",
      readUserComment(unicodeHeadBytes + [0xFE, 0xFF, 0x9C, 0x81, 0x6C, 0x76, 0, 0]),
      .reliable("\u{FEFF}鲁汶\0", header: .unicode))
check("UNICODE 头、小端 BOM：按小端解",
      readUserComment(unicodeHeadBytes + [0xFF, 0xFE, 0x81, 0x9C, 0x76, 0x6C]), .reliable("\u{FEFF}鲁汶", header: .unicode))
check("UNICODE 头、没有 BOM 的大端：读对",
      readUserComment(unicodeHeadBytes + [0x9C, 0x81, 0x6C, 0x76]), .reliable("鲁汶", header: .unicode))
check("UNICODE 头、没有 BOM 的小端：两种都像文本时打平取大端（这一支的字节序判断不变）",
      readUserComment(unicodeHeadBytes + [0x48, 0x00, 0x69, 0x00]), .reliable("\u{4800}\u{6900}", header: .unicode))
check("UNICODE 头、正文是空的或只有 NUL：没有",
      [readUserComment(unicodeHeadBytes), readUserComment(unicodeHeadBytes + [0, 0, 0, 0])], [.absent, .absent])
check("UNICODE 头、两种字节序都解不出（落单的代理项）：猜的，没有猜测串",
      readUserComment(unicodeHeadBytes + [0xD8, 0xD8]), .guessed(nil, raw: unicodeHeadBytes + [0xD8, 0xD8], header: .unicode))
let jisHeadBytes = Array("JIS\0\0\0\0\0".utf8)
check("JIS 头：Shift-JIS 解得出是可靠的文本", readUserComment(jisHeadBytes + [0x82, 0xA0]), .reliable("あ", header: .jis))
check("JIS 头：Shift-JIS 解不出是猜的，没有猜测串",
      readUserComment(jisHeadBytes + [0xFF, 0xFF, 0x80]), .guessed(nil, raw: jisHeadBytes + [0xFF, 0xFF, 0x80], header: .jis))
check("比较用的尺子：去掉开头一个 BOM 和尾部的 NUL 与空白，中间的不动",
      ["\u{FEFF}鲁汶\0 \n", "\u{FEFF}\u{FEFF}x", "a\u{FEFF} b\0\0"].map(normalizedUserComment), ["鲁汶", "\u{FEFF}x", "a\u{FEFF} b"])

print("备注的修补条件：ImageIO 读不出且可靠，或 ASCII 头里装着非 ASCII 的 UTF-8；猜的不修补")
// 行：自己解析的结果；列：ImageIO 读成 没有 / 只有填充 / Latin-1 乱码 / 读对。格子里是
// toRepair（「-」是 nil）和 guessToWrite（「-」是 nil），用「/」隔开。
let imageIOSeen: [String?] = [nil, "\0\0 ", "é²\u{81}æ±\u{B6}", "鲁汶"]
let repairTable: [(String, UserCommentReading, [String])] = [
    ("没有", .absent, ["-/-", "-/-", "-/-", "-/-"]),
    ("无前缀 UTF-8", .reliable("鲁汶", header: .none), ["鲁汶/-", "鲁汶/-", "-/-", "-/-"]),
    ("ASCII 头 + 非 ASCII 的 UTF-8", .reliable("鲁汶\0", header: .ascii), ["鲁汶/-", "鲁汶/-", "鲁汶/-", "鲁汶/-"]),
    ("ASCII 头 + 纯 ASCII", .reliable("Leuven", header: .ascii), ["Leuven/-", "Leuven/-", "-/-", "-/-"]),
    ("8 个 0 的头 + 非 ASCII 的 UTF-8", .reliable("鲁汶", header: .undefined), ["鲁汶/-", "鲁汶/-", "-/-", "-/-"]),
    ("UNICODE 头带 BOM", .reliable("\u{FEFF}鲁汶\0", header: .unicode), ["鲁汶/-", "鲁汶/-", "-/-", "-/-"]),
    ("猜的（Latin-1）", .guessed(gbkGuess, raw: gbkXiHu, header: .none), ["-/\(gbkGuess)", "-/\(gbkGuess)", "-/-", "-/-"]),
    ("猜的（没有猜测串）", .guessed(nil, raw: jisHeadBytes + [0xFF], header: .jis), ["-/-", "-/-", "-/-", "-/-"]),
]
for (name, reading, want) in repairTable {
    let got = imageIOSeen.map { seen -> String in
        let c = SourceUserComment(seenByImageIO: seen, reading: reading)
        return "\(c.toRepair ?? "-")/\(c.guessToWrite ?? "-")"
    }
    check("\(name)：修补成的文本 / 写入用的猜测串", got, want)
}

print("系统重写时含非 ASCII 的备注总是带 BOM")
/// BOM + 文本 + 与（BOM + 文本）同样多的 NUL 单元。
func writerForm(_ text: String) -> String { "\u{FEFF}" + text + String(repeating: "\0", count: text.utf16.count + 1) }
check("纯中文、中英混排、ASCII 开头：前面加 BOM，补等长的 NUL",
      ["鲁汶市政厅", "鲁汶 City Hall", "Note: 鲁汶"].map(userCommentForHEIFWriter),
      [writerForm("鲁汶市政厅"), writerForm("鲁汶 City Hall"), writerForm("Note: 鲁汶")])
check("已带 BOM 的不再加；尾部 NUL 先去掉再补",
      [userCommentForHEIFWriter("\u{FEFF}鲁汶"), userCommentForHEIFWriter("鲁汶\0\0\0")], [writerForm("鲁汶"), writerForm("鲁汶")])
check("纯 ASCII 原样返回（连尾部 NUL 也不动）", userCommentForHEIFWriter("Leuven\0"), "Leuven\0")

print("备注的读法：任意字节不崩")
var readerSamples: [[UInt8]] = []
for head in [Array("ASCII\0\0\0".utf8), unicodeHeadBytes, jisHeadBytes, [UInt8](repeating: 0, count: 8), []] {
    let full = head + utf8LuWen + gbkXiHu + [0xFE, 0xFF, 0xD8, 0x00, 0, 0x20]
    for n in 0...full.count { readerSamples.append(Array(full.prefix(n))) }
}
for _ in 0..<5000 { readerSamples.append((0..<carryRandom(40)).map { _ in UInt8(carryRandom(256)) }) }
var readerBroken = 0
for sample in readerSamples {
    switch readUserComment(sample) {
    case .absent: break
    case .reliable(let text, _): if normalizedUserComment(text).isEmpty { readerBroken += 1 }
    case .guessed(_, let raw, _): if raw != sample { readerBroken += 1 }
    }
}
check("每种头截断到每个长度、随机字节 5000 段都不崩；可靠的文本非空，猜的带着原样的值字节", readerBroken, 0)

print("备注改写：只动 0x9286 那一条的 10 个字节，新值接在块末尾")
/// 手搭的 TIFF：IFD0 只有一个 ExifIFD 指针（指向偏移 26），ExifIFD 的条目是（标签, 类型, 个数,
/// 4 字节值域），表后接 `tail`。`exifPointer` 改写指针，`ifd0Tag` 改写 IFD0 那一条的标签号。
func commentTIFF(bigEndian: Bool, _ entries: [(Int, Int, Int, [UInt8])], tail: [UInt8] = [],
                 exifPointer: Int = 26, ifd0Tag: Int = 0x8769) -> [UInt8] {
    func u16(_ v: Int) -> [UInt8] { bigEndian ? be(v, 2) : le16(v) }
    func u32(_ v: Int) -> [UInt8] { bigEndian ? be(v, 4) : le32(v) }
    var t: [UInt8] = (bigEndian ? [0x4D, 0x4D, 0, 42] : [0x49, 0x49, 42, 0]) + u32(8)
    t += u16(1) + u16(ifd0Tag) + u16(4) + u32(1) + u32(exifPointer) + u32(0)
    t += u16(entries.count)
    for (tag, type, count, value) in entries { t += u16(tag) + u16(type) + u32(count) + value }
    return t + u32(0) + tail
}
/// 一个条目的 ExifIFD 表之后（值从这里起）：26 + 2 + 12 + 4。
let afterExifTable = 44
let rawNote = Array("备注".utf8)   // 6 字节，没有字符集头
/// 按 3.2 的规定手算的改写结果（不调被测函数）：条目在 28，改 type/count/offset，补齐，接上 `value`。
func expectedRewrite(_ tiff: [UInt8], bigEndian: Bool, value: [UInt8], entry: Int = 28) -> [UInt8] {
    var out = tiff
    if out.count % 2 == 1 { out.append(0) }
    let at = out.count
    let fields = bigEndian ? be(7, 2) + be(value.count, 4) + be(at, 4) : le16(7) + le32(value.count) + le32(at)
    out.replaceSubrange((entry + 2)..<(entry + 12), with: fields)
    return out + value
}
func utf16Bytes(_ s: String, bigEndian: Bool) -> [UInt8] {
    s.utf16.flatMap { bigEndian ? be(Int($0), 2) : le16(Int($0)) }
}
let unicodeHead = Array("UNICODE\0".utf8), asciiHead = Array("ASCII\0\0\0".utf8)
// 源块：一条 0x9286（UNDEFINED，6 字节裸 UTF-8，值在表后），MM 的再多一个字节凑成奇数长。
let mmSource = commentTIFF(bigEndian: true, [(0x9286, 7, 6, be(afterExifTable, 4))], tail: rawNote + [0x55])
let iiSource = commentTIFF(bigEndian: false, [(0x9286, 7, 6, le32(afterExifTable))], tail: rawNote)
check("前提：MM 的源块是奇数长，II 的是偶数长", [mmSource.count % 2, iiSource.count % 2], [1, 0])
let emojiText = "鲁汶🎉"
let mmEmojiValue = unicodeHead + [0xFE, 0xFF] + utf16Bytes(emojiText, bigEndian: true)
let iiEmojiValue = unicodeHead + [0xFF, 0xFE] + utf16Bytes(emojiText, bigEndian: false)
check("MM、非 ASCII（含代理对）：只改那 10 个字节，补一个 0，接上 UNICODE + FEFF + 大端 UTF-16",
      rewritingUserComment(mmSource, text: emojiText), expectedRewrite(mmSource, bigEndian: true, value: mmEmojiValue))
check("II、非 ASCII（含代理对）：偶数长不补，接上 UNICODE + 小端 BOM + 小端 UTF-16",
      rewritingUserComment(iiSource, text: emojiText), expectedRewrite(iiSource, bigEndian: false, value: iiEmojiValue))
check("MM 奇数长：补的那个字节是 0，新值从偶数位置起",
      rewritingUserComment(mmSource, text: emojiText).map { [Int($0[mmSource.count]), (mmSource.count + 1) % 2] }, [0, 0])
check("MM、纯 ASCII：ASCII\\0\\0\\0 + 文本",
      rewritingUserComment(mmSource, text: "Leuven 2024"),
      expectedRewrite(mmSource, bigEndian: true, value: asciiHead + Array("Leuven 2024".utf8)))
check("II、纯 ASCII：ASCII\\0\\0\\0 + 文本",
      rewritingUserComment(iiSource, text: "Leuven 2024"),
      expectedRewrite(iiSource, bigEndian: false, value: asciiHead + Array("Leuven 2024".utf8)))
let inlineSource = commentTIFF(bigEndian: false, [(0x9286, 7, 3, Array("abc".utf8) + [0])])
check("值内联在条目里的（count ≤ 4）：照样改写，新值接在块末尾",
      rewritingUserComment(inlineSource, text: "abc"),
      expectedRewrite(inlineSource, bigEndian: false, value: asciiHead + Array("abc".utf8)))
let twoEntries = commentTIFF(bigEndian: true, [(0x9003, 2, 4, Array("2024".utf8)), (0x9286, 7, 6, be(56, 4))],
                             tail: rawNote)
check("0x9286 不是表里第一条：改的是它自己那一条",
      rewritingUserComment(twoEntries, text: "x"),
      expectedRewrite(twoEntries, bigEndian: true, value: asciiHead + [0x78], entry: 40))
let noExifIFD = commentTIFF(bigEndian: true, [(0x9286, 7, 6, be(afterExifTable, 4))], tail: rawNote, ifd0Tag: 0x8825)
check("不改写：没有 ExifIFD", rewritingUserComment(noExifIFD, text: "备注"), nil)
check("不改写：ExifIFD 里没有 0x9286",
      rewritingUserComment(commentTIFF(bigEndian: true, [(0x9003, 2, 4, Array("2024".utf8))]), text: "备注"), nil)
let dupSource = commentTIFF(bigEndian: true, [(0x9286, 7, 6, be(56, 4)), (0x9286, 7, 6, be(56, 4))], tail: rawNote)
check("不改写：两个 0x9286", rewritingUserComment(dupSource, text: "备注"), nil)
// 表说有 2 条，块在第 2 条中间结束：第 2 条可能也是 0x9286，拿不准。
let cutTable = Array(commentTIFF(bigEndian: true, [(0x9286, 7, 3, Array("abc".utf8) + [0]), (0x9286, 7, 3, [0, 0, 0, 0])])
    .prefix(26 + 2 + 12 + 6))
check("不改写：条目越出块", rewritingUserComment(cutTable, text: "abc"), nil)
check("不改写：ExifIFD 指针越出块",
      rewritingUserComment(commentTIFF(bigEndian: true, [(0x9286, 7, 6, be(afterExifTable, 4))], tail: rawNote,
                                       exifPointer: 0xFFF0), text: "备注"), nil)
check("不改写：文本是空的", rewritingUserComment(mmSource, text: ""), nil)

print("照搬过的产物认备注改写：P 与 S 逐字节相同，或恰好是 S 按源侧文本做的备注改写")
/// 源侧：ImageIO 读不出、自己解出了可靠的文本 `text`（无前缀）。
func unread(_ text: String) -> SourceUserComment {
    SourceUserComment(seenByImageIO: nil, reading: .reliable(text, header: .none))
}
let noComment = SourceUserComment(seenByImageIO: nil, reading: .absent)
let mmRewrite = expectedRewrite(mmSource, bigEndian: true, value: mmEmojiValue)
let iiRewrite = expectedRewrite(iiSource, bigEndian: false, value: iiEmojiValue)
let mmAsciiRewrite = expectedRewrite(mmSource, bigEndian: true, value: asciiHead + Array("Leuven".utf8))
let iiAsciiRewrite = expectedRewrite(iiSource, bigEndian: false, value: asciiHead + Array("Leuven".utf8))
check("接受：逐字节相同（源侧没有要修补的备注）", carriedTIFFMatches(source: mmSource, product: mmSource, comment: noComment), true)
check("接受：逐字节相同（源侧有要修补的备注，照原样照搬的）",
      carriedTIFFMatches(source: mmSource, product: mmSource, comment: unread(emojiText)), true)
check("接受：标准的改写，MM、II、ASCII、非 ASCII",
      [carriedTIFFMatches(source: mmSource, product: mmRewrite, comment: unread(emojiText)),
       carriedTIFFMatches(source: iiSource, product: iiRewrite, comment: unread(emojiText)),
       carriedTIFFMatches(source: mmSource, product: mmAsciiRewrite, comment: unread("Leuven")),
       carriedTIFFMatches(source: iiSource, product: iiAsciiRewrite, comment: unread("Leuven"))], [true, true, true, true])
check("接受：改写函数自己的输出（MM、II）",
      [carriedTIFFMatches(source: mmSource, product: rewritingUserComment(mmSource, text: emojiText)!, comment: unread(emojiText)),
       carriedTIFFMatches(source: iiSource, product: rewritingUserComment(iiSource, text: "Leuven")!, comment: unread("Leuven"))],
      [true, true])
/// 改写结果上再动一处，期望被拒。
func rejected(_ product: [UInt8], source: [UInt8] = mmSource, text: String = emojiText,
              seenByImageIO: String? = nil) -> Bool {
    !carriedTIFFMatches(source: source, product: product,
                        comment: SourceUserComment(seenByImageIO: seenByImageIO, reading: .reliable(text, header: .none)))
}
var extraByte = mmRewrite
extraByte[13] ^= 0x01   // IFD0 那一条的类型
check("报出：改写之外另有一个字节不同", rejected(extraByte), true)
var oldNoteTouched = mmRewrite
oldNoteTouched[afterExifTable] = 0   // 旧的备注字节
check("报出：旧的备注字节被清零", rejected(oldNoteTouched), true)
check("报出：尾部文本与源侧文本不同", rejected(mmRewrite, text: "鲁汶🎈"), true)
check("报出：尾部是没有 BOM 的 UTF-16",
      rejected(expectedRewrite(mmSource, bigEndian: true, value: unicodeHead + utf16Bytes(emojiText, bigEndian: true))), true)
check("报出：小端块里 BOM 与 UTF-16 是大端的",
      rejected(expectedRewrite(iiSource, bigEndian: false, value: mmEmojiValue), source: iiSource), true)
check("报出：非 ASCII 文本用了 ASCII 头加 UTF-8",
      rejected(expectedRewrite(mmSource, bigEndian: true, value: asciiHead + Array(emojiText.utf8))), true)
check("报出：纯 ASCII 文本用了 UNICODE 写法",
      rejected(expectedRewrite(mmSource, bigEndian: true, value: unicodeHead + [0xFE, 0xFF] + utf16Bytes("Leuven", bigEndian: true)),
               text: "Leuven"), true)
var pointsElsewhere = mmRewrite
pointsElsewhere.replaceSubrange(36..<40, with: be(afterExifTable, 4))   // offset 指回旧的备注
check("报出：条目指向别处", rejected(pointsElsewhere), true)
check("报出：尾部多一个字节", rejected(mmRewrite + [0]), true)
var badPadding = mmRewrite
badPadding[mmSource.count] = 0xAA
check("报出：补齐字节不是 0", rejected(badPadding), true)
check("报出：源的备注 ImageIO 读得出却被改写", rejected(mmRewrite, seenByImageIO: emojiText), true)
var notUndefined = mmRewrite
notUndefined.replaceSubrange(30..<32, with: be(2, 2))
check("报出：type 不是 7", rejected(notUndefined), true)
check("报出：源里两个 0x9286 时不认改写",
      rejected(expectedRewrite(dupSource, bigEndian: true, value: asciiHead + [0x78]), source: dupSource, text: "x"), true)
check("carriedExifIssues 接上这条规则：改写过的不报，源侧备注读得出时照报",
      [carriedExifIssues(source: jpegWithExif(mmSource),
                         dest: try! carryingExif(mmRewrite, into: buildHEIF(HEIFSpec()).bytes).get(),
                         comment: unread(emojiText)).count,
       carriedExifIssues(source: jpegWithExif(mmSource),
                         dest: try! carryingExif(mmRewrite, into: buildHEIF(HEIFSpec()).bytes).get(),
                         comment: noComment).count], [0, 1])

print("备注改写：任意字节不崩、不越界")
var rewriteCrashes = 0
for sample in [mmSource, iiSource, inlineSource, twoEntries] {
    for n in 0...sample.count { _ = rewritingUserComment(Array(sample.prefix(n)), text: emojiText) }
    for i in 0..<sample.count {
        for value: UInt8 in [0x00, 0xFF, sample[i] ^ 0x80] {
            var mutated = sample
            mutated[i] = value
            if let out = rewritingUserComment(mutated, text: emojiText),
               !carriedTIFFMatches(source: mutated, product: out, comment: unread(emojiText)) { rewriteCrashes += 1 }
        }
    }
}
for _ in 0..<5000 {
    var bad = mmRewrite
    for _ in 0...carryRandom(4) { bad[carryRandom(bad.count)] = UInt8(carryRandom(256)) }
    _ = carriedTIFFMatches(source: mmSource, product: bad, comment: unread(emojiText))
    _ = carriedTIFFMatches(source: bad, product: mmRewrite, comment: unread(emojiText))
    _ = rewritingUserComment(bad, text: emojiText)
}
check("截断到每个长度、每个字节改成 00/FF/翻最高位都不崩，改写了的都认得出；随机改坏 5000 次不崩",
      rewriteCrashes, 0)

print("备注原文核对：可靠的文本要相等，猜的要逐字节相同")
let luWenNoHead = Array("鲁汶市政厅".utf8)
let luWenUnicodeBOM = unicodeHead + [0xFE, 0xFF] + utf16Bytes("鲁汶市政厅", bigEndian: true) + [0, 0, 0, 0]
/// 两边的 TIFF 默认都是大端（ImageIO 写的 HEIC 就是）。
func originalIssues(_ s: [UInt8]?, _ p: [UInt8]?, sourceBE: Bool = true, productBE: Bool = true,
                    elsewhere: Bool = false) -> [String] {
    userCommentOriginalIssues(source: s, sourceBigEndian: sourceBE, product: p, productBigEndian: productBE,
                              reportedElsewhere: elsewhere)
}
check("源里没有备注：产物怎样都不报", [originalIssues(nil, luWenNoHead), originalIssues(asciiHead + [0, 0], nil)], [[], []])
check("可靠：换了写法（无前缀 → UNICODE + BOM + 尾部 NUL）而原文相同，不报",
      originalIssues(luWenNoHead, luWenUnicodeBOM), [])
check("可靠：比之前去掉开头的 BOM（产物 UNICODE + 大端 BOM，小端 BOM）",
      [originalIssues(luWenNoHead, unicodeHead + [0xFE, 0xFF] + utf16Bytes("鲁汶市政厅", bigEndian: true)),
       originalIssues(luWenNoHead, unicodeHead + [0xFF, 0xFE] + utf16Bytes("鲁汶市政厅", bigEndian: false))], [[], []])
check("可靠：比之前去掉尾部的 NUL 与空白（两边各自）",
      [originalIssues(luWenNoHead + [0, 0, 0], unicodeHead + utf16Bytes("鲁汶市政厅", bigEndian: true) + [0, 0x20]),
       originalIssues(asciiHead + Array("Leuven \n".utf8), asciiHead + Array("Leuven".utf8) + [0, 0])], [[], []])
check("可靠：原文变了，报出两边的原文",
      originalIssues(asciiHead + utf8LuWen, asciiHead + Array("é²".utf8)),
      ["变化 备注 UserComment 的原文：鲁汶 → é²"])
check("可靠：产物没有 0x9286、或只有头和填充，报原文丢失",
      [originalIssues(luWenNoHead, nil), originalIssues(luWenNoHead, unicodeHead + [0, 0, 0, 0])],
      [["丢失 备注 UserComment 的原文 = 鲁汶市政厅"], ["丢失 备注 UserComment 的原文 = 鲁汶市政厅"]])
check("可靠：产物里的值解不出可靠的文本，报原文变化",
      originalIssues(luWenNoHead, gbkXiHu), ["变化 备注 UserComment 的原文：鲁汶市政厅 → （4 字节，不是合法的 UTF-8）"])
let longComment = String(repeating: "长", count: 70)
check("可靠：差别在显示截断之后，注明从第几个字符起不同",
      originalIssues(Array((longComment + "甲").utf8), Array((longComment + "乙").utf8)),
      ["变化 备注 UserComment 的原文：\(truncate(longComment)) → \(truncate(longComment))（显示相同，第 71 个字符起不同）"])
// UNICODE 头没有 BOM 的值按它所在 TIFF 的字节序解。产物取系统重写的样子：「ImageIO 按大端读出、
// 带 BOM 写回」，产物的 TIFF 是大端。
func imageIOBigEndianRewrite(_ body: [UInt8]) -> [UInt8] {
    let seen = String(bytes: body, encoding: .utf16BigEndian)!
    return unicodeHead + [0xFE, 0xFF] + utf16Bytes(seen, bigEndian: true) + [0, 0, 0, 0]
}
let emojiBE = utf16Bytes("🎉拍照😀好看👍今天", bigEndian: true)
let luWenBE = utf16Bytes("鲁汶市政厅", bigEndian: true), luWenLE = utf16Bytes("鲁汶市政厅", bigEndian: false)
let luWenLEReadAsBE = String(bytes: luWenLE, encoding: .utf16BigEndian)!
let luWenBEReadAsLE = String(bytes: luWenBE, encoding: .utf16LittleEndian)!
check("大端块、大端无 BOM + emoji：按大端解就是原文，系统重写的产物不报",
      originalIssues(unicodeHead + emojiBE, imageIOBigEndianRewrite(emojiBE)), [])
check("大端块、大端无 BOM + 纯中文：系统重写的产物不报，原样照搬的不报",
      [originalIssues(unicodeHead + luWenBE, imageIOBigEndianRewrite(luWenBE)),
       originalIssues(unicodeHead + luWenBE, unicodeHead + luWenBE)], [[], []])
check("小端块、小端无 BOM + 中文：原样照搬（两边都是小端块）不报",
      originalIssues(unicodeHead + luWenLE, unicodeHead + luWenLE, sourceBE: false, productBE: false), [])
check("小端块、小端无 BOM + 中文：系统重写把 ImageIO 按大端读出的乱码带 BOM 写进产物，报原文变化",
      originalIssues(unicodeHead + luWenLE, imageIOBigEndianRewrite(luWenLE), sourceBE: false),
      ["变化 备注 UserComment 的原文：鲁汶市政厅 → \(luWenLEReadAsBE)"])
check("大端块、小端无 BOM（不合约定）：两边按同一规则都读成那串乱码，不报（已知的漏网）",
      originalIssues(unicodeHead + luWenLE, imageIOBigEndianRewrite(luWenLE)), [])
check("小端块、大端无 BOM（不合约定，ImageIO 读得对）：系统重写的产物被报成变化（已知的多报）",
      originalIssues(unicodeHead + luWenBE, imageIOBigEndianRewrite(luWenBE), sourceBE: false),
      ["变化 备注 UserComment 的原文：\(luWenBEReadAsLE) → 鲁汶市政厅"])
// 小端块里 00 D8 41 00：按小端是落单的高代理项，解不出；按大端解得出（0x00D8 0x4100）。
let loneSurrogateLE = unicodeHead + [0x00, 0xD8, 0x41, 0x00]
check("按 TIFF 字节序解不出：当猜的，字节相同不报，换了写法报",
      [originalIssues(loneSurrogateLE, loneSurrogateLE, sourceBE: false, productBE: false),
       originalIssues(loneSurrogateLE, unicodeHead + [0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x41], sourceBE: false)],
      [[], ["变化 备注 UserComment：源里的字节按 UNICODE 头解不出（12 字节），产物里换了一种写法，原文无法核对"]])
check("产物一侧是没有 BOM 的 UNICODE：按产物 TIFF 的字节序解，小端块里的小端 UTF-16 等于原文",
      originalIssues(luWenNoHead, unicodeHead + luWenLE, productBE: false), [])
check("产物一侧是没有 BOM 的 UNICODE：同样的字节放在大端块里就读成乱码，报",
      originalIssues(luWenNoHead, unicodeHead + luWenLE, productBE: true),
      ["变化 备注 UserComment 的原文：鲁汶市政厅 → \(luWenLEReadAsBE)"])
check("猜的：产物的值字节与源逐字节相同，不报",
      [originalIssues(gbkXiHu, gbkXiHu), originalIssues(asciiHead + gbkXiHu, asciiHead + gbkXiHu)], [[], []])
check("猜的：产物换成 UNICODE 写的 Latin-1 猜测串，报换了写法",
      originalIssues(gbkXiHu, unicodeHead + [0xFE, 0xFF] + utf16Bytes(gbkGuess, bigEndian: true)),
      ["变化 备注 UserComment：源里的字节不是合法的 UTF-8（4 字节），产物里换了一种写法，原文无法核对"])
check("猜的：产物的猜测串与源相同、字节不同（换了头）也报：比的是字节不是文本",
      originalIssues(gbkXiHu, asciiHead + gbkXiHu),
      ["变化 备注 UserComment：源里的字节不是合法的 UTF-8（4 字节），产物里换了一种写法，原文无法核对"])
check("猜的：产物没有备注，报丢失",
      [originalIssues(asciiHead + gbkXiHu, nil), originalIssues(asciiHead + gbkXiHu, asciiHead + [0x20])],
      [["丢失 备注 UserComment（12 字节，不是合法的 UTF-8）"], ["丢失 备注 UserComment（12 字节，不是合法的 UTF-8）"]])
check("猜的：JIS 头解不出的照报，写明是按 JIS 头解不出",
      originalIssues(jisHeadBytes + [0xFF, 0xFF], jisHeadBytes + [0xFF, 0xFE]),
      ["变化 备注 UserComment：源里的字节按 JIS 头解不出（10 字节），产物里换了一种写法，原文无法核对"])
check("让位：同一处已经有一行时，表里每一种该报的都不报",
      [originalIssues(luWenNoHead, nil, elsewhere: true), originalIssues(luWenNoHead, gbkXiHu, elsewhere: true),
       originalIssues(gbkXiHu, luWenNoHead, elsewhere: true), originalIssues(gbkXiHu, nil, elsewhere: true)], [[], [], [], []])
let commentViewKey = "{Exif}/UserComment"
check("让位的条件：键空间比对报了备注丢失或变化，或者原始清点报了 0x9286 丢失",
      [userCommentReportedElsewhere(before: [commentViewKey: "鲁汶"], after: [:], covered: [], rawLostTags: []),
       userCommentReportedElsewhere(before: [commentViewKey: "鲁汶"], after: [commentViewKey: "乱码"], covered: [], rawLostTags: []),
       userCommentReportedElsewhere(before: [:], after: [:], covered: [], rawLostTags: [0x9286]),
       userCommentReportedElsewhere(before: [commentViewKey: "鲁汶"], after: [commentViewKey: "鲁汶"], covered: [], rawLostTags: []),
       userCommentReportedElsewhere(before: [:], after: [commentViewKey: "乱码"], covered: [], rawLostTags: [0x9208]),
       userCommentReportedElsewhere(before: [commentViewKey: "鲁汶"], after: [:], covered: [commentViewKey], rawLostTags: [])],
      [true, true, true, false, false, false])
// 同一处只出一行：源的备注 ImageIO 读得对，产物里没了。键空间比对报丢失，原文核对让位。
let viewBefore = [commentViewKey: "鲁汶市政厅"]
let oneLine = keySpaceDiff(before: viewBefore, after: [:])
    + originalIssues(luWenNoHead, nil, elsewhere: userCommentReportedElsewhere(before: viewBefore, after: [:], covered: [],
                                                                              rawLostTags: []))
check("同一处的备注差异只出一行", oneLine.filter { $0.contains("UserComment") }.count, 1)
var commentCrashes = 0
for _ in 0..<5000 {
    let a = (0..<carryRandom(30)).map { _ in UInt8(carryRandom(256)) }
    var b = luWenUnicodeBOM
    for _ in 0...carryRandom(3) { b[carryRandom(b.count)] = UInt8(carryRandom(256)) }
    for (s, p) in [(a, b), (b, a), (Array(b.prefix(carryRandom(b.count + 1))), a)] {
        let lines = originalIssues(s, p)
        if s == p, !lines.isEmpty { commentCrashes += 1 }
    }
}
check("随机字节、截断 5000 组都不崩，两边字节相同时从不报", commentCrashes, 0)

print("不一致键集合：照搬 EXIF 的自检与 keySpaceDiff 用同一把尺子")
let sourceView = ["{TIFF}/Model": "Canon", "{Exif}/UserComment": "备注", "{IPTC}/DateCreated": "20240915"]
check("等价字段同值承载的键不算不一致，源里没有的承载者本身照算",
      inconsistentKeys(before: sourceView, after: sourceView.merging(["{Exif}/DateTimeOriginal": "2024:09:15 18:42:07"]) { a, _ in a }
                       .filter { $0.key != "{IPTC}/DateCreated" }), ["{Exif}/DateTimeOriginal"])
let regressed = inconsistentKeys(before: sourceView, after: ["{TIFF}/Model": "Canon"])
    .subtracting(inconsistentKeys(before: sourceView, after: sourceView))
check("一致 → 不一致（读不出）算退步", regressed, ["{Exif}/UserComment", "{IPTC}/DateCreated"])
let wrongBefore = inconsistentKeys(before: sourceView, after: sourceView.merging(["{TIFF}/Model": "Nikon"]) { _, b in b })
let wrongAfter = inconsistentKeys(before: sourceView, after: sourceView.merging(["{TIFF}/Model": "Sony"]) { _, b in b })
check("不一致 → 换一个不一致的值不算退步", wrongAfter.subtracting(wrongBefore), [])
check("新出现且与源一致的键不算退步",
      inconsistentKeys(before: sourceView, after: sourceView)
          .subtracting(inconsistentKeys(before: sourceView, after: sourceView.filter { $0.key != "{TIFF}/Model" })), [])
check("新出现而源里没有的键算退步",
      inconsistentKeys(before: sourceView, after: sourceView.merging(["{MakerCanon}/LensModel": "EF"]) { a, _ in a })
          .subtracting(inconsistentKeys(before: sourceView, after: sourceView)), ["{MakerCanon}/LensModel"])
check("尺子不比的键新出现也不算", inconsistentKeys(before: sourceView, after: sourceView.merging(["PixelWidth": "100"]) { a, _ in a }), [])
check("MakerNote 派生键丢失按键逐个算",
      inconsistentKeys(before: ["{MakerCanon}/a": "1", "{MakerCanon}/b": "2"], after: [:]), ["{MakerCanon}/a", "{MakerCanon}/b"])

print("EXIF 文字标签的原文：去掉尾部填充后是合法的 UTF-8 才可靠")
check("没有这个标签、全是填充：当作没有", [readExifText(nil), readExifText([]), readExifText([0, 0x20, 0x0A, 0])],
      [ExifTextReading.absent, .absent, .absent])
check("ASCII、UTF-8：可靠，去掉尾部的 NUL 与空白", [readExifText(Array("West Lake".utf8) + [0, 0x20, 0]),
                                                  readExifText(Array("西湖日落 ".utf8))],
      [ExifTextReading.reliable("West Lake"), .reliable("西湖日落")])
check("Copyright 两段：中间的 NUL 照留，只去最尾部的",
      readExifText(Array("摄影师".utf8) + [0] + Array("编辑者".utf8) + [0]), .reliable("摄影师\0编辑者"))
check("GBK：不可靠，带去掉填充后的字节与值的全部字节数",
      readExifText(gbkXiHu + [0, 0]), .unreliable(bytes: gbkXiHu, size: 6))
let textTIFF = tiffLE([(0x010E, 2, 8, le32(8 + 2 + 3 * 12 + 4)), (0x013B, 2, 4, Array("Ann".utf8) + [0]),
                       (0x8298, 2, 4, gbkXiHu)], tail: Array("Sunset ".utf8) + [0])
check("从 IFD0 读出三组的原文",
      exifTextOriginals(TIFFStructure(textTIFF, base: 0, length: textTIFF.count)),
      [.description: .reliable("Sunset"), .artist: .reliable("Ann"), .copyright: .unreliable(bytes: gbkXiHu, size: 4)])
check("没有 EXIF：三组都没有", exifTextOriginals(nil), [.description: .absent, .artist: .absent, .copyright: .absent])

print("照搬自检的放行：新退步的键属于说明、作者、版权之一，且照搬后等于 EXIF 原文")
let keptOriginals: [ReconciledGroup: ExifTextReading] =
    [.description: .reliable("西湖日落"), .artist: .reliable("测试作者"), .copyright: .reliable("(C) 2024")]
for (key, value, group) in [("{TIFF}/ImageDescription", "西湖日落", ReconciledGroup.description),
                            ("{IPTC}/Caption/Abstract", "西湖日落", .description),
                            ("XMP/dc:description[x-default]", "西湖日落", .description),
                            ("{TIFF}/Artist", "测试作者", .artist), ("{IPTC}/Byline[0]", "测试作者", .artist),
                            ("XMP/dc:creator[0]", "测试作者", .artist),
                            ("{TIFF}/Copyright", "(C) 2024", .copyright), ("{IPTC}/CopyrightNotice", "(C) 2024", .copyright),
                            ("XMP/dc:rights[x-default]", "(C) 2024", .copyright)] {
    checkRule(key, exifOriginalKept(key: key, value: value, originals: keptOriginals), group, "属于该组且等于 EXIF 原文：放行")
}
for (key, value, why) in [("{TIFF}/ImageDescription", "IIM 的说明", "等于别的值：不放行"),
                          ("XMP/dc:creator[0]", "西湖日落", "等于别组的原文：不放行"),
                          ("{IPTC}/Byline[1]", "IIM 作者", "带下标的键等于别的值：不放行"),
                          ("{Exif}/DateTimeOriginal", "西湖日落", "不属于任何组：不放行"),
                          ("{TIFF}/ImageDescriptionX", "西湖日落", "名字里含组的键不算：不放行"),
                          ("XMP/dc:description[x-default]/x", "西湖日落", "下标后面还有子路径不算：不放行")] {
    checkRule(key, exifOriginalKept(key: key, value: value, originals: keptOriginals), nil, why)
}
check("照搬后读不出：不放行", exifOriginalKept(key: "{TIFF}/Artist", value: nil, originals: keptOriginals), nil)
check("EXIF 原文不可靠（GBK）、没有：不放行",
      [exifOriginalKept(key: "{TIFF}/ImageDescription", value: "Î÷ºþ",
                        originals: [.description: .unreliable(bytes: gbkXiHu, size: 4)]),
       exifOriginalKept(key: "{TIFF}/ImageDescription", value: "", originals: [.description: .absent])],
      [ReconciledGroup?.none, nil])
let split = splitRegressions(["{TIFF}/Copyright", "XMP/dc:description[x-default]", "{TIFF}/ImageDescription",
                              "{Exif}/DateTimeOriginal", "{IPTC}/Byline[0]"],
                             afterView: ["{TIFF}/Copyright": "(C) 2024", "XMP/dc:description[x-default]": "西湖日落",
                                         "{TIFF}/ImageDescription": "西湖日落", "{Exif}/DateTimeOriginal": "2024:09:15 10:42:07",
                                         "{IPTC}/Byline[0]": "别人"],
                             originals: keptOriginals)
check("放行的归到组、按说明/作者/版权的顺序，其余是真退步",
      [split.blocking == ["{Exif}/DateTimeOriginal", "{IPTC}/Byline[0]"], split.kept == [.description, .copyright]],
      [true, true])
check("-v 那一行写明哪几组保留了 EXIF 的原值，与备注改写可以同时出现",
      [RawExifOutcome.carried(bytes: 786, commentRewritten: false, keptOriginals: [.description, .artist]).description,
       RawExifOutcome.carried(bytes: 786, commentRewritten: true, keptOriginals: [.copyright]).description,
       RawExifOutcome.carried(bytes: 786, commentRewritten: false).description],
      ["EXIF 整块照搬（786 字节；说明、作者与 IPTC 不一致，保留 EXIF 的原值）",
       "EXIF 整块照搬（786 字节，备注改写成 ImageIO 读得出的写法；版权与 IPTC 不一致，保留 EXIF 的原值）",
       "EXIF 整块照搬（786 字节）"])
var exifTextCrashes = 0
for _ in 0..<5000 {
    var t = textTIFF
    for _ in 0...carryRandom(4) { t[carryRandom(t.count)] = UInt8(carryRandom(256)) }
    let originals = exifTextOriginals(TIFFStructure(Array(t.prefix(carryRandom(t.count + 1))), base: 0,
                                                    length: max(0, carryRandom(t.count + 1))))
    let raw = (0..<carryRandom(12)).map { _ in UInt8(carryRandom(256)) }
    if case .reliable(let s) = readExifText(raw), s.isEmpty { exifTextCrashes += 1 }
    _ = exifOriginalKept(key: "{TIFF}/Artist", value: String(decoding: raw, as: UTF8.self), originals: originals)
}
check("改坏的 TIFF、随机字节 5000 组不崩，可靠的原文从不为空", exifTextCrashes, 0)

print("校验：EXIF 与 IPTC 打架的那一组合成一行，键空间比对让位")
let conflictBefore = ["{TIFF}/ImageDescription": "IIM 说明", "{IPTC}/Caption/Abstract": "IIM 说明",
                      "XMP/dc:description[x-default]": "IIM 说明", "{TIFF}/Model": "Canon"]
let conflictAfter = ["{TIFF}/ImageDescription": "西湖日落", "{IPTC}/Caption/Abstract": "西湖日落",
                     "XMP/dc:description[x-default]": "西湖日落", "{TIFF}/Model": "Canon"]
let descriptionLine = "变化 说明：源里 EXIF 与 IPTC 不一致，ImageIO 原来显示「IIM 说明」，产物显示 EXIF 的原值「西湖日落」"
let merged = reconciledConflicts(before: conflictBefore, after: conflictAfter, originals: keptOriginals)
check("三个键 V → A 合成一行，三个键都记进 covered",
      [merged.issues == [descriptionLine],
       merged.covered == ["{TIFF}/ImageDescription", "{IPTC}/Caption/Abstract", "XMP/dc:description[x-default]"]],
      [true, true])
check("键空间比对按 covered 让位：一处只出那一行",
      keySpaceDiff(before: conflictBefore, after: conflictAfter, covered: merged.covered) + merged.issues, [descriptionLine])
check("组里另一个键是别的变法（既不是 V 也不是 A）：照旧由键空间比对单独报",
      { () -> [String] in
          var after = conflictAfter
          after["{IPTC}/Caption/Abstract"] = "第三种"
          let m = reconciledConflicts(before: conflictBefore, after: after, originals: keptOriginals)
          return keySpaceDiff(before: conflictBefore, after: after, covered: m.covered) + m.issues
      }(), ["变化 {IPTC}/Caption/Abstract: IIM 说明 → 第三种", descriptionLine])
check("组里两个键的 V 不同：各合成一行（按键排序后 V 第一次出现的顺序）",
      reconciledConflicts(before: conflictBefore.merging(["{IPTC}/Caption/Abstract": "乱码"]) { _, b in b },
                          after: conflictAfter, originals: keptOriginals).issues,
      [descriptionLine, "变化 说明：源里 EXIF 与 IPTC 不一致，ImageIO 原来显示「乱码」，产物显示 EXIF 的原值「西湖日落」"])
let threeBefore = conflictBefore.merging(["{TIFF}/Artist": "IIM 作者", "{IPTC}/Byline[0]": "IIM 作者",
                                          "{TIFF}/Copyright": "IIM 版权", "XMP/dc:rights[x-default]": "IIM 版权"]) { a, _ in a }
let threeAfter = conflictAfter.merging(["{TIFF}/Artist": "测试作者", "{IPTC}/Byline[0]": "测试作者",
                                        "{TIFF}/Copyright": "(C) 2024", "XMP/dc:rights[x-default]": "(C) 2024"]) { a, _ in a }
let three = reconciledConflicts(before: threeBefore, after: threeAfter, originals: keptOriginals)
check("三组同时打架：三行，按说明、作者、版权；键空间比对一行都不出",
      keySpaceDiff(before: threeBefore, after: threeAfter, covered: three.covered) + three.issues,
      [descriptionLine,
       "变化 作者：源里 EXIF 与 IPTC 不一致，ImageIO 原来显示「IIM 作者」，产物显示 EXIF 的原值「测试作者」",
       "变化 版权：源里 EXIF 与 IPTC 不一致，ImageIO 原来显示「IIM 版权」，产物显示 EXIF 的原值「(C) 2024」"])
check("不合成：EXIF 原文不可靠或没有、产物不是 A、产物没有这个键、源里本来就是 A",
      [reconciledConflicts(before: conflictBefore, after: conflictAfter,
                           originals: [.description: .unreliable(bytes: gbkXiHu, size: 4)]).issues,
       reconciledConflicts(before: conflictBefore, after: conflictAfter, originals: [.description: .absent]).issues,
       reconciledConflicts(before: conflictBefore, after: conflictAfter.mapValues { _ in "别的" },
                           originals: keptOriginals).issues,
       reconciledConflicts(before: conflictBefore, after: [:], originals: keptOriginals).issues,
       reconciledConflicts(before: conflictAfter, after: conflictAfter, originals: keptOriginals).issues],
      [[], [], [], [], []])

print("校验：三个文字标签的原文核对（与备注原文核对同一套判定）")
func textIssues(_ group: ReconciledGroup, _ s: [UInt8]?, _ p: [UInt8]?, elsewhere: Bool = false) -> [String] {
    exifTextOriginalIssues(group, source: s, product: p, reportedElsewhere: elsewhere)
}
/// 说明那一组。
func textIssues(_ s: [UInt8]?, _ p: [UInt8]?, elsewhere: Bool = false) -> [String] {
    textIssues(.description, s, p, elsewhere: elsewhere)
}
let westLake = Array("西湖日落 sunset".utf8) + [0]
check("原文相同不报；源里没有不报", [textIssues(westLake, westLake), textIssues(nil, westLake)], [[], []])
check("原文变了：报两边的原文", textIssues(westLake, Array("IPTC 备注字段".utf8) + [0]),
      ["变化 EXIF 说明 ImageDescription 的原文：西湖日落 sunset → IPTC 备注字段"])
check("产物里没有这个标签、或只有填充：报原文丢失", [textIssues(.artist, Array("Ann".utf8), nil),
                                                textIssues(.artist, Array("Ann".utf8), [0, 0x20])],
      [["丢失 EXIF 作者 Artist 的原文 = Ann"], ["丢失 EXIF 作者 Artist 的原文 = Ann"]])
check("比较前两边各自去掉尾部的 NUL 与空白",
      [textIssues(Array("Ann  ".utf8) + [0, 0], Array("Ann".utf8) + [0]), textIssues(Array("Ann".utf8), Array("Ann\r\n".utf8))],
      [[], []])
check("源全是填充：当作没有，不报", textIssues([0x20, 0, 0], Array("别的".utf8)), [])
check("产物的值不是合法的 UTF-8：报原文变化", textIssues(westLake, gbkXiHu + [0]),
      ["变化 EXIF 说明 ImageDescription 的原文：西湖日落 sunset → （5 字节，不是合法的 UTF-8）"])
check("源不可靠：去掉填充后的字节相同不报，填充不同也不报",
      [textIssues(gbkXiHu + [0], gbkXiHu + [0]), textIssues(gbkXiHu + [0], gbkXiHu + [0, 0, 0x20])], [[], []])
check("源不可靠：产物换了写法（按 Latin-1 猜出的 UTF-8）报，产物没有报丢失",
      [textIssues(gbkXiHu + [0], Array("Î÷ºþ".utf8) + [0]), textIssues(gbkXiHu + [0], nil)],
      [["变化 EXIF 说明 ImageDescription：源里的字节不是合法的 UTF-8（5 字节），产物里换了一种写法，原文无法核对"],
       ["丢失 EXIF 说明 ImageDescription（5 字节，不是合法的 UTF-8）"]])
let twoPart = Array("Photographer".utf8) + [0] + Array("Editor".utf8) + [0]
check("Copyright 两段：第二段丢了要报，NUL 显示成 \\0；两段都在不报",
      [textIssues(.copyright, twoPart, Array("Photographer".utf8) + [0]), textIssues(.copyright, twoPart, twoPart)],
      [["变化 EXIF 版权 Copyright 的原文：Photographer\\0Editor → Photographer"], []])
check("让位：同一处已经有一行时都不报",
      [textIssues(westLake, nil, elsewhere: true), textIssues(westLake, gbkXiHu, elsewhere: true),
       textIssues(gbkXiHu, westLake, elsewhere: true)], [[], [], []])
let descKey = ReconciledGroup.description.tiffKey
check("让位的条件：键空间比对报了 {TIFF}/ImageDescription 丢失或变化，或原始清点报了 0x010E 丢失",
      [originalReportedElsewhere(key: descKey, tag: 0x010E, before: [descKey: "a"], after: [:], covered: [], rawLostTags: []),
       originalReportedElsewhere(key: descKey, tag: 0x010E, before: [descKey: "a"], after: [descKey: "b"], covered: [],
                                 rawLostTags: []),
       originalReportedElsewhere(key: descKey, tag: 0x010E, before: [:], after: [:], covered: [], rawLostTags: [0x010E]),
       originalReportedElsewhere(key: descKey, tag: 0x010E, before: [descKey: "a"], after: [descKey: "a"], covered: [],
                                 rawLostTags: []),
       originalReportedElsewhere(key: descKey, tag: 0x010E, before: [:], after: [:], covered: [], rawLostTags: [0x9286])],
      [true, true, true, false, false])
// 系统重写把 ImageIO 调和出的值写进 EXIF：两边视图一样（IIM 那份），键空间比对看不见，原文核对报。
let rewrittenView = [descKey: "IPTC 备注字段"]
check("两边视图相同而 EXIF 原文被换掉：键空间比对 0 行，原文核对报 1 行",
      keySpaceDiff(before: rewrittenView, after: rewrittenView)
          + textIssues(westLake, Array("IPTC 备注字段".utf8),
                       elsewhere: originalReportedElsewhere(key: descKey, tag: 0x010E, before: rewrittenView,
                                                            after: rewrittenView, covered: [], rawLostTags: [])),
      ["变化 EXIF 说明 ImageDescription 的原文：西湖日落 sunset → IPTC 备注字段"])
var conflictCrashes = 0
for _ in 0..<5000 {
    let a = (0..<carryRandom(16)).map { _ in UInt8(carryRandom(256)) }
    var b = twoPart
    for _ in 0...carryRandom(3) { b[carryRandom(b.count)] = UInt8(carryRandom(256)) }
    for (s, p) in [(a, b), (b, a), (Array(b.prefix(carryRandom(b.count + 1))), a)] {
        if s == p, !textIssues(.copyright, s, p).isEmpty { conflictCrashes += 1 }
    }
    let v = String(decoding: a, as: UTF8.self), w = String(decoding: b, as: UTF8.self)
    let m = reconciledConflicts(before: ["{TIFF}/Artist": v, "{IPTC}/Byline[0]": w], after: ["{TIFF}/Artist": w],
                                originals: [.artist: readExifText(b)])
    if m.issues.count > 1 { conflictCrashes += 1 }
}
check("随机字节 5000 组都不崩，两边字节相同时从不报，一组至多合成一行", conflictCrashes, 0)

print("{FileContents} 里的编码参数：按去掉下标后的完整键路径认")
check(isFileContentsEncodingKey("{FileContents}/Images[0]/ChromaSubsampling"), "主图的色度抽样忽略")
check(isFileContentsEncodingKey("{FileContents}/Images[12]/ChromaSubsampling"), "任何一张主图的色度抽样都忽略")
for (key, why) in [("{FileContents}/Images[0]/FlexRange", "FlexRange 照报"),
                   ("{FileContents}/Images[0]/AuxiliaryData[0]/ChromaSubsampling", "辅助图下面的同名键照报"),
                   ("{FileContents}/Images[0]/ChromaSubsamplingX", "名字里含它不算"),
                   ("{Exif}/ChromaSubsampling", "别的字典里同名的键不算")] {
    checkRule(key, isFileContentsEncodingKey(key), false, why)
}
check("keySpaceDiff 跳过色度抽样、照报宽",
      keySpaceDiff(before: ["{FileContents}/Images[0]/ChromaSubsampling": "4:2:2", "{FileContents}/Images[0]/Width": "8"],
                   after: ["{FileContents}/Images[0]/ChromaSubsampling": "4:2:0", "{FileContents}/Images[0]/Width": "9"]),
      ["变化 {FileContents}/Images[0]/Width: 8 → 9"])

print("辅助图按类型对齐：产物里换了顺序不算变化")
let auxSource = ["{FileContents}/Images[0]/AuxiliaryData[0]/AuxiliaryDataType": "kCGImageAuxiliaryDataTypeDepth",
                 "{FileContents}/Images[0]/AuxiliaryData[0]/Width": "150",
                 "{FileContents}/Images[0]/AuxiliaryData[1]/AuxiliaryDataType": "kCGImageAuxiliaryDataTypeHDRGainMap",
                 "{FileContents}/Images[0]/AuxiliaryData[1]/HDRHeadroom": "3.5"]
let auxReordered = ["{FileContents}/Images[0]/AuxiliaryData[1]/AuxiliaryDataType": "kCGImageAuxiliaryDataTypeDepth",
                    "{FileContents}/Images[0]/AuxiliaryData[1]/Width": "150",
                    "{FileContents}/Images[0]/AuxiliaryData[0]/AuxiliaryDataType": "kCGImageAuxiliaryDataTypeHDRGainMap",
                    "{FileContents}/Images[0]/AuxiliaryData[0]/HDRHeadroom": "3.5"]
check("换了顺序的两组键对齐后完全相同", keyingAuxiliaryDataByType(auxSource), keyingAuxiliaryDataByType(auxReordered))
check("键里写的是类型", keyingAuxiliaryDataByType(auxSource)["{FileContents}/Images[0]/AuxiliaryData[HDRGainMap]/HDRHeadroom"],
      "3.5")
check("对齐后少了一张照报丢失",
      keySpaceDiff(before: keyingAuxiliaryDataByType(auxSource),
                   after: keyingAuxiliaryDataByType(auxSource.filter { !$0.key.contains("AuxiliaryData[1]") })),
      ["丢失 {FileContents}/Images[0]/AuxiliaryData[HDRGainMap]/AuxiliaryDataType = kCGImageAuxiliaryDataTypeHDRGainMap",
       "丢失 {FileContents}/Images[0]/AuxiliaryData[HDRGainMap]/HDRHeadroom = 3.5"])
let twinTypes = ["{FileContents}/Images[0]/AuxiliaryData[0]/AuxiliaryDataType": "kCGImageAuxiliaryDataTypeDepth",
                 "{FileContents}/Images[0]/AuxiliaryData[1]/AuxiliaryDataType": "kCGImageAuxiliaryDataTypeDepth"]
check("同一张图里类型重复：照旧用下标", keyingAuxiliaryDataByType(twinTypes), twinTypes)

print("ISO 21496 版本标记段：恰好 32 字节的一律不报，多出字节照报")
// 它只有版本号。增益图丢没丢由尾部记账和辅助图的键比对管：这里的 JPEG 没有增益图，标记段照样不报。
let isoID = Array("urn:iso:std:iso:ts:21496:-1".utf8) + [0]
let isoJPEG = [0xFF, 0xD8] + jpegSegment(0xE2, isoID + [0, 0, 0, 0]) + [0xFF, 0xD9]
check("源里没有增益图、只有 32 字节的标记段：不报", unportableSegments(in: isoJPEG, carriedAuxiliary: []), [])
let longerMarker = [0xFF, 0xD8] + jpegSegment(0xE2, isoID + [0, 0, 0, 0, 7]) + [0xFF, 0xD9]
check("标识对、但不只版本号（多 1 字节）：照报", unportableSegments(in: longerMarker, carriedAuxiliary: []),
      ["丢失 APP2 段（urn:iso:std:iso:ts:21496:-1，33 字节）"])
let shorterMarker = [0xFF, 0xD8] + jpegSegment(0xE2, isoID + [0, 0, 0]) + [0xFF, 0xD9]
check("标识对、但少 1 字节：照报", unportableSegments(in: shorterMarker, carriedAuxiliary: []),
      ["丢失 APP2 段（urn:iso:std:iso:ts:21496:-1，31 字节）"])
let isoInAPP3 = [0xFF, 0xD8] + jpegSegment(0xE3, isoID + [0, 0, 0, 0]) + [0xFF, 0xD9]
check("同样的内容放在 APP3：照报", unportableSegments(in: isoInAPP3, carriedAuxiliary: []),
      ["丢失 APP3 段（urn:iso:std:iso:ts:21496:-1，32 字节）"])

print("产物比原图大")
check("大 33%", growthPercent(inBytes: 300, outBytes: 400), "33%")
check("一样大不算变大", growthPercent(inBytes: 300, outBytes: 300), nil)
check("变小不算", growthPercent(inBytes: 300, outBytes: 100), nil)
check("大不到 1% 不写成 0%", growthPercent(inBytes: 1000, outBytes: 1001), "不到 1%")
check("缺体积数据不算", growthPercent(inBytes: 0, outBytes: 100), nil)
var grownTally = BatchTally()
grownTally.recordConverted(inBytes: 300, outBytes: 400, hasIssues: false)
grownTally.recordConverted(inBytes: 300, outBytes: 100, hasIssues: false)
check("汇总单列变大的个数", grownTally.summary(unit: "个"), "完成 2 个，1 个比原图大，总计 600 B → 500 B，节省 17%")
var allGrown = BatchTally()
allGrown.recordConverted(inBytes: 300, outBytes: 400, hasIssues: false)
check("总体变大时写增大而不是负的节省", allGrown.summary(unit: "个"), "完成 1 个，1 个比原图大，总计 300 B → 400 B，增大 33%")

print("产物比原图大时重编一次：注入假的编码步骤")
// 硬件编码器偶发的大产物没法按需触发，这一组给 convert 注入假的编码步骤：按计划依次
// 写出给定字节数的文件（每遍的填充字节不同，好认出留下的是哪一份），nil 表示这一遍
// 失败（失败前先写几个字节，看临时文件有没有被清掉）。
let reencodeRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("glint-reencode-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: reencodeRoot, withIntermediateDirectories: true)
let reencodeSource = reencodeRoot.appendingPathComponent("源.jpg")
if let image = tinyJPEGSource().flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
   let out = CGImageDestinationCreateWithURL(reencodeSource as CFURL, "public.jpeg" as CFString, 1, nil) {
    CGImageDestinationAddImage(out, image, nil)
    _ = CGImageDestinationFinalize(out)
}
let sourceBytes = fileSize(reencodeSource)
check(sourceBytes > 8, "前提：造出了源 JPEG")
/// 按 `plan` 跑一次 convert。`kept` 是留下来的那一遍（从 0 数），nil 表示转换应当失败；
/// `grown` 是留下的产物该不该带「变大」的备注。
func expectReencode(_ name: String, _ plan: [Int?], calls: Int, kept: Int?, grown: Bool = false) {
    let folder = reencodeRoot.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var called = 0
    let fake: HEIFEncoder = { _, _, _, url in
        defer { called += 1 }
        guard called < plan.count, let size = plan[called] else {
            try? Data([0xEE, 0xEE]).write(to: url)
            return false
        }
        return (try? Data(repeating: UInt8(called + 1), count: size).write(to: url)) != nil
    }
    let dest = folder.appendingPathComponent("产物.heic")
    // 假产物不是图，画质核对会把它拦下；这一组只看重编，关掉核对。
    var opts = ConversionOptions()
    opts.qualityCheck = false
    let result = convert(reencodeSource, opts: opts, dest: dest, encode: fake)
    check("\(name)：编码步骤调用 \(calls) 次", called, calls)
    if let kept, let size = plan[kept] {
        guard case .converted(let r) = result else {
            fail("\(name)：转换没有成功（\(result)）"); fail("\(name)：outBytes"); fail("\(name)：变大备注")
            return
        }
        check("\(name)：留下第 \(kept + 1) 遍的产物",
              (try? Data(contentsOf: dest)) == Data(repeating: UInt8(kept + 1), count: size), true)
        check("\(name)：outBytes 是留下那份的大小", r.outBytes, size)
        check("\(name)：\(grown ? "有" : "没有")变大的备注",
              r.note?.contains("HEIF 比原图大") ?? false, grown)
    } else {
        guard case .failed = result else { fail("\(name)：转换应当失败（\(result)）"); return }
        pass("\(name)：转换失败")
    }
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter { $0.hasPrefix(".glint-") }
    check("\(name)：目标目录里不留临时文件", leftovers, [])
}
let big = sourceBytes * 3, bigger = sourceBytes * 4, small = sourceBytes / 2
expectReencode("先大后小", [big, small], calls: 2, kept: 1)
expectReencode("两次都大、第二次更小", [bigger, big], calls: 2, kept: 1, grown: true)
expectReencode("两次都大、第二次更大", [big, bigger], calls: 2, kept: 0, grown: true)
expectReencode("两次一样大", [big, big], calls: 2, kept: 0, grown: true)
expectReencode("先大、第二次失败", [big, nil], calls: 2, kept: 0, grown: true)
expectReencode("第一次不比源大", [sourceBytes, small], calls: 1, kept: 0)
expectReencode("第一次失败", [nil, small], calls: 1, kept: nil)
try? FileManager.default.removeItem(at: reencodeRoot)
check("-v 那一行：第二份更小", Reencode(first: 3_000_000, second: 787_824).description,
      "产物比原图大，重编了一次：2.9 MB → 769.4 KB（用了较小的一份）")
check("-v 那一行：两次一样大", Reencode(first: 2048, second: 2048).description,
      "产物比原图大，重编了一次：2.0 KB → 2.0 KB（两次一样大）")
check("-v 那一行：第二遍失败", Reencode(first: 2048, second: nil).description,
      "产物比原图大，重编了一次：2.0 KB → 重编失败（用了第一份）")

print("扩展属性核对：纯函数")
func binaryPlist(_ object: Any) -> [UInt8] {
    [UInt8]((try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)) ?? Data())
}
let xDescription = "com.apple.assetsd.description"
let xComment = "com.apple.metadata:kMDItemFinderComment"
let xTags = "com.apple.metadata:_kMDItemUserTags"
let xattrSource: [String: [UInt8]] = [
    xDescription: Array("西湖日落".utf8),
    xComment: binaryPlist("访达里的备注"),
    xTags: binaryPlist(["红色\n6", "工作"]),
    "user.custom": Array("abcdef".utf8),
    "com.apple.quarantine": Array("0081;00000000;Safari;".utf8),
    "com.apple.ResourceFork": [1, 2, 3],
]
let xattrCopied = xattrSource.filter { !skippedXattrs.contains($0.key) }
func withXattr(_ name: String, _ value: [UInt8]?) -> [String: [UInt8]] {
    var d = xattrCopied
    d[name] = value
    return d
}
check("同名同值、被跳过的两个产物上没有：不报", extendedAttributeDiff(source: xattrSource, product: xattrCopied), [])
check("产物多一个属性：不报",
      extendedAttributeDiff(source: xattrSource, product: withXattr("user.extra", [9])), [])
let xProvenance = "com.apple.provenance"
let provenanceSource = xattrSource.merging([xProvenance: [1, 2, 0, 3, 4, 5, 6, 7, 8, 9, 10]]) { $1 }
check("provenance 两边值不同：不报",
      extendedAttributeDiff(source: provenanceSource, product: withXattr(xProvenance, [1, 2, 0, 0xAA, 4, 5, 6, 7, 8, 9, 10])), [])
check("provenance 源有、产物没有：不报", extendedAttributeDiff(source: provenanceSource, product: xattrCopied), [])
check("源有 provenance 时别的属性丢了照旧报",
      extendedAttributeDiff(source: provenanceSource, product: withXattr("user.custom", nil)),
      ["丢失 扩展属性 user.custom（6 字节）"])
check("没有名字的属性丢了", extendedAttributeDiff(source: xattrSource, product: withXattr("user.custom", nil)),
      ["丢失 扩展属性 user.custom（6 字节）"])
check("等长改了一个字节：注明从第几个字节起不同",
      extendedAttributeDiff(source: xattrSource, product: withXattr("user.custom", Array("abcXef".utf8))),
      ["变化 扩展属性 user.custom（6 字节 → 6 字节，第 4 个字节起不同）"])
check("长度变了", extendedAttributeDiff(source: xattrSource, product: withXattr("user.custom", Array("abc".utf8))),
      ["变化 扩展属性 user.custom（6 字节 → 3 字节）"])
check("「照片」的说明丢了：显示说明的文本",
      extendedAttributeDiff(source: xattrSource, product: withXattr(xDescription, nil)),
      ["丢失 「照片」的说明（扩展属性 com.apple.assetsd.description）= 西湖日落"])
check("「照片」的说明变了",
      extendedAttributeDiff(source: xattrSource, product: withXattr(xDescription, Array("西湖日出".utf8))),
      ["变化 「照片」的说明（扩展属性 com.apple.assetsd.description）：西湖日落 → 西湖日出"])
check("访达备注丢了：显示 plist 里的字符串",
      extendedAttributeDiff(source: xattrSource, product: withXattr(xComment, nil)),
      ["丢失 访达备注（扩展属性 com.apple.metadata:kMDItemFinderComment）= 访达里的备注"])
check("访达标签丢了：显示标签名，去掉颜色编号",
      extendedAttributeDiff(source: xattrSource, product: withXattr(xTags, nil)),
      ["丢失 访达标签（扩展属性 com.apple.metadata:_kMDItemUserTags）= 红色、工作"])
check("访达标签变了", extendedAttributeDiff(source: xattrSource, product: withXattr(xTags, binaryPlist(["工作"]))),
      ["变化 访达标签（扩展属性 com.apple.metadata:_kMDItemUserTags）：红色、工作 → 工作"])
let rawComment: [String: [UInt8]] = [xComment: Array("不是 plist".utf8)]
check("访达备注解不出：只报字节数", extendedAttributeDiff(source: rawComment, product: [:]),
      ["丢失 访达备注（扩展属性 com.apple.metadata:kMDItemFinderComment，12 字节）"])
check("产物上的访达备注解不出", extendedAttributeDiff(source: xattrSource, product: withXattr(xComment, [0xFF])),
      ["变化 访达备注（扩展属性 com.apple.metadata:kMDItemFinderComment）：访达里的备注 → （\(xattrSource[xComment]!.count) 字节 → 1 字节，解不出）"])
check("说明不是合法的 UTF-8：只报字节数",
      extendedAttributeDiff(source: [xDescription: [0xE8, 0xA5]], product: [xDescription: [0xE8, 0xA6]]),
      ["变化 「照片」的说明（扩展属性 com.apple.assetsd.description，2 字节 → 2 字节，第 2 个字节起不同）"])
check("显示相同的长说明：补上字节数",
      extendedAttributeDiff(source: [xDescription: Array((String(repeating: "长", count: 70) + "甲").utf8)],
                            product: [xDescription: Array((String(repeating: "长", count: 70) + "乙").utf8)]),
      ["变化 「照片」的说明（扩展属性 com.apple.assetsd.description）：\(String(repeating: "长", count: 60))… → "
       + "\(String(repeating: "长", count: 60))…（显示相同，213 字节 → 213 字节，第 211 个字节起不同）"])
check("属性列表读不出：报无法核对",
      extendedAttributeIssues(source: "/不存在的路径/源.jpg", dest: "/不存在的路径/产物.heic"),
      ["无法核对扩展属性：读不出源文件的扩展属性"])

print("扩展属性核对：真实文件")
// 转一张带扩展属性的图，再动产物上的属性，看 metadataDiff 报什么。
let xattrRoot = FileManager.default.temporaryDirectory.appendingPathComponent("glint-xattr-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: xattrRoot, withIntermediateDirectories: true)
let xattrJPEG = xattrRoot.appendingPathComponent("源.jpg")
if let image = tinyJPEGSource().flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
   let out = CGImageDestinationCreateWithURL(xattrJPEG as CFURL, "public.jpeg" as CFString, 1, nil) {
    CGImageDestinationAddImage(out, image, nil)
    _ = CGImageDestinationFinalize(out)
}
for (name, value) in xattrSource { _ = setxattr(xattrJPEG.path, name, value, value.count, 0, XATTR_NOFOLLOW) }
check("前提：源上有给的 6 个扩展属性", extendedAttributes(xattrJPEG.path)?.filter { xattrSource[$0.key] != nil }, xattrSource)
let xattrHEIC = xattrRoot.appendingPathComponent("产物.heic")
if case .converted = convert(xattrJPEG, opts: ConversionOptions(), dest: xattrHEIC) {
    pass("前提：转换成功")
} else {
    fail("前提：转换成功")
}
let xattrBaseline = metadataDiff(source: xattrJPEG, dest: xattrHEIC)
check("转换后不报扩展属性（被跳过的两个产物上没有）", xattrBaseline.filter { $0.contains("扩展属性") }, [])
/// 产物上的属性还原成源上会被拷的那些，再做 `edit`，返回 metadataDiff 比转换后多出来的行。
func xattrIssuesAfter(_ edit: (String) -> Void) -> [String] {
    for name in extendedAttributeNames(xattrHEIC.path) ?? [] { _ = removexattr(xattrHEIC.path, name, XATTR_NOFOLLOW) }
    _ = copyExtendedAttributes(from: xattrJPEG.path, to: xattrHEIC.path)
    edit(xattrHEIC.path)
    return metadataDiff(source: xattrJPEG, dest: xattrHEIC).filter { !xattrBaseline.contains($0) }
}
func setX(_ path: String, _ name: String, _ value: [UInt8]) {
    _ = setxattr(path, name, value, value.count, 0, XATTR_NOFOLLOW)
}
check("删掉一个：报丢失", xattrIssuesAfter { _ = removexattr($0, "user.custom", XATTR_NOFOLLOW) },
      ["丢失 扩展属性 user.custom（6 字节）"])
check("改一个字节：报变化", xattrIssuesAfter { setX($0, "user.custom", Array("abcdeF".utf8)) },
      ["变化 扩展属性 user.custom（6 字节 → 6 字节，第 6 个字节起不同）"])
check("改长度：报变化", xattrIssuesAfter { setX($0, "user.custom", Array("abcdefg".utf8)) },
      ["变化 扩展属性 user.custom（6 字节 → 7 字节）"])
check("删掉说明：那一行带着说明的文本", xattrIssuesAfter { _ = removexattr($0, xDescription, XATTR_NOFOLLOW) },
      ["丢失 「照片」的说明（扩展属性 com.apple.assetsd.description）= 西湖日落"])
check("产物多一个属性：不报", xattrIssuesAfter { setX($0, "user.extra", [1]) }, [])
check("被跳过的两个只在源上：不报", xattrIssuesAfter { _ in }, [])
try? FileManager.default.removeItem(at: xattrRoot)

print("把「照片」的说明写进文件")
// 源是小 JPEG，扩展属性里有说明；默认带 TIFF 的 Make/Model/DateTime（实测有 DateTime 时 ImageIO 写第一遍
// 会写 XMP 项，只有 Make/Model 时不写），
// `bare` 时一个属性都不带。
let captionRoot = FileManager.default.temporaryDirectory.appendingPathComponent("glint-caption-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: captionRoot, withIntermediateDirectories: true)
let captionText = "西湖日落\n第二行 😀"
/// 新造一张带说明的源，返回路径。
func captionSource(_ name: String, bare: Bool = false) -> URL {
    let url = captionRoot.appendingPathComponent("\(name).jpg")
    // 256×256 的渐变按质量 1 存：转出来的 HEIF 比它小，--delete-original 不会因为变大而不删。
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
    if !bare {
        props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone",
                                                 kCGImagePropertyTIFFDateTime: "2024:09:15 18:42:07"]
    }
    let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    for i in 0..<16 {
        ctx?.setFillColor(red: CGFloat(i) / 16, green: 0.5, blue: 1 - CGFloat(i) / 16, alpha: 1)
        ctx?.fill(CGRect(x: i * 16, y: 0, width: 16, height: 256))
    }
    if let image = ctx?.makeImage(),
       let out = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) {
        CGImageDestinationAddImage(out, image, props as CFDictionary)
        _ = CGImageDestinationFinalize(out)
    }
    let bytes = Array(captionText.utf8)
    _ = setxattr(url.path, photosCaptionXattr, bytes, bytes.count, 0, XATTR_NOFOLLOW)
    return url
}
var captionOptions = ConversionOptions()
captionOptions.embedCaption = true
let plainSource = captionSource("只有TIFF")
let plainDest = captionRoot.appendingPathComponent("只有TIFF.heic")
var deletingOptions = captionOptions
deletingOptions.deleteOriginal = true
if case .converted(let r) = convert(plainSource, opts: deletingOptions, dest: plainDest) {
    check("没有 XMP 包的源：写了", r.caption, .written(characters: captionText.count))
} else {
    fail("没有 XMP 包的源：转换没有成功")
}
check("写成了、校验通过：--delete-original 删了源（下面「不删源」那条的对照）",
      FileManager.default.fileExists(atPath: plainSource.path), false)
check("没有 XMP 包的源：产物 XMP 里的 dc:description 是说明", embeddedCaption(at: plainDest), captionText)
// 一个属性都没有的源：ImageIO 第一遍写出的 HEIF 里没有 XMP 项，第二遍的 CopyImageSource 也就加不进去。
// 读回核对把它认作没写成，不静默。
var bareOptions = captionOptions
bareOptions.verify = true
if case .converted(let r) = convert(captionSource("没有属性", bare: true), opts: bareOptions,
                                    dest: captionRoot.appendingPathComponent("没有属性.heic")) {
    check("没有属性的源：-v 说没写成", r.caption, .failed)
    check("没有属性的源：--verify 的结果里有那一条", r.verification, .differences([CaptionOutcome.failureIssue]))
} else {
    fail("没有属性的源：转换没有成功")
}
// 第 5 项：注入一个第二遍不带说明的编码步骤（扔掉传进来的 XMP，按源自己的 XMP 编码）。
let dropCaption: HEIFEncoder = { src, props, _, url in
    encodeHEIF(src, properties: props, xmp: CGImageSourceCopyMetadataAtIndex(src, 0, nil), to: url)
}
let droppedSource = captionSource("没写成")
var droppedOptions = captionOptions
droppedOptions.deleteOriginal = true
if case .converted(let r) = convert(droppedSource, opts: droppedOptions, dest: captionRoot.appendingPathComponent("没写成.heic"),
                                    encode: dropCaption) {
    pass("没写成：转换算成功")
    check("没写成：-v 说没写成", r.caption, .failed)
    check("没写成：--verify 的结果里有那一条", r.verification.hasDifferences
              && { if case .differences(let d) = r.verification { return d.contains(CaptionOutcome.failureIssue) }; return false }(),
          true)
} else {
    fail("没写成：转换算成功"); fail("没写成：-v 说没写成"); fail("没写成：--verify 的结果里有那一条")
}
check("没写成：--delete-original 不删源", FileManager.default.fileExists(atPath: droppedSource.path), true)
let unverifiedSource = captionSource("没写成没校验")
if case .converted(let r) = convert(unverifiedSource, opts: captionOptions,
                                    dest: captionRoot.appendingPathComponent("没写成没校验.heic"), encode: dropCaption) {
    check("没写成、没校验：状态说明里说了", r.note?.contains(CaptionOutcome.failureIssue), true)
} else {
    fail("没写成、没校验：转换没有成功")
}
try? FileManager.default.removeItem(at: captionRoot)
check("-v 那一行：写了", CaptionOutcome.written(characters: 12).description,
      "「照片」的说明：写进了 XMP 的 dc:description（12 个字符）")
check("-v 那一行：没写", CaptionOutcome.skipped("文件里已有说明").description, "「照片」的说明：没写（文件里已有说明）")
check("-v 那一行：没写成", CaptionOutcome.failed.description, "「照片」的说明：没写成")

print("源的种类：按内容判定，符合 public.camera-raw-image 才算 RAW")
checkRule("public.jpeg", SourceKind(typeIdentifier: "public.jpeg"), .jpeg, "JPEG")
checkRule("com.adobe.raw-image", SourceKind(typeIdentifier: "com.adobe.raw-image"), .raw, "DNG 是 RAW")
checkRule("com.canon.cr3-raw-image", SourceKind(typeIdentifier: "com.canon.cr3-raw-image"), .raw, "CR3 是 RAW")
checkRule("com.panasonic.rw2-raw-image", SourceKind(typeIdentifier: "com.panasonic.rw2-raw-image"), .raw, "RW2 是 RAW")
checkRule("public.tiff", SourceKind(typeIdentifier: "public.tiff"), nil, "门槛下的 DNG 被认作 TIFF：不是 RAW")
checkRule("public.heic", SourceKind(typeIdentifier: "public.heic"), nil, "HEIC 两种都不是")
checkRule("nil", SourceKind(typeIdentifier: nil), nil, "认不出类型的两种都不是")
check("RAW 扩展名清单里的每一个，UTType 都认作 RAW", rawExtensions.filter { !utTypeIsRAW($0) }.sorted(), [])
check("RAW 扩展名清单不收 tif（普通 TIFF 也叫这个）", rawExtensions.contains("tif"), false)
check("RAW 扩展名与 JPEG 扩展名不相交", rawExtensions.isDisjoint(with: SourceKind.jpeg.extensions), true)
check("只收 JPEG 时遇到 RAW：指路", skipReason(type: "com.canon.cr3-raw-image", accepted: [.jpeg]),
      "是 RAW 文件（用 raw2heif）")
check("只收 RAW 时遇到 JPEG：指路", skipReason(type: "public.jpeg", accepted: [.raw]), "是 JPEG 文件（用 jpeg2heif）")
check("只收 JPEG 时遇到别的：照旧", skipReason(type: "public.png", accepted: [.jpeg]), "不是 JPEG 文件")
check("只收 RAW 时遇到 TIFF：说出系统认作什么", skipReason(type: "public.tiff", accepted: [.raw]),
      "不是 RAW 文件（系统认作 public.tiff）")
check("只收 RAW 时认不出类型", skipReason(type: nil, accepted: [.raw]), "不是 RAW 文件")
check("两种都收", skipReason(type: "public.png", accepted: [.jpeg, .raw]), "不是 JPEG 或 RAW 文件")

print("RAW 的版本号：整理成写入器能往返的形式")
func versions(_ props: [CFString: Any]) -> [String] {
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
    return [exif[kCGImagePropertyExifVersion], exif[kCGImagePropertyExifFlashPixVersion], gps[kCGImagePropertyGPSVersion]]
        .map { v in (v as? [NSNumber]).map { "[" + $0.map(\.stringValue).joined(separator: ",") + "]" } ?? "无" }
}
func versionProps(_ exifVersion: [NSNumber]?, _ flashPix: [NSNumber]?, _ gps: [NSNumber]?) -> [CFString: Any] {
    var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09"]
    exif[kCGImagePropertyExifVersion] = exifVersion
    exif[kCGImagePropertyExifFlashPixVersion] = flashPix
    var p: [CFString: Any] = [kCGImagePropertyExifDictionary: exif]
    if let gps { p[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSVersion: gps, kCGImagePropertyGPSLatitudeRef: "N"] }
    return p
}
let ints = { (a: [Int]) in a.map { NSNumber(value: $0) } }
let floats = { (a: [Double]) in a.map { NSNumber(value: $0) } }
let cr3Like = versionProps(ints([48, 50, 51, 49]), ints([48, 49, 48, 48]), floats([2, 3, 0, 0]))
check("CR3 那样的字符码与浮点数：换成整数形式", versions(versionFieldsForHEIFWriter(cr3Like)),
      ["[2,3,1]", "[1,0]", "[2,3,0,0]"])
check("浮点数换成整数类型（写入器丢浮点数）",
      ((versionFieldsForHEIFWriter(cr3Like)[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSVersion]
          as? [NSNumber])?.contains { CFNumberIsFloatType($0) }, false)
let rw2Like = versionProps(ints([2, 3]), ints([1, 0]), ints([2, 3, 0, 0]))
check("RW2 那样的整数形式：原样", versions(versionFieldsForHEIFWriter(rw2Like)), ["[2,3]", "[1,0]", "[2,3,0,0]"])
check("不需要整理时原样返回同一个字典",
      (versionFieldsForHEIFWriter(rw2Like) as NSDictionary).isEqual(to: rw2Like as [AnyHashable: Any]), true)
check("字符码只认恰好 4 个 ASCII 数字：[48,50,51] 原样",
      versions(versionFieldsForHEIFWriter(versionProps(ints([48, 50, 51]), nil, nil))), ["[48,50,51]", "无", "无"])
check("GPSVersion 不按字符码读：[50,46,51,46] 原样",
      versions(versionFieldsForHEIFWriter(versionProps(nil, nil, ints([50, 46, 51, 46])))), ["无", "无", "[50,46,51,46]"])
check("不是整数值的浮点数原样", versions(versionFieldsForHEIFWriter(versionProps(floats([2.5, 3]), nil, nil))),
      ["[2.5,3]", "无", "无"])
checkRule("0231", versionDigits("0231"), [2, 3, 1], "0231 → [2,3,1]")
checkRule("0230", versionDigits("0230"), [2, 3], "末尾的 0 去掉")
checkRule("0100", versionDigits("0100"), [1, 0], "至少留两个")
checkRule("0220", versionDigits("0220"), [2, 2], "0220 → [2,2]")
checkRule("02a1", versionDigits("02a1"), nil, "不是数字")
for (elements, codes, want) in [
    (["48", "50", "51", "49"], true, "0231"), (["2", "3", "1"], true, "0231"), (["2", "3"], true, "0230"),
    (["1", "0"], true, "0100"), (["48", "0", "1"], true, "4801"), (["48", "9", "8"], true, "4898"),
    (["2", "3", "0", "0"], false, "2.3.0.0"), (["2", "3"], false, "2.3.0.0"),
] as [([String], Bool, String)] {
    checkRule(elements.joined(separator: ","), canonicalVersion(elements, characterCodes: codes), want,
              "版本号的规范写法：[\(elements.joined(separator: ","))] → \(want)")
}
checkRule("2.5", canonicalVersion(["2.5"], characterCodes: true), nil, "不是整数：不规范化")
checkRule("2,13", canonicalVersion(["2", "13"], characterCodes: true), nil, "后面的数超出一位：不规范化")

// 写进 HEIC 再读回：拿现场生成的 DNG 当源，AddImageFromSource 时覆盖版本号字段，和 RAW 管线一样。
// 先钉住前提（不整理时写入器真会写坏、写丢），再断言整理过的读回与源等价。
let versionRoot = FileManager.default.temporaryDirectory.appendingPathComponent("glint-version-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: versionRoot, withIntermediateDirectories: true)
let versionDNG = versionRoot.appendingPathComponent("源.dng")
try? makeDNG(DNGSpec()).write(to: versionDNG)
/// 用 `props` 覆盖源的属性写一张 HEIC，读回三个版本号字段的规范写法（读不出是「无」）。
func roundTripVersions(_ props: [CFString: Any]) -> [String] {
    guard let src = CGImageSourceCreateWithURL(versionDNG as CFURL, nil) else { return ["源读不出"] }
    var p = imageProperties(src)
    for (k, v) in props {
        var d = p[k] as? [CFString: Any] ?? [:]
        for (kk, vv) in v as? [CFString: Any] ?? [:] { d[kk] = vv }
        p[k] = d
    }
    let out = versionRoot.appendingPathComponent("\(UUID().uuidString).heic")
    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.heic" as CFString, 1, nil) else { return ["写不出"] }
    CGImageDestinationAddImageFromSource(dest, src, 0, p as CFDictionary)
    guard CGImageDestinationFinalize(dest), let back = CGImageSourceCreateWithURL(out as CFURL, nil) else { return ["写不出"] }
    var flat: [String: String] = [:]
    flatten(imageProperties(back), into: &flat)
    func field(_ key: String, _ codes: Bool) -> String {
        let elements = (0..<8).compactMap { flat["\(key)[\($0)]"] }
        return elements.isEmpty ? "无" : canonicalVersion(elements, characterCodes: codes) ?? elements.joined(separator: ",")
    }
    return [field("{Exif}/ExifVersion", true), field("{Exif}/FlashPixVersion", true), field("{GPS}/GPSVersion", false)]
}
check("前提：源是 RAW", CGImageSourceCreateWithURL(versionDNG as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? },
      "com.adobe.raw-image")
check("前提：不整理时字符码被写坏、浮点数的 GPSVersion 写丢", roundTripVersions(cr3Like), ["4801", "4898", "无"])
check("整理过的读回与源等价（0231、0100、2.3.0.0）", roundTripVersions(versionFieldsForHEIFWriter(cr3Like)),
      ["0231", "0100", "2.3.0.0"])
check("RW2 那样的整数形式本来就能往返", roundTripVersions(rw2Like), ["0230", "0100", "2.3.0.0"])

print("RAW 的转换：10 位、不重编、不删、不是 RAW 的跳过")
let rawRoot = versionRoot.appendingPathComponent("转换")
try? FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
var rawOpts = ConversionOptions()
rawOpts.sources = [.raw]
/// 8 位的产物：把源解码后画进 8 位的位图再编码。模拟显影没走 RAW 的路。
let eightBit: HEIFEncoder = { src, props, _, url in
    guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else { return false }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let flat = ctx.makeImage() else { return false }
    CGImageDestinationAddImage(dest, flat, props as CFDictionary)
    return CGImageDestinationFinalize(dest)
}
let depthDest = rawRoot.appendingPathComponent("八位.heic")
let depthResult = convert(versionDNG, opts: rawOpts, dest: depthDest, encode: eightBit)
if case .failed(let why) = depthResult {
    check("产物不是 10 位：转换失败并说明", why, "产物不是 10 位（Depth = 8），没有交出")
} else {
    fail("产物不是 10 位却没有失败（\(depthResult)）")
}
check("产物不是 10 位：目标没有产物", FileManager.default.fileExists(atPath: depthDest.path), false)
check("产物不是 10 位：不留临时文件",
      ((try? FileManager.default.contentsOfDirectory(atPath: rawRoot.path)) ?? []).filter { $0.hasPrefix(".glint-") }, [])

// 产物比源大也不重编：真编码一遍，再在末尾接一个大 free 盒子撑大产物。
var rawEncodes = 0
let padded: HEIFEncoder = { src, props, xmp, url in
    rawEncodes += 1
    guard encodeHEIF(src, properties: props, xmp: xmp, to: url),
          let handle = try? FileHandle(forWritingTo: url) else { return false }
    defer { try? handle.close() }
    let size = 4 * fileSize(versionDNG)
    let header = [24, 16, 8, 0].map { UInt8(size >> $0 & 0xFF) } + Array("free".utf8)
    handle.seekToEndOfFile()
    handle.write(Data(header + [UInt8](repeating: 0, count: size - 8)))
    return true
}
let grownDest = rawRoot.appendingPathComponent("变大.heic")
let grownResult = convert(versionDNG, opts: rawOpts, dest: grownDest, encode: padded)
check("RAW 的产物比源大：编码步骤只调用 1 次（不重编）", rawEncodes, 1)
if case .converted(let r) = grownResult {
    check("RAW 的产物比源大：没有重编那一行", r.reencode == nil, true)
    check("RAW 的产物比源大：照常说明变大", r.note?.contains("HEIF 比原图大") ?? false, true)
} else {
    fail("撑大的 RAW 产物没转成（\(grownResult)）"); fail("RAW 的产物比源大：变大说明")
}

print("截短的 RAW（rawDataShortfall）")
do {
    // 夹具 DNG：主图的条带在 SubIFD 里（IFD0 里只有缩略图），终点就是文件末尾。
    let whole = [UInt8](makeDNG(DNGSpec(width: 600, height: 400)))
    let dngType = "com.adobe.raw-image"
    check("完整的 DNG：不缺", rawDataShortfall(whole, type: dngType), nil)
    check("截掉 1000 字节：缺口按 SubIFD 里的条带算", rawDataShortfall(Array(whole.dropLast(1000)), type: dngType),
          RawShortfall(needed: whole.count, have: whole.count - 1000))
    check("截到只剩一半：照样算出应有的长度", rawDataShortfall(Array(whole.prefix(whole.count / 2)), type: dngType)?.needed,
          whole.count)
    check("CR3、类型不明：不判断", [rawDataShortfall(whole, type: "com.canon.cr3-raw-image") == nil,
                              rawDataShortfall(whole, type: nil) == nil], [true, true])

    // 手搭的 RW2 头：IFD0 里只有尺寸、RawFormat、RawDataOffset，松下那样 StripOffsets 写 0xFFFFFFFF、
    // StripByteCounts 写 0。28×10 个像素，每 14 个装 16 字节是 320 字节，按 0x4000 对齐成 16384。
    func rw2(format: Int, rawStart: Int = 128, next: Int = 0) -> [UInt8] {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
        let entries: [(Int, Int, Int)] = [(0x0002, 3, 28), (0x0003, 3, 10), (0x002D, 3, format),
                                          (0x0111, 4, 0xFFFF_FFFF), (0x0117, 4, 0), (0x0118, 4, rawStart)]
        var b: [UInt8] = Array("IIU".utf8) + [0] + le32(8) + le16(entries.count)
        for (tag, type, v) in entries { b += le16(tag) + le16(type) + le32(1) + (type == 3 ? le16(v) + [0, 0] : le32(v)) }
        b += le32(next)
        return b + [UInt8](repeating: 0, count: rawStart - b.count)
    }
    let rw2Type = "com.panasonic.rw2-raw-image"
    let rw2Whole = rw2(format: 4) + [UInt8](repeating: 0x5A, count: 16384)
    check("RW2 完整：不缺", rawDataShortfall(rw2Whole, type: rw2Type), nil)
    check("RW2 截掉 384 字节：按 RawFormat 4 算出应有的长度", rawDataShortfall(Array(rw2Whole.dropLast(384)), type: rw2Type),
          RawShortfall(needed: 128 + 16384, have: 128 + 16000))
    check("RW2 的 RawFormat 不是核对过的 4：不判断",
          rawDataShortfall(Array((rw2(format: 7) + [UInt8](repeating: 0, count: 16384)).dropLast(384)), type: rw2Type), nil)

    // IFD 链指回自己（坏文件里会有）：走一遍就停，不卡住。DNG 的魔数 42 换上，按 TIFF 系走。
    var loop = rw2(format: 4, next: 8)
    loop[2] = 42
    check("IFD 链成环：照样返回", rawDataShortfall(loop, type: dngType), nil)

    // 走转换：截短的 DNG（ImageIO 显影不了它，用一个拿完整 DNG 编码的编码器顶替），
    // 校验时缺口是一条差异，不校验时写在状态说明里。
    let cutRoot = rawRoot.appendingPathComponent("截短")
    try? FileManager.default.createDirectory(at: cutRoot, withIntermediateDirectories: true)
    let cutDNG = cutRoot.appendingPathComponent("截短.dng")
    try? Data(whole.dropLast(1000)).write(to: cutDNG)
    let wholeSource = CGImageSourceCreateWithData(Data(whole) as CFData, nil)
    let fromWhole: HEIFEncoder = { _, props, xmp, url in
        guard let wholeSource else { return false }
        return encodeHEIF(wholeSource, properties: props, xmp: xmp, to: url)
    }
    let notice = rawTruncatedNotice(RawShortfall(needed: whole.count, have: whole.count - 1000))
    var verifying = rawOpts
    verifying.verify = true
    if case .converted(let r) = convert(cutDNG, opts: verifying, dest: cutRoot.appendingPathComponent("校验.heic"), encode: fromWhole),
       case .differences(let issues) = r.verification {
        check("截短的 RAW 转出来：校验报源文件不完整", issues.contains(notice), true)
    } else {
        fail("截短的 RAW 转出来：校验报源文件不完整（没转成或校验没报差异）")
    }
    if case .converted(let r) = convert(cutDNG, opts: rawOpts, dest: cutRoot.appendingPathComponent("不校验.heic"), encode: fromWhole) {
        check("截短的 RAW 转出来：不校验时写在状态说明里", r.note?.contains(notice) ?? false, true)
    } else {
        fail("截短的 RAW 转出来：不校验时写在状态说明里（没转成）")
    }
}

var deleting = rawOpts
deleting.deleteOriginal = true
let keptDest = rawRoot.appendingPathComponent("不删.heic")
let keptResult = convert(versionDNG, opts: deleting, dest: keptDest)
check("RAW 永远不删：源还在", FileManager.default.fileExists(atPath: versionDNG.path), true)
if case .converted(let r) = keptResult {
    check("RAW 永远不删：说明为什么没删", r.note, "RAW 原片永远保留，没有删除")
    check("RAW 的产物是 10 位", imageDepth(keptDest), 10)
    check("RAW 的 EXIF 整块照搬了", { if case .carried = r.rawExif { return true }; return false }(), true)
} else {
    fail("RAW 没转成（\(keptResult)）"); fail("RAW 的产物是 10 位"); fail("RAW 的 EXIF 照搬那一步")
}
let jpegOnly = convert(versionDNG, opts: ConversionOptions(), dest: rawRoot.appendingPathComponent("只收JPEG.heic"))
if case .skipped(let why) = jpegOnly {
    check("只收 JPEG 时 RAW 跳过并指路", why, "是 RAW 文件（用 raw2heif）")
} else {
    fail("只收 JPEG 时 RAW 没有跳过（\(jpegOnly)）")
}
let tinyDNG = rawRoot.appendingPathComponent("小.dng")
var tinySpec = DNGSpec()
(tinySpec.width, tinySpec.height) = (64, 48)
try? makeDNG(tinySpec).write(to: tinyDNG)
let tinyResult = convert(tinyDNG, opts: rawOpts, dest: rawRoot.appendingPathComponent("小.heic"))
if case .skipped(let why) = tinyResult {
    check("门槛下的 DNG 按「不是 RAW」跳过", why, "不是 RAW 文件（系统认作 public.tiff）")
} else {
    fail("门槛下的 DNG 没有跳过（\(tinyResult)）")
}
try? FileManager.default.removeItem(at: versionRoot)

print("RAW 的 EXIF 拼块：TIFF 系，IFD0 只留白名单，Exif 去掉 MakerNote，Interop、GPS 原样，偏移重算")
/// 手搭 RAW 的一个条目：值是原始字节，按 TIFF 的字节序写好。
struct RT: Equatable {
    let tag: Int, type: Int, count: Int, value: [UInt8]
    init(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) { (self.tag, self.type, self.count, self.value) = (tag, type, count, value) }
}
/// 按字节序写整数。
func ordered(_ v: Int, _ width: Int, _ bigEndian: Bool) -> [UInt8] { bigEndian ? be(v, width) : Array(be(v, width).reversed()) }
/// 一块手搭的 RAW 用的 TIFF 和各个 IFD 的位置（"IFD0"、"Exif"、"Interop"、"GPS"）。
struct BuiltRaw { var bytes: [UInt8]; var at: [String: Int] }
/// 手搭 TIFF 系 RAW：头之后先是 100 字节的「图像数据」，IFD 的先后是 GPS、Interop、Exif、IFD0（与拼块的
/// 顺序相反，值的偏移不重算就对不上）；每个 IFD 的条目照给的顺序写，指针接在各自的表尾。Exif 是 nil、
/// Interop 不是 nil 时，Interop 指针放在 IFD0 里（CR3 的 CMT2 就是这样：第一个 IFD 本身就是 Exif IFD）。
func rawTIFF(bigEndian: Bool = false, magic: Int = 42, ifd0: [RT], exif: [RT]? = nil, interop: [RT]? = nil,
             gps: [RT]? = nil) -> BuiltRaw {
    func o(_ v: Int, _ w: Int) -> [UInt8] { ordered(v, w, bigEndian) }
    func size(_ e: [RT]) -> Int { 2 + 12 * e.count + 4 + e.reduce(0) { $0 + ($1.value.count > 4 ? ($1.value.count + 1) & ~1 : 0) } }
    let junk = [UInt8](repeating: 0xAB, count: 100)
    let interopPointer = interop == nil ? [] : [RT(0xA005, 4, 1, o(0, 4))]
    var exifFull = exif.map { $0 + interopPointer }
    var ifd0Full = ifd0 + (exif == nil ? interopPointer : []) + (exif == nil ? [] : [RT(0x8769, 4, 1, o(0, 4))])
        + (gps == nil ? [] : [RT(0x8825, 4, 1, o(0, 4))])
    var at: [String: Int] = [:]
    var pos = 8 + junk.count
    if let gps { at["GPS"] = pos; pos += size(gps) }
    if let interop { at["Interop"] = pos; pos += size(interop) }
    if let e = exifFull { at["Exif"] = pos; pos += size(e) }
    at["IFD0"] = pos
    func pointed(_ e: RT) -> RT {
        switch e.tag {
        case 0xA005 where e.value == o(0, 4): return RT(0xA005, 4, 1, o(at["Interop"]!, 4))
        case 0x8769 where e.value == o(0, 4): return RT(0x8769, 4, 1, o(at["Exif"]!, 4))
        case 0x8825 where e.value == o(0, 4): return RT(0x8825, 4, 1, o(at["GPS"]!, 4))
        default: return e
        }
    }
    exifFull = exifFull?.map(pointed)
    ifd0Full = ifd0Full.map(pointed)
    func block(_ e: [RT], _ start: Int) -> [UInt8] {
        var table = o(e.count, 2), values: [UInt8] = []
        var v = start + 2 + 12 * e.count + 4
        for t in e {
            table += o(t.tag, 2) + o(t.type, 2) + o(t.count, 4)
            if t.value.count <= 4 {
                table += t.value + [UInt8](repeating: 0, count: 4 - t.value.count)
            } else {
                table += o(v, 4)
                values += t.value + (t.value.count % 2 == 1 ? [0] : [])
                v += (t.value.count + 1) & ~1
            }
        }
        return table + o(0, 4) + values
    }
    var out: [UInt8] = (bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]) + o(magic, 2) + o(at["IFD0"]!, 4) + junk
    if let gps { out += block(gps, at["GPS"]!) }
    if let interop { out += block(interop, at["Interop"]!) }
    if let e = exifFull { out += block(e, at["Exif"]!) }
    out += block(ifd0Full, at["IFD0"]!)
    return BuiltRaw(bytes: out, at: at)
}
func asciiRT(_ tag: Int, _ s: String) -> RT { let b = Array(s.utf8) + [0]; return RT(tag, 2, b.count, b) }
/// 一组照真 RAW 的样子手搭的条目（`bigEndian` 定值的字节序）。IFD0 里白名单内外的都有。
struct RawSample {
    var keptIFD0: [RT], droppedIFD0: [RT], exif: [RT], makerNote: RT, interop: [RT], gps: [RT]
    init(bigEndian be: Bool, orientation: Int? = 6) {
        func o(_ v: Int, _ w: Int) -> [UInt8] { ordered(v, w, be) }
        func rational(_ tag: Int, _ parts: [(Int, Int)]) -> RT { RT(tag, 5, parts.count, parts.flatMap { o($0.0, 4) + o($0.1, 4) }) }
        keptIFD0 = [asciiRT(0x010F, "Canon"), asciiRT(0x0110, "Canon EOS R5"), asciiRT(0x0132, "2024:05:06 07:08:09"),
                    asciiRT(0x013B, "Glint Tester"), asciiRT(0x8298, "(c) Glint"), asciiRT(0x0131, "Firmware 1.8.1"),
                    rational(0x011A, [(240, 1)]), rational(0x011B, [(240, 1)]), RT(0x0128, 3, 1, o(2, 2)),
                    RT(0x4746, 3, 1, o(4, 2)), RT(0x9C9C, 1, 6, [0x07, 0x59, 0xE8, 0x6C, 0, 0])]
        if let orientation { keptIFD0.insert(RT(0x0112, 3, 1, o(orientation, 2)), at: 2) }
        droppedIFD0 = [RT(0x00FE, 4, 1, o(1, 4)), RT(0x0100, 4, 1, o(6000, 4)), RT(0x0101, 4, 1, o(4000, 4)),
                       RT(0x0102, 3, 3, o(8, 2) + o(8, 2) + o(8, 2)), RT(0x0103, 3, 1, o(6, 2)), RT(0x0106, 3, 1, o(32803, 2)),
                       RT(0x0111, 4, 1, o(12345, 4)), RT(0x0117, 4, 1, o(999, 4)), RT(0x014A, 4, 2, o(8, 4) + o(8, 4)),
                       RT(0x02BC, 7, 12, Array("<x:xmpmeta/>".utf8)), RT(0x0002, 7, 4, Array("0100".utf8)),
                       RT(0xC612, 1, 4, [1, 4, 0, 0]), RT(0xC4A5, 7, 8, Array("PrintIM\0".utf8))]
        exif = [rational(0x829A, [(1, 250)]), rational(0x829D, [(28, 10)]), RT(0x9000, 7, 4, Array("0231".utf8)),
                asciiRT(0x9003, "2024:05:06 07:08:09"), RT(0xA430, 2, 32, [UInt8](repeating: 0, count: 32)),
                asciiRT(0xA434, "RF24-105mm F4 L IS USM"), RT(0xA001, 3, 1, o(1, 2))]
        makerNote = RT(0x927C, 7, 40, Array("CANON MAKERNOTE".utf8) + [UInt8](repeating: 0x5A, count: 25))
        interop = [RT(0x0001, 2, 4, Array("R98\0".utf8)), RT(0x0002, 7, 4, Array("0100".utf8))]
        gps = [RT(0x0000, 1, 4, [2, 3, 0, 0]), RT(0x0001, 2, 2, Array("N\0".utf8)),
               rational(0x0002, [(69, 1), (11, 1), (387060, 10000)]), RT(0x0003, 2, 2, Array("E\0".utf8)),
               rational(0x0004, [(18, 1), (57, 1), (123456789, 1000000)]), rational(0x0006, [(1250001, 100000)]),
               RT(0x0008, 2, 1, [0]), rational(0x0007, [(10, 1), (42, 1), (75, 10)]), asciiRT(0x001D, "2024:05:06")]
    }
    /// 源里 IFD0 的全部条目：白名单内外交错。
    var ifd0: [RT] { zip(keptIFD0, droppedIFD0).flatMap { [$0, $1] } + keptIFD0.dropFirst(droppedIFD0.count) + droppedIFD0.dropFirst(keptIFD0.count) }
    /// MakerNote 夹在 Exif IFD 的中间。
    var exifWithMakerNote: [RT] { Array(exif.prefix(3)) + [makerNote] + Array(exif.dropFirst(3)) }
    func tiff(magic: Int = 42, bigEndian: Bool) -> BuiltRaw {
        rawTIFF(bigEndian: bigEndian, magic: magic, ifd0: ifd0, exif: exifWithMakerNote, interop: interop, gps: gps)
    }
}
let sampleLE = RawSample(bigEndian: false), sampleBE = RawSample(bigEndian: true)
/// 拼出来的块读回的条目：(IFD, 标签, 类型, 个数, 值)，子 IFD 指针的值不比（位置由拼块定）。
func blockEntries(_ block: [UInt8]) -> [String] {
    guard let tiff = TIFFStructure(block, base: 0, length: block.count) else { return ["读不出"] }
    return rawExifEntries(tiff).map { e in
        let value = [0x8769, 0x8825, 0xA005].contains(e.tag) && e.ifd != "GPS" && e.ifd != "Interop"
            ? "指针" : e.value.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "值读不出"
        return "\(e.ifd) \(String(format: "%04X", e.tag)) \(e.type) \(e.count) \(value)"
    }
}
/// 期望的块内容：IFD0 白名单内的加两个指针，Exif 去掉 MakerNote 加 Interop 指针，各自按标签号升序。
func expectedEntries(_ s: RawSample) -> [String] {
    func line(_ ifd: String, _ e: RT) -> String {
        "\(ifd) \(String(format: "%04X", e.tag)) \(e.type) \(e.count) \(e.value.map { String(format: "%02x", $0) }.joined())"
    }
    func lines(_ ifd: String, _ entries: [RT], pointers: [Int]) -> [String] {
        (entries + pointers.map { RT($0, 4, 1, []) }).sorted { $0.tag < $1.tag }.map { e in
            pointers.contains(e.tag) ? "\(ifd) \(String(format: "%04X", e.tag)) 4 1 指针" : line(ifd, e)
        }
    }
    // rawExifEntries 的顺序：IFD0，Exif IFD，它的 Interop IFD，GPS IFD。
    return lines("IFD0", s.keptIFD0, pointers: [0x8769, 0x8825]) + lines("ExifIFD", s.exif, pointers: [0xA005])
        + lines("Interop", s.interop, pointers: []) + lines("GPS", s.gps, pointers: [])
}
let dngType = "com.adobe.raw-image"
func rawBlock(_ bytes: [UInt8], _ type: String = dngType) -> [UInt8]? { try? cameraRawExifTIFF(bytes, type: type).get() }
func rawSkip(_ bytes: [UInt8], _ type: String = dngType) -> String? {
    if case .failure(let s) = cameraRawExifTIFF(bytes, type: type) { return s.reason }
    return nil
}
for (name, sample, bigEndian) in [("小端", sampleLE, false), ("大端", sampleBE, true)] {
    let source = sample.tiff(bigEndian: bigEndian)
    guard let block = rawBlock(source.bytes) else {
        fail("\(name)：没拼出来（\(rawSkip(source.bytes) ?? "?")）"); for _ in 0..<7 { fail("（同上）") }; continue
    }
    check("\(name)：块里的条目恰好是 IFD0 白名单内的、Exif 除 MakerNote 外的、Interop 与 GPS 的全部，值逐字节原样",
          blockEntries(block), expectedEntries(sample))
    check("\(name)：字节序与源相同", Array(block.prefix(4)), bigEndian ? [0x4D, 0x4D, 0, 42] : [0x49, 0x49, 42, 0])
    let entries = TIFFStructure(block, base: 0, length: block.count).map(rawExifEntries) ?? []
    check("\(name)：MakerNote 不在块里", entries.contains { $0.tag == 0x927C }, false)
    check("\(name)：描述图像数据与 RAW 容器的标签都不在块里（StripOffsets、Photometric、SubIFDs、DNG、XMP、私有标签……）",
          entries.filter { $0.ifd == "IFD0" && sample.droppedIFD0.map(\.tag).contains($0.tag) }.map(\.tag), [])
    check("\(name)：每个条目的值都在块内（没有指向原文件的偏移）", entries.filter { $0.value == nil }.map(\.tag), [])
    if let t = TIFFStructure(block, base: 0, length: block.count), let ifd0 = t.ifd0, let exifAt = t.exifIFD {
        let tags = [ifd0, exifAt].map { t.entries($0).map(\.tag) }
        check("\(name)：每个 IFD 的条目按标签号升序", tags.map { $0 == $0.sorted() }, [true, true])
        check("\(name)：IFD0 与 Exif IFD 后面的「下一个 IFD」是 0",
              [t.u32(ifd0 + 2 + 12 * tags[0].count), t.u32(exifAt + 2 + 12 * tags[1].count)], [0, 0])
    } else { fail("\(name)：块读不出 IFD0 或 Exif IFD"); fail("（同上）") }
    check("\(name)：块比源小（只有元数据，没有图像数据）", block.count < source.bytes.count, true)
}
let leBlock = rawBlock(sampleLE.tiff(bigEndian: false).bytes) ?? []

print("RAW 的 EXIF 拼块：每种格式按它的结构手搭一个样本，拼出来的块都与 TIFF 系的相同")
/// 手搭 CR3：ftyp（crx）、moov（一个占位的 mvhd 与佳能的 uuid：CNCV、CMT1…CMT4、THMB）、mdat。
/// `cmts` 是 uuid 里的盒子（名字与内容），默认是样本的 CMT1/CMT2/CMT3/CMT4。
func cr3Sample(_ s: RawSample = sampleLE, bigEndian: Bool = false, brand: String = "crx ",
               cmts: [(String, [UInt8])]? = nil, uuids: Int = 1, moovs: Int = 1) -> [UInt8] {
    let cmt1 = rawTIFF(bigEndian: bigEndian, ifd0: s.ifd0 + [RT(0x8769, 4, 1, ordered(9999, 4, bigEndian))]).bytes
    let cmt2 = rawTIFF(bigEndian: bigEndian, ifd0: s.exifWithMakerNote, interop: s.interop).bytes
    let cmt4 = rawTIFF(bigEndian: bigEndian, ifd0: s.gps).bytes
    let inner = cmts ?? [("CMT1", cmt1), ("CMT2", cmt2), ("CMT3", Array("CANON MAKERNOTE".utf8)), ("CMT4", cmt4)]
    let canon = box("uuid", canonCR3MetadataUUID + box("CNCV", Array("CanonCR3_001/00.10.00/00.00.00".utf8))
                    + inner.flatMap { box($0.0, $0.1) } + box("THMB", [UInt8](repeating: 1, count: 32)))
    let moov = box("moov", box("mvhd", [UInt8](repeating: 0, count: 100)) + [[UInt8]](repeating: canon, count: uuids).flatMap { $0 })
    return box("ftyp", Array(brand.utf8) + be(1, 4) + Array("crx isom".utf8)) + [[UInt8]](repeating: moov, count: moovs).flatMap { $0 }
        + box("mdat", [UInt8](repeating: 0xCD, count: 256))
}
/// 手搭 RAF：16 字节的魔数加版本，第 84、88 字节起是内嵌 JPEG 的偏移与长度（大端），JPEG 后面是原始数据。
func rafSample(jpeg: [UInt8], offset: Int? = nil) -> [UInt8] {
    var head = rafMagic + Array("0201FF129502".utf8)
    head += [UInt8](repeating: 0, count: 84 - head.count)
    let at = 100
    head += be(offset ?? at, 4) + be(jpeg.count, 4)
    head += [UInt8](repeating: 0, count: at - head.count)
    return head + jpeg + [UInt8](repeating: 0xEE, count: 300)
}
let leTIFF = sampleLE.tiff(bigEndian: false).bytes
func sampleFor(_ layout: CameraRawExifLayout) -> [UInt8] {
    switch layout {
    case .tiff(let magic): return sampleLE.tiff(magic: magic.contains(42) ? 42 : magic.sorted()[0], bigEndian: false).bytes
    case .cr3: return cr3Sample()
    case .raf: return rafSample(jpeg: jpegWithExif(leTIFF))
    case .rw2:
        // 内嵌 JPEG 的 EXIF 是完整的那份，RW2 自己的 Exif IFD 是它的前 4 条。
        let jpeg = jpegWithExif(leTIFF)
        return rawTIFF(magic: 0x55, ifd0: [RT(0x0001, 3, 1, le16(2)), RT(0x002E, 7, jpeg.count, jpeg), asciiRT(0x010F, "Panasonic")],
                       exif: Array(sampleLE.exif.prefix(4))).bytes
    }
}
for (type, layout) in cameraRawExifLayouts.sorted(by: { $0.key < $1.key }) {
    check("\(type)：拼出来的块与 TIFF 系的相同", rawBlock(sampleFor(layout), type) ?? [], leBlock)
}
let rawTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
check("表里每个类型都是本机 ImageIO 能读的 RAW",
      cameraRawExifLayouts.keys.filter { !rawTypes.contains($0) || !(UTType($0)?.conforms(to: .rawImage) ?? false) }.sorted(), [])
check("大端的 TIFF 系也拼得出（DNG 可以是大端）", rawBlock(sampleBE.tiff(bigEndian: true).bytes).map(blockEntries), expectedEntries(sampleBE))
check("ORF 的三种头：IIRO、IIRS、MMOR",
      [(0x4F52, false), (0x5352, false), (0x4F52, true)].map { magic, bigEndian in
          rawBlock((bigEndian ? sampleBE : sampleLE).tiff(magic: magic, bigEndian: bigEndian).bytes, "com.olympus.or-raw-image") != nil
      }, [true, true, true])
check("CR3 的 CMT 是大端时，块也是大端", rawBlock(cr3Sample(sampleBE, bigEndian: true), "com.canon.cr3-raw-image").map(blockEntries),
      expectedEntries(sampleBE))
check("CR3 没有 CMT3（MakerNote）也照搬：CMT3 本来就不搬",
      rawBlock(cr3Sample(cmts: [("CMT1", rawTIFF(ifd0: sampleLE.ifd0).bytes),
                                ("CMT2", rawTIFF(ifd0: sampleLE.exifWithMakerNote, interop: sampleLE.interop).bytes),
                                ("CMT4", rawTIFF(ifd0: sampleLE.gps).bytes)]), "com.canon.cr3-raw-image") ?? [], leBlock)
// 文件头与类型对不上：不照搬。
check("DNG 的类型配 RW2 的头", rawSkip(sampleLE.tiff(magic: 0x55, bigEndian: false).bytes), "文件头不是 com.adobe.raw-image 应有的 TIFF 头")
check("RW2 的类型配普通 TIFF 头", rawSkip(leTIFF, "com.panasonic.rw2-raw-image"), "文件头不是 com.panasonic.rw2-raw-image 应有的 TIFF 头")
check("CR3 的类型配 TIFF", rawSkip(leTIFF, "com.canon.cr3-raw-image"), "CR3 的顶层盒子读不通")
check("RAF 的类型配 TIFF", rawSkip(leTIFF, "com.fuji.raw-image"), "不是 RAF 的文件头")
check("表里没有的类型（CRW）不照搬", rawSkip(leTIFF, "com.canon.crw-raw-image"), "这种 RAW（com.canon.crw-raw-image）的 EXIF 还不能整块照搬")
check("类型不明不照搬", { () -> String? in if case .failure(let s) = cameraRawExifTIFF(leTIFF, type: nil) { return s.reason }; return nil }(),
      "这种 RAW（类型不明）的 EXIF 还不能整块照搬")

print("RAW 的 EXIF 拼块：闸门，源的长度、偏移、个数都不信")
let leBuilt = sampleLE.tiff(bigEndian: false)
/// 把 `bytes` 里 `at` 起的 `width` 字节换成小端的 `value`。
func patched(_ bytes: [UInt8], at: Int, _ value: Int, width: Int) -> [UInt8] {
    var b = bytes
    b.replaceSubrange(at..<(at + width), with: ordered(value, width, false))
    return b
}
/// 小端 TIFF 里 IFD `ifd` 中标签 `tag` 的条目头位置。
func entryAt(_ bytes: [UInt8], ifd: Int, tag: Int) -> Int? {
    let n = Int(bytes[ifd]) | Int(bytes[ifd + 1]) << 8
    return (0..<n).map { ifd + 2 + 12 * $0 }.first { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 == tag }
}
let ifd0At = leBuilt.at["IFD0"]!, exifAt = leBuilt.at["Exif"]!, gpsAt = leBuilt.at["GPS"]!
check("IFD0 的条目数巨大", rawSkip(patched(leBuilt.bytes, at: ifd0At, 0xFFFF, width: 2)), "IFD0 的条目数 65535 不像真的")
check("IFD0 的条目数刚过上限", rawSkip(patched(leBuilt.bytes, at: ifd0At, maxCarriedIFDEntries + 1, width: 2)),
      "IFD0 的条目数 \(maxCarriedIFDEntries + 1) 不像真的")
check("IFD0 的条目数比实际多（表越出文件）", rawSkip(patched(leBuilt.bytes, at: ifd0At, 200, width: 2)), "IFD0 的条目表越界")
check("IFD0 的位置越出文件", rawSkip(patched(leBuilt.bytes, at: 4, leBuilt.bytes.count - 1, width: 4)), "IFD0 的位置越界")
check("IFD0 指进文件头", rawSkip(patched(leBuilt.bytes, at: 4, 2, width: 4)), "IFD0 的位置越界")
if let make = entryAt(leBuilt.bytes, ifd: ifd0At, tag: 0x010F), let gpsLat = entryAt(leBuilt.bytes, ifd: gpsAt, tag: 0x0002),
   let exifPtr = entryAt(leBuilt.bytes, ifd: ifd0At, tag: 0x8769), let gpsPtr = entryAt(leBuilt.bytes, ifd: ifd0At, tag: 0x8825),
   let maker = entryAt(leBuilt.bytes, ifd: exifAt, tag: 0x927C), let exposure = entryAt(leBuilt.bytes, ifd: exifAt, tag: 0x829A),
   let interopPtr = entryAt(leBuilt.bytes, ifd: exifAt, tag: 0xA005), let strip = entryAt(leBuilt.bytes, ifd: ifd0At, tag: 0x0111),
   let orientation = entryAt(leBuilt.bytes, ifd: ifd0At, tag: 0x0112) {
    let b = leBuilt.bytes
    check("值的偏移越出文件", rawSkip(patched(b, at: make + 8, 0x7FFF_FFF0, width: 4)), "IFD0 里 0x010F 的值越界")
    check("值的偏移差一个字节越出文件", rawSkip(patched(b, at: gpsLat + 8, b.count - 23, width: 4)), "GPS IFD 里 0x0002 的值越界")
    check("值的个数巨大（个数 × 单位越出文件）", rawSkip(patched(b, at: make + 4, 0x7FFF_FFFF, width: 4)), "IFD0 里 0x010F 的值越界")
    check("不搬的条目值越界也不照搬（整张表都不可信）", rawSkip(patched(b, at: maker + 8, 0x7FFF_FFF0, width: 4)), "Exif IFD 里 0x927C 的值越界")
    check("Exif 指针越出文件", rawSkip(patched(b, at: exifPtr + 8, b.count + 100, width: 4)), "Exif IFD 的位置越界")
    check("Exif 指针指回 IFD0（自指循环）", rawSkip(patched(b, at: exifPtr + 8, ifd0At, width: 4)), "Exif IFD 指回了 IFD0")
    check("GPS 指针与 Exif 指针相同", rawSkip(patched(b, at: gpsPtr + 8, exifAt, width: 4)), "GPS IFD 与 Exif IFD 是同一个")
    check("GPS 指针指回 IFD0", rawSkip(patched(b, at: gpsPtr + 8, ifd0At, width: 4)), "GPS IFD 指回了别的 IFD")
    check("Interop 指针指回 Exif IFD 自己", rawSkip(patched(b, at: interopPtr + 8, exifAt, width: 4)), "Interop IFD 指回了别的 IFD")
    check("Interop 指针指向 GPS IFD", rawSkip(patched(b, at: interopPtr + 8, gpsAt, width: 4)), "Interop IFD 指回了别的 IFD")
    check("Exif 指针不是 LONG", rawSkip(patched(b, at: exifPtr + 2, 3, width: 2)), "IFD0 里的子 IFD 指针 0x8769 不是一个 LONG")
    check("类型不认识", rawSkip(patched(b, at: exposure + 2, 14, width: 2)), "Exif IFD 里 0x829A 的类型 14 不认识")
    check("类型是 0", rawSkip(patched(b, at: strip + 2, 0, width: 2)), "IFD0 里 0x0111 的类型 0 不认识")
    check("同一个标签出现两次", rawSkip(patched(b, at: gpsLat, 0x0001, width: 2)), "GPS IFD 里 0x0001 不止一个")
    check("Exif IFD 里有类型是 IFD 的条目", rawSkip(patched(b, at: exposure + 2, 13, width: 2)),
          "Exif IFD 里有不该在那里的子 IFD 指针 0x829A")
    check("方向是 LONG", rawSkip(patched(patched(b, at: orientation + 2, 4, width: 2), at: orientation + 8, 6, width: 4)),
          "IFD0 里的 Orientation 不是 1–8 之间的一个 SHORT")
    check("方向是 9", rawSkip(patched(b, at: orientation + 8, 9, width: 2)), "IFD0 里的 Orientation 不是 1–8 之间的一个 SHORT")
} else {
    for _ in 0..<17 { fail("手搭的 TIFF 里找不到要改的条目") }
}
check("GPS IFD 里有 Exif 指针", rawSkip(rawTIFF(ifd0: sampleLE.ifd0, gps: sampleLE.gps + [RT(0x8769, 4, 1, le32(8))]).bytes),
      "GPS IFD 里有不该在那里的子 IFD 指针 0x8769")
check("Interop IFD 里有 GPS 指针",
      rawSkip(rawTIFF(ifd0: sampleLE.ifd0, exif: sampleLE.exif, interop: sampleLE.interop + [RT(0x8825, 4, 1, le32(8))]).bytes),
      "Interop IFD 里有不该在那里的子 IFD 指针 0x8825")
check("Exif IFD 里有 SubIFDs", rawSkip(rawTIFF(ifd0: sampleLE.ifd0, exif: sampleLE.exif + [RT(0x014A, 4, 1, le32(8))]).bytes),
      "Exif IFD 里有不该在那里的子 IFD 指针 0x014A")
check("只有图像数据的标签：没有可照搬的", rawSkip(rawTIFF(ifd0: sampleLE.droppedIFD0).bytes), "RAW 里没有可照搬的 EXIF")
check("没有 Exif、GPS 指针也照搬 IFD0", rawBlock(rawTIFF(ifd0: sampleLE.ifd0).bytes).map(blockEntries),
      sampleLE.keptIFD0.sorted { $0.tag < $1.tag }.map { "IFD0 \(String(format: "%04X", $0.tag)) \($0.type) \($0.count) \($0.value.map { String(format: "%02x", $0) }.joined())" })
check("Exif IFD 只有 MakerNote：不留空的 Exif IFD 与指针",
      rawBlock(rawTIFF(ifd0: sampleLE.keptIFD0, exif: [sampleLE.makerNote]).bytes).map { blockEntries($0).filter { $0.hasPrefix("ExifIFD") || $0.contains(" 8769 ") } },
      [])
// 截断在每一个位置：要么不照搬，要么（截掉的只是表后不用的字节）拼出来的与完整的相同。
check("截断在每一个位置：不崩，拼得出的都与完整的相同",
      (0..<leTIFF.count).filter { rawBlock(Array(leTIFF.prefix($0))).map { $0 != leBlock } ?? false }, [])
var rawSeed: UInt64 = 2611
func rawRandom(_ n: Int) -> Int {
    rawSeed = rawSeed &* 6364136223846793005 &+ 1442695040888963407
    return Int(rawSeed >> 33) % n
}
/// 拼得出的块必须是合法的 TIFF，每个条目的值都在块内。
func wellFormed(_ block: [UInt8]) -> Bool {
    guard let t = TIFFStructure(block, base: 0, length: block.count) else { return false }
    return rawExifEntries(t).allSatisfy { $0.value != nil }
}
var rawBad = 0
for _ in 0..<3000 {
    var bad = leTIFF
    for _ in 0...rawRandom(4) { bad[rawRandom(bad.count)] = UInt8(rawRandom(256)) }
    if let block = rawBlock(bad), !wellFormed(block) { rawBad += 1 }
}
check("TIFF 系随机改坏 3000 次：不崩，拼得出的都是合法的块", rawBad, 0)

// CR3 的闸门。
let cr3Type = "com.canon.cr3-raw-image"
let cr3 = cr3Sample()
check("前提：手搭的 CR3 拼得出", rawBlock(cr3, cr3Type) != nil, true)
let cr3Block = rawBlock(cr3, cr3Type) ?? []
// 截在 moov 末尾（mdat 整个截掉）时 ftyp、moov 还是完整的，拼得出，也与完整的相同。
check("CR3 截断在每一个位置：不崩，拼得出的都与完整的相同",
      (0..<cr3.count).filter { rawBlock(Array(cr3.prefix($0)), cr3Type).map { $0 != cr3Block } ?? false }, [])
check("CR3 截断在 moov 里面的每一个位置都不照搬", { () -> [Int] in
    let moovEnd = cr3.count - (8 + 256)
    return (0..<moovEnd).filter { rawBlock(Array(cr3.prefix($0)), cr3Type) != nil }
}(), [])
var longMoov = cr3
if let moovAt = (0..<(cr3.count - 8)).first(where: { Array(cr3[($0 + 4)..<($0 + 8)]) == Array("moov".utf8) }) {
    longMoov.replaceSubrange(moovAt..<(moovAt + 4), with: be(cr3.count, 4))
}
check("CR3 的盒子长度越出文件", rawSkip(longMoov, cr3Type), "CR3 的顶层盒子读不通")
let goodCMTs: [(String, [UInt8])] = [("CMT1", rawTIFF(ifd0: sampleLE.ifd0).bytes),
                                     ("CMT2", rawTIFF(ifd0: sampleLE.exifWithMakerNote, interop: sampleLE.interop).bytes),
                                     ("CMT3", Array("MN".utf8)), ("CMT4", rawTIFF(ifd0: sampleLE.gps).bytes)]
for missing in ["CMT1", "CMT2"] {
    check("CR3 缺 \(missing)", rawSkip(cr3Sample(cmts: goodCMTs.filter { $0.0 != missing }), cr3Type), "CR3 里没有 \(missing)")
}
for twice in ["CMT1", "CMT2", "CMT4"] {
    check("CR3 的 \(twice) 有两个", rawSkip(cr3Sample(cmts: goodCMTs + goodCMTs.filter { $0.0 == twice }), cr3Type), "CR3 里的 \(twice) 不止一个")
}
check("CR3 的 CMT2 不是 TIFF", rawSkip(cr3Sample(cmts: goodCMTs.map { $0.0 == "CMT2" ? ("CMT2", Array("not a tiff at all".utf8)) : $0 }), cr3Type),
      "CR3 的 CMT2 不是合法的 TIFF")
check("CR3 的 CMT4 字节序与别的不同",
      rawSkip(cr3Sample(cmts: goodCMTs.map { $0.0 == "CMT4" ? ("CMT4", rawTIFF(bigEndian: true, ifd0: sampleBE.gps).bytes) : $0 }), cr3Type),
      "CR3 的 CMT1、CMT2、CMT4 字节序不一致")
check("CR3 的佳能元数据盒子有两个", rawSkip(cr3Sample(uuids: 2), cr3Type), "CR3 的佳能元数据盒子不是恰好一个")
check("CR3 没有 moov", rawSkip(cr3Sample(moovs: 0), cr3Type), "CR3 的 moov 盒子不是恰好一个")
check("CR3 的 ftyp 主品牌不是 crx", rawSkip(cr3Sample(brand: "heic"), cr3Type), "不是 CR3 的文件头（ftyp 的主品牌不是 crx）")
let cmt2Loop = rawTIFF(ifd0: sampleLE.exif, interop: sampleLE.interop)
var loopBytes = cmt2Loop.bytes
if let p = entryAt(loopBytes, ifd: cmt2Loop.at["IFD0"]!, tag: 0xA005) {
    loopBytes = patched(loopBytes, at: p + 8, cmt2Loop.at["IFD0"]!, width: 4)
}
check("CR3 的 CMT2 里 Interop 指回自己", rawSkip(cr3Sample(cmts: goodCMTs.map { $0.0 == "CMT2" ? ("CMT2", loopBytes) : $0 }), cr3Type),
      "Interop IFD 指回了别的 IFD")
var cr3Bad = 0
for _ in 0..<3000 {
    var bad = cr3
    for _ in 0...rawRandom(4) { bad[rawRandom(bad.count)] = UInt8(rawRandom(256)) }
    if let block = rawBlock(bad, cr3Type), !wellFormed(block) { cr3Bad += 1 }
}
check("CR3 随机改坏 3000 次：不崩，拼得出的都是合法的块", cr3Bad, 0)
// RAF 的闸门。
let rafType = "com.fuji.raw-image"
check("RAF 里内嵌 JPEG 的偏移越出文件", rawSkip(rafSample(jpeg: jpegWithExif(leTIFF), offset: 1 << 30), rafType), "RAF 里内嵌 JPEG 的位置越界")
check("RAF 内嵌的 JPEG 没有 EXIF", rawSkip(rafSample(jpeg: [0xFF, 0xD8, 0xFF, 0xD9]), rafType), "RAF 内嵌的 JPEG：源里没有 EXIF 段")
check("RAF 截断在每一个位置都不照搬", { () -> [Int] in
    let raf = rafSample(jpeg: jpegWithExif(leTIFF))
    // 截掉的只是 JPEG 后面的原始数据时照样拼得出；从 JPEG 末尾往前截都不照搬。
    let jpegEnd = 100 + jpegWithExif(leTIFF).count
    return (0..<jpegEnd).filter { rawBlock(Array(raf.prefix($0)), rafType) != nil }
}(), [])

print("RAW 的 EXIF 拼块：块里的方向必须与产物的相同")
func planSkip(_ bytes: [UInt8], _ orientation: Int) -> String? {
    if case .failure(let s) = cameraRawCarryPlan(source: bytes, type: dngType, productOrientation: orientation) { return s.reason }
    return nil
}
check("方向相同（6）：照搬", planSkip(leTIFF, 6), nil)
check("块里是 6、产物是 1：不照搬", planSkip(leTIFF, 1), "RAW 里 EXIF 的方向（6）与产物的方向（1）不同")
let noOrientationTIFF = RawSample(bigEndian: false, orientation: nil).tiff(bigEndian: false).bytes
check("块里没有方向、产物是 1：照搬", planSkip(noOrientationTIFF, 1), nil)
check("块里没有方向、产物是 6：不照搬", planSkip(noOrientationTIFF, 6), "RAW 里 EXIF 的方向（1）与产物的方向（6）不同")
check("拼块的闸门不过时报的是闸门的原因", planSkip(patched(leTIFF, at: 4, 2, width: 4), 6), "IFD0 的位置越界")

print("RAW 的 EXIF 照搬：拼好的块放进 HEIC，GPS 的分数原样、空串标签还在")
let carryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("glint-rawcarry-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: carryRoot, withIntermediateDirectories: true)
let carryDNG = carryRoot.appendingPathComponent("源.dng")
try? makeDNG(DNGSpec()).write(to: carryDNG)
var systemOpts = rawOpts
systemOpts.rawExif = false
let systemHEIC = carryRoot.appendingPathComponent("系统重写.heic")
_ = convert(carryDNG, opts: systemOpts, dest: systemHEIC)
/// 一份 HEIC 里 Exif 项的条目：(IFD, 标签) → 值的十六进制。
func heicEntries(_ bytes: [UInt8]) -> [String: String] {
    guard case .tiff(let t) = heifExif(bytes) else { return [:] }
    var out: [String: String] = [:]
    for e in rawExifEntries(t) { out["\(e.ifd) \(String(format: "%04X", e.tag))"] = e.value.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "值读不出" }
    return out
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
let dngBytes = (try? [UInt8](Data(contentsOf: carryDNG))) ?? []
let dngEntries = TIFFStructure(dngBytes, base: 0, length: dngBytes.count).map(rawExifEntries) ?? []
let dngLatitude = dngEntries.first { $0.space == .gps && $0.tag == 0x0002 }?.value.map(hex)
if let heic = try? [UInt8](Data(contentsOf: systemHEIC)), !cr3Block.isEmpty {
    check("前提：系统重写的产物里 GPS 的秒被重新编过、没有空串的 CameraOwnerName",
          [dngLatitude != nil && heicEntries(heic)["GPS 0002"] == dngLatitude, heicEntries(heic)["ExifIFD A430"] == nil], [false, true])
    if case .success(let carried) = carryingExif(cr3Block, into: heic) {
        let entries = heicEntries(carried)
        if case .tiff(let t) = heifExif(carried) {
            check("读回的 EXIF 与 CR3 拼出来的块逐字节相同", Array(t.bytes[t.base..<(t.base + t.length)]), cr3Block)
        } else { fail("照搬后读不出 Exif 项") }
        check("GPS 的纬度、经度、海拔、时间戳：分数逐字节原样",
              ["0002", "0004", "0006", "0007"].map { entries["GPS \($0)"] },
              [2, 4, 5, 7].map { hex(sampleLE.gps[$0].value) })
        check("空串的 CameraOwnerName（32 个 NUL）与 Satellites（1 个 NUL）还在",
              [entries["ExifIFD A430"], entries["GPS 0008"]], [hex([UInt8](repeating: 0, count: 32)), "00"])
        check("MakerNote 不在", entries["ExifIFD 927C"], nil)
        let url = carryRoot.appendingPathComponent("照搬.heic")
        try? Data(carried).write(to: url)
        let view = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { metadataKeySpace(of: $0, url: url, repairing: false) } ?? [:]
        check("ImageIO 读得出照搬后的相机与镜头", [view["{TIFF}/Model"], view["{Exif}/LensModel"]], ["Canon EOS R5", "RF24-105mm F4 L IS USM"])
    } else { fail("CR3 拼出来的块放不进 HEIC"); for _ in 0..<4 { fail("（同上）") } }
    // 佳能 CR3 关着定位时 GPS 字典里只有 GPSVersion：ImageIO 重写时整个丢掉；照搬后 GPS IFD 原样在产物里。
    // ImageIO 读 HEIC 时显示不显示它，实测取决于 GPS IFD 里还有没有别的条目（哪怕是个空串）：只有
    // GPSVersion 一条时不显示，多一条空串的 Satellites 就显示。两种都钉住，ImageIO 变了要重看校验的预期。
    // （手写的 DNG 复现不了：ImageIO 读 DNG 时连源里的这种 GPS 字典都不显示。）
    for (what, gps, shown) in [("只有 GPSVersion", [sampleLE.gps[0]], false),
                               ("GPSVersion 加空串的 Satellites", [sampleLE.gps[0], sampleLE.gps[6]], true)] {
        var versionOnly = sampleLE
        versionOnly.gps = gps
        let versionBlock = rawBlock(cr3Sample(versionOnly), cr3Type) ?? []
        if case .success(let carried) = carryingExif(versionBlock, into: heic) {
            let url = carryRoot.appendingPathComponent("\(what).heic")
            try? Data(carried).write(to: url)
            let view = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { metadataKeySpace(of: $0, url: url, repairing: false) } ?? [:]
            check("\(what)：照搬后 GPS IFD 原样在产物里", heicEntries(carried)["GPS 0000"], "02030000")
            check("\(what)：ImageIO 读 HEIC 时\(shown ? "" : "不")显示 GPSVersion",
                  collapsingVersions(view)["{GPS}/GPSVersion"], shown ? "2.3.0.0" : nil)
        } else { fail("\(what) 的块放不进 HEIC"); fail("（同上）") }
    }
} else {
    fail("系统重写的 HEIC 或 CR3 的块没造出来"); for _ in 0..<9 { fail("（同上）") }
}

print("RAW 的转换：EXIF 整块照搬，--no-raw-exif 不照搬，闸门不过时照常转完")
let dngBlock = rawBlock(dngBytes)
check("前提：DNG 夹具拼得出块", dngBlock != nil, true)
let carriedHEIC = carryRoot.appendingPathComponent("转换照搬.heic")
if case .converted(let r) = convert(carryDNG, opts: rawOpts, dest: carriedHEIC), let dngBlock {
    check("DNG：照搬了，字节数是拼出来的块的", r.rawExif, .carried(bytes: dngBlock.count, commentRewritten: false))
    let bytes = (try? [UInt8](Data(contentsOf: carriedHEIC))) ?? []
    if case .tiff(let t) = heifExif(bytes) {
        check("DNG：产物的 EXIF 与拼出来的块逐字节相同", Array(t.bytes[t.base..<(t.base + t.length)]), dngBlock)
    } else { fail("DNG：产物里读不出 Exif 项") }
    check("DNG：产物仍是 10 位", imageDepth(carriedHEIC), 10)
    check("DNG：产物的 GPS 纬度与源的分数逐字节相同", heicEntries(bytes)["GPS 0002"], dngLatitude)
    check("DNG：MakerNote 没搬、空串的 CameraOwnerName 搬了",
          [heicEntries(bytes)["ExifIFD 927C"], heicEntries(bytes)["ExifIFD A430"]], [nil, hex([UInt8](repeating: 0, count: 32))])
} else { fail("DNG 没转成"); for _ in 0..<4 { fail("（同上）") } }
let systemBytes = (try? [UInt8](Data(contentsOf: systemHEIC))) ?? []
if case .converted(let r) = convert(carryDNG, opts: systemOpts, dest: carryRoot.appendingPathComponent("系统重写2.heic")) {
    check("--no-raw-exif：RAW 也不照搬（报告里没有照搬那一项）", r.rawExif == nil, true)
} else { fail("--no-raw-exif 的 DNG 没转成") }
check("--no-raw-exif：产物的 EXIF 是 ImageIO 写的，与拼出来的块不同",
      { if case .tiff(let t) = heifExif(systemBytes) { return Array(t.bytes[t.base..<(t.base + t.length)]) != dngBlock }; return false }(), true)
// 闸门不过：GPS 指针改到文件外。ImageIO 照样认作 RAW、转得出 10 位的产物，EXIF 保持它写的那份。
var brokenDNG = dngBytes
if let tiff = TIFFStructure(dngBytes, base: 0, length: dngBytes.count), let ifd0 = tiff.ifd0,
   let p = entryAt(dngBytes, ifd: ifd0, tag: 0x8825) {
    brokenDNG = patched(dngBytes, at: p + 8, 0x7FFF_FFF0, width: 4)
}
let brokenURL = carryRoot.appendingPathComponent("坏GPS.dng")
try? Data(brokenDNG).write(to: brokenURL)
let brokenDest = carryRoot.appendingPathComponent("坏GPS.heic")
if case .converted(let r) = convert(brokenURL, opts: rawOpts, dest: brokenDest) {
    check("闸门不过：照常转完，报告里写着原因", r.rawExif, .kept("GPS IFD 的位置越界"))
    check("闸门不过：产物仍是 10 位", imageDepth(brokenDest), 10)
} else { fail("GPS 指针坏了的 DNG 没转成"); fail("（同上）") }
// 方向 6 的 DNG：块里是 6，产物也是 6，照搬。
var sixSpec = DNGSpec()
sixSpec.orientation = 6
let sixURL = carryRoot.appendingPathComponent("竖.dng")
try? makeDNG(sixSpec).write(to: sixURL)
if case .converted(let r) = convert(sixURL, opts: rawOpts, dest: carryRoot.appendingPathComponent("竖.heic")),
   case .carried? = r.rawExif {
    check("方向 6 的 DNG：照搬后方向仍是 6",
          CGImageSourceCreateWithURL(carryRoot.appendingPathComponent("竖.heic") as CFURL, nil)
              .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyOrientation] as? Int, 6)
} else { fail("方向 6 的 DNG 没有照搬") }

print("RAW 照搬的自检：以字节为证，块与 RAW 的条目逐字节相同、ImageIO 读 HEIC 与读 JPEG 包装的相同")
/// 把 `block` 照搬进系统重写的 DNG 产物，过一遍自检。
func regression(_ block: [UInt8], source: RawExifParts) -> String? {
    guard let carried = try? carryingExif(block, into: systemBytes).get() else { return "放不进" }
    let after = carryRoot.appendingPathComponent("自检-\(UUID().uuidString).heic")
    try? Data(carried).write(to: after)
    return cameraRawExifRegression(source: source, intended: block, before: systemHEIC, after: after)
}
if case .success(let parts) = cameraRawExifParts(dngBytes, type: dngType) {
    var noMake = parts
    noMake.ifd0.removeAll { $0.tag == 0x010F }
    let full = assembledExifTIFF(parts)!
    check("前提：完整的块就是 cameraRawExifTIFF 拼出来的那块", full, dngBlock ?? [])
    check("完整的块：换得上", regression(full, source: parts), nil)
    check("块里少了 Make：不换，说出是哪一条", regression(assembledExifTIFF(noMake)!, source: parts),
          "拼出来的块与 RAW 里的条目不一致：丢失 {TIFF}/Make（0x010F）")
} else { fail("读不出 DNG 的 EXIF 材料"); fail("（同上）"); fail("（同上）") }
check("ImageIO 的读法：两边相同", exifReadingMismatch(reference: ["{Exif}/A": "1"], heic: ["{Exif}/A": "1"], before: [:]), nil)
check("ImageIO 的读法：HEIC 里读不出", exifReadingMismatch(reference: ["{Exif}/A": "1"], heic: [:], before: [:]),
      "照搬后 HEIC 里读不出 {Exif}/A（把块包进 JPEG 读得出）")
check("ImageIO 的读法：值不同", exifReadingMismatch(reference: ["{GPS}/Altitude": "7.650000095368341"], heic: ["{GPS}/Altitude": "7.65"], before: [:]),
      "照搬后 HEIC 里 {GPS}/Altitude 与把块包进 JPEG 读出的不同")
check("ImageIO 的读法：HEIC 多出瓦片宽高不算", exifReadingMismatch(reference: [:], heic: ["{TIFF}/TileWidth": "256", "XMP/tiff:TileLength": "192"], before: [:]), nil)
check("ImageIO 的读法：HEIC 多出照搬前就有的（XMP 包调和出来的）不算",
      exifReadingMismatch(reference: [:], heic: ["{TIFF}/ImageDescription": "说明"], before: ["{TIFF}/ImageDescription": "说明"]), nil)
check("ImageIO 的读法：HEIC 多出照搬前没有的",
      exifReadingMismatch(reference: [:], heic: ["{Exif}/ISOSpeed": "100"], before: ["{Exif}/ISOSpeed": "200"]),
      "照搬后 HEIC 里多出 {Exif}/ISOSpeed（把块包进 JPEG 读不出）")
check("块大于一个 APP1：包不进 JPEG", jpegWrapping(exif: [UInt8](repeating: 0, count: 0xFFF8)) == nil, true)
check("块正好放得下一个 APP1：包得进", jpegWrapping(exif: [UInt8](repeating: 0, count: 0xFFF7)) != nil, true)

print("RAW 照搬的核对：按原始字节逐条比类型、个数、值")
/// 按真 CR3 的结构（主会话给的标签号与类型，值是编的）手搭：CMT1、CMT2、CMT4（只有 GPSVersion、没有 CMT4 两种变体）。
struct RealCR3 {
    static func o(_ v: Int, _ w: Int) -> [UInt8] { ordered(v, w, false) }
    static func r(_ tag: Int, _ p: [(Int, Int)], signed: Bool = false) -> RT { RT(tag, signed ? 10 : 5, p.count, p.flatMap { o($0.0, 4) + o($0.1, 4) }) }
    static func s(_ tag: Int, _ v: Int) -> RT { RT(tag, 3, 1, o(v, 2)) }
    static let cmt1: [RT] = [s(0x0100, 8192), s(0x0101, 5464), RT(0x0102, 3, 3, o(8, 2) + o(8, 2) + o(8, 2)), s(0x0103, 6),
                             asciiRT(0x010F, "Canon"), asciiRT(0x0110, "Canon EOS R5"), s(0x0112, 1), r(0x011A, [(72, 1)]),
                             r(0x011B, [(72, 1)]), s(0x0128, 2), asciiRT(0x0132, "2024:05:06 07:08:09"),
                             RT(0x013B, 2, 64, [UInt8](repeating: 0, count: 64)), RT(0x8298, 2, 64, [UInt8](repeating: 0, count: 64))]
    static let cmt2: [RT] = [r(0x829A, [(1, 250)]), r(0x829D, [(28, 10)]), s(0x8822, 3), s(0x8827, 100), s(0x8830, 2),
                             RT(0x8832, 4, 1, o(100, 4)), RT(0x9000, 7, 4, Array("0231".utf8)), asciiRT(0x9003, "2024:05:06 07:08:09"),
                             asciiRT(0x9004, "2024:05:06 07:08:09"), asciiRT(0x9010, "+02:00"), asciiRT(0x9011, "+02:00"),
                             asciiRT(0x9012, "+02:00"), RT(0x9101, 7, 4, [1, 2, 3, 0]), r(0x9201, [(8, 1)], signed: true),
                             r(0x9202, [(3, 1)]), r(0x9204, [(0, 1)], signed: true), s(0x9207, 5), s(0x9209, 16), r(0x920A, [(50, 1)]),
                             RT(0x9286, 7, 264, [UInt8](repeating: 0, count: 264)), asciiRT(0x9290, "12"), asciiRT(0x9291, "12"),
                             asciiRT(0x9292, "12"), RT(0xA000, 7, 4, Array("0100".utf8)), s(0xA001, 1), s(0xA002, 8192), s(0xA003, 5464),
                             r(0xA20E, [(8192000, 1419)]), r(0xA20F, [(5464000, 947)]), s(0xA210, 2), s(0xA401, 0), s(0xA402, 0),
                             s(0xA403, 0), s(0xA406, 0), RT(0xA430, 2, 32, [UInt8](repeating: 0, count: 32)),
                             asciiRT(0xA431, "012345678901"), r(0xA432, [(24, 1), (105, 1), (0, 0), (0, 0)]),
                             asciiRT(0xA434, "RF24-105mm F4 L IS USM"), asciiRT(0xA435, "0000000000")]
    /// 海拔用佳能那种非 100 的分母（ImageIO 读 CR3 给 7.650000095368341）。
    static let cmt4: [RT] = [RT(0x0000, 1, 4, [2, 3, 0, 0]), RT(0x0001, 2, 2, Array("N\0".utf8)),
                             r(0x0002, [(69, 1), (11, 1), (387060, 10000)]), RT(0x0003, 2, 2, Array("E\0".utf8)),
                             r(0x0004, [(18, 1), (57, 1), (123456789, 1000000)]), RT(0x0005, 1, 1, [0]),
                             r(0x0006, [(4010765, 524283)]), r(0x0007, [(10, 1), (42, 1), (75, 10)]), RT(0x0008, 2, 1, [0]),
                             RT(0x0009, 2, 2, Array("A\0".utf8)), asciiRT(0x0012, "WGS-84"), asciiRT(0x001D, "2024:05:06")]
    static func bytes(gps: [RT]?) -> [UInt8] {
        var cmts: [(String, [UInt8])] = [("CMT1", rawTIFF(ifd0: cmt1).bytes), ("CMT2", rawTIFF(ifd0: cmt2).bytes),
                                         ("CMT3", Array("CANON MAKERNOTE".utf8))]
        if let gps { cmts.append(("CMT4", rawTIFF(ifd0: gps).bytes)) }
        return cr3Sample(cmts: cmts)
    }
}
let realCR3 = RealCR3.bytes(gps: RealCR3.cmt4)
if case .success(let parts) = cameraRawExifParts(realCR3, type: cr3Type), let block = rawBlock(realCR3, cr3Type) {
    check("真 CR3 的结构：IFD0 留下 Make、Model、方向、分辨率、时间、作者、版权，宽高与 BitsPerSample、Compression 不留",
          parts.ifd0.map(\.tag), [0x010F, 0x0110, 0x0112, 0x011A, 0x011B, 0x0128, 0x0132, 0x013B, 0x8298])
    check("真 CR3 的结构：CMT2 的 39 条、CMT4 的 12 条都在块里", [parts.exif.count, parts.gps.count], [39, 12])
    check("真 CR3 的结构：块与 RAW 的条目逐字节相同",
          carriedEntryIssues(source: parts, product: TIFFStructure(block, base: 0, length: block.count)), [])
    check("真 CR3 的结构：照搬进 HEIC 后自检通过（ISO 换名、OffsetTime、海拔、空串都不挡）", regression(block, source: parts), nil)
    // 字节比对：类型、个数、值，少了、多了，都报。
    func issues(_ edit: (inout RawExifParts) -> Void) -> [String] {
        var changed = parts
        edit(&changed)
        let b = assembledExifTIFF(changed)!
        return carriedEntryIssues(source: parts, product: TIFFStructure(b, base: 0, length: b.count))
    }
    check("类型不同、值字节相同：报变化", issues { p in
        p.exif = p.exif.map { $0.tag == 0x8832 ? CarriedEntry(tag: 0x8832, type: 9, count: 1, value: $0.value) : $0 }
    }, ["变化 {Exif}/RecommendedExposureIndex（0x8832）：LONG × 1 100 → SLONG × 1 100"])
    check("个数不同：报变化", issues { p in
        p.exif = p.exif.map { $0.tag == 0xA430 ? CarriedEntry(tag: 0xA430, type: 2, count: 31, value: Array($0.value.prefix(31))) : $0 }
    }.count, 1)
    check("GPS 海拔的分数重算过：报变化", issues { p in
        p.gps = p.gps.map { $0.tag == 0x0006 ? CarriedEntry(tag: 6, type: 5, count: 1, value: le32(765) + le32(100)) : $0 }
    }.map { String($0.prefix(25)) }, ["变化 {GPS}/Altitude（0x0006）"])
    check("少了 OffsetTime：报丢失", issues { p in p.exif.removeAll { $0.tag == 0x9010 } }, ["丢失 {Exif}/OffsetTime（0x9010）"])
    check("多出一条：报多出", issues { p in let x = asciiRT(0xA433, "Canon"); p.exif.append(CarriedEntry(tag: x.tag, type: x.type, count: x.count, value: x.value)) }, ["多出 {Exif}/LensMake（0xA433）"])
    check("字节序不同：每条都报", issues { p in p.bigEndian = true }.isEmpty, false)
    check("产物的 EXIF 读不出：照实说", carriedEntryIssues(source: parts, product: nil), ["产物里的 EXIF 读不出，无法按原始字节核对"])

    print("RAW 照搬成功时的 --verify：EXIF 派生的视图键改由原始字节核对，只剩 MakerNote 一行")
    // 源的视图照真 CR3 的读法手写（ISO 叫 ISOSpeed、没有 OffsetTime、海拔 7.650000095368341、空串显示出来、
    // 有 {MakerCanon}）；产物的视图是真把块照搬进 HEIC 后 ImageIO 读出来的。
    let carried = try! carryingExif(block, into: systemBytes).get()
    let carriedURL = carryRoot.appendingPathComponent("真CR3结构.heic")
    try? Data(carried).write(to: carriedURL)
    let productView = CGImageSourceCreateWithURL(carriedURL as CFURL, nil).map { metadataKeySpace(of: $0, url: carriedURL, repairing: false) } ?? [:]
    check("前提：产物视图里 ISO 叫 ISOSpeedRatings、显示 OffsetTime、海拔读成 7.650000095368341",
          [productView["{Exif}/ISOSpeedRatings[0]"], productView["{Exif}/OffsetTime"], productView["{GPS}/Altitude"]],
          ["100", "+02:00", "7.650000095368341"])
    let cr3View: [String: String] = [
        "{Exif}/ISOSpeed": "100", "XMP/exifEX:ISOSpeed": "100", "{Exif}/CameraOwnerName": "", "XMP/exifEX:CameraOwnerName": "",
        "{Exif}/ExifVersion[0]": "48", "{Exif}/ExifVersion[1]": "50", "{Exif}/ExifVersion[2]": "51", "{Exif}/ExifVersion[3]": "49",
        "{GPS}/Altitude": "7.650000095368341", "XMP/exif:GPSAltitude": "4010765/524283", "{GPS}/Satellites": "",
        "{GPS}/Latitude": "69.19408500000001", "XMP/exif:GPSLatitude": "69,11.645100N", "XMP/exif:GPSLatitudeRef": "N",
        "{TIFF}/Make": "Canon", "{TIFF}/Model": "Canon EOS R5", "XMP/tiff:Make": "Canon", "{TIFF}/Orientation": "1",
        "{raw}/SensorSize/Width": "8192", "Orientation": "1", "{MakerCanon}/AFInfo[0]": "1",
    ]
    let makerLine = "丢失 厂商私有数据 MakerNote（1 项：{MakerCanon} 1 项）——ImageIO 读不出原始 MakerNote，也无法把它写入 HEIF"
    check("真 CR3 的读法对照搬后的产物：键空间只报 MakerNote", rawCarriedKeySpaceDiff(before: cr3View, after: productView, packets: []),
          [makerLine])
    check("真 CR3 的读法对照搬后的产物：原始字节没有差异",
          { () -> [String] in if case .tiff(let t) = heifExif(carried) { return carriedEntryIssues(source: parts, product: t) }; return ["读不出"] }(), [])
    check("同样的源视图按第 1 段的规则比：一堆误报（ISO、空串、GPS 一行……）",
          rawKeySpaceDiff(before: cr3View, after: productView).count > 3, true)
    var withXMP = cr3View
    withXMP["XMP/xmp:Rating"] = "3"
    withXMP["XMP/dc:title[x-default]"] = "标题"
    check("XMP 包里非 EXIF 派生的键照比", rawCarriedKeySpaceDiff(before: withXMP, after: productView, packets: []),
          ["丢失 XMP/dc:title[x-default] = 标题", "丢失 XMP/xmp:Rating = 3", makerLine])
    let packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF><rdf:Description exif:GPSAltitude=\"4010765/524283\"/></rdf:RDF></x:xmpmeta>"
    var nativeView = cr3View
    nativeView["XMP/exif:GPSAltitude"] = "765/100"
    check("源的 XMP 包里自己写了 exif:GPSAltitude：不当作 EXIF 派生，照比",
          rawCarriedKeySpaceDiff(before: nativeView, after: productView, packets: [packet]),
          ["变化 XMP/exif:GPSAltitude: 765/100 → 4010765/524283", makerLine])
} else { fail("真 CR3 结构的样本拼不出"); for _ in 0..<16 { fail("（同上）") } }
check("包里有这个属性才算包里写的", [isNativeXMPKey("XMP/exif:GPSAltitude", packets: ["<x:xmpmeta><a exif:GPSAltitude=\"1\"/></x:xmpmeta>"]),
                                    isNativeXMPKey("XMP/exif:GPSAltitude", packets: ["<x:xmpmeta><a exif:GPSAltitudeRef=\"1\"/></x:xmpmeta>"]),
                                    isNativeXMPKey("XMP/exif:ISOSpeedRatings[0]", packets: ["<exif:ISOSpeedRatings>"]),
                                    isNativeXMPKey("XMP/exif:GPSAltitude", packets: [])], [true, false, true, false])
check("扫得出文件里的每个 XMP 包", xmpPacketTexts(Array("junk<x:xmpmeta a>1</x:xmpmeta>junk<x:xmpmeta b>2</x:xmpmeta><x:xmpmeta".utf8)),
      ["<x:xmpmeta a>1</x:xmpmeta>", "<x:xmpmeta b>2</x:xmpmeta>"])
check("EXIF 派生的键：{Exif}、{GPS}、{TIFF} 与 XMP 的 exif:、exifEX:、tiff:",
      ["{Exif}/ISOSpeed", "{GPS}/Altitude", "{TIFF}/Make", "XMP/exif:GPSAltitude", "XMP/exifEX:ISOSpeed", "XMP/tiff:Make",
       "{ExifAux}/LensID", "{MakerCanon}/AFInfo", "XMP/xmp:Rating", "XMP/dc:title[x-default]", "{IPTC}/Byline[0]"].map(isExifDerivedKey),
      [true, true, true, true, true, true, false, false, false, false, false])
for (what, gps, want) in [("CMT4 只有 GPSVersion", [RealCR3.cmt4[0]] as [RT]?, 1), ("没有 CMT4", nil, 0)] {
    let bytes = RealCR3.bytes(gps: gps)
    if case .success(let parts) = cameraRawExifParts(bytes, type: cr3Type), let block = rawBlock(bytes, cr3Type) {
        check("\(what)：照搬，GPS IFD 有 \(want) 条", parts.gps.count, want)
        check("\(what)：块里\(want == 0 ? "没有" : "有") GPS 指针",
              TIFFStructure(block, base: 0, length: block.count).flatMap { t in t.ifd0.map { t.find($0, tag: 0x8825) != nil } }, want != 0)
        check("\(what)：自检通过", regression(block, source: parts), nil)
    } else { fail("\(what)：没拼出来"); fail("（同上）"); fail("（同上）") }
}

print("RW2：EXIF 取内嵌 JPEG（JpgFromRaw）的，RW2 自己那份 Exif IFD 得是它的子集")
/// 照真 RW2 的结构手搭：内嵌 JPEG 的 IFD0、35 条的 Exif IFD（含 MakerNote 与 Interop 指针）；RW2 的 IFD0 是
/// 松下私有标签、JpgFromRaw、Make/Model/StripOffsets…、Exif 指针，它的 Exif IFD 是内嵌那份里的 12 条。
struct RealRW2 {
    static func o(_ v: Int, _ w: Int) -> [UInt8] { ordered(v, w, false) }
    static func r(_ tag: Int, _ p: [(Int, Int)], signed: Bool = false) -> RT { RT(tag, signed ? 10 : 5, p.count, p.flatMap { o($0.0, 4) + o($0.1, 4) }) }
    static func s(_ tag: Int, _ v: Int) -> RT { RT(tag, 3, 1, o(v, 2)) }
    static let jpegIFD0: [RT] = [asciiRT(0x010F, "Panasonic"), asciiRT(0x0110, "DC-S5M2"), s(0x0112, 6), r(0x011A, [(180, 1)]),
                                 r(0x011B, [(180, 1)]), s(0x0128, 2), asciiRT(0x0131, "Ver.2.0"), asciiRT(0x0132, "2024:05:06 07:08:09"),
                                 asciiRT(0x013B, "Glint Tester"), s(0x0213, 2), RT(0xC4A5, 7, 8, Array("PrintIM\0".utf8)),
                                 RT(0xC6D2, 7, 8, Array("Title 1\0".utf8)), RT(0xC6D3, 7, 8, Array("Title 2\0".utf8))]
    static let subsetTags: [Int] = [0x829A, 0x829D, 0x8822, 0x9000, 0x9003, 0x9004, 0x9204, 0x9205, 0x9207, 0x9209, 0x920A, 0xA300]
    static let jpegExif: [RT] = [r(0x829A, [(1, 160)]), r(0x829D, [(40, 10)]), s(0x8822, 3), s(0x8827, 200), s(0x8830, 1),
                                 RT(0x9000, 7, 4, Array("0231".utf8)), asciiRT(0x9003, "2024:05:06 07:08:09"),
                                 asciiRT(0x9004, "2024:05:06 07:08:09"), RT(0x9101, 7, 4, [1, 2, 3, 0]), r(0x9102, [(4, 1)]),
                                 r(0x9204, [(0, 100)], signed: true), r(0x9205, [(925, 256)]), s(0x9207, 5), s(0x9208, 0), s(0x9209, 16),
                                 r(0x920A, [(50, 1)]), RT(0x927C, 7, 40, Array("Panasonic\0\0\0".utf8) + [UInt8](repeating: 7, count: 28)),
                                 RT(0xA000, 7, 4, Array("0100".utf8)), s(0xA001, 1), RT(0xA002, 4, 1, o(1920, 4)),
                                 RT(0xA003, 4, 1, o(1440, 4)), s(0xA217, 2), RT(0xA300, 7, 1, [3]), RT(0xA301, 7, 1, [1]), s(0xA401, 0),
                                 s(0xA402, 0), s(0xA403, 0), r(0xA404, [(0, 10)]), s(0xA405, 50), s(0xA406, 0), s(0xA407, 0), s(0xA408, 0),
                                 s(0xA409, 0), s(0xA40A, 0)]
    static let interop: [RT] = [RT(0x0001, 2, 4, Array("R98\0".utf8)), RT(0x0002, 7, 4, Array("0100".utf8))]
    static func jpeg(exif: [RT] = jpegExif) -> [UInt8] { jpegWithExif(rawTIFF(ifd0: jpegIFD0, exif: exif, interop: interop).bytes) }
    static func bytes(jpeg: [UInt8]? = jpeg(), subset: [RT]? = nil) -> [UInt8] {
        var ifd0: [RT] = (1...0x2D).filter { $0 % 7 == 1 }.map { s($0, $0 * 10) }
        if let jpeg { ifd0.append(RT(0x002E, 7, jpeg.count, jpeg)) }
        ifd0 += [asciiRT(0x010F, "Panasonic"), asciiRT(0x0110, "DC-S5M2"), RT(0x0111, 4, 1, o(4096, 4)), s(0x0112, 6),
                 s(0x0116, 16), RT(0x0117, 4, 1, o(64, 4)), s(0x0118, 0), s(0x0119, 0), r(0x011A, [(180, 1)]), r(0x011B, [(180, 1)])]
        let own = subset ?? jpegExif.filter { subsetTags.contains($0.tag) }
        return rawTIFF(magic: 0x55, ifd0: ifd0, exif: own).bytes
    }
}
let rw2Type = "com.panasonic.rw2-raw-image"
if case .success(let parts) = cameraRawExifParts(RealRW2.bytes(), type: rw2Type) {
    check("RW2：IFD0 取内嵌 JPEG 的，留下松下的两个标题，YCbCrPositioning、PrintIM 不留",
          parts.ifd0.map(\.tag), [0x010F, 0x0110, 0x0112, 0x011A, 0x011B, 0x0128, 0x0131, 0x0132, 0x013B, 0xC6D2, 0xC6D3])
    check("RW2：Exif IFD 取内嵌 JPEG 的 35 条，去掉 MakerNote 与 Interop 指针还剩 33 条", [parts.exif.count, parts.exif.contains { $0.tag == 0x927C } ? 1 : 0], [33, 0])
    check("RW2：Interop 跟着搬", parts.interop.map(\.tag), [0x0001, 0x0002])
    check("RW2：块与直接拼内嵌 JPEG 的 EXIF 相同", rawBlock(RealRW2.bytes(), rw2Type) ?? [],
          rawBlock(rafSample(jpeg: RealRW2.jpeg()), rafType) ?? [1])
} else { fail("真 RW2 结构的样本拼不出"); for _ in 0..<3 { fail("（同上）") } }
var badSubset = RealRW2.jpegExif.filter { RealRW2.subsetTags.contains($0.tag) }
badSubset[0] = RealRW2.r(0x829A, [(1, 200)])
check("RW2 自己的 Exif IFD 与内嵌的值不同：不照搬", rawSkip(RealRW2.bytes(subset: badSubset), rw2Type),
      "RW2 的 Exif IFD 里 0x829A 与内嵌 JPEG 的不同")
check("RW2 自己的 Exif IFD 有内嵌那份没有的标签：不照搬",
      rawSkip(RealRW2.bytes(subset: RealRW2.jpegExif.filter { RealRW2.subsetTags.contains($0.tag) } + [RealRW2.s(0xA420, 1)]), rw2Type),
      "RW2 的 Exif IFD 里有 0xA420，内嵌 JPEG 的 EXIF 里没有")
check("RW2 自己的 Exif IFD 里有内嵌那份去掉的 MakerNote：不照搬",
      rawSkip(RealRW2.bytes(subset: [RealRW2.jpegExif.first { $0.tag == 0x927C }!]), rw2Type),
      "RW2 的 Exif IFD 里有 0x927C，内嵌 JPEG 的 EXIF 里没有")
check("RW2 没有 JpgFromRaw：不照搬", rawSkip(RealRW2.bytes(jpeg: nil), rw2Type), "RW2 里没有内嵌的 JPEG（JpgFromRaw）")
check("RW2 内嵌的 JPEG 没有 EXIF：不照搬", rawSkip(RealRW2.bytes(jpeg: [0xFF, 0xD8, 0xFF, 0xD9]), rw2Type), "RW2 内嵌的 JPEG：源里没有 EXIF 段")
let rw2Bytes = RealRW2.bytes()
check("RW2 截断在每一个位置：不崩，拼得出的都是合法的块",
      (0..<rw2Bytes.count).filter { rawBlock(Array(rw2Bytes.prefix($0)), rw2Type).map { !wellFormed($0) } ?? false }, [])
try? FileManager.default.removeItem(at: carryRoot)

print("RAW 的校验：结构字段白名单，只放实测过的")
for key in ["{raw}/CropSize/Width", "{raw}/SensorSize/Height", "{raw}/Thumbnails[0]/Width", "{DNG}/ColorMatrix1[3]",
            "{DNG}/DNGVersion[0]", "{DNG}/UniqueCameraModel", "{Exif}/CFAPattern[2]", "{TIFF}/BitsPerPixel[0]",
            "{TIFF}/Width", "{TIFF}/Height", "XMP/tiff:Compression", "{TIFF}/PhotometricInterpretation",
            "XMP/tiff:PhotometricInterpretation"] {
    checkRule(key, isRawStructuralKey(key), true, "结构字段不比")
}
for key in ["{Raw}/CropSize/Width", "{DNGPrivate}/X", "{GPS}/Latitude", "{GPS}/GPSVersion", "{Exif}/ExifVersion",
            "{Exif}/CameraOwnerName", "{Exif}/CFAPatternX", "{TIFF}/Model", "{TIFF}/WidthX", "{TIFF}/Orientation",
            "{MakerCanon}/AFInfo[0]", "XMP/tiff:Compressions", "XMP/exif:GPSLatitude", "XMP/tiff:ImageWidth",
            "{TIFF}/PhotometricInterpretationX", "XMP/tiff:PhotometricInterpretations"] {
    checkRule(key, isRawStructuralKey(key), false, "白名单外的字段照比")
}

print("RAW 的校验：版本号按规范写法比，按源的原值")
let cr3Version = ["{Exif}/ExifVersion[0]": "48", "{Exif}/ExifVersion[1]": "50", "{Exif}/ExifVersion[2]": "51",
                  "{Exif}/ExifVersion[3]": "49", "{Exif}/FlashPixVersion[0]": "48", "{Exif}/FlashPixVersion[1]": "49",
                  "{Exif}/FlashPixVersion[2]": "48", "{Exif}/FlashPixVersion[3]": "48",
                  "{GPS}/GPSVersion[0]": "2", "{GPS}/GPSVersion[1]": "3", "{GPS}/GPSVersion[2]": "0", "{GPS}/GPSVersion[3]": "0"]
check("规范化：三个字段各合成一个键", collapsingVersions(cr3Version),
      ["{Exif}/ExifVersion": "0231", "{Exif}/FlashPixVersion": "0100", "{GPS}/GPSVersion": "2.3.0.0"])
let fixedVersion = ["{Exif}/ExifVersion[0]": "2", "{Exif}/ExifVersion[1]": "3", "{Exif}/ExifVersion[2]": "1",
                    "{Exif}/FlashPixVersion[0]": "1", "{Exif}/FlashPixVersion[1]": "0",
                    "{GPS}/GPSVersion[0]": "2", "{GPS}/GPSVersion[1]": "3", "{GPS}/GPSVersion[2]": "0", "{GPS}/GPSVersion[3]": "0"]
check("修整好的产物：与字符码的源等价，不报", rawKeySpaceDiff(before: cr3Version, after: fixedVersion), [])
let brokenVersion = ["{Exif}/ExifVersion[0]": "48", "{Exif}/ExifVersion[1]": "0", "{Exif}/ExifVersion[2]": "1",
                     "{Exif}/FlashPixVersion[0]": "48", "{Exif}/FlashPixVersion[1]": "9", "{Exif}/FlashPixVersion[2]": "8"]
check("修整没修好：照报（写坏的、写丢的）", rawKeySpaceDiff(before: cr3Version, after: brokenVersion),
      ["变化 {Exif}/ExifVersion: 0231 → 4801", "变化 {Exif}/FlashPixVersion: 0100 → 4898", "丢失 {GPS}/GPSVersion = 2.3.0.0"])
check("空字符串的 CameraOwnerName 丢了照报",
      rawKeySpaceDiff(before: ["{Exif}/CameraOwnerName": "", "{TIFF}/Model": "EOS R5"], after: ["{TIFF}/Model": "EOS R5"]),
      ["丢失 {Exif}/CameraOwnerName = "])
check("结构字段之外的丢失照报，MakerNote 照旧一行",
      rawKeySpaceDiff(before: ["{DNG}/BlackLevel[0]": "0", "{raw}/CropSize/Width": "256", "{Exif}/CFAPattern[0]": "0",
                               "{Exif}/LensModel": "RF50mm", "{MakerCanon}/AFInfo[0]": "1"], after: [:]),
      ["丢失 {Exif}/LensModel = RF50mm",
       "丢失 厂商私有数据 MakerNote（1 项：{MakerCanon} 1 项）——ImageIO 读不出原始 MakerNote，也无法把它写入 HEIF"])
check("顶层 Orientation 不在键空间里报（rawProductIssues 核对）",
      rawKeySpaceDiff(before: ["Orientation": "6", "{TIFF}/Orientation": "6"], after: ["Orientation": "1", "{TIFF}/Orientation": "1"]),
      ["变化 {TIFF}/Orientation: 6 → 1"])

print("RAW 的校验：XMP 的版本号键是从属性视图派生的，交给属性视图那一侧比")
// 真 CR3 上量到的：源的 XMP 视图是 ImageIO 照读坏的字符码合成的（485051），产物修整后是 0231。
var cr3XMP = cr3Version
cr3XMP["XMP/exif:ExifVersion"] = "485051"; cr3XMP["XMP/exif:FlashPixVersion"] = "484948"; cr3XMP["XMP/exif:GPSVersionID"] = "2.3.0.0"
var fixedXMP = fixedVersion
fixedXMP["XMP/exif:ExifVersion"] = "0231"; fixedXMP["XMP/exif:FlashPixVersion"] = "0100"; fixedXMP["XMP/exif:GPSVersionID"] = "2.3.0.0"
check("源 XMP 版本键是乱码、属性视图正常往返：不报", rawKeySpaceDiff(before: cr3XMP, after: fixedXMP), [])
var gpsVersionLost = fixedXMP
for k in ["{GPS}/GPSVersion[0]", "{GPS}/GPSVersion[1]", "{GPS}/GPSVersion[2]", "{GPS}/GPSVersion[3]", "XMP/exif:GPSVersionID"] {
    gpsVersionLost.removeValue(forKey: k)
}
check("属性视图里丢了：仍报一行（XMP 那行不另报）", rawKeySpaceDiff(before: cr3XMP, after: gpsVersionLost),
      ["丢失 {GPS}/GPSVersion = 2.3.0.0"])
var xmpBroken = fixedXMP
xmpBroken["{Exif}/ExifVersion[0]"] = "48"; xmpBroken["{Exif}/ExifVersion[1]"] = "0"; xmpBroken["{Exif}/ExifVersion[2]"] = "1"
check("属性视图里改坏了：照报", rawKeySpaceDiff(before: cr3XMP, after: xmpBroken), ["变化 {Exif}/ExifVersion: 0231 → 4801"])
let xmpOnlySource = ["XMP/exif:ExifVersion": "0231", "XMP/exif:FlashPixVersion": "0100", "XMP/exif:GPSVersionID": "2.3.0.0"]
check("源只有 XMP 版本键：照原样比", rawKeySpaceDiff(before: xmpOnlySource,
                                                after: ["XMP/exif:ExifVersion": "0230", "XMP/exif:FlashPixVersion": "0100"]),
      ["变化 XMP/exif:ExifVersion: 0231 → 0230", "丢失 XMP/exif:GPSVersionID = 2.3.0.0"])
check("盖哪几个：属性视图里有的那几个（带下标、规范化不了的也算）",
      derivedXMPVersionKeys(["{Exif}/ExifVersion": "0231", "{GPS}/GPSVersion[0]": "2.5", "XMP/exif:FlashPixVersion": "0100"]),
      ["XMP/exif:ExifVersion", "XMP/exif:GPSVersionID"])

print("RAW 的校验：GPS 只差在取整范围内时合成一行")
// 夹具 DNG 转出来的真实值：{GPS} 的差在数值容差以内，XMP 的分被取整到 4 位、方向键丢了。
let gpsSource = ["{GPS}/Latitude": "31.22935525", "{GPS}/LatitudeRef": "N",
                 "{GPS}/Longitude": "121.4719787166667", "{GPS}/LongitudeRef": "E",
                 "XMP/exif:GPSLatitude": "31,13.761315N", "XMP/exif:GPSLatitudeRef": "N",
                 "XMP/exif:GPSLongitude": "121,28.318723E", "XMP/exif:GPSLongitudeRef": "E", "{TIFF}/Model": "TestCamera"]
let gpsProduct = ["{GPS}/Latitude": "31.229355", "{GPS}/LatitudeRef": "N",
                  "{GPS}/Longitude": "121.4719783333333", "{GPS}/LongitudeRef": "E",
                  "XMP/exif:GPSLatitude": "31,13.7613N", "XMP/exif:GPSLongitude": "121,28.3187E", "{TIFF}/Model": "TestCamera"]
let rounding = "GPS 精度降低：最大偏差 4 厘米（ImageIO 写入时取整）"
check("夹具那样的取整：合成一行", rawKeySpaceDiff(before: gpsSource, after: gpsProduct), [rounding])
check("盖住的是 XMP 的四个键", gpsRounding(before: gpsSource, after: gpsProduct).covered,
      ["XMP/exif:GPSLatitude", "XMP/exif:GPSLatitudeRef", "XMP/exif:GPSLongitude", "XMP/exif:GPSLongitudeRef"])
check("坐标没变就没有这一行", rawKeySpaceDiff(before: gpsProduct, after: gpsProduct), [])
// 高纬度的 CR3 那样：{GPS}/Latitude 在第 6–7 位小数变了，超出数值容差，也合进这一行。
var highLatSource = gpsSource, highLatProduct = gpsProduct
highLatSource["{GPS}/Latitude"] = "69.194085"; highLatProduct["{GPS}/Latitude"] = "69.1940867"
highLatSource["XMP/exif:GPSLatitude"] = "69,11.645100N"; highLatProduct["XMP/exif:GPSLatitude"] = "69,11.6452N"
check("视图键超出容差的取整也合进这一行（最大偏差 19 厘米）", rawKeySpaceDiff(before: highLatSource, after: highLatProduct),
      ["GPS 精度降低：最大偏差 19 厘米（ImageIO 写入时取整）"])
check("{GPS}/Latitude 也被盖住", gpsRounding(before: highLatSource, after: highLatProduct).covered.contains("{GPS}/Latitude"), true)
var tiny = gpsProduct
tiny["XMP/exif:GPSLatitude"] = "31,13.76130002N"
check("不到 1 厘米", gpsRounding(before: tiny, after: gpsProduct).issues, ["GPS 精度降低：最大偏差 不到 1 厘米（ImageIO 写入时取整）"])
/// 产物的纬度换成源的纬度挪 `degrees` 度（{GPS} 与 XMP 一起挪），看还合不合成一行。
func shiftedLatitude(_ degrees: Double) -> [String: String] {
    var p = gpsProduct
    p["{GPS}/Latitude"] = String(31.22935525 + degrees)
    p["XMP/exif:GPSLatitude"] = String(format: "31,%.8fN", 13.761315 + degrees * 60)
    return p
}
check("挪 0.5 米：合成一行", gpsRounding(before: gpsSource, after: shiftedLatitude(0.5 / 111_000)).issues,
      ["GPS 精度降低：最大偏差 50 厘米（ImageIO 写入时取整）"])
for (meters, label) in [(1.5, "1.5 米"), (2.0, "2 米"), (1110.0, "0.01°")] {
    let moved = shiftedLatitude(meters / 111_000)
    check("坐标真改了（\(label)）：不合成，逐字段报", gpsRounding(before: gpsSource, after: moved), GPSRounding())
    check("坐标真改了（\(label)）：差异行里有 XMP 的纬度",
          rawKeySpaceDiff(before: gpsSource, after: moved).contains { $0.hasPrefix("变化 XMP/exif:GPSLatitude:") }, true)
}
check("坐标真改了（0.01°）：{GPS}/Latitude 逐字段报",
      rawKeySpaceDiff(before: gpsSource, after: shiftedLatitude(0.01)).contains { $0.hasPrefix("变化 {GPS}/Latitude:") }, true)
var flipped = gpsProduct
flipped["{GPS}/LatitudeRef"] = "S"; flipped["XMP/exif:GPSLatitude"] = "31,13.7613S"
check("方向变了：不合成", gpsRounding(before: gpsSource, after: flipped), GPSRounding())
check("方向变了：逐字段报", rawKeySpaceDiff(before: gpsSource, after: flipped),
      ["变化 XMP/exif:GPSLatitude: 31,13.761315N → 31,13.7613S", "丢失 XMP/exif:GPSLatitudeRef = N",
       "变化 XMP/exif:GPSLongitude: 121,28.318723E → 121,28.3187E", "丢失 XMP/exif:GPSLongitudeRef = E",
       "变化 {GPS}/LatitudeRef: N → S"])
// 没有 XMP 那几个键时，方向只能靠 {GPS}/LatitudeRef 看出来（高纬度那组，{GPS}/Latitude 超出容差）。
let viewOnly = { (view: [String: String]) in view.filter { !$0.key.hasPrefix("XMP/") } }
var viewFlipped = viewOnly(highLatProduct)
viewFlipped["{GPS}/LatitudeRef"] = "S"
check("只有视图键、方向变了：不合成", gpsRounding(before: viewOnly(highLatSource), after: viewFlipped), GPSRounding())
check("只有视图键、方向没变：合成一行", gpsRounding(before: viewOnly(highLatSource), after: viewOnly(highLatProduct)).issues,
      ["GPS 精度降低：最大偏差 19 厘米（ImageIO 写入时取整）"])
var xmpOnlyFlip = gpsProduct
xmpOnlyFlip["XMP/exif:GPSLatitude"] = "31,13.7613S"
check("只有 XMP 坐标的方向变了：不合成", gpsRounding(before: gpsSource, after: xmpOnlyFlip), GPSRounding())
var xmpRefChanged = gpsProduct
xmpRefChanged["XMP/exif:GPSLatitudeRef"] = "S"
check("XMP 的方向键还在但变了：不合成", gpsRounding(before: gpsSource, after: xmpRefChanged), GPSRounding())
var noGPS = gpsProduct
for k in ["{GPS}/Latitude", "{GPS}/LatitudeRef", "{GPS}/Longitude", "{GPS}/LongitudeRef",
          "XMP/exif:GPSLatitude", "XMP/exif:GPSLongitude"] { noGPS.removeValue(forKey: k) }
check("产物里没有 GPS：不合成", gpsRounding(before: gpsSource, after: noGPS), GPSRounding())
check("产物里没有 GPS：逐字段报丢失", rawKeySpaceDiff(before: gpsSource, after: noGPS).filter { $0.hasPrefix("丢失 {GPS}/") }.count, 4)
var noXMPLat = gpsProduct
noXMPLat.removeValue(forKey: "XMP/exif:GPSLatitude")
check("XMP 坐标一边有一边没有：不合成", gpsRounding(before: gpsSource, after: noXMPLat), GPSRounding())
var sourceWithoutGPS = gpsSource
for k in ["{GPS}/Latitude", "{GPS}/Longitude"] { sourceWithoutGPS.removeValue(forKey: k) }
check("源的 {GPS} 坐标不全：不合成", gpsRounding(before: sourceWithoutGPS, after: gpsProduct), GPSRounding())
for (text, degrees, ref) in [("31,13.761315N", 31.22935525, "N"), ("31,13,45.6789N", 31 + 13.0 / 60 + 45.6789 / 3600, "N"),
                             ("121,28.3187E", 121 + 28.3187 / 60, "E"), ("0,0.5S", 0.5 / 60, "S")] {
    let got = xmpGPSCoordinate(text)
    checkRule(text, got.map { abs($0.degrees - degrees) < 1e-12 && $0.ref == ref }, true, "XMP 的 GPS 坐标读得出")
}
for text in ["31,13.76", "31N", "31,60.0N", "31,13,60N", "-31,13.7N", "31,1e3N", "31,13.7X", "３１,13.7N", "31,,13N", "31,13.7.1N"] {
    checkRule(text, xmpGPSCoordinate(text) == nil, true, "XMP 的 GPS 坐标读不出就是读不出")
}

print("RAW 的校验：产物本身——10 位、宽高不变、方向照抄")
let good: [CFString: Any] = [kCGImagePropertyDepth: 10, kCGImagePropertyPixelWidth: 256, kCGImagePropertyPixelHeight: 192,
                             kCGImagePropertyOrientation: 6]
let rawProps: [CFString: Any] = [kCGImagePropertyDepth: 16, kCGImagePropertyPixelWidth: 256, kCGImagePropertyPixelHeight: 192,
                                 kCGImagePropertyOrientation: 6]
check("都对：不报", rawProductIssues(source: rawProps, product: good), [])
var eight = good; eight[kCGImagePropertyDepth] = 8
check("8 位：报", rawProductIssues(source: rawProps, product: eight), ["产物不是 10 位（Depth = 8）"])
var noDepth = good; noDepth.removeValue(forKey: kCGImagePropertyDepth)
check("读不出位深：报", rawProductIssues(source: rawProps, product: noDepth), ["读不出产物的位深"])
var rotated = good; rotated[kCGImagePropertyPixelWidth] = 192; rotated[kCGImagePropertyPixelHeight] = 256
check("像素被转过：报", rawProductIssues(source: rawProps, product: rotated), ["变化 像素尺寸（不按方向转正）：256×192 → 192×256"])
var upright = good; upright[kCGImagePropertyOrientation] = 1
check("方向标签没照抄：报", rawProductIssues(source: rawProps, product: upright), ["变化 方向标签：6 → 1"])
var noOrientation = rawProps; noOrientation.removeValue(forKey: kCGImagePropertyOrientation)
check("源里没有方向、产物里多出一个：报", rawProductIssues(source: noOrientation, product: good), ["变化 方向标签：1 → 6"])
upright.removeValue(forKey: kCGImagePropertyOrientation)
check("源里没有方向、产物里也没有：不报", rawProductIssues(source: noOrientation, product: upright), [])

print("被打断时清理临时产物（TemporaryFiles）")
// 用一个新实例，不碰 TemporaryFiles.shared：收尾以后它不再登记新的，后面的转换都会失败。
do {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("glint-temporaries-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = TemporaryFiles()
    let written = dir.appendingPathComponent(".glint-a.heic")
    let late = dir.appendingPathComponent(".glint-b.heic")
    check("收尾前登记得上", registry.register(written) && registry.register(late), true)
    fm.createFile(atPath: written.path, contents: Data([1]))
    // late 这张还在编码：0.1 秒后才冒出文件（ImageIO 收尾时才建文件），0.3 秒后转换收手、注销。
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { fm.createFile(atPath: late.path, contents: Data([2])) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { registry.forget([late]) }
    let started = Date()
    let removed = registry.shutDown(timeout: 2)
    check("收尾删掉已经写出的、等待期间冒出来的临时文件", [removed == 2, fm.fileExists(atPath: written.path), fm.fileExists(atPath: late.path)],
          [true, false, false])
    check("收尾会等正在进行的转换收手（不是一删就走）", Date().timeIntervalSince(started) >= 0.25, true)
    check("收尾以后不再登记新的临时文件", registry.register(dir.appendingPathComponent(".glint-c.heic")), false)
    // ImageIO 写到一半失败时留在旁边的 `.<文件名>-XXXXXX` 一并删掉，别的文件不动。
    let tmp = dir.appendingPathComponent(".glint-d.heic")
    for name in [".glint-d.heic", "..glint-d.heic-u41uww", "..glint-e.heic-abc123", "照片.heic"] {
        fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data([3]))
    }
    check("删临时产物连同 ImageIO 的半截文件，别的不动", [TemporaryFiles.remove(tmp) == 2,
          fm.fileExists(atPath: dir.appendingPathComponent("..glint-e.heic-abc123").path),
          fm.fileExists(atPath: dir.appendingPathComponent("照片.heic").path)], [true, true, true])
    try? fm.removeItem(at: dir)
}

print("去掉坏掉的 ICC（jpegWithoutICC）")
do {
    // 一个描述文件可以分在几个 APP2 段里（每段 ICC_PROFILE\0、序号、总数）。全部去掉，别的段原样。
    func segment(_ marker: UInt8, _ content: [UInt8]) -> [UInt8] {
        [0xFF, marker, UInt8((content.count + 2) >> 8), UInt8((content.count + 2) & 0xFF)] + content
    }
    let icc: [UInt8] = Array("ICC_PROFILE".utf8) + [0]
    let exif = segment(0xE1, Array("Exif".utf8) + [0, 0, 1, 2])
    let mpf = segment(0xE2, Array("MPF".utf8) + [0, 9])
    let scan = segment(0xDA, [1, 2, 3]) + [0x11, 0x22, 0xFF, 0xD9]
    let withICC = [0xFF, 0xD8] + exif + segment(0xE2, icc + [1, 2, 0xAA]) + mpf + segment(0xE2, icc + [2, 2, 0xBB]) + scan
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-icc-\(UUID().uuidString).jpg")
    try? Data(withICC).write(to: url)
    check("分成两段的 ICC 都去掉，别的段与图像数据原样", jpegWithoutICC(url).map { [UInt8]($0) },
          [0xFF, 0xD8] + exif + mpf + scan)
    try? Data([0xFF, 0xD8] + exif + mpf + scan).write(to: url)
    check("没有 ICC：nil（没有可去掉的，不再编一次）", jpegWithoutICC(url) == nil, true)
    try? FileManager.default.removeItem(at: url)
}

print("产物写盘失败（writeProduct、isOutOfSpace、encodeFailureReason）")
do {
    func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    func cocoa(_ code: Int, underlying: Error? = nil) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code, userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }
    check("卷满了的几种写法都认得", [isOutOfSpace(cocoa(NSFileWriteOutOfSpaceError)), isOutOfSpace(posix(ENOSPC)),
                                 isOutOfSpace(posix(EDQUOT)), isOutOfSpace(cocoa(NSFileWriteUnknownError, underlying: posix(ENOSPC)))],
          [true, true, true, true])
    check("别的写盘错误不算卷满", [isOutOfSpace(posix(EIO)), isOutOfSpace(cocoa(NSFileWriteNoPermissionError)),
                               isOutOfSpace(cocoa(NSFileWriteUnknownError, underlying: posix(EIO)))], [false, false, false])

    // 写不进去时记下原因，按路径取一次就清掉；写成功的不记。
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("glint-write-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let missing = dir.appendingPathComponent("没有这个目录/a.heic"), fine = dir.appendingPathComponent("b.heic")
    check("写进不存在的目录：失败", writeProduct(Data([1, 2, 3]), to: missing), false)
    check("写成功：字节原样", [writeProduct(Data([1, 2, 3]), to: fine) ? 1 : 0] + [UInt8]((try? Data(contentsOf: fine)) ?? Data()).map(Int.init),
          [1, 1, 2, 3])
    check("失败的原因按路径记着，成功的不记", ProductWriteFailures.shared.take([fine, missing]) != nil, true)
    check("取过一次就清掉", ProductWriteFailures.shared.take([fine, missing]) == nil, true)

    // 失败原因：卷满了说磁盘空间不够（带剩余空间），别的写盘错误照实说，没有写盘错误才去查源解不解得出。
    if let src = tinyJPEGSource() {
        check("写盘时卷满了：磁盘空间不够",
              encodeFailureReason(src, kind: .jpeg, folder: dir, writeError: posix(ENOSPC)).hasPrefix("磁盘空间不够：输出目录所在的卷只剩 "), true)
        check("别的写盘错误：写不进输出文件",
              encodeFailureReason(src, kind: .jpeg, folder: dir, writeError: posix(EIO)).hasPrefix("写不进输出文件："), true)
        check("没有写盘错误、源解得出：编码器的问题",
              encodeFailureReason(src, kind: .jpeg, folder: dir, writeError: nil), "HEIC 编码失败")
    } else {
        check("造得出小 JPEG", false, true)
    }
    try? fm.removeItem(at: dir)
}

print("-o 的解读（OutputPlan.resolve）")
do {
    func plan(_ path: String, _ count: Int) -> String {
        do {
            switch try OutputPlan.resolve(output: URL(fileURLWithPath: path), fileCount: count, createDirectories: false) {
            case .singleFile(let u): return "文件 \(u.lastPathComponent)"
            case .directory(let u): return "目录 \(u.lastPathComponent)"
            case .sameFolder: return "源旁边"
            }
        } catch { return "错误 \(error.localizedDescription)" }
    }
    let missing = "/glint-不存在-\(UUID().uuidString)"
    check("单个输入、.heic 名字：是产物的文件名", plan("\(missing)/x.heic", 1), "文件 x.heic")
    check("单个输入、大写 .HEIF：也是文件名", plan("\(missing)/y.HEIF", 1), "文件 y.HEIF")
    check("多个输入、.heic 名字：报错，不悄悄建一个叫 x.heic 的目录", plan("\(missing)/x.heic", 2),
          "错误 有多个输入时 -o 要给一个目录，x.heic 是文件名（单个输入时才能指定产物的文件名）")
    check("别的图片后缀：报错，不写出名叫 .jpg 的 HEIF", plan("\(missing)/w.jpg", 1), "错误 产物的文件名要以 .heic 或 .heif 结尾：w.jpg")
    check("不认识的后缀照旧当目录", plan("\(missing)/2024.09", 1), "目录 2024.09")
    let existing = FileManager.default.temporaryDirectory.appendingPathComponent("glint-plain-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: existing.path, contents: Data())
    check("多个输入、指向已有的文件：报错说清", plan(existing.path, 2),
          "错误 -o 指向的 \(existing.path) 是一个已有的文件；有多个输入时 -o 要给一个目录")
    try? FileManager.default.removeItem(at: existing)
}

print("画质核对：判据（合成的像素缓冲）")
/// `width`×`height` 的 RGBX 缓冲，像素由 `pixel(x, y)` 给出（R、G、B）。
func rgbx(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> (Int, Int, Int)) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let at = (y * width + x) * 4
            (out[at], out[at + 1], out[at + 2]) = (UInt8(r), UInt8(g), UInt8(b))
        }
    }
    return out
}
/// 有纹理的图案：每个 16×16 块里都有起伏，SSIM 不会因为块是平的而对噪声不敏感。
func texture(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    (40 + (x * 7 + y * 3) % 160, 60 + (x * 5 + y * 11) % 150, 30 + (x * 13 + y * 2) % 170)
}
/// 固定种子的伪随机数（0–255）。
func noiseByte(_ x: Int, _ y: Int, _ c: Int) -> Int { Int((UInt32(x &* 7_919 &+ y &* 104_729 &+ c &* 31) &* 2_654_435_761) >> 24) }
func measure(_ a: [UInt8], _ b: [UInt8], _ width: Int, _ height: Int) -> QualityMeasurement {
    a.withUnsafeBufferPointer { pa in
        b.withUnsafeBufferPointer { pb in
            qualityMeasurement(RGBPixels(base: pa.baseAddress!, width: width, height: height, rowBytes: width * 4),
                               RGBPixels(base: pb.baseAddress!, width: width, height: height, rowBytes: width * 4))
        }
    }
}
let qcBase96 = rgbx(96, 96, texture)
let qcSame = measure(qcBase96, qcBase96, 96, 96)
check("完全相同：PSNR 是无穷大", qcSame.psnr, .infinity)
check("完全相同：局部 SSIM 是 1", qcSame.worstSSIM, 1)
// 每个像素的 R 加 3，G、B 不变：MSE = 9 / 3 = 3。
let qcPlus3 = rgbx(96, 96) { x, y in let (r, g, b) = texture(x, y); return (r + 3, g, b) }
check(abs(measure(qcBase96, qcPlus3, 96, 96).psnr - 10 * log10(255.0 * 255 / 3)) < 1e-9, "已知 MSE = 3：PSNR = 10·log10(255²/3)")
// 隔行的像素换成另一套 RGB：MSE 按定义逐像素算出来，和函数给的比。
let qcStriped = rgbx(40, 24) { x, y in y % 2 == 0 ? texture(x, y) : (noiseByte(x, y, 0), noiseByte(x, y, 1), noiseByte(x, y, 2)) }
let qcPlain40 = rgbx(40, 24, texture)
var qcStripedError = 0.0
for i in 0..<(40 * 24) { for c in 0..<3 { let d = Double(qcStriped[i * 4 + c]) - Double(qcPlain40[i * 4 + c]); qcStripedError += d * d } }
check(abs(measure(qcPlain40, qcStriped, 40, 24).psnr - 10 * log10(255.0 * 255 / (qcStripedError / Double(40 * 24 * 3)))) < 1e-9,
      "逐像素算出的 MSE 与函数给的 PSNR 一致")
// 36 块里只坏一块（换成噪声）：最差 1% 是那一块本身（⌊36/100⌋ = 0），远低于 36 块的平均。
func corrupted(_ base: @escaping (Int, Int) -> (Int, Int, Int), blocks: [(Int, Int, Int)]) -> (Int, Int) -> (Int, Int, Int) {
    { x, y in
        for (bx, by, strength) in blocks where x / 16 == bx && y / 16 == by {
            let (r, g, b) = base(x, y)
            func mix(_ v: Int, _ c: Int) -> Int { min(255, max(0, v + (noiseByte(x, y, c) - 128) * strength / 100)) }
            return (mix(r, 0), mix(g, 1), mix(b, 2))
        }
        return base(x, y)
    }
}
let qcOneBad = rgbx(96, 96, corrupted(texture, blocks: [(2, 3, 100)]))
let qcOneBadWorst = measure(qcBase96, qcOneBad, 96, 96).worstSSIM
// 那一块单独量（16×16 正好一块）。
let qcBadBlockA = rgbx(16, 16) { x, y in texture(x + 32, y + 48) }
let qcBadBlockB = rgbx(16, 16) { x, y in corrupted(texture, blocks: [(2, 3, 100)])(x + 32, y + 48) }
let qcBadBlockSSIM = measure(qcBadBlockA, qcBadBlockB, 16, 16).worstSSIM
check(qcBadBlockSSIM < 0.5, "前提：坏掉的那一块 SSIM 很低（\(qcBadBlockSSIM)）")
check(abs(qcOneBadWorst - qcBadBlockSSIM) < 1e-9, "坏一块：最差 1% 就是那一块（\(qcOneBadWorst)），不是 36 块的平均（约 \((35 + qcBadBlockSSIM) / 36)）")
// 100 块里坏两块，一重一轻：⌊100/100⌋ = 1，取的是轻的那块（第二差），不是最差的那块。
let qcBase160 = rgbx(160, 160, texture)
let qcTwoBad = rgbx(160, 160, corrupted(texture, blocks: [(1, 1, 100), (7, 8, 30)]))
let qcMildA = rgbx(16, 16) { x, y in texture(x + 112, y + 128) }
let qcMildB = rgbx(16, 16) { x, y in corrupted(texture, blocks: [(7, 8, 30)])(x + 112, y + 128) }
let qcSevereA = rgbx(16, 16) { x, y in texture(x + 16, y + 16) }
let qcSevereB = rgbx(16, 16) { x, y in corrupted(texture, blocks: [(1, 1, 100)])(x + 16, y + 16) }
let qcMildSSIM = measure(qcMildA, qcMildB, 16, 16).worstSSIM, qcSevereSSIM = measure(qcSevereA, qcSevereB, 16, 16).worstSSIM
check(qcSevereSSIM < qcMildSSIM && qcMildSSIM < 1, "前提：重的那块比轻的那块更差（\(qcSevereSSIM) < \(qcMildSSIM)）")
check(abs(measure(qcBase160, qcTwoBad, 160, 160).worstSSIM - qcMildSSIM) < 1e-9, "100 块取下标 1：是第二差的那块")
// 右边、下边凑不满 16 的部分不进 SSIM，但进 PSNR。
let qcEdgeOnly = rgbx(40, 40) { x, y in x >= 32 || y >= 32 ? (noiseByte(x, y, 0), noiseByte(x, y, 1), noiseByte(x, y, 2)) : texture(x, y) }
let qcEdgeResult = measure(rgbx(40, 40, texture), qcEdgeOnly, 40, 40)
check("只改了凑不满 16 的边：局部 SSIM 仍是 1", qcEdgeResult.worstSSIM, 1)
check(qcEdgeResult.psnr < 30, "只改了凑不满 16 的边：PSNR 照样算进去（\(qcEdgeResult.psnr)）")
// 不到 16 的小图整张当一块：每个通道都加 5，亮度整体加 5，方差、协方差不变。
let qcSmallA = rgbx(10, 20, texture)
let qcSmallB = rgbx(10, 20) { x, y in let (r, g, b) = texture(x, y); return (r + 5, g + 5, b + 5) }
var qcLumas: [Double] = []
for y in 0..<20 { for x in 0..<10 { let (r, g, b) = texture(x, y); qcLumas.append(0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) } }
let qcMu = qcLumas.reduce(0, +) / 200
let qcVariance = qcLumas.map { ($0 - qcMu) * ($0 - qcMu) }.reduce(0, +) / 199
let qcC1 = 6.5025, qcC2 = 58.5225
let qcWantSmall = ((2 * qcMu * (qcMu + 5) + qcC1) * (2 * qcVariance + qcC2)) / ((qcMu * qcMu + (qcMu + 5) * (qcMu + 5) + qcC1) * (2 * qcVariance + qcC2))
check(abs(measure(qcSmallA, qcSmallB, 10, 20).worstSSIM - qcWantSmall) < 1e-9, "宽不到 16：整张图当一块，按公式（n−1）算")
check(abs(measure(rgbx(20, 10, texture), rgbx(20, 10) { x, y in let (r, g, b) = texture(x, y); return (r + 5, g + 5, b + 5) }, 20, 10)
      .worstSSIM - measure(qcSmallA, qcSmallB, 10, 20).worstSSIM) < 0.05, "高不到 16：同样整张当一块（量出一个数，不崩）")
check("1×1 的图：块里只有一个像素，方差取 0", measure(rgbx(1, 1) { _, _ in (10, 20, 30) }, rgbx(1, 1) { _, _ in (10, 20, 30) }, 1, 1).worstSSIM, 1)
// 按条带喂与一次喂完结果相同（16 行、32 行一条，最后一条凑不满）。
let qcTall = rgbx(48, 100, texture), qcTallBad = rgbx(48, 100, corrupted(texture, blocks: [(1, 2, 60), (0, 5, 20)]))
let qcWholeTall = measure(qcTall, qcTallBad, 48, 100)
for stripRows in [16, 32] {
    let qcTally = QualityTally(width: 48, height: 100)
    qcTall.withUnsafeBufferPointer { pa in
        qcTallBad.withUnsafeBufferPointer { pb in
            let a = RGBPixels(base: pa.baseAddress!, width: 48, height: 100, rowBytes: 48 * 4)
            let b = RGBPixels(base: pb.baseAddress!, width: 48, height: 100, rowBytes: 48 * 4)
            var y = 0
            while y < 100 { let n = min(stripRows, 100 - y); qcTally.add(a.rows(y, n), b.rows(y, n)); y += n }
        }
    }
    check("每条 \(stripRows) 行地喂，与一次喂完相同", qcTally.result(), qcWholeTall)
}
// 像素里 R、G、B 的位置：XRGB 排布的同一幅图量出同样的数。
func xrgb(_ v: [UInt8]) -> [UInt8] { var o = v; for i in stride(from: 0, to: v.count, by: 4) { (o[i], o[i + 1], o[i + 2], o[i + 3]) = (0, v[i], v[i + 1], v[i + 2]) }; return o }
let qcXa = xrgb(qcTall), qcXb = xrgb(qcTallBad)
let qcXResult = qcXa.withUnsafeBufferPointer { pa in
    qcXb.withUnsafeBufferPointer { pb in
        qualityMeasurement(RGBPixels(base: pa.baseAddress!, width: 48, height: 100, rowBytes: 48 * 4, offsets: (1, 2, 3)),
                           RGBPixels(base: pb.baseAddress!, width: 48, height: 100, rowBytes: 48 * 4, offsets: (1, 2, 3)))
    }
}
check("XRGB 排布：按通道位置读，量出同样的数", qcXResult, qcWholeTall)

print("画质核对：门槛")
let qcGate = QualityThresholds(minSSIM: 0.90, minPSNR: 33)
check(qcGate.accepts(QualityMeasurement(psnr: 33, worstSSIM: 0.90)), "两项恰好等于门槛：达标")
check(!qcGate.accepts(QualityMeasurement(psnr: 33, worstSSIM: 0.8999999)), "SSIM 低一丁点：不达标")
check(!qcGate.accepts(QualityMeasurement(psnr: 32.9999999, worstSSIM: 0.90)), "PSNR 低一丁点：不达标")
check(!qcGate.accepts(QualityMeasurement(psnr: 50, worstSSIM: 0.5)), "PSNR 很高、SSIM 不够：不达标（要比 SSIM）")
check(!qcGate.accepts(QualityMeasurement(psnr: 20, worstSSIM: 0.99)), "SSIM 很高、PSNR 不够：不达标（要比 PSNR）")
check(qcGate.accepts(QualityMeasurement(psnr: .infinity, worstSSIM: 1)), "完全相同：达标")
check(qcGate.accepts(QualityMeasurement(psnr: 40, worstSSIM: 0.95)), "两项都高于门槛：达标")
check(!QualityReading.sizeChanged(source: PixelSize(width: 2, height: 2), product: PixelSize(width: 2, height: 1)).accepted(by: qcGate),
      "尺寸变了：不达标")
check(!QualityReading.undecodable("解不出产物的像素").accepted(by: QualityThresholds(minSSIM: 0, minPSNR: 0)),
      "解不出像素：门槛再低也不达标")
checkRule("0.9", QualityThresholds.parseSSIM("0.9"), 0.9, "SSIM 门槛：0.9")
checkRule(" 1 ", QualityThresholds.parseSSIM(" 1 "), 1, "SSIM 门槛：1（去掉首尾空白）")
checkRule("0", QualityThresholds.parseSSIM("0"), 0, "SSIM 门槛：0")
for bad in ["1.01", "-0.1", "abc", "", "nan", "inf", "0,9"] {
    checkRule(bad, QualityThresholds.parseSSIM(bad), nil, "SSIM 门槛：不收")
}
checkRule("33", QualityThresholds.parsePSNR("33"), 33, "PSNR 门槛：33")
checkRule("100", QualityThresholds.parsePSNR("100"), 100, "PSNR 门槛：100")
for bad in ["100.5", "-1", "x", "", "nan", "inf"] {
    checkRule(bad, QualityThresholds.parsePSNR(bad), nil, "PSNR 门槛：不收")
}

print("画质核对：文案")
check("两个数：PSNR 1 位、SSIM 3 位，向下截断", QualityMeasurement(psnr: 32.99, worstSSIM: 0.8996).description,
      "PSNR 32.9 dB，局部 SSIM 0.899")
check("PSNR 无穷大写 ∞", QualityMeasurement(psnr: .infinity, worstSSIM: 1).description, "PSNR ∞ dB，局部 SSIM 1.000")
check("门槛的写法", qcGate.description, "门槛 0.90 / 33 dB")
check("门槛带更多小数时照写", QualityThresholds(minSSIM: 0.925, minPSNR: 33.5).description, "门槛 0.925 / 33.5 dB")
let qcLowReading = QualityReading.measured(QualityMeasurement(psnr: 31.25, worstSSIM: 0.8625))
check("不转", QualityDrop(first: qcLowReading, firstQuality: 0.8, thresholds: qcGate, retry: nil).description,
      "画质下降明显（PSNR 31.2 dB，局部 SSIM 0.862，门槛 0.90 / 33 dB），没有转换，保留原 JPEG")
check("重编后仍不达标",
      QualityDrop(first: qcLowReading, firstQuality: 0.8, thresholds: qcGate,
                  retry: .stillBelow(.measured(QualityMeasurement(psnr: 32.5, worstSSIM: 0.95)))).description,
      "画质下降明显（PSNR 31.2 dB，局部 SSIM 0.862，门槛 0.90 / 33 dB），用质量 0.95 重编后仍不达标（PSNR 32.5 dB，局部 SSIM 0.950），没有转换，保留原 JPEG")
check("质量已不低于 0.95", QualityDrop(first: qcLowReading, firstQuality: 0.95, thresholds: qcGate, retry: .notNeeded).description,
      "画质下降明显（PSNR 31.2 dB，局部 SSIM 0.862，门槛 0.90 / 33 dB），质量已不低于 0.95，没有重编，没有转换，保留原 JPEG")
check("尺寸变了", QualityDrop(first: .sizeChanged(source: PixelSize(width: 4, height: 3), product: PixelSize(width: 2, height: 1)),
                          firstQuality: 0.8, thresholds: qcGate, retry: nil).description,
      "画质核对不通过（尺寸变了（4×3 → 2×1），门槛 0.90 / 33 dB），没有转换，保留原 JPEG")
check("-v 的画质行", QualityOutcome.passed(QualityMeasurement(psnr: 43.56, worstSSIM: 0.9791)).description,
      "画质：PSNR 43.5 dB，局部 SSIM 0.979")
let qcRetried = QualityOutcome.passedAfterRetry(first: qcLowReading, firstQuality: 0.8,
                                              retried: QualityMeasurement(psnr: 45, worstSSIM: 0.97))
check("重编后达标的 -v 行", qcRetried.description,
      "画质：质量 0.8 不达标（PSNR 31.2 dB，局部 SSIM 0.862），用 0.95 重编后 PSNR 45.0 dB，局部 SSIM 0.970")
check("重编后达标的状态说明", qcRetried.note, "质量 0.8 画质不达标，改用 0.95 重编")
check("一次达标的没有状态说明", QualityOutcome.passed(QualityMeasurement(psnr: 45, worstSSIM: 0.97)).note, nil)

print("画质核对：从文件量")
let qcQualityRoot = FileManager.default.temporaryDirectory.appendingPathComponent("glint-quality-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: qcQualityRoot, withIntermediateDirectories: true)
/// 把像素写成文件（JPEG 或 HEIC）。
func writeImage(_ pixels: [UInt8], _ width: Int, _ height: Int, to url: URL, type: String, quality: Double = 0.95) -> Bool {
    let data = NSMutableData(bytes: pixels, length: pixels.count)
    guard let provider = CGDataProvider(data: data),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let out = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(out)
}
/// 像照片的图案：平滑的渐变加细噪声，色度上下左右都在变。
func photoLike(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let fx = Double(x) / 640, fy = Double(y) / 1100
    let wave = sin(fx * 9) * cos(fy * 7) * 40
    let n = noiseByte(x, y, 0) % 17 - 8
    func clamp(_ v: Double) -> Int { min(255, max(0, Int(v) + n)) }
    return (clamp(70 + 130 * fx + wave), clamp(90 + 90 * (1 - fy) + wave * 0.6), clamp(150 + 80 * fy - wave * 0.5))
}
let qcPhotoJPEG = qcQualityRoot.appendingPathComponent("源.jpg"), qcPhotoHEIC = qcQualityRoot.appendingPathComponent("产物.heic")
let qcPhotoPixels = rgbx(640, 1100, photoLike)
check(writeImage(qcPhotoPixels, 640, 1100, to: qcPhotoJPEG, type: "public.jpeg"), "前提：写出了源 JPEG")
if let src = CGImageSourceCreateWithURL(qcPhotoJPEG as CFURL, nil),
   encodeHEIF(src, properties: [kCGImageDestinationLossyCompressionQuality: 0.6], xmp: nil, to: qcPhotoHEIC) {
    // 产物按条带解（上下多带几行）与整幅解码逐字节相同，所以量出的数也相同。
    let qcWhole = qualityReading(source: src, product: qcPhotoHEIC, stripRows: 1104)
    check(qcWhole.measurement != nil, "前提：整幅解码量出了数（\(qcWhole)）")
    for rows in [16, 512] {
        check("按条带解产物（每条 \(rows) 行）与整幅解码量出的数相同", qualityReading(source: src, product: qcPhotoHEIC, stripRows: rows), qcWhole)
    }
    check("按条带解产物（默认每条 \(qualityStripRows(height: 1100)) 行）与整幅解码量出的数相同", qualityReading(source: src, product: qcPhotoHEIC), qcWhole)
    check("源与自己比：PSNR 无穷大、SSIM 1", qualityReading(source: src, product: qcPhotoJPEG),
          .measured(QualityMeasurement(psnr: .infinity, worstSSIM: 1)))
    let qcShortJPEG = qcQualityRoot.appendingPathComponent("矮.jpg")
    check(writeImage(rgbx(640, 1000, photoLike), 640, 1000, to: qcShortJPEG, type: "public.jpeg"), "前提：写出了矮一截的图")
    check("宽高不同：量不了，原因是尺寸变了", qualityReading(source: src, product: qcShortJPEG),
          .sizeChanged(source: PixelSize(width: 640, height: 1100), product: PixelSize(width: 640, height: 1000)))
    let qcGarbage = qcQualityRoot.appendingPathComponent("坏.heic")
    try? Data([0, 1, 2, 3]).write(to: qcGarbage)
    check("产物不是图：量不了", qualityReading(source: src, product: qcGarbage), .undecodable("解不出产物的像素"))
} else {
    for _ in 0..<8 { fail("编不出 HEIC 产物，从文件量的那几条没法测") }
}

check("产物的条带：整幅高的四分之一，补到 16 的倍数", [4000, 3024, 1100, 64, 10].map { qualityStripRows(height: $0) }, [1008, 768, 288, 16, 16])

print("画质核对：源图画进复用的内存")
/// 不经缓存地取第 0 张：每次都重新解码，两次取到的像素互不沾边。
func freshImage(_ url: URL) -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCache: false] as CFDictionary) }
}
/// 一幅图画进新开的 RGBX 上下文（色彩空间沿用图自己的，.copy、不插值），逐行紧排的字节。不经 drawnPixels。
func contextBytes(_ image: CGImage) -> [UInt8]? {
    var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drew: Bool = out.withUnsafeMutableBytes { raw in
        guard let space = image.colorSpace,
              let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return drew ? out : nil
}
/// 图的 dataProvider 解出的字节（逐行紧排）。只收 8 位 RGBX，别的布局是 nil。
func providerBytes(_ image: CGImage) -> [UInt8]? {
    guard image.bitsPerPixel == 32, image.alphaInfo == .noneSkipLast, image.byteOrderInfo == .orderDefault,
          let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
    var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
    for y in 0..<image.height {
        for i in 0..<(image.width * 4) { out[y * image.width * 4 + i] = base[y * image.bytesPerRow + i] }
    }
    return out
}
func measurePacked(_ a: [UInt8], _ b: [UInt8], _ width: Int, _ height: Int) -> QualityReading {
    .measured(measure(a, b, width, height))
}
// 宽 330：每行 1320 字节，drawnPixels 补到 1344；行尾补齐处和缓冲以外都不该被写。
let qcOddJPEG = qcQualityRoot.appendingPathComponent("宽330.jpg")
check(writeImage(rgbx(330, 250, photoLike), 330, 250, to: qcOddJPEG, type: "public.jpeg"), "前提：写出了宽 330 的 JPEG")
if let oddImage = freshImage(qcOddJPEG), let oddWant = contextBytes(oddImage), let oddDraw = freshImage(qcOddJPEG) {
    let rowBytes = drawnRowBytes(330), body = rowBytes * 250, tail = 4096
    check("每行补到 64 的倍数", rowBytes, 1344)
    let memory = UnsafeMutableRawPointer.allocate(byteCount: body + tail, alignment: 64)
    memset(memory, 0xA5, body + tail)
    let bytes = memory.assumingMemoryBound(to: UInt8.self)
    if let px = drawnPixels(oddDraw, colorSpace: oddDraw.colorSpace!, into: memory) {
        var got: [UInt8] = []
        for y in 0..<250 { got += UnsafeBufferPointer(start: px.base + y * px.rowBytes, count: 330 * 4) }
        check(got == oddWant, "drawnPixels 画出的像素与另开一个上下文画的逐字节相同")
        var touched = 0
        for y in 0..<250 { for i in (330 * 4)..<rowBytes where bytes[y * rowBytes + i] != 0xA5 { touched += 1 } }
        for i in body..<(body + tail) where bytes[i] != 0xA5 { touched += 1 }
        check("行尾补齐处与缓冲以外一个字节都没写", touched, 0)
    } else {
        fail("drawnPixels 画不出来"); fail("drawnPixels：行尾与缓冲以外")
    }
    memory.deallocate()
} else {
    for _ in 0..<3 { fail("取不出宽 330 的图，drawnPixels 那几条没法测") }
}
// 源图走的是「画进去」那条路：量出的数等于「源画进上下文、产物整幅取 dataProvider」算出来的。
// 源改回取 dataProvider 时数就不同了（前提那条确认这张图上两条路的像素确实有差）。两条路只在图够大
// （约一百万像素以上，ImageIO 改用硬件解 JPEG）时才有差，所以这里用 1200×900。
let qcLargeJPEG = qcQualityRoot.appendingPathComponent("1200x900.jpg"), qcLargeHEIC = qcQualityRoot.appendingPathComponent("1200x900.heic")
check(writeImage(rgbx(1200, 900) { x, y in photoLike(x * 640 / 1200, y * 1100 / 900) }, 1200, 900, to: qcLargeJPEG, type: "public.jpeg"),
      "前提：写出了 1200×900 的源 JPEG")
if let src = CGImageSourceCreateWithURL(qcLargeJPEG as CFURL, nil),
   encodeHEIF(src, properties: [kCGImageDestinationLossyCompressionQuality: 0.6], xmp: nil, to: qcLargeHEIC),
   let drawnSource = freshImage(qcLargeJPEG).flatMap(contextBytes),
   let providedSource = freshImage(qcLargeJPEG).flatMap(providerBytes),
   let product = freshImage(qcLargeHEIC).flatMap(providerBytes) {
    let viaDrawing = measurePacked(drawnSource, product, 1200, 900)
    check(drawnSource != providedSource && viaDrawing != measurePacked(providedSource, product, 1200, 900),
          "前提：这张 JPEG 画进去与取 dataProvider 解出的像素不同，量出的数也不同")
    check("源图画进复用的内存：量出的数与「源画进上下文」算的相同", qualityReading(source: src, product: qcLargeHEIC), viaDrawing)
} else {
    for _ in 0..<2 { fail("编不出产物或取不出像素，源图解法那两条没法测") }
}

print("画质核对：核对用的缓冲")
let qcMiB = 1 << 20
let qcPool = QualityBuffers(slots: 2)
let qcSlotA = qcPool.acquire(), qcSlotB = qcPool.acquire()
if let a = qcSlotA.memory(qcMiB), let b = qcSlotB.memory(qcMiB) {
    let pa = UInt(bitPattern: a), pb = UInt(bitPattern: b)
    check(pa + UInt(qcMiB) <= pb || pb + UInt(qcMiB) <= pa, "同时拿到的两个槽，内存不重叠")
} else {
    fail("两个槽要不到内存")
}
check("占着的字节数是两块之和", qcPool.retainedBytes, 2 * qcMiB)
let qcThird = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    let slot = qcPool.acquire()
    qcThird.signal()
    qcPool.release(slot)
}
check("槽都占着：acquire 等着", qcThird.wait(timeout: .now() + 0.3), .timedOut)
qcPool.release(qcSlotA)
check("放回一个槽：等着的那个拿到了", qcThird.wait(timeout: .now() + 10), .success)
check("没有批量在跑：槽放回就把内存还掉", qcPool.retainedBytes, qcMiB)
qcPool.release(qcSlotB)
check("没有批量在跑：全部放回后一个字节都不占", qcPool.retainedBytes, 0)

let qcOne = QualityBuffers(slots: 1)
qcOne.beginBatch()
var qcSlot = qcOne.acquire()
let qcFirstBlock = qcSlot.memory(qcMiB)
qcOne.release(qcSlot)
check("批量里放回的槽留着内存", qcOne.retainedBytes, qcMiB)
qcSlot = qcOne.acquire()
check(qcFirstBlock != nil && qcSlot.memory(qcMiB / 2) == qcFirstBlock, "批量里再拿到的槽，要的不比原来多：用原来那块")
_ = qcSlot.memory(2 * qcMiB)
check("要得比原来多：换一块大的，旧的还掉", qcOne.retainedBytes, 2 * qcMiB)
qcOne.release(qcSlot)
qcOne.endBatch()
check("一批结束：一个字节都不占", qcOne.retainedBytes, 0)
qcOne.beginBatch(); qcOne.beginBatch()
qcSlot = qcOne.acquire(); _ = qcSlot.memory(qcMiB); qcOne.release(qcSlot)
qcOne.endBatch()
check("两批同时在跑、先结束一批：内存留给另一批", qcOne.retainedBytes, qcMiB)
qcOne.endBatch()
check("最后一批结束：还掉", qcOne.retainedBytes, 0)
qcOne.beginBatch()
qcSlot = qcOne.acquire(); _ = qcSlot.memory(qcMiB)
qcOne.endBatch()
check("一批结束时还在用的槽：先不动", qcOne.retainedBytes, qcMiB)
qcOne.release(qcSlot)
check("……放回时还掉", qcOne.retainedBytes, 0)

// 几个核对同时跑、图各不相同：每个量出的数都与单独量时相同（共用一块内存就会互相画花）。
let qcOtherJPEG = qcQualityRoot.appendingPathComponent("另一张.jpg"), qcOtherHEIC = qcQualityRoot.appendingPathComponent("另一张.heic")
check(writeImage(rgbx(640, 1100) { x, y in let (r, g, b) = photoLike(639 - x, 1099 - y); return (b, r, g) }, 640, 1100,
                 to: qcOtherJPEG, type: "public.jpeg"), "前提：写出了另一张源 JPEG")
if let one = CGImageSourceCreateWithURL(qcPhotoJPEG as CFURL, nil),
   let other = CGImageSourceCreateWithURL(qcOtherJPEG as CFURL, nil),
   encodeHEIF(other, properties: [kCGImageDestinationLossyCompressionQuality: 0.4], xmp: nil, to: qcOtherHEIC) {
    let pairs = [(qcPhotoJPEG, qcPhotoHEIC), (qcOtherJPEG, qcOtherHEIC)]
    let alone = [one, other].enumerated().map { qualityReading(source: $0.element, product: pairs[$0.offset].1) }
    check(alone[0] != alone[1], "前提：两张单独量出的数不同（\(alone[0]) / \(alone[1])）")
    let qcConcurrentPool = QualityBuffers(slots: 4)
    var together = [QualityReading?](repeating: nil, count: 16)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: together.count) { i in
        let r = CGImageSourceCreateWithURL(pairs[i % 2].0 as CFURL, nil).map {
            qualityReading(source: $0, product: pairs[i % 2].1, stripRows: 64, buffers: qcConcurrentPool)
        }
        lock.lock(); together[i] = r; lock.unlock()
    }
    check(together.enumerated().allSatisfy { $0.element == alone[$0.offset % 2] }, "几个核对同时跑：每个都与单独量时相同")
    check("同时跑完、没有批量：一个字节都不占", qcConcurrentPool.retainedBytes, 0)
} else {
    for _ in 0..<3 { fail("编不出另一张的 HEIC，同时核对那几条没法测") }
}

print("画质核对：转换流程（注入编码步骤）")
/// 一张把图画坏的编码：编码前把源的像素换成一张平的灰图（同样大小），照常写 HEIC。
func blurring(_ src: CGImageSource, _ props: [CFString: Any], _ xmp: CGImageMetadata?, _ url: URL) -> Bool {
    guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return false }
    ctx.setFillColor(gray: 0.5, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let jpeg = NSMutableData()
    guard let flat = ctx.makeImage(), let out = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(out, flat, nil)
    guard CGImageDestinationFinalize(out), let gray = CGImageSourceCreateWithData(jpeg, nil) else { return false }
    return encodeHEIF(gray, properties: props, xmp: xmp, to: url)
}
/// 记下每次编码用的质量；`goodAt` 里的质量照常编码，别的质量把图画坏。
final class QualityRecorder {
    var qualities: [Double] = []
    let goodAt: Set<Double>
    let failAt: Set<Double>
    init(goodAt: Set<Double>, failAt: Set<Double> = []) { self.goodAt = goodAt; self.failAt = failAt }
    func encode(_ src: CGImageSource, _ props: [CFString: Any], _ xmp: CGImageMetadata?, _ url: URL) -> Bool {
        let q = props[kCGImageDestinationLossyCompressionQuality] as? Double ?? -1
        qualities.append(q)
        if failAt.contains(q) { return false }
        return goodAt.contains(q) ? encodeHEIF(src, properties: props, xmp: xmp, to: url) : blurring(src, props, xmp, url)
    }
}
let qcFlowSource = qcQualityRoot.appendingPathComponent("流程源.jpg")
check(writeImage(rgbx(320, 240, photoLike), 320, 240, to: qcFlowSource, type: "public.jpeg"), "前提：写出了流程用的源 JPEG")
func leftovers(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".glint-") }
}
/// 在一个新目录里拷一份源，按 `opts` 和 `recorder` 转一次。
func runFlow(_ name: String, _ opts: ConversionOptions, _ recorder: QualityRecorder, existing: Data? = nil)
    -> (result: ConvertResult, source: URL, dest: URL, folder: URL) {
    let folder = qcQualityRoot.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("源.jpg"), dest = folder.appendingPathComponent("源.heic")
    try? FileManager.default.copyItem(at: qcFlowSource, to: source)
    if let existing { try? existing.write(to: dest) }
    return (convert(source, opts: opts, dest: dest, encode: recorder.encode), source, dest, folder)
}
var qcFlowOpts = ConversionOptions()
check("默认开着画质核对", qcFlowOpts.qualityCheck, true)
check("默认门槛 0.90 / 33 dB", qcFlowOpts.qualityThresholds, QualityThresholds(minSSIM: 0.90, minPSNR: 33))
check("默认不达标就不转", qcFlowOpts.onQualityDrop, .skip)

let qcGood = runFlow("正常", qcFlowOpts, QualityRecorder(goodAt: [0.8]))
if case .converted(let r) = qcGood.result, case .passed(let m)? = r.quality {
    check(qcGate.accepts(m), "正常编码：达标（\(m.description)）")
    check("正常编码：没有状态说明", r.note, nil)
} else {
    fail("正常编码没有达标（\(qcGood.result)）"); fail("正常编码：状态说明")
}

var qcDeletingFlow = qcFlowOpts
qcDeletingFlow.deleteOriginal = true
qcDeletingFlow.overwrite = true
let qcPrevious = Data("原来就在的文件".utf8)
let qcDropped = runFlow("不转", qcDeletingFlow, QualityRecorder(goodAt: []), existing: qcPrevious)
if case .qualityDropped(let drop) = qcDropped.result {
    check(drop.first.measurement.map { !qcGate.accepts($0) } == true, "画坏的图：不达标（\(drop.first.description)）")
    check("「不转」不重试", drop.retry, nil)
} else {
    fail("画坏的图没有判成不达标（\(qcDropped.result)）"); fail("「不转」不重试")
}
check("不转：源还在（开着 --delete-original）", FileManager.default.fileExists(atPath: qcDropped.source.path), true)
check("不转：目标位置原来的文件没被覆盖（开着 -f）", try? Data(contentsOf: qcDropped.dest), qcPrevious)
check("不转：不留临时文件", leftovers(qcDropped.folder), [])
let qcDroppedNoFile = runFlow("不转-没有旧文件", qcFlowOpts, QualityRecorder(goodAt: []))
check("不转：没有产物", FileManager.default.fileExists(atPath: qcDroppedNoFile.dest.path), false)

var qcRetryOpts = qcFlowOpts
qcRetryOpts.onQualityDrop = .retry
let qcRetryGood = QualityRecorder(goodAt: [qualityRetryLevel])
let qcRetriedFlow = runFlow("重编后达标", qcRetryOpts, qcRetryGood)
check("重编：第二遍用质量 0.95", qcRetryGood.qualities, [0.8, qualityRetryLevel])
if case .converted(let r) = qcRetriedFlow.result, case .passedAfterRetry(let first, let q, let m)? = r.quality {
    check(first.measurement.map { !qcGate.accepts($0) } == true, "重编后达标：记下了第一遍不达标")
    check("重编后达标：记下了第一遍的质量", q, 0.8)
    check(qcGate.accepts(m), "重编后达标：第二遍达标")
    check(r.note?.contains("质量 0.8 画质不达标，改用 0.95 重编") == true, "重编后达标：状态说明里留一句（\(r.note ?? "")）")
    check(FileManager.default.fileExists(atPath: qcRetriedFlow.dest.path), "重编后达标：产物在")
} else {
    fail("重编后没有达标（\(qcRetriedFlow.result)）")
    for _ in 0..<4 { fail("重编后达标的那几条") }
}
check("重编后达标：不留临时文件", leftovers(qcRetriedFlow.folder), [])

let qcRetryBad = QualityRecorder(goodAt: [])
let qcStillBad = runFlow("重编后仍不达标", qcRetryOpts, qcRetryBad)
check("重编后仍不达标：编了两遍", qcRetryBad.qualities, [0.8, qualityRetryLevel])
if case .qualityDropped(let drop) = qcStillBad.result, case .stillBelow(let again)? = drop.retry {
    check(again.measurement.map { !qcGate.accepts($0) } == true, "重编后仍不达标：第二遍也核对了（\(again.description)）")
} else {
    fail("重编后仍不达标却没有判成不达标（\(qcStillBad.result)）")
}
check("重编后仍不达标：没有产物", FileManager.default.fileExists(atPath: qcStillBad.dest.path), false)
check("重编后仍不达标：不留临时文件", leftovers(qcStillBad.folder), [])

var qcHighOpts = qcRetryOpts
qcHighOpts.quality = qualityRetryLevel
let qcHigh = QualityRecorder(goodAt: [])
let qcHighResult = runFlow("质量已经够高", qcHighOpts, qcHigh)
check("质量已不低于 0.95：只编一遍", qcHigh.qualities, [qualityRetryLevel])
if case .qualityDropped(let drop) = qcHighResult.result {
    check("质量已不低于 0.95：不重试", drop.retry, .notNeeded)
} else {
    fail("质量已不低于 0.95 时没有判成不达标（\(qcHighResult.result)）")
}

let qcRetryFails = QualityRecorder(goodAt: [], failAt: [qualityRetryLevel])
let qcFailedRetry = runFlow("重编失败", qcRetryOpts, qcRetryFails)
if case .qualityDropped(let drop) = qcFailedRetry.result {
    check("重编那一遍编码失败：按不转处理", drop.retry, .encodeFailed)
} else {
    fail("重编失败时没有判成不达标（\(qcFailedRetry.result)）")
}
check("重编失败：不留临时文件", leftovers(qcFailedRetry.folder), [])

var qcOffOpts = qcFlowOpts
qcOffOpts.qualityCheck = false
let qcOff = runFlow("关掉核对", qcOffOpts, QualityRecorder(goodAt: []))
if case .converted(let r) = qcOff.result {
    check("关掉核对：画坏的图照样交出，没有画质结果", r.quality, nil)
} else {
    fail("关掉核对时没有转成（\(qcOff.result)）")
}

var qcDryOpts = qcFlowOpts
qcDryOpts.dryRun = true
if case .converted(let r) = runFlow("预演", qcDryOpts, QualityRecorder(goodAt: [])).result {
    check("预演不核对", r.quality, nil)
} else {
    fail("预演没有走通")
}

// 界面混批（两种源都收）里的 RAW 不核对：门槛设到不可能达到，RAW 照样转成。
let qcMixedDNG = qcQualityRoot.appendingPathComponent("混批.dng")
try? makeDNG(DNGSpec()).write(to: qcMixedDNG)
var qcMixedOpts = ConversionOptions()
qcMixedOpts.sources = [.jpeg, .raw]
qcMixedOpts.qualityThresholds = QualityThresholds(minSSIM: 1, minPSNR: 100)
if case .converted(let r) = convert(qcMixedDNG, opts: qcMixedOpts, dest: qcQualityRoot.appendingPathComponent("混批.heic")) {
    check("混批里的 RAW 不核对画质", r.quality, nil)
} else {
    fail("混批里的 RAW 没有转成")
}
var qcTally = BatchTally()
qcTally.record(qcDropped.result)
qcTally.record(qcGood.result)
check("批量汇总单列画质不达标的个数，不算失败", [qcTally.qualityDropped, qcTally.failed, qcTally.converted], [1, 0, 1])
check(qcTally.summary(unit: "个").contains("1 个画质不达标，保留原 JPEG"), "汇总里的那一句（\(qcTally.summary(unit: "个"))）")

// 一批转完，核对用的缓冲还给系统；批量进行中留着（每转完一张时看）。
let qcBatchFolder = qcQualityRoot.appendingPathComponent("一批")
try? FileManager.default.createDirectory(at: qcBatchFolder, withIntermediateDirectories: true)
let qcBatchJobs: [Job] = (1...4).map { i in
    let url = qcBatchFolder.appendingPathComponent("第\(i)张.jpg")
    try? FileManager.default.copyItem(at: qcFlowSource, to: url)
    return Job(input: url, relative: url.lastPathComponent, root: nil)
}
check("前提：批量开始前核对用的缓冲一个字节都不占", QualityBuffers.shared.retainedBytes, 0)
var qcBatchSeen: [(passed: Bool, retained: Int)] = []
runConversions(qcBatchJobs, opts: ConversionOptions(), plan: .sameFolder) { _, result in
    var passed = false
    if case .converted(let r) = result, case .passed? = r.quality { passed = true }
    qcBatchSeen.append((passed, QualityBuffers.shared.retainedBytes))
}
check(qcBatchSeen.count == 4 && qcBatchSeen.allSatisfy(\.passed), "前提：一批 4 张都转成、核对达标")
check(qcBatchSeen.allSatisfy { $0.retained > 0 }, "批量进行中：核对用的缓冲留着（\(qcBatchSeen.map(\.retained))）")
check("一批转完：核对用的缓冲全部还掉", QualityBuffers.shared.retainedBytes, 0)
try? FileManager.default.removeItem(at: qcQualityRoot)

print("命令行参数解析")
func parsed(_ args: [String]) -> ConversionOptions? {
    guard case .run(let o)? = try? parseArguments(args, command: .jpeg2heif) else { return nil }
    return o
}
func expectRejected(_ args: [String], _ why: String) {
    do {
        _ = try parseArguments(args, command: .jpeg2heif)
        fail("\(why)：本该报错却接受了")
    } catch {
        pass("\(why)：\(error.localizedDescription)")
    }
}
check("收下一个输入文件", parsed(["a.jpg"])?.inputs, ["a.jpg"])
check("-r 打开递归", parsed(["-r", "目录"])?.recursive, true)
check("-q 读出质量", parsed(["-q", "0.95", "a.jpg"])?.quality, 0.95)
check("-j 读出并发数", parsed(["-j", "4", "a.jpg"])?.jobs, 4)
check("默认整块照搬 EXIF", parsed(["a.jpg"])?.rawExif, true)
check("--no-raw-exif 关掉整块照搬", parsed(["--no-raw-exif", "a.jpg"])?.rawExif, false)
check("默认不写「照片」的说明", parsed(["a.jpg"])?.embedCaption, false)
check("--embed-caption 打开写说明", parsed(["--embed-caption", "a.jpg"])?.embedCaption, true)
check("默认跳过 CMYK 的 JPEG", parsed(["a.jpg"])?.convertCMYK, false)
check("--allow-cmyk 强制转换 CMYK 的 JPEG", parsed(["--allow-cmyk", "a.jpg"])?.convertCMYK, true)
check("-- 之后的横杠开头当文件名",
      parsed(["--", "-奇怪的文件名.jpg"])?.inputs, ["-奇怪的文件名.jpg"])
check("-o 展开 ~", parsed(["-o", "~/out", "a.jpg"])?.output?.path.hasPrefix("/"), true)
check("--help 退出码 0", try? parseArguments(["--help"], command: .jpeg2heif), .showUsage(exitCode: 0))
check("没给输入时退出码 1", try? parseArguments([], command: .jpeg2heif), .showUsage(exitCode: 1))
expectRejected(["-q", "1.5", "a.jpg"], "质量超出 0–1")
expectRejected(["-q", "abc", "a.jpg"], "质量不是数字")
expectRejected(["-j", "0", "a.jpg"], "并发数为零")
expectRejected(["--bogus", "a.jpg"], "未知选项")
expectRejected(["-q"], "选项缺少参数")
check("jpeg2heif 只收 JPEG", parsed(["a.jpg"])?.sources, [.jpeg])
check("jpeg2heif 默认并发数是核数", parsed(["a.jpg"])?.jobs, ProcessInfo.processInfo.activeProcessorCount)
check("jpeg2heif 接受 --delete-original", parsed(["--delete-original", "a.jpg"])?.deleteOriginal, true)
check("默认核对画质", parsed(["a.jpg"])?.qualityCheck, true)
check("--no-quality-check 关掉画质核对", parsed(["--no-quality-check", "a.jpg"])?.qualityCheck, false)
check("--min-ssim、--min-psnr 设门槛", parsed(["--min-ssim", "0.95", "--min-psnr", "40.5", "a.jpg"])?.qualityThresholds,
      QualityThresholds(minSSIM: 0.95, minPSNR: 40.5))
check("默认不达标就不转", parsed(["a.jpg"])?.onQualityDrop, .skip)
check("--on-quality-drop retry", parsed(["--on-quality-drop", "retry", "a.jpg"])?.onQualityDrop, .retry)
check("--on-quality-drop skip", parsed(["--on-quality-drop", "skip", "--on-quality-drop", "skip", "a.jpg"])?.onQualityDrop, .skip)
func rejection(_ args: [String], _ command: Command = .jpeg2heif) -> String {
    do { _ = try parseArguments(args, command: command); return "接受了" } catch { return error.localizedDescription }
}
check("--min-ssim 越界", rejection(["--min-ssim", "1.5", "a.jpg"]), "--min-ssim 必须是 0 到 1 之间的数字，收到: 1.5")
check("--min-ssim 不是数字", rejection(["--min-ssim", "高", "a.jpg"]), "--min-ssim 必须是 0 到 1 之间的数字，收到: 高")
check("--min-psnr 越界", rejection(["--min-psnr", "-3", "a.jpg"]), "--min-psnr 必须是 0 到 100 之间的数字（单位 dB），收到: -3")
check("--min-psnr 不是数字", rejection(["--min-psnr", "33dB", "a.jpg"]), "--min-psnr 必须是 0 到 100 之间的数字（单位 dB），收到: 33dB")
check("--on-quality-drop 写错", rejection(["--on-quality-drop", "keep", "a.jpg"]),
      "--on-quality-drop 只能是 skip（不转）或 retry（提高质量再试），收到: keep")
check("--min-ssim 缺参数", rejection(["--min-ssim"]), "选项 --min-ssim 缺少参数")

print("raw2heif 的参数：只收 RAW、默认并发数保守、不接受 --delete-original")
func parsedRAW(_ args: [String]) -> ConversionOptions? {
    guard case .run(let o)? = try? parseArguments(args, command: .raw2heif) else { return nil }
    return o
}
check("raw2heif 只收 RAW", parsedRAW(["a.CR3"])?.sources, [.raw])
check("raw2heif 默认并发数是 min(核数, 4)", parsedRAW(["a.CR3"])?.jobs, min(ProcessInfo.processInfo.activeProcessorCount, 4))
check("raw2heif 的 -j 照给的来", parsedRAW(["-j", "9", "a.CR3"])?.jobs, 9)
check("raw2heif 的其余选项与 jpeg2heif 同义",
      parsedRAW(["-r", "-f", "-n", "-v", "--verify", "--no-raw-exif", "--embed-caption", "-q", "0.6", "-o", "/tmp/出", "目录"])
          .map { [$0.recursive, $0.overwrite, $0.dryRun, $0.verbose, $0.verify, !$0.rawExif, $0.embedCaption,
                  $0.quality == 0.6, $0.output?.path == "/tmp/出"] },
      [true, true, true, true, true, true, true, true, true])
do {
    _ = try parseArguments(["--delete-original", "a.CR3"], command: .raw2heif)
    fail("raw2heif 接受了 --delete-original")
} catch {
    check("raw2heif 拒绝 --delete-original 并说明", error.localizedDescription, "raw2heif 不删除 RAW 原片，不接受 --delete-original")
}
do {
    _ = try parseArguments(["a.CR3", "-v", "--delete-original"], command: .raw2heif)
    fail("raw2heif 接受了放在后面的 --delete-original")
} catch {
    pass("raw2heif 拒绝放在后面的 --delete-original")
}
do {
    _ = try parseArguments(["--allow-cmyk", "a.CR3"], command: .raw2heif)
    fail("raw2heif 接受了 --allow-cmyk")
} catch {
    check("raw2heif 不认 --allow-cmyk", error.localizedDescription, "未知选项: --allow-cmyk（用 --help 查看用法）")
}
check("raw2heif --help 退出码 0", try? parseArguments(["--help"], command: .raw2heif), .showUsage(exitCode: 0))
for args in [["--no-quality-check", "a.CR3"], ["a.CR3", "--min-ssim", "0.9"], ["--min-psnr", "30", "a.CR3"],
             ["--on-quality-drop", "retry", "a.CR3"]] {
    let flag = args.first { $0.hasPrefix("--") }!
    check("raw2heif 不接受 \(flag)", rejection(args, .raw2heif), "raw2heif 不核对画质（画质核对只对 JPEG），不接受 \(flag)")
}

print("命令行与界面的默认值")
// 两端都取自 ConversionOptions.default，这组断言守住它们不各自漂移。
func expectSame<T: Equatable>(_ gui: T, _ cli: T, _ why: String) {
    gui == cli ? pass("\(why) 两端一致（\(gui)）")
               : fail("\(why) 不一致：界面 \(gui)，命令行 \(cli)")
}
// 命令行这一侧必须真的解析一遍参数再读默认值，否则"两端一致"从未碰过命令行。
guard case .run(let cli) = (try? parseArguments(["照片.jpg"], command: .jpeg2heif)) else {
    fail("命令行解析不出最简单的一条命令"); finish("单元测试")
}
let gui = ConversionModel()
expectSame(gui.options.recursive, cli.recursive, "递归子文件夹")
expectSame(gui.options.quality, cli.quality, "质量")
expectSame(gui.options.overwrite, cli.overwrite, "覆盖同名文件")
expectSame(gui.options.deleteOriginal, cli.deleteOriginal, "删除源文件")
expectSame(gui.options.rawExif, cli.rawExif, "整块照搬 EXIF")
expectSame(gui.options.convertCMYK, cli.convertCMYK, "转 CMYK 的 JPEG")
expectSame(gui.options.sources, cli.sources, "收的源（模型的默认值；界面每批开始时由 ConversionTargets.apply 设成两种都收）")
expectSame(gui.options.jobs, cli.jobs, "并发数")
expectSame(gui.options.qualityCheck, cli.qualityCheck, "画质核对")
expectSame(gui.options.qualityThresholds, cli.qualityThresholds, "画质核对的门槛")
expectSame(gui.options.onQualityDrop, cli.onQualityDrop, "画质不达标时的处理")

// verify 是有意分叉：界面结果直接给人看，默认校验；命令行按需开关。
// 若哪天两端被"统一"成一样，这条会失败，提醒连同 Model.swift 的注释一起改。
if gui.options.verify && !cli.verify {
    pass("校验开关：界面默认开、命令行默认关（有意分叉）")
} else {
    fail("校验开关的分叉变了，Model.swift 里的说明需要同步更新")
}

finish("单元测试")
