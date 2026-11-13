# Glint

把 JPEG 转成 HEIF（`.heic`），并完整保留元数据——拍摄时间、拍摄位置、备注、
相机参数、版权、访达备注与标签、文件时间戳，一样不丢。

提供**图形界面**和**命令行**两种用法，两者共用同一套转换核心
（[Sources/Eclose/Converter.swift](Sources/Eclose/Converter.swift)）。

macOS 原生实现（Swift + ImageIO + AppKit），**零依赖**：不需要 ImageMagick、
libheif、exiftool 或 Python 包，也不需要安装完整的 Xcode——命令行工具即可构建。
用系统自带的 HEIC 编码器，Apple Silicon 上走硬件加速。

## 构建与安装

```bash
make
```

`make` 会同时产出命令行工具 `glint` 和应用 `Glint.app`。命令行工具装到系统里：

```bash
sudo make install          # 或 make install-cli PREFIX=~/.local
```

应用不装进 `/Applications`：`make install-dev` 在仓库的上一级目录（如 `~/Developer`）放一份。
想先试试，直接 `make run` 打开应用。

## 图形界面

应用叫 **Glint**，中文名吉光（取自「吉光片羽」）：一个看得见自己照片的窗口。左边是文件夹，中间是缩略图，
右边是选中那张的拍摄时间、位置、相机和**备注**；在这之上能把 JPEG 转成 HEIF，转完逐项校验，
差异摆在明面上。浏览的是磁盘上的文件夹，不接「照片」App 的图库。

除了转换时勾了「校验无差异后删除源文件」，应用不删除、移动、改名或改写任何文件；
备注只读不改。

- **加文件夹**：把文件夹拖进窗口，或「文件 › 添加文件夹…」（⇧⌘O）。加进来的文件夹会记住；
  路径不在了，侧栏上标「找不到」并置灰。右键「从侧栏移除」只是不再显示，不动磁盘。
  拖进单张图片、或在访达里对图片选「打开方式 › Glint」，归到「单独添加的图片」（不记住）。
- **侧栏**：「全部图片」「可以转换」（其中的 JPEG）「有备注」；做过转换后有「最近一次转换」及
  它下面的「有差异」「失败」；「文件夹」下是加进来的文件夹和里面有图片的子文件夹，选中一个文件夹
  看它和它所有子文件夹里的图片。扫描在后台进行，先扫到的先显示。
- **网格与列表**：⌘1 / ⌘2 切换，选中状态共用。网格的缩略图默认什么都不叠，只在有备注
  （右下角）、这次转换有差异 / 失败 / 正在转换（右上角）时放一个小标记；⌘+ / ⌘− 或触控板捏合
  调大小。列表有拍摄时间、格式、尺寸、大小、备注、转换结果几列，点表头排序。
  空格 Quick Look，双击或 ⌘O 用默认应用打开，右键还有「在访达中显示」「拷贝路径」。
  工具栏的搜索框搜文件名和备注（不分大小写），⌘F 进搜索框；排序菜单按拍摄时间、文件名、大小、格式。
- **信息栏**（⌥⌘I 显示 / 隐藏）：预览、文件名和尺寸；转换结果（这次转过的才有：结论、
  逐条差异、体积、EXIF 是否整块照搬、源文件还在不在）；**备注**；拍摄时间、相机与参数、镜头、
  位置（「在地图中打开」）；所在文件夹和修改时间。选中多张或没选中时是格式分布和有备注的张数，
  在「最近一次转换」里还有这一批的汇总和最常见的差异。
- **备注都读哪几处**：「照片」App 的说明（扩展属性 `com.apple.assetsd.description`）、访达备注
  （扩展属性 `com.apple.metadata:kMDItemFinderComment`）、文件里的说明（XMP `dc:description`、
  IPTC Caption/Abstract、TIFF ImageDescription，同值只显示一条）、EXIF 备注（`UserComment`；
  ImageIO 读不出或读成乱码时用和转换、校验同一套的原始字节读法，只取可靠的文本）。读到几条
  显示几条，每条下面写它存在哪：`存在文件里`、`存在文件里（EXIF 备注）`、`文件里外各有一份`，
  或者带橙色三角的 `存在文件之外，换设备或传网盘容易丢`。
- **转换**：点工具栏的「转换…」（⌘E）。有选中时转选中的那些里的 JPEG，没选中时转当前视图里
  全部的 JPEG，别的格式不动。面板里可以选：
  - 转成：目前只有 HEIF（.heic）；
  - 画质（与命令行 `-q` 同一个取值范围）；
  - 保存到：源文件旁边，或指定文件夹（转整个文件夹时按原来的子目录结构摆放）；
  - 转完逐项校验（默认开；命令行的 `--verify` 默认关，这是有意的分叉）；
  - 把备注写进文件：把「照片」的说明写进产物的 XMP（同命令行的 `--embed-caption`，
    规则见「把「照片」的说明写进文件」）；这批里没有存在文件之外的「照片」说明时不可选；
  - 校验无差异后删除源文件：勾上后自动锁定逐项校验，主按钮变成「转换并删除源文件」。
    有差异的、HEIF 比源文件大的不删；删除不进废纸篓；
  - 高级：EXIF 交给系统重写（同命令行的 `--no-raw-exif`）、覆盖同名的 HEIF。

  画质、保存到、逐项校验、把备注写进文件、EXIF 那一项会记住；「删除源文件」和「覆盖同名的
  HEIF」不记，每次打开面板都是关的。两端的默认值取自同一处（`ConversionOptions.default`）。
- **转换进行中**窗口底部出现一条活动条（进度和「取消」，⌘. 也行），照常可以浏览和查看；
  正在转的缩略图右上角转圈，转完有差异或失败的立刻换成对应标记。转完活动条上是一句话，
  例如 `转完 195 张，省下 398 MB。9 张有差异，1 张失败。`，点「9 张有差异」跳到那几张；
  受影响的文件夹重新读取，新的 HEIF 出现在网格里。应用不在前台时在程序坞上提醒一下，
  不发系统通知。转换记录只在这次运行里有。
- 不监视文件夹变化：切回应用、转完、⌘R 时重新读取。

## 命令行

```bash
glint 照片.jpg
```

整个文件夹批量转换（`-r` 递归子目录，`-o` 指定输出位置）：

