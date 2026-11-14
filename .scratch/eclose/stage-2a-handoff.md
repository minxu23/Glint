# eclose 第 2 段 a：RAW 的 EXIF 整块照搬

Status: resolved

先读同目录的 `spec.md`（用户拍板与实测）和 `stage-1-handoff.md`（第 1 段做了什么），再读 `Sources/Eclose/RawExifCarry.swift`、`Converter.swift` 的 `carryRawExif` / `rawExifRegression`、`CameraRaw.swift`、`HEIFExif.swift`、`ExifReader.swift`。

## 为什么做

第 1 段合并后，主会话用真 RAW（3 个佳能 CR3、2 个松下 RW2）跑 `raw2heif --verify`，剩下的差异：

| 样本 | 剩下的行 |
|---|---|
| CR3 ×3 | `GPS 精度降低：最大偏差 18 / 7 厘米`（有坐标的两个）；`丢失 {Exif}/CameraOwnerName =`（空串）及其 XMP；`丢失 {GPS}/Satellites =`（空串）及其 XMP；r1（GPS 字典只有 GPSVersion、没坐标）`丢失 {GPS}/GPSVersion = 2.3.0.0`；MakerNote 一行 |
| RW2 ×2 | 只有 MakerNote 一行 |

这些都来自 ImageIO 从属性字典**重写** EXIF：取整 GPS、丢空串、丢没坐标的 GPS 字典。JPEG 路线早就靠「EXIF 整块照搬」绕开了它（`carryingExif`：把源的 TIFF 原样放进 HEIF 的 Exif 项）。本段给 RAW 也做照搬：**从 RAW 里把 EXIF 拼成一个干净的 TIFF 块**，再交给现有的 `carryingExif` + 自检。

目标：上面这些行在真样本上消失，只剩 MakerNote 一行（MakerNote 本段**不**照搬，见下）。

## 要做的

### 1. 从 RAW 里取 EXIF，拼成一个干净的 TIFF 块（纯函数，进字节出字节）

- **CR3**（ISO BMFF）：`moov` 下 UUID 为 `85c0b687-820f-11e0-8111-f4ce462b6a48` 的 `uuid` 盒子里，`CMT1` = IFD0（带 TIFF 头的完整 TIFF），`CMT2` = Exif IFD（同上），`CMT3` = 佳能 MakerNote，`CMT4` = GPS IFD。
- **TIFF 系 RAW**（DNG、CR2、NEF、ARW、PEF、SRW、RW2 的魔数是 0x55、ORF 的魔数是 `IIRO`/`IIRS`/`MMOR`……）：IFD0 里的 ExifIFD 指针（0x8769）、GPS 指针（0x8825）。
- **RAF**：头后面嵌着一个 JPEG，里面有正常的 EXIF APP1，可以复用 `sourceExifTIFF`。
- 本机 ImageIO 能读、但你没把握解析的格式：不照搬，原因写清楚（`RawExifSkip`）。**先做 CR3、DNG、RW2**（有真样本或夹具能验），其余格式能顺手做就做，但每种都要有测试；没测试的不开。
- 拼出来的块：保持源的字节序；
  - IFD0 只留描述性标签（Make、Model、Orientation、DateTime、ImageDescription、Artist、Copyright、Software、X/YResolution、ResolutionUnit 等，白名单写在代码里并写理由），去掉一切描述图像数据或 RAW 容器的（StripOffsets/TileOffsets/SubIFDs/BitsPerSample/Compression/Photometric/宽高/DNG 私有标签 50706 起……）；
  - Exif IFD 全部条目照搬，**除了 MakerNote（0x927C）**；Interop IFD 如果有，一起搬或者去掉指针，二选一并写理由；
  - GPS IFD 全部条目照搬，值的字节原样（rational 不重算，这正是 GPS 精度能保住的原因）；
  - 所有值数据重新排布，偏移重算；块内不留指向原文件的偏移。
- 闸门：源的长度、偏移、个数都不信，任何一条读不通就不照搬（与 `RawExifCarry.swift` 同一种态度）。

### 2. 接进转换

