# jpeg2heif

把 JPEG 转成 HEIF（`.heic`），并完整保留元数据——拍摄时间、拍摄位置、备注、
相机参数、版权、访达备注与标签、文件时间戳，一样不丢。

提供**图形界面**和**命令行**两种用法，两者共用同一套转换核心
（[Sources/Core/Converter.swift](Sources/Core/Converter.swift)）。

macOS 原生实现（Swift + ImageIO + AppKit），**零依赖**：不需要 ImageMagick、
libheif、exiftool 或 Python 包，也不需要安装完整的 Xcode——命令行工具即可构建。
用系统自带的 HEIC 编码器，Apple Silicon 上走硬件加速。

## 构建与安装

```bash
make
```

`make` 会同时产出命令行工具 `jpeg2heif` 和应用 `JPEG2HEIF.app`。装到系统里：

```bash
sudo make install
```

也可以分开装：`make install-app` 只装应用，`make install-cli PREFIX=~/.local`
只装命令行工具。想先试试不安装，直接 `make run` 打开应用。

## 图形界面

把 JPEG 文件或整个文件夹拖进窗口，调好设置，点「开始转换」。

- **拖放或选择**：拖文件、拖文件夹，或用「添加…」；也可以在访达里对 JPEG
  选「打开方式 → JPEG 转 HEIF」。
- **默认只处理文件夹顶层**，与命令行不加 `-r` 时一致；要连子目录一起转就勾上
  「递归子文件夹」。两端的默认值取自同一处（`ConversionOptions.default`），不会各自漂移。
  唯一有意分叉的是「转换后校验元数据」：界面默认开（结果直接给人看），命令行
  的 `--verify` 按需开。
- **每张图的结果**一目了然：转换前后体积、节省比例、保留了多少条元数据。
- **元数据差异**会单独标出来，点橙色的「N 处差异」能看到具体是哪些字段。
- **输出位置**可以选源文件旁边或指定文件夹；递归转换整个相册时，输出目录会
  镜像原有的子目录结构，同名文件不会互相覆盖。
- 勾选「校验无损后删除源文件」时会先弹窗确认，且只有逐条比对确认完全无损的
  那些文件才会被删除。转出来比原图大的也不删，副标题会写「HEIF 比原图大 N%」。
- 转换在后台并发进行，随时可以取消。

## 命令行

```bash
jpeg2heif 照片.jpg
```

整个文件夹批量转换（`-r` 递归子目录，`-o` 指定输出位置）：

```bash
jpeg2heif -r ~/Pictures/2024 -o ~/Pictures/2024-heic
```

不加 `-r` 只处理该文件夹顶层，不下钻子目录；不加 `-o` 就把 `.heic` 输出到每张
源图旁边。文件夹里的非 JPEG（`.png`、`.txt`、已有的 `.heic`）会被自动跳过，
`.JPG` / `.jpeg` / `.JPEG` 等大小写写法都认。

| 选项 | 说明 |
| --- | --- |
| `-q, --quality <0.0-1.0>` | 压缩质量，默认 `0.8` |
| `-o, --output <路径>` | 输出目录；单个输入时也可以是输出文件名。默认输出到源文件同一目录 |
| `-r, --recursive` | 递归处理目录下所有 JPEG，并在输出目录中镜像原有的子目录结构 |
| `-f, --overwrite` | 覆盖已存在的输出文件（默认跳过，不覆盖） |
| `--verify` | 转换后逐条比对元数据，报告任何丢失或变化 |
| `--delete-original` | 删除源 JPEG。会自动先做 `--verify`，只有完全无损、且 HEIF 不比原图大才删 |
| `-n, --dry-run` | 只打印将要做什么，完全不碰磁盘（连输出目录也不建） |
| `-j, --jobs <n>` | 并发数，默认为 CPU 核心数 |
| `-v, --verbose` | 打印每张图保留的元数据条目数 |

想在替换原图前确认万无一失：

```bash
jpeg2heif --verify -r ~/Pictures/相册 -o /tmp/heic-试转
```

## 保留了哪些元数据

分三层，全部由系统级 API 搬运，不做任何字段白名单过滤：

1. **图像元数据字典** —— EXIF、GPS、IPTC、TIFF、ExifAux。
   包括拍摄时间（`DateTimeOriginal`、时区偏移、亚秒）、拍摄位置（经纬度、
   海拔、方位角、GPS 时间戳）、相机与镜头型号、光圈快门 ISO 焦距、
   图像描述、`UserComment` 备注、作者、版权、星级评分等。
   `ImageUniqueID` 也包括 ImageIO 读不出的写法：ImageIO 只读长度恰好 33 字节（32 个字符
   加 NUL，规范的定长）的值，别的长度（如 24 字节的 `J12LLKF00SM J12LLKL01GM`、26 字节的
   `OPPO_20201019_204116_0001`）它当作不存在，与内容无关。本工具从源 JPEG 的原始字节里
   取出值（取到第一个 NUL 为止）补进要写入的属性，写入器把它原样写进产物。只补能原样写回
   的：Exif 子 IFD 里恰好一个、ASCII 类型、有数据、取出的字节是合法 UTF-8；别的写法不补，
   `--verify` 照报丢失。