```bash
glint -r ~/Pictures/2024 -o ~/Pictures/2024-heic
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
| `--no-raw-exif` | EXIF 交给系统重写，不整块照搬源文件的 EXIF（见「保留了哪些元数据」）。遇到读不了产物的软件时用 |
| `--embed-caption` | 把「照片」App 的说明（文件扩展属性里的那段）写进 HEIF 的 XMP 说明字段 `dc:description`，让它离开 Mac 也跟着文件走。文件里已有说明时不写（见「把「照片」的说明写进文件」）。默认关；图形界面的转换面板里是「把备注写进文件」 |
| `-n, --dry-run` | 只打印将要做什么，完全不碰磁盘（连输出目录也不建） |
| `-j, --jobs <n>` | 并发数，默认为 CPU 核心数 |
| `-v, --verbose` | 打印每张图保留的元数据条目数，以及 EXIF 整块照搬了没有（照搬了多少字节，或没照搬的原因）；产物比原图大而重编过一次的，再说明两次的大小；开了 `--embed-caption` 的，再说明说明写了没有 |

想在替换原图前确认万无一失：

```bash
glint --verify -r ~/Pictures/相册 -o /tmp/heic-试转
```

## 保留了哪些元数据

分三层，不做任何字段白名单过滤：

1. **EXIF 整块照搬，其余图像元数据字典由系统搬** —— EXIF（含 GPS、IFD1 缩略图、
   MakerNote）是源文件 EXIF 段的原始字节，一个字节不改地放进产物（见下面「EXIF 整块
   照搬」）；IPTC 等字典由 ImageIO 写入。包括拍摄时间（`DateTimeOriginal`、时区偏移、
   亚秒）、拍摄位置（经纬度、海拔、方位角、GPS 时间戳，分数的精度与源相同）、相机与
   镜头型号、光圈快门 ISO 焦距、图像描述、`UserComment` 备注、作者、版权、星级评分，
   以及各家 MakerNote、规范新标签、不合规范的写法、Windows XP 标签、内嵌缩略图。
2. **XMP 数据包** —— Lightroom / Photoshop / Bridge 写入的标题、说明、
   关键词、评级、版权、人脸区域等，整包合并进产物：包括属性字典表达不了的
   `xmp:Label`、`lr:hierarchicalSubject`、`dc:title` 的各个语言、人脸区域的
   `Name`、`xmpMM:*` 和自定义命名空间，也包括扩展 XMP 段里的内容。
3. **文件层元数据** —— 创建时间、修改时间、POSIX 权限，以及全部扩展属性
   （「照片」App 的说明 `com.apple.assetsd.description` 和别的 `com.apple.assetsd.*`、
   访达备注 `kMDItemFinderComment`、访达标签 `kMDItemUserTags` 等），只有隔离标记
   `com.apple.quarantine`、资源分支 `com.apple.ResourceFork` 和系统管的来源标记
   `com.apple.provenance` 不拷（`-v` 里的「扩展属性 N 项」不数它们）。扩展属性由 `--verify`
   逐个核对（见「`--verify` 到底比什么」）。加 `--embed-caption` 时「照片」的说明另写进 XMP
   （见下面「把「照片」的说明写进文件」）。
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
元数据、不重新编码像素，辅助图原样留在产物里。两遍之后再做 EXIF 整块照搬（下一节）。
写入采用「先写临时文件、成功后再原子替换」，中断不会留下半个文件。

### EXIF 整块照搬

ImageIO 写 EXIF 走的是「读成属性字典 → 从字典写出去」，它不认识的东西在这一读一写里
就没了：各家 MakerNote、规范新标签、类型或位置不合规范的写法、GPS 秒的精度（写入器
一律存成分母 100）、IFD1 缩略图、Windows XP 标签。所以 ImageIO 写完 HEIC 之后，本工具
把产物里 Exif 项的内容换成源 JPEG EXIF 段的原始字节：新内容（原来的 4 字节偏移和
`Exif\0\0` 前缀，加源的 TIFF 字节）接在最后一个 `mdat` 的末尾，改 `mdat` 的长度和 `iloc`
里 Exif 项的偏移、长度，原来那份 EXIF 所在的字节清零（不留一份没人引用的旧 EXIF，免得
日后用别的工具删了位置信息，旧的 GPS 还在文件里）。别的字节一个不动，图像数据不挪
位置；源的 TIFF 字节也一个不改：不摘缩略图、不改方向和尺寸（像素没有旋转也没有缩放，
源的值就是对的）。产物会比 ImageIO 自己写的大一个 EXIF 的大小（带 MakerNote 的相机照片
约 2–4%）。ImageMagick 也是这么做的（EXIF 当不透明字节块整块交给 libheif）。

**ImageIO 读错或读不出的备注，块上只改备注这一条。** 不少安卓机型的 `UserComment` 没有
8 字节字符集头、直接塞裸 UTF-8，ImageIO 当它不存在；`ASCII` 头里装着 UTF-8 中文的，ImageIO
按 Latin-1 读成乱码（见「已知限制」里「不合规范的 `UserComment`」那条）。源里的备注要修补
（条件见那一条：ImageIO 读不出而本工具读出的是可靠的文本，或者 `ASCII` 头里装着非 ASCII 的
UTF-8），而且 Exif 子 IFD 里恰好一个 `0x9286` 条目、整张表都在块内时，照搬的那份 TIFF 是
改写过备注的源 TIFF：

- 新值接在 TIFF 块末尾（块长为奇数时先补一个 0）：文本全是 ASCII 时是 `ASCII\0\0\0`
  加文本；否则是 `UNICODE\0` 加 BOM 加文本的 UTF-16，字节序（BOM 也一样）与 TIFF 头相同。
- `0x9286` 条目的类型改成 7（UNDEFINED）、个数改成新值的字节数、偏移指向新值。
- 除这一条的类型、个数、偏移这 10 个字节以外，源 TIFF 的每个字节都不动：旧的备注字节
  留在块里原处，只是没人引用了；别的标签、MakerNote 的偏移都没变。

BOM 不能省：ImageIO 读 `UNICODE` 备注时有 BOM 认 BOM，没有就一律当大端，小端（`II`）块里
不带 BOM 的 UTF-16 会读成乱码。非 ASCII 文本也不能用 `ASCII` 头，ImageIO 按 Latin-1 解。
HEIC 和 JPEG 两种容器里读法一样；ImageIO 读回时去掉 BOM。条件不满足（比如有两个 `0x9286`）
就照原样照搬，由下面的自检决定去留。字节不是合法 UTF-8 的备注（本工具分不出是 GBK 还是
别的编码，只能猜）不改写，原样照搬，一个字节不动。

下面任何一条不满足就不照搬，产物保持 ImageIO 写出来的样子（也就是 `--no-raw-exif` 的
产物，逐字节相同），不算错误：

- 源里恰好一个 `Exif\0\0` 开头的 APP1 段，内容是合法的 TIFF 头。源里没有 EXIF 段就无事可做。
- 产物的结构是 ImageIO 写的那种：恰好一个 Exif 项，在 `iloc` 里恰好一段、按文件偏移存放，
  整个落在顶层 `mdat` 里、不与别的项重叠；最后一个顶层盒子是 `mdat`，长度字段和 `iloc` 的
  字段放得下新的值（32 位放不下时不换，不改盒头宽度）。所有长度、偏移都不信，读不通就不换。
- 产物里的 EXIF 已经与源逐字节相同时无事可做。
- 换完以后在落盘之前自检：重新取出 Exif 项，与打算照搬的那份（源 TIFF，或改写过备注的
  源 TIFF）逐字节相同；ImageIO 打得开，图像数、宽高、方向不变；**视图不退步**——用
  `--verify` 的那把尺子，照搬前与源一致的键，照搬后一个都不许变得不一致、读不出，也不许
  多出源里没有的键。只有一种例外，见下面「EXIF 与 IPTC 打架的说明、作者、版权」。时间字段
  打架的源图（ImageIO 用 IIM 的时间调和出 EXIF 的拍摄时间）靠这一条退回系统重写，备注改写过
  也一样；缺字符集头而没能改写的 `UserComment`（照搬原样过去 ImageIO 读不出，系统重写那条路
  的修补读得出）也是。

**EXIF 与 IPTC 打架的说明、作者、版权：照搬，保留 EXIF 的原值。** ImageIO 读 JPEG 时用 IPTC-IIM
的值调和说明、作者、版权（IIM 摘要对不上时，视图里显示 IIM 的值；IIM 的字符集标记坏了时就是
乱码），系统重写把这个调和出的值写进产物的 EXIF 和 XMP。照搬的产物里 EXIF 是源的原值，HEIC 里
EXIF 压过 XMP，ImageIO 显示的值就变回 EXIF 的原值；调和出的那个值留在产物的 XMP 里。三组是：

| 组 | EXIF 标签（IFD0） | 视图里的键 |
|---|---|---|
| 说明 | ImageDescription 0x010E | `{TIFF}/ImageDescription`、`{IPTC}/Caption/Abstract`、`XMP/dc:description[…]` |
| 作者 | Artist 0x013B | `{TIFF}/Artist`、`{IPTC}/Byline[…]`、`XMP/dc:creator[…]` |
| 版权 | Copyright 0x8298 | `{TIFF}/Copyright`、`{IPTC}/CopyrightNotice`、`XMP/dc:rights[…]` |

自检里照搬后新变得不一致的键，属于其中一组、且照搬后的值等于源 EXIF 里该标签的原文（值字节
去掉尾部的 NUL 与空白后是 ASCII 或合法 UTF-8 的文本；按 `--verify` 的值比较规则比），不算
退步：产物只是如实显示了源自己 EXIF 里写的东西。原文不是可靠文本的（如 GBK 字节）不放行；
别的键的退步照旧退回。EXIF 里的字节一个不改。显示的值变了，`--verify` 照实报出来（见
「`--verify` 到底比什么」里「EXIF 与 IPTC 打架」那条），所以这样的产物校验不通过，
`--delete-original` 不删源。

`-v` 时每张图多一行：`EXIF 整块照搬（N 字节）`，改写过备注时是
`EXIF 整块照搬（N 字节，备注改写成 ImageIO 读得出的写法）`（N 是源 TIFF 的字节数），保留了
EXIF 原值的组写在分号后面，例如 `EXIF 整块照搬（786 字节；说明、作者与 IPTC 不一致，保留 EXIF 的原值）`，
与备注改写可以同时出现；没照搬时是 `EXIF 没有照搬：原因`（例如
`照搬后 {Exif}/DateTimeOriginal 会与源不一致`、`源里的 EXIF 段不止一个`）。

**EXIF 交给系统重写时**（加了 `--no-raw-exif`，或上面退回时），EXIF 由 ImageIO 从属性
字典写出，丢的东西见「已知限制」。这条路上本工具补两处 ImageIO 读不出的写法：

- ImageIO 读错或读不出的 `UserComment`（见「已知限制」里「不合规范的 `UserComment`」那条，
  以及它前面那条非 ASCII 备注的写法）。
- `ImageUniqueID`：ImageIO 只读长度恰好 33 字节（32 个字符加 NUL，规范的定长）的值，
  别的长度（如 24 字节的 `J12LLKF00SM J12LLKL01GM`、26 字节的 `OPPO_20201019_204116_0001`）
  它当作不存在，与内容无关。本工具从源 JPEG 的原始字节里取出值（取到第一个 NUL 为止）
  补进要写入的属性，写入器把它原样写进产物。只补能原样写回的：Exif 子 IFD 里恰好一个、
  ASCII 类型、有数据、取出的字节是合法 UTF-8；别的写法不补，`--verify` 照报丢失。

转出来的 HEIF 比原图大时，先把「编码 + EXIF 整块照搬」原样再做一遍，写到另一个临时
文件，第二份更小就用第二份，一样大、更大或第二遍失败就用第一份，没用上的那份删掉。
只重编这一次；产物不比原图大时不重编。这一遍对付的是硬件编码器偶发的大产物（见「已知
限制」）；已经压得很小的 JPEG 转出来本来就比原图大，重编得到的通常是一样大的产物。`-v` 时
多一行，例如 `产物比原图大，重编了一次：2.8 MB → 769.4 KB（用了较小的一份）`，两次一样
大时写「（两次一样大）」，第二遍失败时写「重编失败（用了第一份）」；不带 `-v` 和界面
里不显示。重编之后仍比原图大的，命令行和界面都会提示「HEIF 比原图大 N%」，批量汇总里
单列变大的个数，`--delete-original` 也不删这样的源。

### 把「照片」的说明写进文件

「照片」App 里给照片写的说明不在图像文件里，存在文件的扩展属性 `com.apple.assetsd.description`
里（UTF-8 文本）。扩展属性照常拷到产物上，但它离开 macOS 很容易丢（非苹果文件系统、网盘、
发到别的设备）。加 `--embed-caption`，说明同时写进产物 XMP 的 `dc:description`（`x-default`
那一项）：ImageIO 读产物时 `{IPTC}/Caption/Abstract`、`{TIFF}/ImageDescription` 也是这段文本，
exiftool 读到的是 `XMP-dc:Description`。写的是扩展属性里的原文。只动 XMP，EXIF 一个字节不碰，
EXIF 整块照搬照常（照搬的自检把产物里多出来的说明当作照搬前后都有、源里没有的键，不算退步）。
默认关；图形界面的转换面板里是「把备注写进文件」，这批里有能写的说明时才可选。

不写的情形：

- 扩展属性没有、去掉首尾空白后为空、不是合法的 UTF-8；
- 源的元数据里已经有说明：XMP 里有 `dc:description`（任何语言）、`{IPTC}/Caption/Abstract` 或
  `{TIFF}/ImageDescription` 三者有任何一个。不覆盖、不追加，与扩展属性里的相同也不写。字段在
  而值是空的也不写（第一遍会把它写进产物）。这一条同时挡住一个崩溃：源里已有 `dc:description`
  时再往要合并的 XMP 上设说明，ImageIO 在合并时抛 Objective-C 异常，进程直接退出。

写完读回核对：产物 XMP 里 `dc:description` 的 `x-default` 必须等于那段文本，不等或没有算没写成。
没写成时 `--verify` 的结果里多一条差异 `没能把「照片」的说明写进文件`，`--delete-original` 因此
不删源；没开校验时这句写进状态说明。实测会没写成的一种：源里几乎没有元数据（比如只有色彩
空间和像素尺寸，没有拍摄时间、修改时间这类会进 XMP 的字段）时，ImageIO 第一遍写出的 HEIF 里
没有 XMP 项，第二遍合并 XMP 时也加不进去。

`-v` 时每张图多一行：`「照片」的说明：写进了 XMP 的 dc:description（N 个字符）`、
`「照片」的说明：没写（没有说明 / 文件里已有说明 / 文件里已有说明字段（空的） / 不是合法的 UTF-8）`
或 `「照片」的说明：没写成`。没开选项时不出这一行。

`dc:description` 是 XMP 的标准说明字段，没在鸿蒙、安卓的图库上验证过它们读不读得出。

## `--verify` 到底比什么

把源文件和产物的元数据各自递归展开成「路径 = 值」的集合，逐条比对，报告
丢失和变化。

**XMP 的键按命名空间认，不按文件里的前缀。** XMP 里一个命名空间由 URI 认，前缀只是
文件里的简写。ImageIO 读 XMP 时，标准 URI 一律换成它自己的标准前缀；文件声明的前缀已被
别的 URI 占着时（比如非标准的 `http://ns.adobe.com/photoshop/1.1/` 也叫 `photoshop`），
改叫 `photoshop_1_`、`photoshop_2_`……要不要加、加几，取决于同一个进程里同时还有哪些
XMP：批量并发转换时，两个文件用同一个前缀指不同的命名空间，同一个文件源读一次、产物读
一次可能拿到不同的前缀。所以 `XMP/…` 键里的前缀不用 ImageIO 给的，由 URI 定：

