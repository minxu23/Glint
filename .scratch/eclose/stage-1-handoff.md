# eclose 第 1 段交接稿

Status: resolved

先读 `spec.md`（同目录）：用户的拍板与主会话的实测都在那里，本稿不重复。再读仓库根的 `CLAUDE.md`、`README.md`、`GLOSSARY.md`、`docs/adr/`。

## 目标

1. **eclose 成为真正独立的 Swift 模块**
2. **两个命令** `jpeg2heif`、`raw2heif`，取消 `glint` 命令行
3. **应用改名 Glint**
4. **RAW→HEIF 管线**（系统默认显影、10 位、永不删 RAW）
5. **CR3 版本号修整**
6. **RAW 的校验规则**
7. **自造 DNG 的测试**

第 2 段（RAW 的 EXIF 整块照搬、GUI 转 RAW）**不在本段**，但本段的接口要给它们留好位置（见各节）。

## 1. 模块

- `Sources/Core` → `Sources/Eclose`（`git mv`，保留历史），模块名 `Eclose`。
- 编成真正的模块：`swiftc -parse-as-library -emit-module -emit-library -static -module-name Eclose`（或等价做法）产出静态库 + `.swiftmodule`；两个命令和 Glint.app 用 `import Eclose` 链接它，**只能用 `public` 的东西**。构建产物放在一个被 `.gitignore` 的目录（如 `build/`），`make clean` 清掉。
- 公开面要小而完整：转换选项、两种转换的入口（或一个按源类型分派的入口）、批处理（收集输入、分配输出、并发执行、取消）、转换结果/报告/校验结果、`humanSize` 这类界面和命令行都要用的小工具。其余保持 `internal`。界面（`Sources/GUI`）现在直接用到的 Core 符号，逐个决定是公开还是换成更高层的接口——别为了编过就把整个模块 `public` 一遍。
- 测试可以用 `@testable import Eclose`（模块加 `-enable-testing`），或者测试工具继续直接编 Eclose 源码——选一种，Makefile 里写清理由。**要求**：`make test` 里至少有一个产物是通过 `import Eclose`（非 testable）编出来的，保证公开面真的够用。
- Makefile 的 `.SECONDEXPANSION` / `TOOL_SRC` / `ARTIFACTS` 那套依赖规则保留其意图：改了 Eclose 源码，所有依赖它的产物都要重建（库 → 命令 → 应用 → 测试工具），不能出现「改了源码不重建」。

## 2. 两个命令

- `Sources/CLI` 按需改成两个入口（如 `Sources/CLI/jpeg2heif/main.swift`、`Sources/CLI/raw2heif/main.swift`）+ 共用的参数解析（`Arguments.swift`，仍不碰 `CommandLine`、不 `exit()`，好链进测试）。
- `jpeg2heif`：行为与现在的 `glint` 逐字节一致（选项、输出、退出码），只是名字变了。用法里的命令名跟着变。
- `raw2heif`：选项与 `jpeg2heif` 相同，除了：
  - `--delete-original`（及任何删除源文件的写法）**报错退出**，错误文字说明「raw2heif 不删除 RAW 原片」，不做任何转换。
  - 其余（`-r -o -f -j -q --verify --embed-caption -n -v --no-raw-exif …`）语义相同。`--no-raw-exif` 本段对 RAW 无实际作用（照搬在第 2 段），用法里注明或暂不列出，二选一并说明。
  - 默认并发数：**先量**（`/usr/bin/time -l` 看峰值内存，用自造的大 DNG 或多份小 DNG 测不出真实 RAW 的量级——见末尾「需要主会话量的」），本段先用一个保守值（如 `min(核数, 4)`），在代码注释里写明理由与待主会话实测。
- 两个命令各自只收自己的源类型；收到另一种时的跳过提示要指路，如 `跳过 x.CR3: 是 RAW 文件（用 raw2heif）`、`跳过 x.jpg: 是 JPEG 文件（用 jpeg2heif）`。
- 目录扫描（`collectInputs`）：jpeg2heif 照旧按扩展名；raw2heif 用一份 RAW 扩展名清单（CR2 CR3 CRW NEF NRW ARW SRF SR2 RAF ORF RW2 RWL DNG PEF SRW 3FR IIQ ERF MEF MOS X3F…，以 ImageIO 支持为准），**但是否转换按内容判定**：`CGImageSourceGetType` 的 UTType 符合 `public.camera-raw-image` 才转（小于门槛的 DNG 会被识别成 `public.tiff`，要按「不是 RAW」跳过而不是转出 8 位预览图）。
- Makefile：`BIN` 拆成两个目标；`install-cli` 装两个；`uninstall` 相应改。