2. **XMP 数据包** —— Lightroom / Photoshop / Bridge 写入的标题、说明、
   关键词、评级、版权、人脸区域等，整包合并进产物：包括属性字典表达不了的
   `xmp:Label`、`lr:hierarchicalSubject`、`dc:title` 的各个语言、人脸区域的
   `Name`、`xmpMM:*` 和自定义命名空间，也包括扩展 XMP 段里的内容。
3. **文件层元数据** —— 创建时间、修改时间、POSIX 权限，以及全部扩展属性
   （访达备注 `kMDItemFinderComment`、访达标签 `kMDItemUserTags` 等）。
   相册类 App 在 EXIF 缺失时会回退到文件时间，所以这一层同样影响"拍摄时间"。

ICC 色彩描述文件和图像方向也一并保留。CMYK 的 JPEG 例外：产物会变成 RGB、
描述文件变成 sRGB，`--verify` 会把这两项报出来。

**辅助图像**也搬进产物：HDR 增益图（苹果格式与 ISO 格式，ISO 增益图单通道、3 通道
都算——手机 HDR 照片里常见 3 通道的）、深度图、视差图、人像蒙版和各种语义分割蒙版
（皮肤、头发、牙齿、眼镜、天空），即 ImageIO 的 `kCGImageAuxiliaryDataType*` 全部成员。
每张辅助图附带的元数据跟着走，例如苹果增益图的 `HDRGainMap:HDRGainMapVersion`、
`HDRGainMap:HDRGainMapHeadroom`，ISO 增益图的 `HDRToneMap:*`，所以带增益图的照片转换后
按 HDR 显示的亮度余量不变。辅助图的像素是重新有损编码的，见「已知限制」。

转换分两遍。第一遍走 `CGImageDestinationAddImageFromSource`，直接从源转码而不是
先解码成位图再编码，ICC 跟着走，EXIF 等属性字典（含本工具修补过的 `UserComment` 和补回的
`ImageUniqueID`）写进去；增益图由这一步的 `kCGImageDestinationPreserveGainMap` 带过去，深度图、视差图、
蒙版用 `CGImageDestinationAddAuxiliaryDataInfo` 逐个加在主图后面。增益图不走后一条路：
3 通道的 ISO 增益图从源里取出来没有像素数据，交给 `AddAuxiliaryDataInfo` 时写入照样
成功、产物里却没有增益图；单通道增益图两条路写出的产物逐字节相同，两条一起走则苹果
增益图会写两份、ISO 增益图会写入失败。这一遍不接受 XMP 包。第二遍用
`CGImageDestinationCopyImageSource` 把第一遍的结果连同源的 XMP 一起写出，这一步只合并
元数据、不重新编码像素，辅助图原样留在产物里。写入采用「先写临时文件、成功后再原子
替换」，中断不会留下半个文件。

转出来的 HEIF 比原图大时（已经压得很小的 JPEG 会这样），命令行和界面都会提示
「HEIF 比原图大 N%」，批量汇总里单列变大的个数，`--delete-original` 也不删这样的源。

## `--verify` 到底比什么

把源文件和产物的元数据各自递归展开成「路径 = 值」的集合，逐条比对，报告
丢失和变化。

**源侧的时间字段以原始字节为准。** ImageIO 读 JPEG 时会把 EXIF、IPTC-IIM、XMP
三处的时间互相调和：只改过 EXIF 时间的照片，它的属性视图里 IIM 的 `184207+0800`
会变成 `184208`、XMP 里的 `+08:00` 随之消失；只改过 IIM 时，视图里的 EXIF 拍摄
时间又会跟着 IIM 变。所以源侧这些字段不取视图，而是直接从 JPEG 字节里读，覆盖
视图里的同名键：EXIF 的 `DateTime`、`DateTimeOriginal`、`DateTimeDigitized`、
`OffsetTime*`，IIM 的 `DateCreated`、`TimeCreated`、`DigitalCreationDate`、
`DigitalCreationTime`，以及 XMP 包里所有值形如时间戳的标签。然后照下面的规则
比对。XMP 的时间戳按时刻比：日期相同，时刻在源值给出的精度上相同，源值带小数秒
或偏移则必须一样；产物多带小数秒或偏移不算差异——ImageIO 写产物时会从 EXIF 补上
`.42` 这样的小数秒。

**ImageIO 看不见的段逐段报出。** 属性视图里没有、转换后必然消失的东西，比对键
空间是发现不了的，所以另外扫一遍源 JPEG 的段结构，每段报一条：