- 第 1 段在「编码之后、校验之前」给 RAW 留了位置（现在输出「EXIF 没有照搬：RAW 的 EXIF 还不能整块照搬」）。照搬走现有的 `carryingExif` 写进产物，再过现有的自检（读回、视图不退步，`rawExifRegression` 那一套）。自检不过就保留 ImageIO 写的那份，原因写进报告。
- 写入前的版本号修整（`versionFieldsForHEIFWriter`）照留：照搬失败时它还是兜底。
- `--no-raw-exif` 现在对 RAW 生效；把 raw2heif 用法里「目前对 RAW 不起作用」的说明去掉。
- 方向：拼块的 IFD0 里的 Orientation 必须与产物现有的一致（ImageIO 写的就是源的方向）；不一致就不照搬。

### 3. 校验

- 照搬成功时，GPS 一行、空串丢失、GPSVersion 丢失这些应该自然消失——不要为此改校验规则。
- 照搬了的块里去掉了 MakerNote：校验照旧报 MakerNote 那一行（这是真丢失）。
- 第 1 段的 RAW 白名单、GPS 一行、版本号规则都保留（照搬失败时还用得上）。

## 测试

- **夹具**：`Tests/DNG.swift` 的 DNG 是 TIFF 系路线的端到端夹具；GPS 秒带小数（第 1 段已有）。端到端断言：`raw2heif --verify` 对带 GPS 的夹具**零差异**（第 1 段是 GPS 一行），`-v` 里显示 EXIF 照搬了多少字节。
- **CR3**：造不出 ImageIO 能解码的 CR3。用合成字节测解析与拼块：一个最小的 ISO BMFF（`ftyp` + `moov` + 那个 `uuid` + `CMT1`/`CMT2`/`CMT3`/`CMT4`），断言拼出的块里 IFD0/Exif/GPS 的条目与源一致、MakerNote 不在、偏移都在块内。再把这个块用 `carryingExif` 放进一张由 DNG 夹具转出来的 HEIC，读回断言 GPS rational 原样、空串标签还在。
- **闸门**：截断的盒子、长度越界、IFD 自指循环、条目数巨大、CMT 缺失或重复——都不照搬，产物仍是 ImageIO 写的，转换不失败。
- **变异**（交付说明列出，每条都要变红）：拼块时不去掉 MakerNote、GPS rational 重算成浮点再写回、IFD0 白名单放进 StripOffsets、方向不一致仍照搬、闸门放过越界偏移、`--no-raw-exif` 对 RAW 无效。
- 更新计数。

## 约束

- 只在你的 worktree 里构建、测试；不碰主仓库 `/Users/minxu/Developer/Glint`。
- **另一个代理（2b，界面转 RAW）同时在另一个 worktree 里改 `Sources/GUI`、`Tests/guimodel`、`Tests/snapshot`。你不要改这些文件**；你的改动应该集中在 `Sources/Eclose`、`Sources/CLI`、`Tests/unit`、`Tests/selftest.sh`、`Tests/DNG.swift`、README。如果必须改 Eclose 的公开接口（`public` 的签名），停下来在交付说明里写清楚，不要改。
- 不读、不拷用户的任何照片或 RAW，不下载任何东西；不写用户真实设置域 `local.minxu.glint`。
- 不安装应用、不 push、不合并到 main。
- HEIC 编码不是逐字节确定的（别的进程同时编码时会改走软件编码器）；另一个代理可能同时在跑 `make test`，逐字节比较一批产物时看到无关差异，先串行重跑再下结论。
- make 时间戳陷阱：`cp` 恢复后 `touch`，确认日志里有对应的 `swiftc` 行。
- 中文注释与输出，风格照现有代码；零第三方依赖。每个提交 `make test` 全绿；提交信息结尾 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 交付说明

1. 分支与提交列表。
2. 支持照搬的 RAW 格式清单（每种：怎么取 EXIF、有什么测试）；不支持的格式与原因。
3. IFD0 白名单、Interop 的处理及理由。
4. 夹具的 `raw2heif -v --verify` 完整输出。
5. 变异清单与结果。
6. 最后一次 `make test` 计数行。
7. 需要主会话用真 CR3/RW2 验的东西。

## Comments

2026-11-13：已实现并合并到 main（`e03a0e9`、`7b8554a`、`2dd7162`），验收结果见仓库根目录的 HANDOVER.md。