- URI 是标准的 → 标准前缀。标准的是 ImageIO 公开的十个命名空间（`exif`、`aux`、`exifEX`、
  `dc`、`Iptc4xmpCore`、`Iptc4xmpExt`、`photoshop`、`tiff`、`xmp`、`xmpRights`），加上
  `MicrosoftPhoto`（`http://ns.microsoft.com/photo/1.0/`）和 `iio`
  （`http://ns.apple.com/ImageIO/1.0/`）。本节和下面各张表里点名的 XMP 键，认的都是这些
  URI：文件把 `photoshop` 这个前缀借给别的 URI，那些字段不算 `photoshop:City` 之类。
- 不是标准的 → ImageIO 给的前缀去掉末尾所有的 `_数字_`（`jt_1_` → `jt`）。去掉之后与某个
  标准前缀同名、或同一个文件里有几个非标准 URI 落到同一个名字时，键里带上 URI：
  `XMP/photoshop{http%3A%2F%2Fns.adobe.com%2Fphotoshop%2F1.1%2F}:City`。URI 的 UTF-8 字节
  里，ASCII 字母、数字和 `-._~` 照写，其余（`/`、`:`、`%`、方括号、花括号、空格、控制
  字符、非 ASCII）写成 `%XX`，不同的 URI 写出来一定不同。