- `COM` 注释段；
- ImageIO 不认识的 `APPn` 段（如 C2PA 用的 APP11）。认识的是 JFIF/JFXX、EXIF、
  XMP 主包与扩展 XMP、ICC、MPF、Photoshop（IPTC）和 Adobe 这几种。带 ISO 增益图的
  JPEG 主图里还有一个 32 字节的 ISO 21496-1 版本标记段（APP2
  `urn:iso:std:iso:ts:21496:-1`，只有版本号）：源和产物里都有 ISO 增益图时它算带过去了，
  否则（产物里没有 ISO 增益图，或源里只有这个孤立的段）照报；段里多出版本号以外的
  字节也照报；
- `EOI` 之后的数据（安卓动态照片的视频、MPF 多图格式的附加图像等）。全是
  `0x00`/`0xFF` 填充的不算。JPEG 的辅助图就存放在这里、由 APP2 的 MPF 索引登记，
  已经搬进产物的那几段不计入，剩下的字节照报。一个 MPF 条目算作已搬走，要同时满足：
  MP 类型码是 0（辅助图写的就是 0，大尺寸预览图是 `0x010001`/`0x010002`）；范围整个
  落在 `EOI` 之后、不与别的已认条目重叠；范围里恰好是一张完整的 JPEG（`SOI` 开头、
  `EOI` 结尾，不多不少）；这张 JPEG 的宽高等于某一张辅助图的宽高，而这张辅助图在源和
  产物里都有、类型、宽高、像素格式都相同。每张辅助图只认领一个条目。MPF 索引里的偏移、
  长度、条目数都来自源文件，越界、自相矛盾或读不出时一个条目都不认，整段照报。剩下的
  字节报成 `丢失 EOI 之后的 N 字节（尾部共 M 字节，其中 K 字节是已搬进产物的辅助图像）`；
  一个条目都没认下时报整段，和没有辅助图时一样。

**辅助图本身由键空间比对管着。** ImageIO 在容器级属性的 `{FileContents}` 里给每张
辅助图列一组键（类型、宽、高、像素格式、增益图的 `HDRHeadroom`，ISO 增益图还有
`DerivationDetails[…]` 下的色调映射参数）。ImageIO 按数组下标列它们，但辅助图在产物里
的先后不由源决定（增益图随主图一起写，排在别的辅助图前面），所以比对前把下标换成辅助
图的类型：`{FileContents}/Images[0]/AuxiliaryData[Depth]/Width`。同一张图里类型重复时
那一组照旧用下标。搬过去了这些键就在产物里，没搬过去就逐条报丢失。辅助图的像素数据
不比——它们和主图一样是有损重新编码的。

**EXIF 标签在原始字节层再清点一遍。** 上面的比对两边都走 ImageIO 的视图，ImageIO 在
源一侧就读不出的标签，产物里当然也没有，两边都看不见，于是一声不响。真实照片里这样的
标签不少：类型存成 ASCII 的 `GPSProcessingMethod`（规范是 UNDEFINED）、类型存成 LONG 的
`LightSource`（规范是 SHORT）、放错 IFD 的标签（实测 ImageIO 既不读 Exif 子 IFD 里的
`DocumentName`、`Artist`，也不读 IFD0 里的 `LensMake`，不会把它们挪到规范位置）、
不认识的私有标签、国产机型写的几字节 MakerNote、相机写的 `PrintImageMatching`。所以
另外直接读源 JPEG 和产物 HEIF 的 TIFF 结构（产物一侧从 HEIF 的 Exif 项里取），源里有、
产物里没有的标签报丢失，例如
`丢失 EXIF 标签 GPSProcessingMethod（GPS 0x001B，ASCII，"CELLID"）——类型不合规范（规范是 UNDEFINED），ImageIO 读不出这种写法`。

- 按标签号比。IFD0 和 Exif 子 IFD 合成一个命名空间（源里放错 IFD 的标签，写入方挪到
  规范位置时不算丢失）；GPS、Interop 各自一个；IFD1（缩略图）整个不比，与下面的缩略图
  策略一致。
- 同号的标签出现几次都合成一行，注明个数。键空间比对已经为同一个字段报了丢失的、
  已经出了 MakerNote 汇总行（佳能、松下那种被 ImageIO 解析成 `{MakerCanon}` 等伪字典的）
  的，这里不再重复。
