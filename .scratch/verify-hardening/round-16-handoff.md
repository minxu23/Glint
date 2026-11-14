# 第 16 轮交接稿：真实照片测出来的五件事

工作规则、长期要求、变异与 mtime 陷阱的注意事项，全部沿用
[`round-12-handoff.md`](round-12-handoff.md) 的第 0 节，先读那一节。

起因：交接方拿一组 10 张真实手机照片（安卓/鸿蒙机型、微信导出、佳能、截图）跑了
`--verify`。照片属于用户个人，**不给你、不入库**；交接方验收时自己再跑一遍。下面把量到的
事实和样本特征写全，你用仓库内合成的样本复现。

## 交接方量到的事实（main = b8bd91f）

量具在 [`round-16-repro/`](round-16-repro/)，只供参考写法，测试不得依赖。

### 1. 彩色 ISO 增益图被静默丢掉（转换缺陷，校验报出来了）

一张手机 HDR 照片的增益图是 **3 通道**（MPF 第二张 JPEG，`ColorComponents = 3`，4:2:0）。
ImageIO 对它的表现：

- `CGImageSourceCopyAuxiliaryDataInfoAtIndex(…, kCGImageAuxiliaryDataTypeISOGainMap)` 返回的
  字典**只有三个键**：`DataDescription`（`PixelFormat = 875704422` 即 `'420f'`）、
  `ColorSpace`、`Metadata`——**没有 `kCGImageAuxiliaryDataInfoData`**。
- 把这个字典交给 `CGImageDestinationAddAuxiliaryDataInfo`，`Finalize` **返回 true**，但产物里
  没有增益图。所以 `encodeFirstPass` 的"带辅助图失败就回退"不会触发。
- 后果：HDR 效果整个没了。HDR 解码后高光区相对误差中位 37%，最亮 0.94（源 1.64）。

单通道增益图（第 15 轮那四张公开样本，`PixelFormat = 'L008'`）有 `Data` 键，不受影响。

**修法已量定：首遍 `AddImageFromSource` 的属性里加 `kCGImageDestinationPreserveGainMap: true`，
增益图两种类型不再走 `AddAuxiliaryDataInfo`。** 量具 `combo.swift`，三种模式对比：

| 样本 | 现行（aux） | 只用 preserve | preserve + aux |
|---|---|---|---|
| 苹果新/旧格式增益图 | 有增益图 | **与现行逐字节相同** | 体积 25.7→29.2 KB（写了两份） |
| Ultra HDR 两张 | 有增益图 | **与现行逐字节相同** | 失败 |
| 彩色增益图那张 | **无增益图** | 有，HDR 误差中位 0.37%、最亮 1.642，SDR 不变 | 同 preserve |

- 第二遍 `CopyImageSource` 之后增益图仍在，HDR 度量不变（量过）。
- 另外两条路都不行：自己从 MPF 解出增益图再按 BGRA 交给写入器能搬（误差 0.27%），但
  复杂得多；"解码成 HDR 再 `EncodeToISOGainmap`"会把 SDR 基础图改暗（平均误差 0.11），否决。
- 深度图、视差图、各种蒙版照旧走 `AddAuxiliaryDataInfo`。

**ISO 21496 版本标记段**：带 ISO 增益图的 JPEG 主图里有一个 32 字节的
`APP2 urn:iso:std:iso:ts:21496:-1` 段（只有版本号），现在被报成"丢失 APP2 段"。产物里
ISO 增益图在的时候，这个段就算已带过去；产物里没有 ISO 增益图（或源里本来就没有增益图、
只有这个孤立的段，真实样本里有一张这样的）就照旧报。

### 2. ImageIO 读不到的 EXIF 标签被静默丢掉（校验盲区）

校验两边都走 ImageIO 视图，ImageIO 在源一侧就读不到的标签，产物里当然也没有，两边都
看不见，于是一声不响。真实样本里的实例（`tiffwalk.py` / exiftool 量的）：

| 标签 | 位置 | 怎么不规范 | 值 |
|---|---|---|---|
| GPSProcessingMethod 0x001B | GPS IFD | 类型存成 ASCII（规范是 UNDEFINED 带 8 字节字符集头） | `CELLID` |
| MakerNote 0x927C | ExifIFD | 国产机型写的私有短串，有一张**重复了三次** | `J`、`##**N4206_vivi`、`Auto` |
| LightSource 0x9208 | ExifIFD | 类型存成 LONG（规范是 SHORT） | `0` |
| DocumentName 0x010D | ExifIFD（规范在 IFD0） | 长度 0 | 空 |
| UserComment 0x9286 | ExifIFD | 8 字节全 0 字符集头 + 248 个空格 | 空白 |
| tag 0、类型 0、长度 0（四个） | ExifIFD | 空条目 | 无 |