- 嵌套结构的路径里每一段的前缀都这样换，方括号里的下标（`[0]`、`[x-default]`）不动。同一个
  前缀在一个文件里报出不止一个 URI、或路径里的前缀不在这个文件的「前缀 → URI」表里时，
  那一段原样保留。

正常的文件（命名空间要么是标准的、要么各用各的前缀）键与前缀一一对应，写法就是文件里的
前缀。转换时照搬 EXIF 的自检（「视图不退步」）用的是同一套键。

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
  XMP 主包与扩展 XMP、ICC、MPF、Photoshop（IPTC）和 Adobe 这几种。下面几种没有可带的
  信息，不报；每种只认写明的形状，差一点就照报：
  - ISO 21496-1 版本标记段：APP2，`urn:iso:std:iso:ts:21496:-1\0` 加 4 字节版本号，恰好
    32 字节。它只有版本号；增益图本身丢没丢由尾部记账和辅助图的键比对负责，所以源里没有
    增益图（编辑软件重存时扔了增益图、只留下这个段）时也不报。多出或少了字节照报。
  - FlashPix 扩展：APP2，内容以 `FPXR\0` 开头（富士等相机写的预览图和它的目录）。主图的
    派生物，目录段和数据段都不报。别的标识（如 `FPXQ`）或别的 APPn 照报。
  - 只有保存质量的 Ducky 段：APP12，`Ducky` 后面的记录（2 字节标签、2 字节长度、数据，
    大端，标签 0 或段尾结束）完整解析得通，且全是标签 1（保存质量，长度 4）。这是
    Photoshop「存储为 Web 格式」记下的编码参数。带注释（标签 2）、版权（标签 3）或别的
    标签，记录越界，标签 0 后面还有字节，都照报。

  还有一种不报：ImageIO 写大图 JPEG 时加的 APP10 段，内容以 `AROT\0\0` 开头
  （exiftool 叫它 `HDRGainCurve`，但与增益图无关，有没有增益图它都在）。它是这份 JPEG
  压缩数据的逐行索引：实测一张 5712×4284 的照片里它按 4 字节一条有 269 条，MCU 行数
  （高 ÷ 16）是 268，同一个文件的重启间隔正好是一行的 MCU 数（宽 ÷ 16），也就是每行一个
  重启标记、索引指向它们，供快速解码或旋转。它只对这份 JPEG 的码流有意义，转成 HEIF 后
  本就不该在。`AROT` 后面不是两个 0 的、别的内容的 APP10 段照报；
- `EOI` 之后的数据（安卓动态照片的视频、MPF 多图格式的附加图像等）。全是
  `0x00`/`0xFF` 填充的不算。JPEG 的辅助图和相机的大尺寸预览图就存放在这里、由 APP2 的
  MPF 索引登记。下面两种条目不计入，剩下的字节照报：
  - 已经搬进产物的辅助图。要同时满足：MP 类型码是 0 或 `0x050000`（辅助图多写 0，新版
    MPF 给增益图另定了 `0x050000`，华为的 HDR 照片用它；`0x040000` 编辑前的原图不算）；
    范围整个落在 `EOI` 之后、不与别的已认条目重叠；范围里恰好是一张完整的 JPEG（`SOI`
    开头、`EOI` 结尾，不多不少）；这张 JPEG 的宽高等于某一张辅助图的宽高，而这张辅助图
    在源和产物里都有、类型、宽高、像素格式都相同。每张辅助图只认领一个条目。
  - MPF 登记的大尺寸预览图：MP 类型码 `0x010001` 或 `0x010002`，范围整个落在 `EOI` 之后、
    不与已认的辅助图或别的预览图重叠，范围里恰好是一张完整的 JPEG。它是主图的缩小拷贝，
    与 EXIF 缩略图同理不需要带。

  MPF 索引里的偏移、长度、条目数都来自源文件，越界、自相矛盾或读不出时一个条目都不认。
  去掉认下的条目后，剩下的字节恰好是 `tyf-` 加 4 个 0（微信导出时加的标记）也不报；前后
  多一个字节都照报。别的情形，剩下的字节里只要有一个不是填充就报一行，记尾部共 M 字节、
  其中搬走的辅助图 K 字节、预览图 P 字节，报的是 R = M − K − P：
  - K、P 都是 0：`丢失 EOI 之后的 R 字节`；R 里的非填充字节全落在 MPF 登记的条目范围内时
    后面加 `（MPF 多图格式的附加图像）`。
  - K 或 P 不是 0：`丢失 EOI 之后的 R 字节（尾部共 M 字节，其中 K 字节是已搬进产物的辅助图像，P 字节是 MPF 登记的预览图，不需要带）`，
    是 0 的那一项不写。

  例如仓库里的 `test_pic/P1130939.JPG`：尾部 845456 字节，其中 845023 字节是预览图，
  另有 384 字节 MPF 没登记的相机数据，报 `丢失 EOI 之后的 433 字节（…其中 845023 字节是 MPF 登记的预览图，不需要带）`。

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
    偏移修正值）。清单写在 [`structuralExifTags`](Sources/Eclose/RawExifTags.swift)。
  - **没有数据的条目**：长度 0；ASCII/UNDEFINED 的值只含 NUL 和空格；`UserComment` 带着
    合规的 8 字节字符集头、去掉头之后只含 NUL 和空格。数值型的 0 算数据（`LightSource`
    0 是「未知光源」，照报）。
  - **已经由别的规则负责的标签**：Windows XP 标签和评级（见下面「等价字段」那条），
    时间字段（源侧以原始字节为准那条）。

**照搬过的产物，EXIF 必须与源逐字节相同，或者恰好是源的备注改写。** 上面的原始清点对 GPS
以外的标签只看在不在、不比值；照搬过来的 MakerNote、私有标签的字节对不对，视图和清点都
看不见。所以另有一条只看结构的规则：产物的 Exif 项结束在文件的最后一个字节（ImageIO 自己
写的产物里它在 `mdat` 靠前的位置、图像数据之前，永远不在末尾），就认定是照搬过的。它的
TIFF 字节（P）与源 EXIF 段的（S）之间只认两种关系：

1. P 与 S 逐字节相同。
2. P 是 S 的备注改写（见「EXIF 整块照搬」），下面全部满足：源的备注满足修补条件（见「已知
   限制」里「不合规范的 `UserComment`」那条；ImageIO 本来读得对的、字节只能猜的备注被改写了，
   不算）、Exif 子 IFD 里恰好一个 `0x9286`；P 的前 |S| 个字节与 S 相同，只有那一条的类型、个数、偏移这 10 个字节可以不同；那一条
   在 P 里是类型 7，值恰好占满 S 之后（补齐到偶数之后）到 P 末尾的全部字节，补的那个字节是 0；
   这段值解出来正是规定的写法——文本全是 ASCII 时是 `ASCII\0\0\0` 加文本，否则是 `UNICODE\0`
   加 BOM 加 UTF-16（字节序与 TIFF 头相同），解出的文本与源侧修补的文本逐字相同。这段值是解出来
   逐项核对的，不拿写的那一侧的函数算一遍来比，写的一侧写错了这里不会跟着错。

别的情形都报
`变化 EXIF 数据块：照搬过来的 EXIF 与源不一致（N 字节 → M 字节，第 K 个字节起不同）`（K 从 1 数起；
源里没有 EXIF 段时按 0 字节比）。`--verify` 只看两个文件，不知道转换时走了哪条路，认的就是
这个结构。系统重写的产物永远不触发它。备注的值由键空间比对（源侧视图里是修补后的文本，
产物侧是 ImageIO 读回的值）和下一条的备注原文核对管。逐字节相同或只差备注改写的产物，
原始清点、GPS 分数、`ImageUniqueID`、备注原文各条自然都过。