- 产物里的 EXIF 读不出时报一行「无法核对原始 EXIF 标签」，不当作没有差异。
- 不报的有三类：
  - **描述文件结构或编码方式的标签**：`ImageWidth`、`ImageLength`、`PixelXDimension`、
    `PixelYDimension`（像素尺寸由编码结果决定）；`BitsPerSample`、`Compression`、
    `PhotometricInterpretation`、`SamplesPerPixel`、`PlanarConfiguration`（像素的存储
    方式）；`YCbCrCoefficients`、`YCbCrSubSampling`、`YCbCrPositioning`、
    `ComponentsConfiguration`（JPEG 的色度编码参数）；Exif、GPS、Interop 三个 IFD 指针
    （结构本身）；Interop 里的 `InteroperabilityIndex`、`InteroperabilityVersion`（说明
    EXIF 按哪套互通规则存放，HEIF 产物里 ImageIO 不写 Interop IFD）；Windows 写的
    `Padding`（`0xEA1C`）和 `OffsetSchema`（`0xEA1D`，为日后原地改写 EXIF 留的填充块与
    偏移修正值）。清单写在 [`structuralExifTags`](Sources/Core/RawExifTags.swift)。
  - **没有数据的条目**：长度 0；ASCII/UNDEFINED 的值只含 NUL 和空格；`UserComment` 带着
    合规的 8 字节字符集头、去掉头之后只含 NUL 和空格。数值型的 0 算数据（`LightSource`
    0 是「未知光源」，照报）。
  - **已经由别的规则负责的标签**：Windows XP 标签和评级（见下面「等价字段」那条），
    时间字段（源侧以原始字节为准那条）。

**GPS 的分数按原始值比。** 源文件常把坐标的「秒」存成分母 1000000 的分数，ImageIO
写 HEIF 时一律存成分母 100。ImageIO 视图里的 `{GPS}/Latitude` 在源一侧就已经按 XMP 的
`度,分.分` 形式四舍五入过，只有截断恰好跨过它的舍入档时才看得出来。所以 GPS IFD 里的
分数字段（纬度、经度、海拔、时间戳、方向、速度等）两边都在时逐个比原始分数，约分后
相等才算没变，不加容差，例如
`变化 GPS 纬度：22°38′53.743286″ → 22°38′53.74″（HEIF 写入器只保留到 1/100 秒）`。报了这一行，
ImageIO 视图里同一处的 `{GPS}/Latitude`、`XMP/exif:GPSLatitude` 就不再另报。

**ImageIO 读不出的 `ImageUniqueID` 按原始字节比值。** 33 字节以外的 `ImageUniqueID`
在源和产物的 ImageIO 视图里都没有，转换时补写进去的值写对没有，键空间比对看不见。所以源的
视图里没有 `{Exif}/ImageUniqueID`、两边原始 EXIF 里都有 `0xA420` 时，按补写时的取值规则
（取到第一个 NUL 为止）逐字节比两边的值，不同就报，例如
`变化 EXIF 标签 ImageUniqueID："J12LLKF00SM J12LLKL01GM" → "J12LLKF00SM J12LLKL01GM "`。
值照文本显示、不去尾部空格；不是合法 UTF-8 的写字节数，显示相同时注明原始字节从第几个起
不同。产物里没有就是上面那条「丢失」。源的视图里读得到它（33 字节）时，值照常由键空间
比对管。逐值比只做这一个标签：别的标签 ImageIO 在源一侧读不出就不会写进产物，没有值可比；
两边视图都读得到的标签已经由键空间比对按值比过，原始值的写法（分数的分母、补齐长度、
整数宽度）重新写一遍本来就会变，再逐字节比只会刷出噪声。

**认识的段里还有两类 ImageIO 不读的数据，同样直接从源文件字节里读。**

- Windows 资源管理器写在 EXIF IFD0 里的 `XPTitle`、`XPComment`、`XPAuthor`、
  `XPKeywords`、`XPSubject`（`0x9C9B`–`0x9C9F`，UTF-16LE 文本）和 `Rating`
  （`0x4746`）、`RatingPercent`（`0x4749`）。ImageIO 不读也不搬这几个标签。
  Windows 写它们时通常同时写一份标准字段（`test_pic/IMG_1225.JPG` 的 `XPAuthor`
  与 `Artist` 都是 `Zhang San;Li Si`），标准字段会被搬走，所以判据和 IIM 日期一样：
  目标里的等价字段**确实带着同一个值**才算承载，不是"等价字段存在"；否则每个
  标签报一条丢失。等价字段：

  | 源标签 | 目标里的等价字段 |
  |---|---|
  | `XPTitle` | `{TIFF}/ImageDescription`、`XMP/dc:title` 的任一语言、`XMP/dc:description` 的任一语言 |
  | `XPComment` | `{Exif}/UserComment`、`XMP/exif:UserComment` |
  | `XPAuthor` | `{TIFF}/Artist`、`XMP/dc:creator` |
  | `XPKeywords` | `XMP/dc:subject`、`{IPTC}/Keywords` |
  | `XPSubject` | 没有，出现就报 |
  | `Rating` | `XMP/xmp:Rating` |
  | `RatingPercent` | `XMP/MicrosoftPhoto:Rating` |

  标题、备注按整串比。作者和关键词是分号分隔的列表：拆成各项、去掉两边空白，
  再和等价字段按顺序逐项比。等价字段可以是一个同样带分号的串——ImageIO 不拆
  `Artist` 里的分号，产物的 `dc:creator[0]` 就是 `Zhang San;Li Si`——也可以是数组
  （`[甲, 乙]`）；多一项、少一项、顺序不同都算丢失。评级按整数比；IPTC 的
  `StarRating` 不在等价字段里。标签在、值读不出（偏移越界、类型不对）也报。
