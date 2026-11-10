# 第 14 轮交接稿：非 ASCII 的 UserComment 转换后被截掉一半

工作规则、长期要求、变异与 mtime 陷阱的注意事项，全部沿用
[`round-12-handoff.md`](round-12-handoff.md) 的第 0 节，先读那一节。本稿只有一条。

## 现象（交接方已复现，main = c4834fc）

源 JPEG 里一条**完整的、带 `UNICODE\0` 前缀的非 ASCII UserComment**，如果字段后面
没有足够的 NUL 填充，转成 HEIC 后只剩大约前一半：

| 样本 | 源里的备注 | 产物里的备注 | 校验 |
|---|---|---|---|
| B：字段 48 字节，正文 23 个字（46 字节）+ 2 字节 NUL | 备注：这是拍摄当时写下的一段说明文字，用于测试 | 备注：这是拍摄当时写下的 | 报 2 处"变化" |
| D：字段 48 字节，正文 24 个字正好占满，零填充 | …用于测试啊 | 备注：这是拍摄当时写下的 | 报 2 处"变化" |

- ImageIO **读**源时拿到的是完整的字符串（`probe --no-repair` 读 B 得到全文），截断发生在
  **写**产物时。
- 不是近两轮引入的：用 `10c2dfd`（单遍旧路径）的二进制转同一张 B，结果相同。
- 不是静默的：`--verify` 会报 `{Exif}/UserComment` 和 `XMP/exif:UserComment` 两条"变化"，
  `--delete-original` 保留源。但数据确实没搬过去。
- README `## 已知限制` 写的是"本工具走的是源属性直通路径，源文件里的 NUL 填充恰好抵消了
  这个问题，实测中英文备注都能完整保留"——只在填充够的时候才成立。
- 可达性：相机通常给这个字段留一大块填充，不受影响；用 exiftool 之类写中文备注的文件
  （字段长度正好等于正文）会中。

样本是这样造的：默认夹具的 UserComment 条目总长 56 字节（8 字节前缀 + 48 字节正文区），
ImageIO 写夹具时只往里存了前 11 个字、后面全是 NUL；把完整全文的 UTF-16BE 字节原地写进
那 48 字节，就得到 B（23 个字）和 D（24 个字）。条目的 count 不变，所以不需要重排 IFD。

## 交接方做过的实验（仅供参考，不是指定做法）

在拷贝里给 `encodeHEIF` 开头加了这么一段，把非 ASCII 的备注在写入前补上等长的 NUL：

```swift
var properties = properties
if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
   let c = exif[kCGImagePropertyExifUserComment] as? String, !c.allSatisfy(\.isASCII) {
    exif[kCGImagePropertyExifUserComment] = c + String(repeating: "\0", count: c.utf16.count)
    properties[kCGImagePropertyExifDictionary] = exif
}
```

结果：B、D 的产物备注与源完全一致，`✓ 元数据校验通过`；夹具直出的那张（11 个字）和无前缀
裸 UTF-8 那张（第 6 轮的样本）不变；`make test` 全过。

这只证明"可行"。它是按"ImageIO 把字符数当字节数"这个猜测凑的，没有量过 ImageIO 到底按
什么规则决定写多少字节。

## 修改方向

目标：**凡是 ImageIO 读得出来的 UserComment，转换后产物里的值与源里的值完全一致**，
不依赖源字段碰巧留了多少填充。

1. **先量规则，再定修法。** 用几个长度、几种字符组成的字符串实测 ImageIO 写 HEIC 时
   往 UserComment 里放了多少字节（看产物里的原始字节，不只看读回来的字符串），把规则
   写进报告。至少覆盖：纯 CJK、ASCII 与 CJK 混排、BMP 之外的字符（emoji，UTF-16 里是
   代理对——`String.count`、`utf16.count`、UTF-8 字节数三者都不同，猜错哪个都会差一截）、
   长备注（几百个字）、纯 ASCII。
2. 修法要在**唯一一处**生效：备注有两个来源（源属性直通；`rawExifUserComment` 对无前缀
   写法的修补），两条路都得走到同一个处理点，不要各补一遍。
3. 补出来的填充不能变成内容：产物里读回来的字符串不能带尾部 NUL 或别的垃圾（现有的
   "尾部 NUL 填充只比有效内容"规则会掩盖这一点，所以要直接看 probe 读回的值和原始字节）。
4. 纯 ASCII 的备注不要动：对不含非 ASCII UserComment 的输入，产物必须与修改前**逐字节
   相同**。

## 验证方案

见证样本要能在仓库内自足地造出来（扩展 `Tests/mangle/`，例如加一个"把 UserComment 原地
改写成带 UNICODE 前缀的给定文本"的模式；不能用 Python）。

- B 型（少量填充）与 D 型（零填充）：产物的 `{Exif}/UserComment` 与源逐字符相同，
  `✓ 元数据校验通过`；
- 含 emoji 的备注、ASCII 与 CJK 混排的备注：同上；
- 一条明显长于夹具字段的备注如果在仓库内造不出来（需要改 count、重排 IFD），就用单测
  直接测那个处理函数，并在报告里说明端到端没覆盖到；
- 第 6 轮（无前缀裸 UTF-8）仍然全过；
- **变异**：去掉你的修复 → B、D 两条变红；
- **零噪声**：六种夹具（默认、`--no-exif-offset`、`--lossy`、`--cmyk`、`--rich-xmp`、
  `--extended-xmp`）和 `test_pic/` 两张真实照片（先拷贝再转）的 `--verify` 输出不得多出
  任何一行；
- **产物不变性**：上面这些样本里，凡是不含非 ASCII UserComment 的，产物逐字节相同；
  含的，解码后的像素、尺寸、色彩描述文件不变，差别只在 EXIF 那一个字段。把你怎么比的
  写进报告。

## 文档

README `## 已知限制` 里"非 ASCII 的 EXIF `UserComment` 依赖源文件的字段填充"那一条，
按修好之后的实际行为改写：还剩什么限制就写什么，没有就删掉这一条。只写现在的行为。

`Tests/fixture.swift` 里有一段注释说夹具自己的备注在生成 JPEG 时就存不全——那说的是
ImageIO 的 JPEG 写入路径，是量过的事实，与本条无关，不要动。

## 交付报告

提交 SHA；量到的 ImageIO 写入规则；修法及为什么选它；每张见证的源值与产物值；变异与
红线；零噪声与产物不变性的对比；三个计数及增量来源（现为 103 / 277 / 41）；未处理的
发现；没完成的。