**备注的原文按原始字节核对。** 键空间比对比的是 ImageIO 两边读出来的值：ImageIO 把源里的
备注读错、又把读错的那串写进产物（`ASCII` 头里的 UTF-8 中文被读成 Latin-1 乱码，系统重写
时就以乱码为正文写进产物），两边一样，它看不见。所以另按两边 `0x9286` 的原始字节各读一遍
（源读 JPEG 的 EXIF 段，产物读 HEIF 的 Exif 项；读法见「已知限制」里「不合规范的
`UserComment`」那条，分「可靠的文本」和「猜的」），源里有备注时：

| 源的备注 | 产物必须 | 否则报 |
|---|---|---|
| 可靠的文本 T | 也是可靠的文本，且等于 T | `变化 备注 UserComment 的原文：T → …`；产物没有备注是 `丢失 备注 UserComment 的原文 = T` |
| 猜的 | `0x9286` 的值字节与源的逐字节相同 | `变化 备注 UserComment：源里的字节不是合法的 UTF-8（N 字节），产物里换了一种写法，原文无法核对`；产物没有备注是 `丢失 备注 UserComment（N 字节，不是合法的 UTF-8）` |

比文本之前两边都去掉开头的一个 BOM、尾部的 NUL 和空白（与键空间比对的尾部填充规则同一把
尺子），所以换了字符集头、换了字节序、多了填充都不算变。`UNICODE` 头没有 BOM 的值按它所在
TIFF 的字节序解（源看 JPEG EXIF 段的 TIFF 头，产物看 Exif 项的；EXIF 里没有 BOM 的 UTF-16
约定俗成与 TIFF 同字节序，exiftool 也这样读），按这个字节序解不出的（如落单的代理项）按
「猜的」那一行核对；有 BOM 的认 BOM。报的时候两边显示的就是这样解出来的文本。产物里的值解不出可靠的文本时，
「…」写成 `（N 字节，不是合法的 UTF-8）`；`JIS`、`UNICODE` 头的值按头解不出时，「不是合法的
UTF-8」写成「按 JIS 头解不出」「按 UNICODE 头解不出」。显示截断后两边一样时注明从第几个
字符起不同。同一处只出一行：键空间比对已经为 `{Exif}/UserComment` 报了丢失或变化、或原始
清点报了 `UserComment` 标签丢失，这一条就不再报（那两行写的是别的软件里看得到的值，早就
有；这一条只补它们看不见的那种）。产物的 EXIF 读不出时也不报（原始清点已经有「无法核对」
那一行）。

**EXIF 与 IPTC 打架的说明、作者、版权，每组合成一行。** 三组和它们的键见「EXIF 整块照搬」里
「EXIF 与 IPTC 打架的说明、作者、版权」那张表。某一组满足下面全部条件时，就是照搬保留了 EXIF
原值的情形：源 EXIF 里该标签的原文 A 是可靠的文本（去掉尾部 NUL 与空白后是 ASCII 或合法
UTF-8）；源视图里该组某个键的值 V 与 A 不同；产物视图里那个键的值等于 A。这时不逐键报
`变化 键: V → A`，改出一行
`变化 说明：源里 EXIF 与 IPTC 不一致，ImageIO 原来显示「V」，产物显示 EXIF 的原值「A」`
（「说明」换成「作者」「版权」）。这一行算差异：显示的值变了，校验不通过，`--delete-original`
不删源。组里不同的键 V 不同时各出一行；组里别的变法（既不是 V 也不是 A，或者键丢了）照旧由
键空间比对逐条报。

**说明、作者、版权的原文按原始字节核对。** 系统重写把 EXIF 里这三个标签换成 ImageIO 调和出的值
（IIM 读成乱码时就是乱码）时，两边视图显示的是同一个调和值，键空间比对一行都没有。所以另按两边
IFD0 里 `ImageDescription`（`0x010E`）、`Artist`（`0x013B`）、`Copyright`（`0x8298`）的原始值字节
各读一遍（源读 JPEG 的 EXIF 段，产物读 HEIF 的 Exif 项），比之前去掉尾部的 NUL 与空白，全空的当作
没有。源里有这个标签时，判定与措辞和上面备注原文核对的同一套：

| 源的值 | 产物必须 | 否则报 |
|---|---|---|
| 可靠的文本 A | 也是可靠的文本，且等于 A | `变化 EXIF 说明 ImageDescription 的原文：A → B`；产物没有是 `丢失 EXIF 说明 ImageDescription 的原文 = A` |
| 不是合法的 UTF-8（如 GBK） | 去掉填充后的字节与源的相同 | `变化 EXIF 说明 ImageDescription：源里的字节不是合法的 UTF-8（N 字节），产物里换了一种写法，原文无法核对`；产物没有是 `丢失 EXIF 说明 ImageDescription（N 字节，不是合法的 UTF-8）` |

（作者是 `EXIF 作者 Artist`，版权是 `EXIF 版权 Copyright`。）`Copyright` 可以写成「摄影师\0编辑者\0」
两段，两段都是原文，中间的 NUL 照留、显示成 `\0`；实测系统重写只留第一段，这一条报
`变化 EXIF 版权 Copyright 的原文：摄影师\0编辑者 → 摄影师`。同一处只出一行：原始清点报了这个标签
丢失、键空间比对为对应的 `{TIFF}/…` 键报了丢失或变化、或者上一条为它合成了一行，这一条就不报。
产物的 EXIF 读不出时也不报。整块照搬的产物两边字节相同，这一条恒过。

**GPS 的分数按原始值比。** 源文件常把坐标的「秒」存成分母 1000000 的分数，ImageIO
写 HEIF 时一律存成分母 100。ImageIO 视图里的 `{GPS}/Latitude` 在源一侧就已经按 XMP 的
`度,分.分` 形式四舍五入过，只有截断恰好跨过它的舍入档时才看得出来。所以 GPS IFD 里的
分数字段（纬度、经度、海拔、时间戳、方向、速度等）两边都在时逐个比原始分数，约分后
相等才算没变，不加容差，例如
`变化 GPS 纬度：22°38′53.743286″ → 22°38′53.74″（HEIF 写入器只保留到 1/100 秒）`。报了这一行，
ImageIO 视图里同一处的 `{GPS}/Latitude`、`XMP/exif:GPSLatitude` 就不再另报。

**ImageIO 读不出的 `ImageUniqueID` 按原始字节比值。** 33 字节以外的 `ImageUniqueID`
在源和产物的 ImageIO 视图里都没有，系统重写时补写进去的值写对没有，键空间比对看不见。所以源的
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
  （`0x4746`）、`RatingPercent`（`0x4749`）。ImageIO 不读这几个标签，系统重写 EXIF 时
  也不写。承载它们的有两种：产物原始 EXIF 的 IFD0 里有同一个标签、解出来的值相同
  （EXIF 整块照搬过的产物就是这样；源里值读不出的不算）；或者目标里的等价字段带着
  同一个值。Windows 写它们时通常同时写一份标准字段（`test_pic/IMG_1225.JPG` 的
  `XPAuthor` 与 `Artist` 都是 `Zhang San;Li Si`），标准字段会被搬走，所以判据和 IIM 日期
  一样：等价字段**确实带着同一个值**才算承载，不是"等价字段存在"。两种都没有时每个
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

**扩展属性逐个核对。** 「照片」App 的说明、访达备注、标签都不在图像文件里，存在文件的
扩展属性里，拷贝失败或目标文件系统不存扩展属性时它们就没了，元数据比对看不见。所以源上
的每一个扩展属性，产物上必须有同名、值逐字节相同的一份：