- APP13 里 IPTC 以外的 Photoshop 资源。ImageIO 只读、只搬其中的 IPTC-IIM（8BIM
  `0x0404`），同一段里的其它资源随段消失。它们合成**一条**差异，写个数和资源号，
  例如 `丢失 APP13 里的 1 个 Photoshop 资源（0x0BB7）`——Photoshop 存出来的 JPEG
  常带十来个资源，每个一行会刷屏。不计入的只有 `0x0404` 本身（由逐字段比对管着）、
  `0x0425`（IPTC 摘要，`0x0404` 的校验和）和两个缩略图资源 `0x0409`、`0x040C`
  （见下面的有意忽略）。资源块里解析不了的数据（长度越界、不以 `8BIM` 开头）
  按字节数计入同一行。

有几类差异会被有意忽略，因为它们描述的是文件本身而非照片内容：

- 编码相关的键：文件体积、像素尺寸、色深、压缩方式、JFIF 段、ImageIO 内部标记。
  按**完整键路径**精确匹配，不用子串——`Depth`、`Compression` 这类片段太短，
  子串匹配会让 `{MakerCanon}/FocusDepth`、`XMP/crs:DepthMapInfo` 这类真实字段
  被整条跳过且悄无声息。色彩描述文件名（`ProfileName`）和色彩模型
  （`ColorModel`）**不**在其中：它们决定像素怎么解读，CMYK 被转成 sRGB 会报出来。
  带辅助图的 JPEG 在 `{FileContents}/Images[n]/` 下还列出主图的 `ChromaSubsampling`
  （4:2:2 的源转出来是 4:2:0），按同样的办法忽略：去掉每一层的数组下标后按完整键路径
  比对。同一组里的宽、高、方向、`NamedColorSpace`、`FlexRange` 照常比。
- 缩略图：EXIF IFD1 里的缩略图，以及 Photoshop 资源里的缩略图（8BIM `0x0409`、
  `0x040C`）。缩略图是从像素派生的预览，不是照片内容，和文件体积、压缩方式同类。
  产物里不带内嵌缩略图，而几乎所有相机直出的 JPEG 都带一个（`test_pic/` 里两张
  都有），报它会让几乎所有真实照片校验不过，所以不检测。带辅助图的 JPEG 还会在
  `{FileContents}/Images[n]/ThumbnailImages[m]/` 下列出内嵌缩略图的 `Width`、
  `Height`、`Orientation`、`ThumbnailOffset`、`ThumbnailSize`，这五个键按同一条策略
  忽略：去掉每一层的数组下标后按完整键路径比对，不用前缀或子串；这组下面出现别的
  子键照常报。
- EXIF 定长字符串的尾部 NUL 填充——JPEG 和 HEIC 的填充长度天然不同，
  只比对有效内容。
- **有理数的重新编码噪声**。EXIF 的数值以「分子/分母」存放，写入方常常换成另一个
  等价但不完全相等的分数。例如佳能 R5 Mark II 的 `FocalPlaneXResolution`
  `8192000/1419` 会被写成 `3769821/653`，相对误差约 `2e-10`——物理上是同一个值。
  所以数值型的值按相对误差比较（容差 `1e-8`），非数值仍逐字符比较。容差比实测
  噪声宽一个数量级，又远小于任何有意义的改动：GPS 纬度差 `1e-8` 只相当于几厘米，
  照样会报出来。GPS IFD 里的分数另有原始分数那条规则（见上），不吃这个容差。
