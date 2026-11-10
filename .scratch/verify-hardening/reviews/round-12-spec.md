# 第 12 轮 Spec 轴报告（agent 原文，Fable 5.2）

- 时间：2026-11-10T10:12:14.822Z
- 范围：基线 ecc0f1b 以来的全部改动，Spec 轴另审整条 --verify 管线的现状。
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，不带任何用户授权；
  哪些断言被复现过、哪些被采纳，见 ../round-12-handoff.md。

---

# Spec 轴报告（第 12 轮）

  偏移解析器本身没有发现新的静默通道，但它所在的管线有四条实测的静默放过，其中最严重的一条正是长期要求 #1 点名的"偏移丢了却报通过"。全部在副本里实测（Darwin 27.2），原仓库未动。

  复现材料都在 `/private/tmp/claude-501/-Users-minxu-Claude/44cedf7f-2708-42ba-bc48-8bf34b801508/scratchpad/r12/`：造样本用 `tools/jt.py`、`tools/mm.py`，变异用 `tools/mutate.sh`，探针源码在 `probes/`，样本在 `work/`。

  ## 1. 源侧读的是 ImageIO 调和后的视图，偏移和拍摄时间被静默改写
  1. **现象**：`MetadataDiff.swift:564` 的 `metadataKeySpace` 对源文件只读 ImageIO 视图。
     - `fixture --no-exif-offset`，把 3 处 EXIF `2024:09:15 18:42:07` 等长改成 `…18:42:08`（IIM 仍是 `184207+0800`，XMP 仍带 `+08:00`）→ 源视图 `{IPTC}/TimeCreated = 184208`，偏移没了 → HEIC 里 `+08:00`/`+0800` 出现 0 次 → `✓ 元数据校验通过`，`--delete-original` 删了源。去掉 XMP 包（只剩 EXIF+IIM）结果相同。
     - 反向：默认夹具只把 IIM 改成 `104207+0000` → HEIC 的 EXIF `DateTimeOriginal` 被写成 `10:42:07`，`OffsetTimeOriginal` 仍是 `+08:00`，照样通过。
     - 违反 #1："读出一个合法值比读不出更坏，因为连差异都不剩"。
  2. **方向**：静默放过。真实文件可达：任何 EXIF 与 IIM/XMP 时间不一致的 JPEG，例如 Lightroom 导出后用 `exiftool -AllDates` 只改 EXIF。
  3. **修改方向**：ImageIO 会调和的字段（EXIF 0x9003/9004/0132/9010–9012、IIM 2:55/60/62/63）在源侧另读原始字节；`ExifReader` 已有 IFD 遍历。原始值与源视图不一致就报。
  4. **验证方案**：上面两张图（等长字节替换即可造）。断言 verify 输出含差异且源文件保留；删掉原始比对必须变红。
  5. **建议**：接——这是 #1 点名的场景。

  ## 2. ImageIO 看不见的源数据整段丢失
  1. **现象**：四种样本各自 `✓ 通过`，HEIC 里搜不到内容，`--delete-original` 删源：
     - JPEG COM 段备注；
     - EXIF IFD0 的 `XPComment`/`XPKeywords`/`XPTitle`（0x9C9B–9C9E）和 `Rating`（0x4746）；
     - APP11；
     - EOI 之后 65KB 尾部数据。
     - 违反 README"备注…一样不丢"。`ExifReader.swift:12` 自己写着"连 --verify 也发现不了，因为它比的也是 ImageIO 的视角"，却只修了 UserComment 一个实例。
  2. **方向**：静默放过。真实可达：Windows 资源管理器写的备注和标记、安卓 Motion Photo 的尾部视频、C2PA。
  3. **修改方向**：复用 `ExifReader` 的段扫描做源文件清单，COM、未知 APPn、EOI 后字节各报一条"源里有、搬不走"。
  4. **验证方案**：`jt.py com|xp|app11|trailer` 的四张样本，断言报差异且不删源；清单函数返回空必须变红。
  5. **建议**：接段清单。XP 标签可以先只写进"已知限制"。

  ## 3. 界面没校验却显示"校验无差异"
  1. **现象**：`Sources/GUI/Model.swift:73` 的判据是 `issues.isEmpty && tagCount > 0`。`verify=false` 时，`--lossy` 夹具（必丢 EditStatus）显示 `元数据 54 项 · … · 校验无差异`。根源是 `Converter.swift:134` 的"空表示没有差异（或没开校验）"一值两义。违反 #1。
  2. **方向**：静默放过（谎报）。用户取消勾选"转换后校验元数据"就触发。
  3. **修改方向**：`ConversionReport` 改成三态（未校验/通过/有差异），让下游无法混用。
  4. **验证方案**：guimodel 测试里 `verify=false` 加 lossy 夹具，`detailText` 不得含"校验无差异"；恢复原判据必须变红。
  5. **建议**：接。

  ## 4. `metadataDiff` 的接线没有证人
  1. **现象**：三处变异 `make test` 全绿（67 项），违反 #2：
     - `:589` 改成 `if equivalentKeys[k] != nil { continue }`，即 README 明令禁止的"等价字段存在就放过"；
     - `:595` 整条"变化"分支禁用；
     - `:600` MakerNote 汇总行禁用（相机图会直接通过并被删）。
     - 十一轮加固的解析器可以整个从 `--verify` 上摘掉而测试不红。
  2. **方向**：一旦回归就是静默放过。
  3. **修改方向**：抽出纯函数 `diff(before:after:)`，单测逐分支喂手搭字典。
  4. **验证方案**：四个用例——值变化；IIM 日期在但等价值不同；`{MakerCanon}/x` 丢失后出现汇总行；volatile 键被跳过。另加 `test_pic/IMG_1225.JPG` 端到端断言含"MakerNote"且不删源。上述三变异必须变红。
  5. **建议**：接。

  ## 5. XMP"原样搬运"没有实现
  1. **现象**：`Converter.swift:199-203` 的 `kCGImageDestinationMetadata`/`MergeMetadata` 对 `AddImageFromSource` 是空操作：删掉这几行测试全绿，产物键集完全相同。富 XMP 样本 45 个键丢 12 个：`xmp:Label`、`lr:hierarchicalSubject`、`dc:title` 的其它语言、人脸区域的 `Name`、自定义命名空间、`xmpMM:*`。违反 README"关键词、评级、版权、人脸区域等，原样搬运"。
  2. **方向**：多报（verify 会报出来），但功能本身是坏的。Lightroom 导出的文件都会命中。
  3. **修改方向**：改走 `CGImageDestinationAddImageAndMetadata`。实测富 XMP 样本和夹具零差异，两张真实照片只剩 MakerNote。UserComment 修补要改走 `CGImageMetadata`，这一步未测。不改代码的话就改 README。
  4. **验证方案**：夹具加一个纯 XMP 键并在第 2 轮断言；删掉那几行必须变红。
  5. **建议**：接。

  ## 6. `ProfileName`/`ColorModel` 被当作 volatile，CMYK 的 ICC 被悄悄替换
  1. **现象**：`MetadataDiff.swift:103`。CMYK JPEG 转换后 `Generic CMYK Profile → sRGB IEC61966-2.1`、`CMYK → RGB`，校验通过并删源。README 的忽略清单里没有这两个键，且写着"ICC 色彩描述文件…一并保留"。
  2. **方向**：静默放过。只有 CMYK 文件可达（印刷流程，少见）。
  3. **修改方向**：把这两键移出 `volatileKeys`。实测 sRGB、P3、AdobeRGB、ProPhoto、BT.2020、灰度和两张真实照片零噪声。
  4. **验证方案**：CMYK 样本期望报 2 条；单测里这两条 `expectVolatile` 改成 `false`。
  5. **建议**：接——只删代码。

  ## 7. 文件层（第 3 层）不在校验内
  1. **现象**：`Converter.swift:214-215` 的失败全被吞掉（`try?`，`setxattr` 失败不计数），`:230` 不看文件层。把这两行整段禁用后仍然 `✓` 并删源，访达备注、标签、mtime、权限全丢。
  2. **方向**：静默放过。但 APFS 和 FAT 上都没能自然复现；"某些网络卷会失败"只是推断。
  3. **修改方向**：复制后回读比对，差异并入 `issues`。
  4. **验证方案**：同上变异；它目前只让第 3 轮变红，verify 自己不红。
  5. **建议**：拒——没有可达证据，等有真实失败卷再做。

  ## 8. `carriesSameValue` 子串包含、`valuesMatch` 对纯数字串的容差
  1. **现象**（纯函数实测）：
     - `carriesSameValue("091518", "2024:09:15 18:42:07")` 为 true；
     - `("074208", "2024-09-15T18:42:07.42+08:00")` 为 true，靠小数秒和偏移的数字凑成；
     - `valuesMatch("042", "42")`、`("123456789012", "123456789013")` 为 true。
  2. **方向**：静默放过，但端到端不可达。9 组不一致样本里 ImageIO 源视图的三处时间永远同值；前导零 ImageIO 原样保留。
  3. **修改方向**：前者改成按位比较（前 8 位日期、第 9–14 位时间）；后者让纯整数串逐字符比较。
  4. **验证方案**：上面的输入全部期望 false。
  5. **建议**：拒单独修。但接了第 1 条就必须同时改 `carriesSameValue`，因为原始值入场后它就可达了。

  ## 查过、干净的
  - 偏移解析器对 EXIF `"   :  "`/`±HH:MM`、XMP 的 TZD 全集、IIM 四种形状：没有新的误收；`+08` 只会多报。
  - 尾部空白：ImageIO 原样保留。
  - 有理数噪声实测 4.8e-10，在容差内。
  - 增益图和深度图转换时确实丢，但会经 `{FileContents}` 报出来。
  - RGB 和灰度的 ICC 保留。
  - `OffsetTime*` 混用（如 `OffsetTimeDigitized` 承载 `TimeCreated` 的偏移）与 README 一致，端到端不可达。
  - 删掉 XMP 层合并、放宽 volatile 前缀这两个变异都会变红。
