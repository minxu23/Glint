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
        // 产物字段应是：前缀 + 文本（ASCII 打头的非 ASCII 文本前面加 BOM）的编码，后面只有 NUL。
        let units = (!ascii && text.utf16.first! <= 0x7F ? [0xFEFF] : []) + Array(text.utf16)
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
               makerNote: Bool = false) -> [String] {
    compareRawExif(source: source, dest: dest, viewLosses: viewLosses, makerNoteReported: makerNote).issues
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

print("GPS 按原始分数比：值不等就报，不加容差")
let srcLatitude = rawEntry(.gps, "GPS", 0x0002, 5, rationalBytes([(22, 1), (38, 1), (53743286, 1000000)]))
let gps = compareRawExif(source: [srcLatitude],
                         dest: [rawEntry(.gps, "GPS", 0x0002, 5, rationalBytes([(22, 1), (38, 1), (5374, 100)]))],
                         viewLosses: [], makerNoteReported: false)
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
    } else {
        fail("写不出作为 heifExif 输入的 HEIC"); fail("（同上）"); fail("（同上）"); fail("（同上）")
    }
    try? FileManager.default.removeItem(at: url)
} else {
    fail("造不出作为 encodeHEIF 源的 JPEG"); fail("（同上）"); fail("（同上）"); fail("（同上）")
}
for (bytes, why) in [([UInt8](), "空文件"), (Array("not a heif file at all".utf8), "垃圾"),
                     ([0, 0, 0, 1] + Array("ftyp".utf8) + [UInt8](repeating: 0xFF, count: 8), "64 位盒子长度离谱"),
                     ([0, 0, 0, 0x10] + Array("meta".utf8) + [0, 0, 0, 0] + [0, 0, 0, 0x30], "meta 里的子盒子越界")] {
    if case .unreadable = heifExif(bytes) { pass("读不出：\(why)") } else { fail("\(why) 没被判成读不出") }
}

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

// verify 是有意分叉：界面结果直接给人看，默认校验；命令行按需开关。
// 若哪天两端被"统一"成一样，这条会失败，提醒连同 Model.swift 的注释一起改。
if gui.options.verify && !cli.verify {
    pass("校验开关：界面默认开、命令行默认关（有意分叉）")
} else {
    fail("校验开关的分叉变了，Model.swift 里的说明需要同步更新")
}

finish("单元测试")