- JPEG 的 IPTC-IIM 日期字段（`DateCreated` / `TimeCreated` 等）。HEIF 没有 IIM
  容器，同样的信息由 `XMP/photoshop:DateCreated` 和 `{Exif}/DateTimeOriginal`
  承载。判据是等价字段**确实带着同一个值**，不是"等价字段存在"——这几种格式
  各不相同（IIM 写 `20240915`，EXIF 写 `2024:09:15 18:42:07`），所以按位置比：
  等价值拆成日期、时刻、小数秒、偏移，IIM 的日期只和日期位比，IIM 的时间只和
  时、分、秒比，只认 ASCII 数字。等价字段在、值却是另一个时间，照样算丢失。
  IIM 的时间可以带时区（`184207+0800`）。EXIF 那边的时区由 `OffsetTime` 单独
  承载，所以比对时把偏移拆开：时间部分跨格式比对，**偏移本身必须在目标文件里
  也找得到**，否则照样算丢失。只拆时间部分不管偏移去哪了，就会在"偏移只存在于
  IIM 后缀、目标又没有 `OffsetTime`"时把真丢失静默放过。
  找的范围是 `{Exif}/OffsetTime*`、`XMP/exif:OffsetTime*`，以及**该键自己的那
  两个等价时间戳**（偏移可以长在值里，如 `2024-09-15T18:42:07+08:00`）。别的
  时间戳（`xmp:ModifyDate`、`tiff:DateTime` 之类）不算，`+0000` 与 `-0000` 也
  按不同值处理——这两条都只会让它多报，符合"宁可多报"的方向。
  读偏移时三种形状（`±HHMM`、`±HH:MM`、`…Z`）都锚定在末尾逐字符核对，还要验
  范围——约束的是**总偏移量**落在 `-12:00`…`+14:00`，不是时和分各自的上限：
  `+05:30`、`+05:45`、`+09:30`、`+13:45` 都是真实存在的偏移必须认，而
  `+14:30`、`-12:30` 不存在必须拒；分钟本身还要 `< 60`，否则 `+00:70`
  折算后虽落在范围内，却不是一个合规的偏移拼法。

  **下面这条前文规则三种形状共用**，不是 Z 专属：偏移字段前面的那一截要么是空
  （整个值就是一个偏移，如 `+08:00`），要么是一个**完整时刻**。完整时刻指
  `<时刻>` 或 `<日期><T 或空格><时刻>`：

  - `<时刻>` 是 `HHMMSS`、`HH:MM:SS`、`HHMM`、`HH:MM`，时分秒各自验范围
    （秒允许 60，那是闰秒）。四位无分隔的 `HHMM` 不能单独成立——它和年份分不开
    （`2024` 会被读成 20:24）。六位的那个歧义消不掉：`202409` 既像年月也像
    20:24:09，按形状分不开，只能当时刻收下——于是 `202409Z` 读成 `+0000`、
    `202409+0800` 读成 `+0800`。这条和上面一样**三种形状共用**，不是 Z 专属。
  - `<日期>` 是 `YYYY-MM-DD`、`YYYYMMDD`，也认 **EXIF 自己的冒号写法**
    `YYYY:MM:DD`，因为 `{Exif}/DateTimeOriginal` 写的就是
    `2024:09:15 18:42:07`，而它正是上面点名的等价承载键之一。月验 1–12、
    日验 1–31（不查某月到底有几天，这里只是在判断"这段是不是日期"）。
  - 小数秒可用 `.` 或 `,`。

  所以 `2024-09-15T18:42:07+08:00`、`20240915T184207+0800`、
  `2024:09:15 18:42:07+08:00`、`184207Z`、`2024-09-15T18:42:07Z` 都读得出，而
  `ISO100+0800`、`镜头型号RF50mm1+0800`、`20240915+0800`（日期不是时刻）、
  `拍摄于 18:42:07Z`、`995999Z`（时刻越界）、`9999-99-99T18:42:07+08:00`
  都读不出。只查"符号或 Z 前一位是数字"的话，这些全都会被读成一个偏移——读成
  一个**合法值**比读不出更坏，因为连差异都不剩。`±` 和 `Z` 两侧用的是同一把
  尺子。

  `…Z` 那一种只多一条自己的规则：Z 本身不带数值，所以它要求前文**非空**——
  光一个 `Z` 不算 UTC。

  前文规则松一点就会反向出事：只取最后一个加减号、后面数字数够 4 位的话，
  `2024-09-15T18` 会被读成偏移 `-1518`，于是"偏移其实已经丢了"被误判成"还在"。源侧和目标侧用的是同一把尺子。
  拆与不拆**按键决定**：IIM 里只有 `TimeCreated` / `DigitalCreationTime` 能带
  偏移，日期字段不能。按值的长相去拆会把不合规范的 `2024-0915` 从减号处砍成
  `2024`，而 `2024` 几乎出现在任何日期里——于是"9 月 15 日丢了、目标写着 1 月
  1 日"会被判成承载。方向上宁可多报一条，不要静默放过。

## 已知限制

- **厂商私有数据 MakerNote 无法保留**。EXIF 里的 `MakerNote`（标签 0x927C）是相机
  厂商的私有块，佳能/松下等机型能占好几 KB，装着对焦点位置、照片风格、防抖状态、
  机身序列号这类只有厂商软件看得懂的信息。ImageIO **既不把原始 MakerNote 作为属性
  暴露出来，写入时传 `kCGImagePropertyExifMakerNote` 也会被静默忽略**（实测过），
  所以这块必然丢失。`--verify` 会把它报成一条而不是上百条——ImageIO 解析出的
  `{PictureStyle}`、`{MakerCanon}` 等伪字典都只是这一个块的不同视图。ImageIO 不解析的
  MakerNote（不少国产机型只写几个字节的私有串）没有伪字典可看，由原始 EXIF 清点报成
  一行 `丢失 EXIF 标签 MakerNote（…）`。
  拍摄时间、GPS、光圈快门 ISO、镜头型号这些标准字段不受影响。

  归并的判据不是字典前缀：`{ExifAux}` 是混的。ImageIO 正式声明过的那几个键
  （`LensModel`、`SerialNumber`、`LensInfo`、`Firmware`、`LensID` 等）有 XMP
  `aux:` 命名空间承载，实测能完好转换，**不参与归并**——它们真丢了会逐条报出来。
  只有 ImageIO 顺手塞进同一个字典的未声明键（`AFInfo`、`FocusMode`、
  `ImageStabilization`）才算 MakerNote 派生。要的是不刷噪声，不是掩盖真丢失。
  在意 MakerNote 的话就别用 `--delete-original`：校验不通过时工具本来也会拒绝删除。