## 3. 应用改名 Glint

- `APP_NAME := Glint`、`Sources/GUI/AppName.swift` 的 `appName = "Glint"`；应用包 `Glint.app`，可执行文件仍是 `Glint`，`CFBundleIdentifier` 仍是 `local.minxu.glint`（**不改**，用户设置不用迁）。
- 用户不把应用装进 /Applications，只放 `~/Developer`（`make install-dev`）。**删掉** Makefile 里往 /Applications 装应用的 `install-app`（`install` 只装命令行；`uninstall` 不再碰 /Applications）。`install-dev` 保留。
- README、CLAUDE.md、用法文字、界面里出现的「吉光」改成 Glint；README 可以保留一句「中文名吉光」。测试里断言应用名的地方跟着改。
- `.scratch/` 里的历史文件不改。
- **不要**真的跑 `make install-dev`、不要往 `~/Developer` 或 `/Applications` 放东西（主会话合并后做）。

## 4. RAW→HEIF 管线

- 编码：`CGImageDestinationAddImageFromSource(rawSource, 0, props)` → `public.heic`，质量用 `opts.quality`。产物必须 `Depth` = 10；写完读回确认，不是 10 位就算失败（别静默交出 8 位）。
- 方向：标签照抄，像素不转。
- 「产物比源大就重编一次」那条规则对 RAW 不适用（RAW 转出来总是小很多），确认不会误触发；如果代码路径共用，用测试钉住。
- 时间戳、扩展属性（共用 `skippedXattrs`）、`--embed-caption`（照片说明写进 XMP `dc:description`）、`-n`、`-f`、`-o` 镜像目录：与 JPEG 路线同一套实现，不要复制一份。
- JPEG 专有的步骤（JPEG 结构解析、APP 段、UserComment 修补、EXIF 整块照搬）对 RAW 跳过；跳过要显式（按源类型分派），不能靠「解析失败就算了」。
- **给第 2 段留位置**：「编码之后、校验之前，对产物做一次 EXIF 处理」的那一步，对 RAW 先是空操作（或只返回「本段未实现」的结果），第 2 段往里填。

## 5. CR3 版本号修整

- 写入前整理属性字典：`{Exif}/ExifVersion`、`{Exif}/FlashPixVersion` 若是 ASCII 数字字符码数组（如 `[48,50,51,49]`），换成写入器能正确往返的形式（RW2 实测 `[2,3]` / `[1,0]` 能往返；具体怎样才能让产物读回与源等价，**自己量**，测试钉住）。
- `{GPS}/GPSVersion` 被写入器丢掉：设法写回（量出写入器认的形式）；写不回就让校验如实报。
- 校验仍按**源的原值**比；修整没修好就报出来，不能因为「我们修整过」就不比。
- 手写 DNG 复现不了 CR3 的这个问题，所以单元测试直接喂属性字典（`[48,50,51,49]` 等）给修整函数，并做一次「修整后的字典 → 写 HEIC → 读回」的往返断言。

## 6. RAW 的校验规则

- 对 RAW 源，`metadataDiff` 不比下面这些**结构字段**，每一类在代码里写一行理由（HEIC 是显影后的图像，这些描述的是传感器原始数据或 RAW 容器本身）：
  - `{raw}/…`
  - `{DNG}/…`
  - `{Exif}/CFAPattern…`
  - `{TIFF}/BitsPerPixel…`、`{TIFF}/Width`、`{TIFF}/Height`
  - `XMP/tiff:Compression`
  白名单只放这些实测过的；任何别的新放行都要有真实数据支撑并在交付说明里列出。**不放行**：GPS、版本号、`CameraOwnerName`（哪怕是空串——第 2 段照搬后会保住；本段如实报）、MakerNote 那一行（照旧报）。
- **GPS 取整压成一行**（用户拍板）：经纬度（`{GPS}/Latitude`、`Longitude`，以及由它们派生的 XMP `exif:GPSLatitude`/`GPSLongitude`/`…Ref` 写法变化）只差在取整范围内时，不逐字段报，改报一行，如 `GPS 精度降低：最大偏差 3 厘米（ImageIO 写入时取整）`。
  - 偏差按真实距离算（纬度差 × 111 km；经度差 × 111 km × cos 纬度），取整到厘米。
  - 「取整范围」的上限要严：超过约 1 米、或方向（N/S/E/W）变了、或一边有一边没有，都按原来的逐字段报。这条规则只能把「几厘米的取整」压成一行，不能吞掉真的坐标改动。
  - 这一行算差异（`--verify` 的结果是有差异），不是静默放行。
  - 第 2 段照搬成功后这一行自然消失；本段要用测试钉住「坐标真改了（如 0.01°）仍逐字段报」。