能不能写回去：GPSProcessingMethod **写不回去**——属性字典里放
`kCGImagePropertyGPSProcessingMethod`、XMP 里放 `exif:GPSProcessingMethod` 再合并，两条路
产物里都没有（`gpswrite.swift`、`pmxmp.swift`）。其余几种同理，ImageIO 不认就写不出。所以
这一条**只做检测**。

### 3. GPS 精度被截断，而且校验只是有时能报出来

源文件把坐标的"秒"存成分母 1000000 的分数（`53743286/1000000`）。ImageIO 写 HEIF（写 JPEG
也一样）不管给多精确的 double，**秒都存成分母 100**（`5374/100`），误差最多约 15 cm。
写不回去，只能如实报。

校验现在靠的是 ImageIO 视图：`{GPS}/Latitude` 在源一侧就已经被四舍五入（ImageIO 用 XMP 的
`度,分.分` 形式反推），只有截断恰好跨过它的舍入档才报。一张样本的经度报了、纬度没报；
另一张两条都报。

### 4. 转出来比原图大，照样写、照样能删源

25.3 KB 的 JPEG 转出 33.7 KB 的 HEIF（-33%），`--delete-original` 下校验通过就会删源。

### 5. 色度抽样（上一轮遗留）

带辅助图的 JPEG，ImageIO 才暴露 `{FileContents}`。4:2:2 的源会报
`变化 {FileContents}/Images[0]/ChromaSubsampling: 4:2:2 → 4:2:0`。这是编码属性，README 说
有意忽略，但这条键路径没被覆盖。

## 要做的

### A. 彩色增益图搬过去

按事实 1 的修法改 `encodeFirstPass`。回退路径（带辅助图 `Finalize` 失败时）要连
PreserveGainMap 一起去掉，保证转换本身能成功、校验报丢。ISO 21496 版本标记段按事实 1 的
规则记账。`auxiliaryDataTypes` 在校验一侧照旧列全。

### B. 原始 EXIF 标签清点

在原始字节层比较源与产物各有哪些 EXIF 标签，源里有、产物里没有的报"丢失"。要点：

1. **产物一侧也要读原始 EXIF**：需要从 HEIC 里取出 Exif 项（`meta` → `iinf`/`iloc`，项里
   先是 4 字节的 TIFF 头偏移）。只需支持 ImageIO 自己写出来的形态；解析不了就报一行
   "无法核对原始 EXIF 标签"，**不能当作没有差异**。现有 `TIFFStructure` 复用。
2. **按标签号比，IFD0 和 ExifIFD 合并成一个命名空间**（源里放错 IFD 的标签，ImageIO 读到后
   会写到规范位置，按 (IFD, 标签号) 比会误报）；GPS、Interop 各自一个命名空间；IFD1（缩略图）
   整个不比，与 README 现有的缩略图策略一致。
3. **不报的**：
   - 结构/编码类标签（宽高、BitsPerSample、Compression、YCbCr 系列、各 IFD 指针、
     PixelX/YDimension、Interop 里的 InteropIndex/InteropVersion 等）。清单写死在一处，
     README 同步列出；以零噪声测试为准增删，**每加一个都要在报告里说明为什么它不算信息**。
   - **没有数据的条目**：长度 0；ASCII/UNDEFINED 的值只含 NUL 和空格；UserComment 去掉
     8 字节字符集头后只含 NUL 和空格。数值型的 0 **算数据**（LightSource 0 = 未知光源，照报）。
   - 已经由别的规则负责的标签（Windows XP 标签、Rating/RatingPercent 由"等价字段带着同一个值"
     规则管，时间字段由原始时间规则管）。
4. **一处丢失一行**：MakerNote 已经由 ImageIO 视图那条规则报出来的（佳能那种
   `{ExifAux}`/`{MakerCanon}` 字典），原始清点不再重复报 0x927C；重复出现的同号标签合成一行，
   注明次数。
5. 报告行要让人看得懂，例如
   `丢失 EXIF 标签 GPSProcessingMethod（GPS 0x001B，ASCII，"CELLID"）——ImageIO 读不出这种写法`。
   值很长的截断显示。

### C. GPS 按原始分数比

源与产物的 GPS 坐标（纬度、经度，以及海拔、时间戳等同类分数字段）按**原始分数**比较，
值不等就报，例如 `变化 GPS 纬度：22°38′53.743286″ → 22°38′53.74″（HEIF 写入器只保留到 1/100 秒）`。
不加容差（用户此前已否决数值容差）。这条报出来之后，ImageIO 视图里同一处变化
（`{GPS}/Latitude`、`XMP/exif:GPSLatitude` 等）不再重复报——同样是"一处丢失一行"。

后果要写进 README：秒的精度高于 1/100 的照片（很多手机都是）校验一律报 GPS 变化，
`--delete-original` 不会删它们。

### D. 变大了就提示，并且不删源

产物比源大时，CLI 和图形界面都给出明确提示（例如"HEIF 比原图大 33%"）；
`--delete-original` 下即使校验通过也不删源，并说明原因。批量汇总里单列"变大"的个数。

