// 纯逻辑单元测试：校验器判定两个元数据值"是否算变化"的规则。
// 这块规则很容易在两个方向上出错——太严就刷出一堆假差异，太松就把真的丢失藏起来，
// 所以正反两类用例都要有。

import Foundation
import ImageIO

// 下面这些 expectXxx 都是同一个形状：喂一组输入给某条判定规则，比对结果。
// 打印与失败计数一律交给 harness 的 checkRule：自己写 print + failedChecks
// 的话，漏掉一处 failedChecks 就会让失败悄悄变成通过。
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
// 键的拼法已对着真实照片核过：IMG_1225.JPG / P1130939.JPG 的 ImageIO 输出里
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
expectTrailer(mpfJPEG([(0x010002, gainMap)]), carried: [(40, 30)], ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"],
              "MP 类型是预览图（0x010002）：尺寸碰巧对上也照报")
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
expectTrailer(mpfJPEG([(0, gainMap)]) { $0[1].offset = 0x7FFF_FFF0 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "条目偏移指到文件外：照报，不崩")
expectTrailer(mpfJPEG([(0, gainMap)]) { $0[1].size += 1 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "条目长度越过文件末尾：照报")
expectTrailer(mpfJPEG([(0, gainMap)], tail: [1]) { $0[1].size += 1 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer + 1) 字节\(mpfNote)"], "条目范围里不只一张 JPEG：照报")
expectTrailer(mpfJPEG([(0, Array(gainMap.dropLast(2)) + [0x12, 0x34])]), carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "登记的图像没有 EOI：照报")
expectTrailer(mpfJPEG([(0, gainMap)]) { $0[1].offset = 0 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "偏移 0 指回主图自己：照报")
expectTrailer(mpfJPEG([(0, gainMap)]) { $0[1].offset -= 4 }, carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "条目范围伸进主图里：照报")
expectTrailer(mpfJPEG([(0, gainMap)], entryBytes: 0xFFFF_FFF0), carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "MPEntry 声称的条目数离谱：照报，不崩")
expectTrailer(mpfJPEG([(0, gainMap)], entryBytes: 40), carried: [(40, 30)],
              ["丢失 EOI 之后的 \(oneTrailer) 字节\(mpfNote)"], "MPEntry 长度不是 16 的倍数：照报")
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
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jpeg2heif-unit-\(UUID().uuidString)")
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
let uidDir = FileManager.default.temporaryDirectory.appendingPathComponent("jpeg2heif-uid-\(UUID().uuidString)")
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
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("jpeg2heif-unit-\(UUID().uuidString).heic")
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
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("jpeg2heif-carry-\(UUID().uuidString).heic")
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
func originalIssues(_ s: [UInt8]?, _ p: [UInt8]?, elsewhere: Bool = false) -> [String] {
    userCommentOriginalIssues(source: s, product: p, reportedElsewhere: elsewhere)
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
// UNICODE 头没有 BOM 的源：字节序没有声明，产物等于大端、小端两种解法里任何一种都算一致。
// 产物取「ImageIO 按大端读出、带 BOM 写回」的样子。
func imageIOBigEndianRewrite(_ body: [UInt8]) -> [UInt8] {
    let seen = String(bytes: body, encoding: .utf16BigEndian)!
    return unicodeHead + [0xFE, 0xFF] + utf16Bytes(seen, bigEndian: true) + [0, 0, 0, 0]
}
let noBOMSources: [(String, [UInt8])] = [
    ("大端无 BOM + emoji", utf16Bytes("🎉拍照😀好看👍今天", bigEndian: true)),
    ("小端无 BOM + 中文", utf16Bytes("鲁汶市政厅", bigEndian: false)),
    ("大端无 BOM + 纯中文", utf16Bytes("鲁汶市政厅", bigEndian: true)),
]
for (name, body) in noBOMSources {
    check("\(name)：产物是 ImageIO 按大端读出再带 BOM 写回的，不报",
          originalIssues(unicodeHead + body, imageIOBigEndianRewrite(body)), [])
    let other = originalIssues(unicodeHead + body, unicodeHead + [0xFE, 0xFF] + utf16Bytes("别的文字", bigEndian: true))
    check("\(name)：产物文本与两种解法都不同，报一行原文变化",
          other.count == 1 && other[0].hasPrefix("变化 备注 UserComment 的原文：") && other[0].hasSuffix(" → 别的文字"), true)
}
check("产物一侧是没有 BOM 的 UNICODE：两种解法里有一种与源相等就不报",
      originalIssues(luWenNoHead, unicodeHead + utf16Bytes("鲁汶市政厅", bigEndian: false)), [])
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

print("ISO 21496 版本标记段：产物里有 ISO 增益图才算带过去")
let isoMarker = jpegSegment(0xE2, Array("urn:iso:std:iso:ts:21496:-1".utf8) + [0, 0, 0, 0, 0])
let isoJPEG = [0xFF, 0xD8] + isoMarker + [0xFF, 0xD9]
let lostMarker = "丢失 APP2 段（urn:iso:std:iso:ts:21496:-1，32 字节）"
check("产物里有 ISO 增益图：不报", unportableSegments(in: isoJPEG, carriedAuxiliary: [], isoGainMapCarried: true), [])
check("产物里没有 ISO 增益图：照报", unportableSegments(in: isoJPEG, carriedAuxiliary: [], isoGainMapCarried: false),
      [lostMarker])
let longerMarker = [0xFF, 0xD8] + jpegSegment(0xE2, Array("urn:iso:std:iso:ts:21496:-1".utf8) + [0, 0, 0, 0, 0, 7])
    + [0xFF, 0xD9]
check("标识对、但不只版本号（多 1 字节）：照报",
      unportableSegments(in: longerMarker, carriedAuxiliary: [], isoGainMapCarried: true),
      ["丢失 APP2 段（urn:iso:std:iso:ts:21496:-1，33 字节）"])

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
    .appendingPathComponent("jpeg2heif-reencode-\(UUID().uuidString)")
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
    let result = convert(reencodeSource, opts: ConversionOptions(), dest: dest, encode: fake)
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
        .filter { $0.hasPrefix(".jpeg2heif-") }
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

print("命令行参数解析")
func parsed(_ args: [String]) -> ConversionOptions? {
    guard case .run(let o)? = try? parseArguments(args) else { return nil }
    return o
}
func expectRejected(_ args: [String], _ why: String) {
    do {
        _ = try parseArguments(args)
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
check("-- 之后的横杠开头当文件名",
      parsed(["--", "-奇怪的文件名.jpg"])?.inputs, ["-奇怪的文件名.jpg"])
check("-o 展开 ~", parsed(["-o", "~/out", "a.jpg"])?.output?.path.hasPrefix("/"), true)
check("--help 退出码 0", try? parseArguments(["--help"]), .showUsage(exitCode: 0))
check("没给输入时退出码 1", try? parseArguments([]), .showUsage(exitCode: 1))
expectRejected(["-q", "1.5", "a.jpg"], "质量超出 0–1")
expectRejected(["-q", "abc", "a.jpg"], "质量不是数字")
expectRejected(["-j", "0", "a.jpg"], "并发数为零")
expectRejected(["--bogus", "a.jpg"], "未知选项")
expectRejected(["-q"], "选项缺少参数")

print("命令行与界面的默认值")
// 两端都取自 ConversionOptions.default，这组断言守住它们不各自漂移。
func expectSame<T: Equatable>(_ gui: T, _ cli: T, _ why: String) {
    gui == cli ? pass("\(why) 两端一致（\(gui)）")
               : fail("\(why) 不一致：界面 \(gui)，命令行 \(cli)")
}
// 命令行这一侧必须真的解析一遍参数再读默认值，否则"两端一致"从未碰过命令行。
guard case .run(let cli) = (try? parseArguments(["照片.jpg"])) else {
    fail("命令行解析不出最简单的一条命令"); finish("单元测试")
}
let gui = ConversionModel()
expectSame(gui.options.recursive, cli.recursive, "递归子文件夹")
expectSame(gui.options.quality, cli.quality, "质量")
expectSame(gui.options.overwrite, cli.overwrite, "覆盖同名文件")
expectSame(gui.options.deleteOriginal, cli.deleteOriginal, "删除源文件")
expectSame(gui.options.rawExif, cli.rawExif, "整块照搬 EXIF")

// verify 是有意分叉：界面结果直接给人看，默认校验；命令行按需开关。
// 若哪天两端被"统一"成一样，这条会失败，提醒连同 Model.swift 的注释一起改。
if gui.options.verify && !cli.verify {
    pass("校验开关：界面默认开、命令行默认关（有意分叉）")
} else {
    fail("校验开关的分叉变了，Model.swift 里的说明需要同步更新")
}

finish("单元测试")