- JPEG 专有的核对（UserComment 原文、EXIF 文本原文、JPEG 布局等）对 RAW 源不跑；跑不了的原因要显式（按源类型），不是读不通就跳过。
- 校验额外核对：产物 `Depth` = 10；产物像素宽高与源一致（不考虑方向）；方向标签一致。

## 7. 测试

- **夹具生成器**：把 `dng-reference.swift` 的做法搬进测试夹具（`Tests/fixture.swift` 或新文件），测试时现场生成，**不提交二进制 RAW**。至少：
  - 256×192 拜耳 DNG，方向 1 和 6；带拍摄时间、作者/版权/说明、GPS（秒带小数，好暴露取整）。
  - 一个低于门槛的小 DNG（64×48），断言 raw2heif 把它当「不是 RAW」跳过。
- **端到端**（`selftest.sh`）：
  - raw2heif 转夹具：产物 `Depth` 10、宽高、方向（方向 6 不被转两遍）；`--verify` 的输出**恰好**是预期的那几行（GPS 一行 + 结构字段之外没有别的）——用精确断言，不要「包含」。
  - `--delete-original` 报错、RAW 原样还在、没有产物。
  - 混合目录：jpeg2heif 跳过 RAW 并指路、raw2heif 跳过 JPEG 并指路。
  - jpeg2heif 与改名前的 `glint` 行为一致：现有全部断言照旧过（只改命令名）。
- **单元**：版本号修整（第 5 节）、GPS 一行的判定（取整内 → 一行；1 米以上/换方向/一边没有 → 逐字段）、RAW 结构字段白名单（白名单外的字段照报）、输入判定（类型符合 `public.camera-raw-image` 才转）。
- **变异**：交付说明里列出你做过的变异（至少：删掉版本号修整、放宽 GPS 上限到 1 km、把白名单扩到 `{GPS}`、去掉 Depth 10 检查、让 raw2heif 接受 `--delete-original`、门槛下的 DNG 被当 RAW 转），每条都要让测试变红。
- 更新 `EXPECTED_ASSERTIONS` / `EXPECTED_UNIT` / `EXPECTED_GUI` 等计数。

## 约束（必须遵守）

- 在你的 worktree 里工作；**不要**在主仓库 `/Users/minxu/Developer/Glint` 里构建或跑测试。同一目录不要同时跑两个 `make test`。
- **不要**读、拷、上传用户的任何照片或 RAW 文件（`~/Pictures`、测试集目录、主会话的临时目录都不碰）。测试只用现场生成的夹具。不下载任何东西。
- 测试不得写用户真实的应用设置（`local.minxu.glint` 域）；需要设置的测试用独立的测试域，结束时清掉。
- HEIC 编码不是逐字节确定的：别的进程同时在编码时，部分图会改走软件编码器、产物大小变化。逐字节比较产物前确认没有别的转换或测试在跑；看到大批无关产物不同，先串行重跑再下结论。
- make 的时间戳陷阱：用 `cp` 恢复文件后要 `touch`，改完源码确认日志里有对应的 `swiftc` 行，必要时 `sleep 2` 再改。
- 代码注释、输出、文档用中文，风格照现有代码。零第三方依赖，只用 Command Line Tools。
- 分几个提交（如：模块化 / 两个命令 / 改名 / RAW 管线 / 校验规则 / 测试），每个提交 `make test` 全绿。提交信息结尾：
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- 不要 push，不要合并到 main。

## 交付说明（完成时回报）

1. 分支名与提交列表。
2. 模块的公开面清单（每个 `public` 符号一行，说明谁用它）。
3. Makefile 的构建图（谁依赖谁），以及「改 Eclose 一个文件 → 哪些产物重建」的实测日志摘要。
4. 版本号修整：量出的写入器认的形式、往返结果。
5. RAW 校验白名单与 GPS 一行规则的最终形式；对夹具的 `--verify` 完整输出。
6. 变异清单与结果。
7. `make test` 最后一次的计数行。
8. 需要主会话用真 RAW 量的东西（至少：raw2heif 默认并发数的峰值内存、CR3 版本号修整在真 CR3 上的结果、GPS 一行在真样本上的偏差数值）。

## Comments

2026-11-13：已实现并合并到 main（`c48b6bb` … `2e888c1`），验收结果见仓库根目录的 HANDOVER.md。