- 产物上没有：`丢失 扩展属性 <名字>（N 字节）`；
- 值不同：`变化 扩展属性 <名字>（N 字节 → M 字节）`，两边等长时加上「第 K 个字节起不同」（K 从 1 数）。
- 三种换成人看得懂的名字并显示值（截断规则同别处）：`com.apple.assetsd.description` 是
  「「照片」的说明」，值按 UTF-8 文本显示；`com.apple.metadata:kMDItemFinderComment` 是
  「访达备注」，值是二进制 plist 里的字符串；`com.apple.metadata:_kMDItemUserTags` 是
  「访达标签」，值是 plist 里的标签名（去掉颜色编号，用「、」连起来）。例如
  `丢失 「照片」的说明（扩展属性 com.apple.assetsd.description）= 西湖日落`、
  `变化 访达标签（扩展属性 com.apple.metadata:_kMDItemUserTags）：红色、工作 → 工作`。
  值解不出时照旧只报字节数，如 `丢失 访达备注（扩展属性 com.apple.metadata:kMDItemFinderComment，12 字节）`；
  变化后的值解不出时写 `（N 字节 → M 字节，解不出）`；截断后两边显示一样时补上字节数。
- 不比的只有转换时本来就不拷的那三个：`com.apple.quarantine`（隔离标记，产物是本机新写的
  文件）、`com.apple.ResourceFork`（资源分支）、`com.apple.provenance`（来源标记，由系统管：
  每个新建文件都会被自动加上，值由创建它的进程决定，`setxattr` 返回成功但写不进去；源由别的
  App 创建时产物上的值必然不同，核对它只会误报）。拷贝和核对用的是同一份清单
  （[`skippedXattrs`](Sources/Eclose/Converter.swift)）。除此之外，实测没有哪个扩展属性会在
  转换后被系统改写：`FinderInfo`、`lastuseddate#PS`、`macl`、`kMDItemWhereFroms` 等都原样
  拷过去。
- 产物上多出来的属性不报。
- 源或产物的扩展属性读不出（属性列表或某个属性的值读不出，包括文件系统不支持扩展属性）时
  报一行 `无法核对扩展属性：…`，不当作没有差异。

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
  系统重写 EXIF 的产物里不带内嵌缩略图，而几乎所有相机直出的 JPEG 都带一个
  （`test_pic/` 里两张都有），报它会让这些照片一律校验不过，所以不检测。EXIF 整块照搬
  的产物里 IFD1 缩略图原样在，由上面「照搬过的产物逐字节相同」那条一并核对。带辅助图的 JPEG 还会在
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

- **`--embed-caption` 写进的 `dc:description` 没在鸿蒙、安卓的图库上验证过**读不读得出；量过的是
  ImageIO（照片、预览、访达）和 exiftool。源里几乎没有元数据时写不进去（见「把「照片」的说明写进
  文件」），会报出来，不会静默。
- **EXIF 整块照搬的产物没在 libheif、Windows、安卓的读取器上量过**。量过的是 ImageIO
  （照片、预览、访达都走它）：照搬前后像素、按方向转正的缩略图、HDR 解码、辅助图都相同，
  属性只多不少（多出 MakerNote 解析出的 `{MakerCanon}` 等，GPS 的值变回源的精确值）。
  结构上与 ImageMagick/libheif 写的产物同类（EXIF 不是 ImageIO 写的）。遇到读不了产物的
  软件，用 `--no-raw-exif` 重新转。
- **`exiftool -validate` 对带 IFD1 缩略图的照搬产物报 `IFD1:ThumbnailOffset is past end of file`**。
  它把 HEIC 里 IFD1 的偏移基址加了两遍（报出的偏移 = 真实位置 + Exif 项的文件偏移），是
  exiftool 的算法问题，`exiftool -b -ThumbnailImage` 取出的缩略图与源逐字节相同。
- **产物 XMP 里声明的前缀名可能与源不同**。一个文件把标准前缀借给了非标准 URI（如
  `xmlns:photoshop="http://ns.adobe.com/photoshop/1.1/"`），或几个文件用同一个前缀指不同的
  URI 又在一起批量转换时，产物 XMP 里可能写成 `photoshop_1_`、`photoshop_1__1_`、`stArea_1_`
  这样的前缀。前缀名由 ImageIO 写产物时定，URI 和值都与源相同，含义不变；按 URI 读 XMP 的
  软件读出的是同样的字段。`--verify` 按 URI 比（见「`--verify` 到底比什么」），不报这种差别。
- 下面标着「（系统重写时）」的几条——MakerNote、读不出的标签、GPS 精度、Windows XP 标签、
  IFD1 缩略图、说明作者版权的调和值、非 ASCII 备注的写法——只发生在 **EXIF 交给系统重写时**（加了 `--no-raw-exif`，
  或「EXIF 整块照搬」一节里退回的那几种情形）。默认的整块照搬下它们原样在产物里。
- **（系统重写时）厂商私有数据 MakerNote 无法保留**。EXIF 里的 `MakerNote`（标签 0x927C）是相机
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
  段、`EOI` 之后除辅助图以外的数据（动态照片的视频、MPF 登记的其他附加图像、MPF 没登记的
  私有数据）。`--verify` 会逐段报出，所以 `--delete-original` 不会删这样的源文件。没有可带
  信息的几种不报，也一样不保留：ISO 21496-1 版本标记段、FlashPix 扩展、只有保存质量的
  Ducky 段、`AROT` 段、MPF 登记的大尺寸预览图、微信的 `tyf-` 尾部标记（见「`--verify`
  到底比什么」）。只有这些的源文件校验通过，`--delete-original` 会删掉它。
- **辅助图像的像素是有损重新编码的**。增益图、蒙版这类 8 位的辅助图，以及深度图、
  视差图，都和主图一样被重新编码，尺寸、像素格式、附带的元数据不变，像素值有小幅
  变化：平滑的合成图案上最大差 3 级（按 8 位计；深度图、视差图在 JPEG 里本来就是按
  取值范围量化成 8 位存的，按同一把尺子算），四张真实 HDR 照片的增益图上最大差 5–8 级。
  `-q` 不影响辅助图的编码。读回时每行字节数可能变大（多了对齐填充），数据本身不受影响。
- **辅助图加不进产物时，转换照常完成，辅助图丢失**。带辅助图的那一遍编码失败时，
  本工具不带辅助图（连增益图一起）再编一次；`--verify` 会把没搬过去的辅助图逐项报出来
  （`{FileContents}/…/AuxiliaryData…` 几条，外加 EOI 之后的数据），`--delete-original`
  不会删源。
- **（系统重写时）ImageIO 读不出的 EXIF 标签不会保留**：类型写错的（ASCII 的 `GPSProcessingMethod`、
  LONG 的 `LightSource`）、放错 IFD 的、ImageIO 不认识的私有标签、`PrintImageMatching`、
  不被 ImageIO 解析的短 MakerNote。属性字典里补上、XMP 里补上都写不进产物（实测过），
  所以只做检测：`--verify` 逐个报出（见「`--verify` 到底比什么」的原始标签清点），
  `--delete-original` 不会删源。`ImageUniqueID` 是例外：33 字节以外的写法 ImageIO 读不出，
  但写入器照写，所以能原样写回的由本工具补写（见「保留了哪些元数据」）；写不回原样的
  （类型不是 ASCII、放错 IFD、同号条目不止一个、不是合法 UTF-8）照报丢失。
- **（系统重写时）GPS 坐标的秒只保留到 1/100**。ImageIO 写 HEIF 时不管给多精确的值，秒都存成分母 100，
  误差最多约 15 厘米；海拔这类分数也会被换成别的近似分数（如 `1250001/100000` →
  `624988/49999`）。写不回去，只能如实报：秒的精度高于 1/100 的照片（很多手机都是）
  `--verify` 一律报 GPS 变化，`--delete-original` 不会删它们。
- **转出来可能比原图大**。已经压得很小的 JPEG（低质量导出、聊天软件转存的图）转成
  HEIF 可能反而变大，重编一次通常也一样大。工具照样写出产物并提示「HEIF 比原图大 N%」，
  `--delete-original` 不删这样的源。
- **产物不是逐字节可复现的**。平时 HEVC 编码走系统的硬件编码器；别的进程同时在编码、
  本进程又在并发转多张时，一部分图会改由软件编码器编（带增益图的文件可能只有增益图
  那一项换了编码器）。两者大小不同（实测同一张图 788 KB 对 685 KB），画质相当（对源
  JPEG 的 PSNR 44.45 对 44.50 dB），都是合法的 HEIC，元数据不受影响。所以同一张图
  转两次，产物不一定逐字节相同。
