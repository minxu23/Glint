# eclose（羽化）：格式转换模块

Status: resolved

## 用户的要求与拍板（2026-11-13）

> 整個APP叫Glint，把格式轉換功能做成一個獨立的模塊，取名eclose（羽化），提供JPEG到HEIF(jepg2heif）、RAW到HEIF（raw2heif）的功能

| 问题 | 用户的选择 |
|---|---|
| 命令行形式 | 两个独立命令 `jpeg2heif`、`raw2heif`（都由 eclose 模块构建）；`glint` 不再是命令行，Glint 只指图形界面应用 |
| raw2heif 删不删源文件 | **不支持删除，RAW 永远保留** |
| RAW 冲印 | **系统默认显影**，产物 **10 位 HEIF** |
| 本轮范围 | **全部都做**：模块、两个命令、RAW 管线、CR3 版本号修整、RAW 校验规则、应用改名 Glint、自造 DNG 测试，**加上** GUI 也能转 RAW、RAW 的 EXIF 整块照搬 |
| GPS 被 ImageIO 取整（搬块之前/搬块失败时） | **如实报，压成一行**（给出最大偏差的厘米数） |
| 应用安装 | Glint.app **不装 /Applications**，只放 `~/Developer`（`make install-dev`，和 Spark 一样）；旧的两份「吉光.app」合并后由主会话删除 |

## 实测（主会话，5 个真 RAW：佳能 CR3 ×3、松下 RW2 ×2；样本不进仓库、不给子代理）

1. **显影**：`CGImageDestinationAddImageFromSource(rawSource, 0, props)` 写 `public.heic` 就是系统默认显影——与 `CIRAWFilter` 默认参数的输出比（都转正后缩到 512 px），平均差 0.08%、最大差 2.5%。产物全尺寸、`Depth` = 10、方向标签照抄（像素不转）、竖拍正确。4500 万像素 CR3：0.85 秒、8.7 MB。
   - **不要用** `CIRAWFilter` + `CIContext.writeHEIF10Representation`：它把方向转进像素、又保留 Orientation 标签，竖拍照片转两遍（RW2 方向 6 实测 3776×2520 → 2520×3776 且标签仍是 6）。
2. **现有 `metadataDiff` 对 RAW→HEIC 直接能跑**，抓到的东西：
   - **CR3 的版本号被写坏**（真问题）：ImageIO 读 CR3 给的 `{Exif}/ExifVersion` 是字符码 `[48,50,51,49]`（"0231"），写入器把它当数字写，产物读回 `[48,0,1]`；`FlashPixVersion` `[48,49,48,48]` → `[48,9,8]`；`{GPS}/GPSVersion` `[2,3,0,0]` 丢失。RW2 给的是 `[2,3]` / `[1,0]`，往返无损。
   - **GPS 精度降低**（真问题，小）：写入器把坐标重新编成度分秒时取整，读回 `{GPS}/Latitude` 在第 6–7 位小数变化（几厘米）；XMP 视图里还会出现 `GPSLatitudeRef` 丢失、`GPSLatitude` 写法变化（`69,11.645100N` → `69,11.6452N` 这类）。JPEG 路线没这问题是因为整块照搬原始 EXIF。
   - **MakerNote 丢失**（已知局限，现有报告已有一行）：`{MakerCanon}`、松下的 `{ExifAux}`/`{PictureStyle}` 等。
   - **RAW 专有的结构字段**全被报成「丢失」，几十行噪声：`{raw}/…`（CropSize、SensorSize、Thumbnails[n]/…）、`{DNG}/…`（色彩矩阵、黑白电平、裁切、DNGVersion…）、`{Exif}/CFAPattern[n]`、`{TIFF}/BitsPerPixel[n]`、`{TIFF}/Width`、`{TIFF}/Height`、`XMP/tiff:Compression`。
   - 空字符串的 `{Exif}/CameraOwnerName`（及 `XMP/exifEX:CameraOwnerName`）丢失。
3. **ImageIO 不能写 DNG**（`CGImageDestinationCopyTypeIdentifiers` 里没有），但手写的 DNG 能用：见 `dng-reference.swift`（主会话写的，可以直接拿来改）。要点：
   - 结构：IFD0 是 8 位 RGB 小预览（`NewSubfileType=1`）+ DNG 标签 + Exif/GPS 指针；原始数据在 SubIFD（tag 330）里，16 位拜耳阵列（CFA，`Photometric=32803`）。
   - **尺寸有门槛**：256×192 时 `CGImageSourceGetType` = `com.adobe.raw-image`，解码 16 位，转出 10 位 HEIC、方向 6 正确，约 100 KB；**64×48 时被当成 `public.tiff`**，读到的是 16×12 的预览图（8 位）。门槛在两者之间，没细测。测试必须断言「类型是 RAW、产物 Depth 10」，不能只看转换成功。
   - 必须带全那一串推荐标签（BlackLevelRepeatDim、BlackLevel、WhiteLevel、DefaultScale、DefaultCropOrigin/Size、BayerGreenSplit、ActiveArea、AnalogBalance、AsShotNeutral、BaselineExposure/Noise/Sharpness、BestQualityScale、ColorMatrix1、CalibrationIlluminant1…）；只带最少几个时 ImageIO 不认作 RAW。
   - DNG 路线下没有复现 CR3 的版本号问题；对手写 DNG 的现有 diff：GPS 精度/写法几行 + 上面那些结构字段。
4. 现状：`convert()` 只收 `public.jpeg`，RAW 报「不是 JPEG 文件」跳过；目录扫描按扩展名 `jpegExtensions` 过滤。用户的 RAW 文件夹里**没有** `.xmp` 附属文件；有的文件夹 RAW 和同名 JPG 并存（两个命令都产出 `X.heic`，后转的按现有规则「输出已存在」跳过——保持，提示里写清楚）。

## 分段

- **第 1 段**（`stage-1-handoff.md`）：模块 + 两个命令 + 改名 Glint + RAW 管线 + 版本号修整 + RAW 校验规则（含 GPS 一行）+ 自造 DNG 测试。
- **第 2 段**（第 1 段合并后再写交接稿，两个可并行）：
  - 2a：RAW 的 EXIF 整块照搬（CR3 的 CMT1/CMT2/CMT4，TIFF 系 RAW 的 IFD0/ExifIFD/GPS IFD → 干净的 TIFF 块 → 现有 `carryingExif` 写进 HEIF），根治 GPS 精度与版本号。
  - 2b：Glint.app 里 RAW 也能转（列表里 RAW 算可转换、转换面板 RAW 不给删除选项、记录与信息栏认 RAW）。

## Comments

2026-11-13：已实现并合并到 main（第 1 段 `5ccab4b` … `2612c46`，第 2 段 `72e82ab` … `16a0dcd`），验收结果见仓库根目录的 HANDOVER.md。
