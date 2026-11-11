# 第 17 轮交接稿：把 ImageUniqueID 补进产物

工作规则、长期要求、变异与 mtime 陷阱的注意事项，全部沿用
[`round-12-handoff.md`](round-12-handoff.md) 的第 0 节，先读那一节。另加一条：变异后用
`cp -p` 从快照还原，会连旧 mtime 一起还原，make 不重编，下一次测的还是变异版——还原后
`touch` 源文件，并确认那次 `make test` 里有 swiftc 那行。

## 交接方量到的事实（main = 0bfa5b9）

量具在 [`round-17-repro/`](round-17-repro/)，只供参考写法，测试不得依赖。

### 1. ImageIO 只认长度恰好 33 字节的 ImageUniqueID

ExifIFD 0xA420，规范是定长 ASCII，33 字节（32 个字符加 NUL）。用 exiftool 往同一张照片
写不同的值，看 ImageIO 视图（`{Exif}/ImageUniqueID`）和现行版本转出的 HEIC：

| 写入的值 | 字节数 | ImageIO 视图 | 产物里 |
|---|---|---|---|
| `0123456789abcdef0123456789abcdef` | 33 | 有 | 有，值相同 |
| 同上大写 | 33 | 有 | 有 |
| `0123456789abcdef0123456789abcdeX`（不是十六进制） | 33 | 有 | 有 |
| `abc` | 4 | **无** | **无** |
| `0123456789abcdef` | 17 | **无** | **无** |
| `J12LLKF00SM J12LLKL01GM` | 24 | **无** | **无** |
| 36 个字符 | 37 | **无** | **无** |
| `OPPO_20201019_204116_0001` | 26 | **无** | **无** |

判据就是长度，与内容无关。现行版本的原始清点已经把它报成
`丢失 EXIF 标签 ImageUniqueID（ExifIFD 0xA420，ASCII，"…"）——ImageIO 没有把它写进产物`，
没有静默；这一轮是把它搬过去。

### 2. 写入器什么长度都照写

属性字典里放 `kCGImagePropertyExifImageUniqueID`，HEIC 写入器（JPEG 写入器也一样）照写，
存成"值的 UTF-8 字节 + 一个 NUL"：`abc` → 4 字节，`J12LLKF00SM J12LLKL01GM` → 24 字节，
`唯一标识` → 13 字节。所以用 ImageIO 写 JPEG 就能造出见证样本（`round-17-repro/iw2.swift`，
把 heic 换成 jpeg 即可）。

### 3. 原始清点对非 GPS 标签只看有没有，不比值

`compareRawExif` 只有 GPS 分数是逐值比的，其余标签只看产物里有没有同号条目。产物一侧的
ImageIO 视图同样读不出非 33 字节的 ImageUniqueID，所以补进去之后，**值写对没有，现在没有
任何一处在核对**。

## 要做的

### A. 转换时补上

照 UserComment 的先例（`Converter.swift` 里 `rawExifUserComment` 那条路）：源里有 0xA420，
而 ImageIO 视图里没有 `{Exif}/ImageUniqueID` 时，从原始字节取出值，放进属性字典。

- 值取到第一个 NUL 为止（没有 NUL 就取满 count）。
- 字节不是合法 UTF-8 时不补——写不回原样，就让校验照报丢失。
- 源里 0xA420 不是 ASCII 类型、或同号条目不止一个时不补，照报。拿不准就不补。
- ImageIO 自己读得到（33 字节）时什么都不做：这类输入的产物必须与修改前逐字节相同。

### B. 按原始字节核对值

源 view 里没有、靠 A 补进去的 ImageUniqueID，要按原始字节比较源和产物的值（同 A 的取值规则），
不一致就报 `变化 EXIF 标签 ImageUniqueID：… → …`。规则写成"源一侧 ImageIO 读不到、两边原始
条目都在的标签逐值比"还是只针对 0xA420，你定，但要说明为什么；前者的话零噪声测试要覆盖到。

### C. 文档

README 的 `## 保留了哪些元数据`、`## 已知限制`（如果那里提到了它）、`## --verify 到底比什么`
按做完后的行为改写。只写现在的行为。

## 验证方案

1. **见证**：夹具加一个选项，用 ImageIO 写出带非 33 字节 ImageUniqueID 的 JPEG（至少
   `J12LLKF00SM J12LLKL01GM` 和一个含非 ASCII 字符的值）。断言：源的 ImageIO 视图里没有它
   （前提）；产物原始 EXIF 里有，值逐字节等于源；`✓ 元数据校验通过`；`--delete-original` 删源。
2. **不补的情形**：用 `mangle` 造非法 UTF-8 的值、非 ASCII 类型的 0xA420 → 照报丢失，源文件保留。
3. **33 字节的值**：产物与修改前逐字节相同，校验输出不变。
4. **变异**（每条亲眼看红）：
   - 去掉 A 的补写 → 第 1 项红；
   - A 写进去的值故意改一个字符（例如末尾加个空格）→ B 抓住，第 1 项红；
   - B 去掉 → 上一条变异下变绿（说明它是唯一的守门人），恢复后红回来；
   - A 去掉"非法 UTF-8 不补"的判断 → 第 2 项红（或说明为什么不会红、改用什么断言兜住）。
5. **零噪声**：六种夹具、`test_pic/` 两张、第 15/16 轮的辅助图与原始清点见证，`--verify`
   输出不得多出任何一行；源里没有 0xA420 或 ImageIO 读得到它的输入，产物逐字节相同。
6. **健壮性**：0xA420 的 count 离谱、偏移指向 EXIF 外、长度 0，都不能崩，也不能因此吞掉差异。

## 交接方顺带量到、这一轮不做的

记在这里，交付报告里不用处理，留给用户决定：

- Exif 2.32 / 3.0 的新标签（0x9400–0x9405 温度、湿度、气压、水深、加速度、仰角；
  0xA436–0xA43C ImageTitle、Photographer、ImageEditor、CameraFirmware、
  RAWDevelopingSoftware、ImageEditingSoftware、MetadataEditingSoftware）：ImageIO 不认，
  原始清点照报丢失，但报告行里名字显示成「未知标签」。
- 规范写法（UNDEFINED 带字符集头）的 GPSProcessingMethod、GPSAreaInformation：ImageIO 读得到，
  但写不进 HEIC，校验照报丢失。
- IFD0 的 PageName：ImageIO 不读，照报。
- 用 exiftool 规范写入的 CameraOwnerName、BodySerialNumber、LensSerialNumber、LensMake、
  LensModel、LensSpecification、CompositeImage 等约 30 个标准标签，现行版本都完好带过去了。

## 交付报告

提交 SHA；A–C 各做了什么；B 选了哪种规则及理由；每张见证的断言结果；每条变异与红线；零噪声
与产物不变性；三个计数及增量来源（现为 197 / 418 / 48）；未处理的发现；没完成或没覆盖到的。