- **硬件编码器偶尔会把一张图按高得多的质量编出来**。见过一次，约 4.5 万次转换里一次：
  769 KB 的产物变成 2.8 MB（画质相当于质量 0.98–0.99），产物合法、只是大。原因在
  ImageIO / VideoToolbox 里面，本工具每张图传的是同一个质量值。产物比原图大时本工具
  重编一次、取小的那份（见「保留了哪些元数据」末尾）；重编后仍比原图大的照旧提示，
  `--delete-original` 照旧保留源文件。原图本身很大、异常的产物仍不超过原图时察觉不到，
  只是多占空间。
- **APP13 里 IPTC 以外的 Photoshop 资源不会保留**。只有 8BIM `0x0404`（IPTC-IIM）
  会被 ImageIO 读出并搬走，其它资源随段一起消失。`--verify` 把它们报成一条
  （见「`--verify` 到底比什么」），所以 `--delete-original` 不会删这样的源文件。
- **（系统重写时）Windows 资源管理器写的 XP 标签和评级本身不会保留**：IFD0 里的 `XPTitle`、
  `XPComment`、`XPAuthor`、`XPKeywords`、`XPSubject`（`0x9C9B`–`0x9C9F`）和
  `Rating`、`RatingPercent`（`0x4746`、`0x4749`）。ImageIO 不读也不写它们，信息
  只有在同时写了同值的标准字段时才跟着标准字段走。没有同值的标准字段时
  `--verify` 逐个报出，`--delete-original` 不会删源。
- **（系统重写时）EXIF 的说明、作者、版权会被换成 ImageIO 调和出的值**。ImageIO 读 JPEG 时用
  IPTC-IIM 的值调和这三个字段（IIM 摘要对不上时用 IIM 的；IIM 的字符集标记坏了时就是乱码），
  系统重写把调和出的值写进产物的 EXIF，源 EXIF 里的原文没了；`Copyright` 写成两段（摄影师、
  编辑者）的只留第一段。两边视图显示的是同一个值，`--verify` 由说明、作者、版权的原文核对报出来
  （见「`--verify` 到底比什么」），`--delete-original` 不删源。默认的整块照搬保留 EXIF 的原值，
  ImageIO 显示的值随之变回 EXIF 的原值，校验照样报出来（打架的那一组一行）。
- **（系统重写时）EXIF 的 IFD1 缩略图不会保留；Photoshop 资源里的缩略图无论哪条路都
  不保留。`--verify` 对两者有意不报**：它们是从像素派生的预览（见「`--verify` 到底比什么」
  的有意忽略），`{FileContents}` 里的 `ThumbnailImages` 那组键同样不报。原始 EXIF 清点也不比 IFD1。
- **界面用 AppKit 而非 SwiftUI**。SwiftUI 的 `@State` 等属性包装器现在是宏，
  宏插件只随完整版 Xcode 分发；用 AppKit 才能只靠命令行工具构建。
- **应用是本地临时签名的**，没有开发者证书。自己构建自己用没问题，拷给别人
  会被 Gatekeeper 拦。
- **只处理 JPEG 输入**。其它格式会被跳过并给出提示，不会误转。
- **HEIF 编码是有损的**，元数据无损但像素会重新编码。默认 `-q 0.8` 通常比源
  JPEG 小 60%–85%。想更接近原画质用 `-q 0.95`。要绝对像素无损请不要用本工具。
- **（系统重写时）非 ASCII 的 EXIF `UserComment` 在产物里多占一倍空间**。ImageIO 的 HEIC 写入器
  对含非 ASCII 的备注只写进前一半（按 UTF-16 单元算），ASCII 打头的还会被整条当成
  ASCII 写、非 ASCII 字符全变成 `?`。本工具写之前把这类备注改写一次（见
  [`userCommentForHEIFWriter`](Sources/Eclose/Converter.swift)）：在前面加一个 BOM（已经有
  就不加），再补上与（BOM 加文本）等长的 NUL。BOM 一律要加：首字符是 ASCII 时它让写入器
  选 `UNICODE` 头；写入器写的是大端 UTF-16，没有 BOM 时 exiftool 等别的读取器得自己猜字节序，
  纯中文的备注会被猜成小端、读成乱码（ImageIO 自己读得对）。产物里的备注与源逐字相同，
  代价是字段尾部跟着一段比正文还长一个单元的 NUL 填充；ImageIO 读出来的字符串尾部也带着
  这些 NUL（它读源 JPEG 的填充时也一样），`--verify` 按尾部填充规则不计较它们。纯 ASCII
  的备注原样写入。
- **不合规范的 `UserComment` 由本工具自己解析**。EXIF 要求该字段以 8 字节字符集
  标识开头（`ASCII\0\0\0` / `UNICODE\0` / `JIS…` / 全零），但不少安卓机型直接写
  裸 UTF-8，ImageIO 认不出这种写法，当作字段不存在；`ASCII` 头里装着 UTF-8 中文的，
  ImageIO 按 Latin-1 读成一串乱码（`è¥¿æ¹…`）。本工具因此自己解析 EXIF 段里 `0x9286`
  的原始字节（见 [`readUserComment`](Sources/Eclose/ExifReader.swift)），读出来的分两种：
  - **可靠的文本**：`UNICODE` 头（有 BOM 认 BOM，没有就大端、小端各解一遍取更像文本的）；
    `JIS` 头且 Shift-JIS 解得出；`ASCII` 头、全零头、没有头，且字节全是 ASCII 或是合法的 UTF-8。
  - **猜的**：`ASCII` 头、全零头、没有头而字节含高位又不是合法 UTF-8 的（GBK、Latin-1 写的
    西欧文字……），以及 `JIS` / `UNICODE` 头解不出的。本工具分不出这些字节是哪种编码，不猜。

  **修补**（`--verify` 源侧视图里的值、整块照搬时块上的备注改写、系统重写时写进去的文本，
  三处同一个条件）在两种情况下做：ImageIO 读不出（去掉填充后为空）而备注是可靠的文本；
  或者备注是 `ASCII` 头、字节含非 ASCII 的合法 UTF-8——不管 ImageIO 读成什么。修补时
  `--verify` 源侧 XMP 层里与 ImageIO 原读值相同的 `exif:UserComment`（ImageIO 从同一段字节
  合成的同一个误读）也换成修补后的文本。整块照搬时在照搬的块上把备注改写成 ImageIO 读得
  对的写法（见「EXIF 整块照搬」，旧的备注字节留在块里），系统重写时把文本放进要写入的属性。

  **猜的备注不修补**：默认路径原样照搬，字节一个不动，ImageIO 读它和读源一样（读不出，或读成
  同一串 Latin-1）。系统重写那条路上，ImageIO 读不出的猜的备注按 Latin-1 解出的那串写进产物
  （一个字节对一个码位，原字节还能从产物里一一还原，比不写强），ImageIO 读成 Latin-1 的照它
  读的写；这样写过之后原字节没了，`--verify` 的备注原文核对把它报出来（见「`--verify` 到底
  比什么」），`--delete-original` 不删源。

  注意有些机型往这个字段塞的是整段相机调试信息而非人写的备注，工具会一并原样保留——
  判断哪些算"噪音"不是转换工具该替你做的决定。
- **小端 EXIF 里没有 BOM 的 `UNICODE` 备注，ImageIO 读成乱码**。`UNICODE` 头的备注没有 BOM
  时 ImageIO 一律按大端读；小端（`II`）EXIF 里按小端写的这种备注（约定俗成的写法，exiftool
  读得对）它读成一串乱码。默认路径字节原样照搬，完好无损。系统重写时 ImageIO 把那串乱码带着
  BOM（声明了大端）写进产物，原文没了；`--verify` 的备注原文核对按源 TIFF 的字节序解出原文，
  报 `变化 备注 UserComment 的原文：<原文> → <乱码>`，`--delete-original` 不删源。转换时本工具
  不替 ImageIO 判断字节序（修补只认读不出和 `ASCII` 头里的 UTF-8 两种情形）。