### E. `{FileContents}` 里的编码属性

先量带辅助图的源暴露出哪些 `{FileContents}/Images[n]/…` 键，把其中属于编码属性的（至少
`ChromaSubsampling`）按**完整键路径、去掉数组下标**的规则加进忽略，与现有 `isThumbnailKey`
的做法一致，不用子串匹配。量到的键清单写进报告。

### F. 文档

README 的 `## 已知限制`、`## 保留了哪些元数据`、`## --verify 到底比什么` 按做完后的行为
改写：彩色增益图、原始标签清点及其不报清单、GPS 精度、变大不删。只写现在的行为。

## 验证方案

见证样本全部在仓库内合成（扩展 `Tests/fixture.swift` 和 `Tests/mangle`）。

1. **彩色增益图**：ImageIO 合成 JPEG 时增益图总是单通道（`EncodeGainMapPixelFormatRequest`
   试过 BGRA/RGBA/420f/L008，全是单通道）。可行的造法（`round-16-repro/colorize.swift` 已
   验证）：先用 `kCGImageDestinationEncodeToISOGainmap` 从扩展范围浮点图合成带单通道 ISO 增益图
   的 JPEG，再把 MPF 第二张换成 3 通道 JPEG（保留原增益图 JPEG 的 APPn 段，即 ISO 21496 元数据），
   改写 MPF 条目里的长度。造出来的样本 ImageIO 读回 `'420f'`、无 `Data`，与真实照片同一状态。
   注意让合成图的 HDR 余量明显大于 1（交接方那张只有 1，不够做 HDR 度量）。断言：产物有
   ISO 增益图；HDR 解码余量与源相同；`✓ 元数据校验通过`（含 ISO 21496 标记段不再报）。
2. **原始标签清点**：`mangle` 加一种模式，往 ExifIFD / GPS IFD 塞 ImageIO 不认的条目。至少：
   ASCII 类型的 GPSProcessingMethod（必须报）、LONG 类型的 LightSource（必须报）、未知私有标签
   （必须报）、长度 0 的条目和全空格的 UserComment（必须**不**报）、源里放在 ExifIFD 的
   DocumentName 带非空值（若 ImageIO 读得到并写到 IFD0，必须**不**报——先量）。
3. **GPS**：`mangle` 把源的 GPS 秒改写成分母 1000000 的分数 → 报一行 GPS 变化，ImageIO 视图那几条
   不重复出现；分母本来就是 100 的源 → 不报。
4. **变大**：造一张转出来会变大的小 JPEG（先量什么样的输入能稳定变大），断言提示出现、
   `--delete-original` 不删源；正常变小的样本照旧删。
5. **色度抽样**：造一张 4:2:2 且带辅助图的样本（`test_pic/P1130939.JPG` 是 4:2:2，可参考），
   断言不再报 `ChromaSubsampling`。
6. **变异**（每条亲眼看红，确认 swiftc 那行真的重编了）：
   - 去掉 PreserveGainMap → 第 1 项红；
   - 增益图同时也走 AddAuxiliaryDataInfo → 你加的"产物里只有一份增益图/体积"断言红
     （先量苹果样本那种情况在合成样本上能否复现；复现不了就在报告里说明）；
   - ISO 标记段改成"一律算带过去" → 一张"只有标记段、没有增益图"的样本红；
   - 原始清点关掉 → 第 2 项的"必须报"红；不报清单里去掉"没有数据的条目" → 第 2 项的
     "必须不报"红；
   - GPS 改回只看 ImageIO 视图 → 第 3 项红；
   - 变大不删去掉 → 第 4 项红；
   - 色度抽样忽略去掉 → 第 5 项红。
7. **零噪声**：六种夹具、`test_pic/` 两张照片、第 15 轮的辅助图见证，`--verify` 输出不得
   多出任何一行（原始清点和 GPS 会让 `test_pic/` 的输出变化的话，逐行说明是不是真丢失）；
   没有增益图的输入，产物与修改前**逐字节相同**。
8. **第 15 轮四张公开样本**（若临时目录还在，只量不入库）：产物与修改前逐字节相同，校验
   输出不变。
9. **健壮性**：HEIC 解析和原始清点都吃不可信输入。截断的 `iloc`、指向文件外的偏移、
   IFD 条目数离谱、循环指针，都不能崩，也不能因此吞掉该报的差异。交接方会拿现有的
   2907 个畸形样本再跑一遍。

## 交付报告

提交 SHA；A–F 各做了什么；量到的东西（`{FileContents}` 编码键清单、结构标签不报清单及每条
理由、变大的样本怎么造、DocumentName 放错位置时 ImageIO 的行为）；每张见证的断言结果；
每条变异与红线；零噪声与产物不变性；三个计数及增量来源（现为 153 / 338 / 41）；未处理的
发现；没完成或没覆盖到的。
