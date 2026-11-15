# 交接稿：每张源 JPEG 只读一次、只解析一次

Status: resolved

工作规则沿用 [`../verify-hardening/round-12-handoff.md`](../verify-hardening/round-12-handoff.md) 第 0 节和根目录
`HANDOVER.md` 的「质量原则」「隐私规则」「工作方式」。另加：

- 变异后用 `cp` 从快照还原要 `touch` 源文件，并确认那次 `make test` 的输出里有 swiftc 那行。
- 计时、逐字节比较时机器上不能有别的转换或 `make test` 在跑（先 pgrep；另一个会话也在这个仓库的 main 上工作）。
- 用户的照片你拿不到，也不要去找；样本用 `Tests/fixture`（含 `--camera panasonic|canon`、`--size … --photo`）、`Tests/mangle-tool` 造。

一批一个提交，全绿就提交；文档单独一个。这是**纯重构**：行为、输出、产物一律不变。

## 1. 现象（main = 98f33b6）

一次 `jpeg2heif` 转换（含 `--verify` 时更多）里，同一个源 JPEG：

- 被 `JPEGLayout.init` 解析多次：`ExifReader.swift:27`、`Converter.swift:1086/1130`、`JPEGLayout.swift:183/316/477`、
  `RawExifCarry.swift:37`、`RawTimes.swift:37` 等各自重解（前一轮性能报告数到每张约 8 次）；
- 被整份读进内存多次：`Converter.swift:164/564/584/766/845/1101/1128`、`ExifReader.swift:145`、`MetadataDiff.swift:817` 等，
  不少地方再 `[UInt8](data)` 整份拷一遍。

交接方用 `sample` 量了 56 张用户的风景照（大多 6000×4000，5–12 MB），`--no-quality-check -j 1`：用户态 2.90 s，其中
`JPEGLayout.init` 约 1.49 s（每张约 27 ms），`_platform_memmove` 约 0.63 s。也就是转换本身的用户态 CPU 有七成花在
重复解析和重复拷贝上。`JPEGLayout.init` 慢在逐字节扫熵编码数据找下一个标记（要找到 EOI）。

## 2. 设计（已定）

1. **读一次、解析一次**：`convert` 里对 JPEG 源读一次文件、解析一次结构，得到一个值（名字自定，例如 `SourceJPEG`：
   字节 + `JPEGLayout?`），往下传给所有需要源字节或源结构的函数。`--verify` 的 `metadataDiff` 也用同一份（不要再读源）。
   函数签名改成接收它；原来接收 URL 或字节、自己去读去解的入口，只在确实没有现成值的调用方（如单测、RAW 路径）保留一个
   薄包装。解析失败（`JPEGLayout` 为 nil）时各处现有的退路不变。
2. **不再整份拷贝**：同一份字节在各处共用，不要每处 `[UInt8](data)`。读文件的方式（`mappedIfSafe` 与否）沿用现在
   源侧的做法；注意映射的文件在转换中途被删源（`--delete-original`）时的安全——删源在最后，删之前用完即可，写清楚。
3. **扫描提速（可选，量了再定）**：`JPEGLayout.init` 在熵编码段里找 `0xFF` 可以改用 `memchr` 之类批量找。要做的话，
   单测必须覆盖 `FF 00` 填充、`FF D0–D7` 重启标记、`FF FF` 填充、截断、EOI 之后的数据这些情形，结果与旧实现逐字段相同
   （可以在测试版里保留旧实现做对照）。量出来收益不到解析总时间的一半就不做。
4. 产物（HEIC）那一侧、RAW 那一侧的读文件不在这一轮范围内，除非顺手且零风险。

## 3. 验收标准

1. `make test` 全绿；计数变化逐条说明。
2. **解析次数要有测试守着**：测试版里给 `JPEGLayout.init` 加一个计数（只在 `-enable-testing` 的那份库里有，交付库里没有开销），
   断言一次 `convert`（分别在：默认、`--verify`、`--embed-caption`、`--no-raw-exif`、画质核对开/关）里对源 JPEG 只解析 1 次
   （HEIC 产物、内嵌 JPEG 之类另算，写清楚数的是什么）。读文件次数同理能守就守。
3. **零噪声**：12 张以上夹具（含相机样、CMYK、坏 ICC、多份 EXIF、MPF、辅助图、ISO 增益图、备注各写法、XMP 扩展、截断）
   用 main 和新版各跑 `-j 1 -v --verify`（再加一遍 `--no-raw-exif`、一遍 `--embed-caption`），产物逐字节相同、输出逐行相同。
   主会话会再跑 2907 个畸形样本和用户测试集。
4. **开销**：同一批夹具（含 18 张 6000×4000 相机样 JPEG），`--no-quality-check` 与默认各量三次取中位，给出用户态、墙钟。
   期望转换的用户态明显下降（主会话会在用户照片上复量）。
5. 变异，全部要红：某一处改回自己读文件/自己解析（解析计数断言要红）；`metadataDiff` 改回自己读源；扫描提速若做了，
   `FF 00` 处理错、重启标记处理错各一。
6. 只动 `Sources/Eclose` 里读源文件和调 `JPEGLayout` 的地方、测试；README 只在有对外可见的变化时改（应该没有）。

## 4. 不做的

- 不改任何报告规则、判据、输出文案。
- 不改编码路径、画质核对。

## 5. 交付报告

改了什么（新类型、改了哪些签名）、解析与读文件次数前后对比、扫描提速做没做及数据、开销实测、变异与结果、零噪声、风险点。