- **字节序不合约定的无 BOM `UNICODE` 备注，校验按 TIFF 的字节序读**。备注原文核对认定没有 BOM
  的 UTF-16 与所在 TIFF 同字节序，所以：大端（`MM`）EXIF 里按小端写的（ImageIO 和本工具都读成
  同一串乱码），系统重写把那串乱码写进产物时两边读法一样，**不报**——这是已知的漏网，这种写法
  与正常的写法分不出来；小端 EXIF 里按大端写的（ImageIO 读得对），系统重写的产物会被**多报**
  成原文变化。默认路径字节原样照搬，两种都不报。
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
「输出到指定文件夹」和「取消」（取消一定要能拦下后续任务，否则测试形同虚设），并测图库的
扫描、过滤、排序、搜索、备注四种来源与去重、转换对象与转换记录、设置读写；最后再驱动真实
窗口跑一遍完整流程，并确认只浏览不转换时文件夹里的文件一样都不变。产物比原图大时的重编没法让系统编码器按需出错，
单元测试给转换注入假的编码步骤来测。

每次运行在独立的 `Tests/.work.XXXXXX` 目录里进行，两个 `make test` 可以同时跑。
全部通过时这个目录会被删掉；有失败或提前退出时保留，并在末尾打印路径供诊断。

界面排版可以离屏渲染出来看，不需要屏幕录制权限：

```bash
make snapshot OUT=/tmp/ui.png ARGS="--convert ~/Pictures/测试"
make snapshot OUT=/tmp/ui.png ARGS="--appearance dark --view list --select IMG_0001.jpg ~/Pictures/测试"
```

参数：`--appearance light|dark`、`--size 宽x高`、`--view grid|list`、`--sidebar <条目或文件夹名>`、
`--select <文件名>`（可重复）、`--search <词>`、`--sheet`（显示转换面板）、`--convert`（把当前视图里
全部的 JPEG 转完再截图）、`--inspector <宽>`（把信息栏拖到这个宽度），以及量性能用的 `--measure`、`--scroll`。
设置存在内存里，不碰应用自己的设置。离屏渲染画不出毛玻璃和侧栏的 source list 样式，截图里侧栏
换成不透明背景和普通列表来画，工具栏是非活动窗口的样子；加 `--onscreen` 则把窗口放到屏幕上、
用 `screencapture` 截真实窗口（需要屏幕录制权限）。

## 目录结构

`Sources/Eclose/` 是格式转换模块 **eclose**（羽化），编成真正的 Swift 模块 `Eclose`（静态库加
`.swiftmodule`，构建产物在 `build/` 下）。命令行和应用都 `import Eclose`，只用得到它公开的那一小块：
转换选项、转换入口与批处理、转换结果与校验结果、界面读备注的几个函数和 `humanSize` 这类小工具；
其余规则保持模块内部，测试工具用 `@testable import Eclose` 直接断言它们。

| 路径 | 说明 |
| --- | --- |
| `Sources/Eclose/Converter.swift` | 单张图的转换：读元数据、编码 HEIF、搬运文件层属性、把「照片」的说明写进 XMP |
| `Sources/Eclose/Batch.swift` | 批量编排：扫描输入、分配目标路径（含重名避让）、并发调度 |
| `Sources/Eclose/MetadataDiff.swift` | `--verify` 的比对规则：什么算真丢失、什么只是重编码噪声 |
| `Sources/Eclose/ExifReader.swift` | 手写 EXIF 解析：按原始字节读 `UserComment`（分可靠的文本与猜的），按标签读原始值 |
| `Sources/Eclose/ExifText.swift` | 说明、作者、版权三组调和字段：EXIF 原文的读法、照搬自检的放行、打架合成一行、原文核对 |
| `Sources/Eclose/HEIFExif.swift` | 从 HEIF 的 `meta` 盒子里取出 Exif 项的原始 TIFF，供原始 EXIF 清点读产物一侧；`iloc` 的逐项读取 |
| `Sources/Eclose/RawExifCarry.swift` | EXIF 整块照搬的闸门与改写（纯函数：进产物字节与源 EXIF，出新字节或不换的原因），以及照搬块上的备注改写与校验认改写的规则 |
| `Sources/Eclose/RawExifTags.swift` | 原始 EXIF 标签清点（源里有、产物里没有的标签）、GPS 原始分数比对、`ImageUniqueID` 的补写规则与按原始字节比值，含不报清单 |
| `Sources/Eclose/JPEGLayout.swift` | JPEG 段结构，以及 ImageIO 搬不走的段（COM、未知 APPn、EOI 之后）、MPF 索引与尾部记账、APP13 里的 Photoshop 资源 |
| `Sources/Eclose/RawTimes.swift` | 源文件里 EXIF、IIM、XMP 时间字段的原始值，供 `--verify` 当源侧真相 |
| `Sources/Eclose/WindowsTags.swift` | IFD0 里 ImageIO 不读的 Windows XP 标签和评级，及其在目标里的等价字段 |
| `Sources/Eclose/PhotoNotes.swift` | 界面信息栏读备注用的几条规则（「照片」的说明、访达备注、EXIF 备注该显示什么、说明能不能写进文件），只公开结果 |
| `Sources/CLI/Arguments.swift` | 命令行参数解析（纯函数，可被测试直接调用） |
| `Sources/CLI/main.swift` | 命令行入口：串起解析、转换与输出 |
| `Sources/GUI/AppName.swift` | 应用的名字（与 `Makefile` 的 `APP_NAME` 一起，改名只动这两处） |
| `Resources/` | 应用图标：`AppIcon.icns` 装进应用包，`AppIcon-1024.png` 是大图 |
| `Tools/make_icon.swift` | 生成应用图标（`make icon`）：极光色渐变底上一根白色羽毛，羽尖化成光——「吉光片羽」「极光」与把格式转换看作「羽化」 |
| `Sources/GUI/PhotoInfo.swift` | 一张图的信息：格式、尺寸、拍摄时间、相机、位置、备注的四种来源与存放位置（不依赖 AppKit） |
| `Sources/GUI/Library.swift` | 图库：来源、后台扫描与读元数据、过滤排序搜索、张数、文件夹树、副标题与汇总（不依赖 AppKit） |
| `Sources/GUI/ConversionRecord.swift` | 转换的对象（面板标题与说明）、转换记录（标记、汇总、最常见的差异、活动条那句话）（不依赖 AppKit） |
| `Sources/GUI/Settings.swift` | 设置的读写：转换面板、浏览偏好、加进来的文件夹（不依赖 AppKit） |
| `Sources/GUI/Model.swift` | 转换的调度（`ConversionModel`）：跑批、取消、把结果回填到行（不依赖 AppKit） |
| `Sources/GUI/MainWindowController.swift` | 主窗口：三栏、工具栏、活动条，汇总各模型的状态交给各栏，菜单动作 |
| `Sources/GUI/SidebarViewController.swift` | 侧栏 |
| `Sources/GUI/BrowserViewController.swift` | 网格与列表、空状态、Quick Look、右键菜单 |
| `Sources/GUI/InspectorViewController.swift` | 信息栏 |
| `Sources/GUI/ConversionSheet.swift` | 转换面板 |
| `Sources/GUI/Thumbnails.swift` | 后台生成缩略图（带缓存、并发上限、可取消） |
| `Sources/GUI/Views.swift` | 网格单元与角标、空状态、活动条、整窗拖放等小视图 |
| `Sources/GUI/main.swift` | 应用入口与菜单 |
| `Tests/` | 自检脚本、测试图生成器、元数据探针、界面截图工具、模型层集成测试 |