- **ImageIO 不认识的 JPEG 段不会保留**：`COM` 注释段、C2PA 的 APP11 等未知 `APPn`
  段、`EOI` 之后除辅助图以外的数据（动态照片的视频、相机写的大尺寸预览图等 MPF 附加
  图像）。`--verify` 会逐段报出，所以 `--delete-original` 不会删这样的源文件。
- **辅助图像的像素是有损重新编码的**。增益图、蒙版这类 8 位的辅助图，以及深度图、
  视差图，都和主图一样被重新编码，尺寸、像素格式、附带的元数据不变，像素值有小幅
  变化：平滑的合成图案上最大差 3 级（按 8 位计；深度图、视差图在 JPEG 里本来就是按
  取值范围量化成 8 位存的，按同一把尺子算），四张真实 HDR 照片的增益图上最大差 5–8 级。
  `-q` 不影响辅助图的编码。读回时每行字节数可能变大（多了对齐填充），数据本身不受影响。
- **辅助图加不进产物时，转换照常完成，辅助图丢失**。带辅助图的那一遍编码失败时，
  本工具不带辅助图（连增益图一起）再编一次；`--verify` 会把没搬过去的辅助图逐项报出来
  （`{FileContents}/…/AuxiliaryData…` 几条，外加 EOI 之后的数据），`--delete-original`
  不会删源。
- **ImageIO 读不出的 EXIF 标签不会保留**：类型写错的（ASCII 的 `GPSProcessingMethod`、
  LONG 的 `LightSource`）、放错 IFD 的、ImageIO 不认识的私有标签、`PrintImageMatching`、
  不被 ImageIO 解析的短 MakerNote。属性字典里补上、XMP 里补上都写不进产物（实测过），
  所以只做检测：`--verify` 逐个报出（见「`--verify` 到底比什么」的原始标签清点），
  `--delete-original` 不会删源。`ImageUniqueID` 是例外：33 字节以外的写法 ImageIO 读不出，
  但写入器照写，所以能原样写回的由本工具补写（见「保留了哪些元数据」）；写不回原样的
  （类型不是 ASCII、放错 IFD、同号条目不止一个、不是合法 UTF-8）照报丢失。
- **GPS 坐标的秒只保留到 1/100**。ImageIO 写 HEIF 时不管给多精确的值，秒都存成分母 100，
  误差最多约 15 厘米；海拔这类分数也会被换成别的近似分数（如 `1250001/100000` →
  `624988/49999`）。写不回去，只能如实报：秒的精度高于 1/100 的照片（很多手机都是）
  `--verify` 一律报 GPS 变化，`--delete-original` 不会删它们。
- **转出来可能比原图大**。已经压得很小的 JPEG（低质量导出、聊天软件转存的图）转成
  HEIF 可能反而变大。工具照样写出产物并提示「HEIF 比原图大 N%」，`--delete-original`
  不删这样的源。
- **APP13 里 IPTC 以外的 Photoshop 资源不会保留**。只有 8BIM `0x0404`（IPTC-IIM）
  会被 ImageIO 读出并搬走，其它资源随段一起消失。`--verify` 把它们报成一条
  （见「`--verify` 到底比什么」），所以 `--delete-original` 不会删这样的源文件。
- **Windows 资源管理器写的 XP 标签和评级本身不会保留**：IFD0 里的 `XPTitle`、
  `XPComment`、`XPAuthor`、`XPKeywords`、`XPSubject`（`0x9C9B`–`0x9C9F`）和
  `Rating`、`RatingPercent`（`0x4746`、`0x4749`）。ImageIO 不读也不写它们，信息
  只有在同时写了同值的标准字段时才跟着标准字段走。没有同值的标准字段时
  `--verify` 逐个报出，`--delete-original` 不会删源。
- **EXIF 的 IFD1 缩略图和 Photoshop 资源里的缩略图不会保留，`--verify` 有意不报**：
  它们是从像素派生的预览（见「`--verify` 到底比什么」的有意忽略），`{FileContents}`
  里的 `ThumbnailImages` 那组键同样不报。原始 EXIF 清点也不比 IFD1。
- **界面用 AppKit 而非 SwiftUI**。SwiftUI 的 `@State` 等属性包装器现在是宏，
  宏插件只随完整版 Xcode 分发；用 AppKit 才能只靠命令行工具构建。
- **应用是本地临时签名的**，没有开发者证书。自己构建自己用没问题，拷给别人
  会被 Gatekeeper 拦。
- **只处理 JPEG 输入**。其它格式会被跳过并给出提示，不会误转。
- **HEIF 编码是有损的**，元数据无损但像素会重新编码。默认 `-q 0.8` 通常比源
  JPEG 小 60%–85%。想更接近原画质用 `-q 0.95`。要绝对像素无损请不要用本工具。
- **非 ASCII 的 EXIF `UserComment` 在产物里多占一倍空间**。ImageIO 的 HEIC 写入器
  对含非 ASCII 的备注只写进前一半（按 UTF-16 单元算），ASCII 打头的还会被整条当成
  ASCII 写、非 ASCII 字符全变成 `?`。本工具写之前把这类备注改写一次（见
  [`userCommentForHEIFWriter`](Sources/Core/Converter.swift)）：ASCII 打头的在前面加
  一个 BOM，再补上等长的 NUL。产物里的备注与源逐字相同，代价是字段尾部跟着比正文
  多 2 字节的 NUL 填充；ImageIO 读出来的字符串尾部也带着这些 NUL（它读源 JPEG 的
  填充时也一样），`--verify` 按尾部填充规则不计较它们。纯 ASCII 的备注原样写入。
- **不合规范的 `UserComment` 由本工具自己解析**。EXIF 要求该字段以 8 字节字符集
  标识开头（`ASCII\0\0\0` / `UNICODE\0` / `JIS…` / 全零），但不少安卓机型直接写
  裸 UTF-8。ImageIO 认不出这种写法，会当作字段不存在，备注就在转码时被静默丢掉。
  本工具因此额外自己扫一遍 JPEG 的 EXIF 段（见
  [`rawExifUserComment`](Sources/Core/ExifReader.swift)），把 ImageIO 漏掉的内容
  补回去。注意有些机型往这个字段塞的是整段相机调试信息而非人写的备注，工具会
  一并原样保留——判断哪些算"噪音"不是转换工具该替你做的决定。
- 需要 macOS 与 Xcode 命令行工具（`swiftc`）来构建。

## 测试

```bash
make test
```

自检先跑一组纯逻辑单元测试（值比较规则：哪些算噪声、哪些必须报出来），再生成
一张元数据齐全的 JPEG（拍摄时间、GPS、中文备注、IPTC、访达备注），
转成 HEIC，然后逐字段断言与源文件一致，并覆盖递归目录、防覆盖、参数校验、
非 JPEG 跳过等行为。`--delete-original` 是唯一会删文件的功能，正反两侧都有用例
守着（校验无损才删、有差异必须保留）。界面侧分两层：模型层用真实文件验证
「输出到指定文件夹」和「取消」（取消一定要能拦下后续任务，否则测试形同虚设），
最后再驱动真实窗口跑一遍完整流程。

每次运行在独立的 `Tests/.work.XXXXXX` 目录里进行，两个 `make test` 可以同时跑。
全部通过时这个目录会被删掉；有失败或提前退出时保留，并在末尾打印路径供诊断。

界面排版可以离屏渲染出来看，不需要屏幕录制权限：

```bash
make snapshot OUT=/tmp/ui.png ARGS="--convert ~/Pictures/测试"
```

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `Sources/Core/Converter.swift` | 单张图的转换：读元数据、编码 HEIF、搬运文件层属性 |
| `Sources/Core/Batch.swift` | 批量编排：扫描输入、分配目标路径（含重名避让）、并发调度 |
| `Sources/Core/MetadataDiff.swift` | `--verify` 的比对规则：什么算真丢失、什么只是重编码噪声 |
| `Sources/Core/ExifReader.swift` | 手写 EXIF 解析：捞回 ImageIO 读不出的 `UserComment`，按标签读原始值 |
| `Sources/Core/HEIFExif.swift` | 从 HEIF 的 `meta` 盒子里取出 Exif 项的原始 TIFF，供原始 EXIF 清点读产物一侧 |
| `Sources/Core/RawExifTags.swift` | 原始 EXIF 标签清点（源里有、产物里没有的标签）、GPS 原始分数比对、`ImageUniqueID` 的补写规则与按原始字节比值，含不报清单 |
| `Sources/Core/JPEGLayout.swift` | JPEG 段结构，以及 ImageIO 搬不走的段（COM、未知 APPn、EOI 之后）、MPF 索引与尾部记账、APP13 里的 Photoshop 资源 |
| `Sources/Core/RawTimes.swift` | 源文件里 EXIF、IIM、XMP 时间字段的原始值，供 `--verify` 当源侧真相 |
| `Sources/Core/WindowsTags.swift` | IFD0 里 ImageIO 不读的 Windows XP 标签和评级，及其在目标里的等价字段 |
| `Sources/CLI/Arguments.swift` | 命令行参数解析（纯函数，可被测试直接调用） |
| `Sources/CLI/main.swift` | 命令行入口：串起解析、转换与输出 |
| `Sources/GUI/` | AppKit 界面：窗口、列表行、拖放区、界面状态 |
| `Tests/` | 自检脚本、测试图生成器、元数据探针、界面截图工具、模型层集成测试 |
