# eclose 第 2 段 b：Glint.app 里 RAW 也能转

Status: ready-for-agent

先读同目录的 `spec.md`（用户拍板）和 `stage-1-handoff.md`（第 1 段做了什么），再读 `.scratch/gui-redesign/spec.md`（界面规格，界面的设计语言以它为准）、`Sources/GUI/` 全部、`Sources/Eclose/SourceKind.swift`、`Sources/Eclose/Batch.swift` 的公开部分。

## 背景

第 1 段把转换核心做成了模块 Eclose，命令行拆成 `jpeg2heif` / `raw2heif`，RAW 走系统默认显影、产出 10 位 HEIF、**永不删除 RAW**。界面（Glint.app）还只认 JPEG：`Library.swift` 的 `isJPEG`、「可以转换」筛选只收 JPEG；`ConversionRecord.swift` 的范围、标题「转换 N 张 JPEG」；`BrowserViewController` 里有 JPEG 才能点「转换…」；`ConversionSheet` 的「校验无差异后删除源文件」。

用户拍板：本轮界面里 RAW 也能转；RAW 不给删除。

交接稿写完之后又加了一条：CMYK 的 JPEG 默认跳过（`ConversionOptions.convertCMYK`，命令行 `jpeg2heif --allow-cmyk`）。界面上是转换面板「高级」里的「也转 CMYK 的 JPEG」，不记住；`ConversionTargets.cmykCount` / `cmykHint` 按 `PhotoInfo.isCMYK` 数这批里有几张，有就展开「高级」。改范围和标题时别把这一项丢了；它只对 JPEG 有意义，RAW 没有 CMYK 一说。

## 要做的

1. **图库认 RAW**：按 Eclose 的 `SourceKind`（与命令行同一份判定、同一份扩展名清单）分出 RAW；「可以转换」筛选、工具栏副标题（`248 张，其中 JPEG 196 张、RAW 30 张，共 612 MB` 这样）、按格式的统计行都认 RAW；格式名显示成相机 RAW 的具体类型（CR3、NEF、ARW、DNG……）或统一「RAW」，二选一，与界面规格的写法一致并说明。
2. **转换范围与面板**：
   - 选中/当前视图里的 JPEG 和 RAW 都能转，一批里可以混着；标题和说明跟着改（`转换 12 张（JPEG 8 张、RAW 4 张）` 这类，措辞自己定，照现有风格）。
   - 转换时把 `ConversionOptions.sources` 设成两种都要，每个文件由 Eclose 按类型分派。
   - 「校验无差异后删除源文件」：**只对 JPEG 生效**。批里有 RAW 时，选项文字或旁边的说明要让人看懂「RAW 原片始终保留」；只有 RAW 时这个选项不出现或明确写「RAW 不删除」（尽量不用灰掉的控件——界面规格偏好可用的控件加说明）。勾了删除也绝不能让 RAW 被删——Eclose 那层已经挡了（`RAW 原片永远保留，没有删除`），界面这层也要有测试钉住。
3. **记录与信息栏**：转换记录、结果汇总认 RAW（`N 张有差异` 等照旧）；信息栏里 RAW 条目显示得出相机、拍摄参数等（ImageIO 读得出的都显示），转出的 HEIF 标「10 位」之类的说明如果界面规格里有合适的位置就加，没有就不加。
4. **缩略图**：ImageIO 对 RAW 出缩略图，确认不慢到卡界面（大 CR3 有内嵌预览，用 `kCGImageSourceCreateThumbnailFromImageIfAbsent` 一类的选项别强制全幅显影）。

## 测试

- `Tests/guimodel`：图库分类、筛选、副标题计数、转换范围（混合选择）、删除选项对 RAW 不生效、RAW 永不删除——都用界面模型层测，存储用注入的字典（**不要碰真实设置域 `local.minxu.glint`**）。
- 需要真 RAW 文件的测试用 `Tests/DNG.swift` 现场生成的 DNG（256×192 以上才被认作 RAW；更小的会被当 TIFF——别踩）。
- `Tests/snapshot`（离屏截图工具）：混合选择时的转换面板、RAW 条目的信息栏，各出一张图，交付时附路径。**注意**：以前离屏截图掩盖过真实窗口里的裁切问题（信息栏被截、分栏宽度不对）。截图要在几个窗口尺寸下出（最小窗口、默认、宽屏），自己看图确认没有截断、重叠；做不到真实窗口验证就在交付说明里写明，主会话来验。
- 变异（交付说明列出，每条都要变红）：「可以转换」不收 RAW、删除选项对 RAW 生效（界面层）、副标题不数 RAW、混合批只转 JPEG。
- 更新 `EXPECTED_GUI` 等计数。

## 约束

- 只在你的 worktree 里构建、测试；不碰主仓库 `/Users/minxu/Developer/Glint`。
- **另一个代理（2a，RAW 的 EXIF 整块照搬）同时在另一个 worktree 里改 `Sources/Eclose`、`Sources/CLI`、`Tests/unit`、`Tests/selftest.sh`、`Tests/DNG.swift`。你不要改这些文件**；改动集中在 `Sources/GUI`、`Tests/guimodel`、`Tests/snapshot`、README 的界面部分。如果 Eclose 的公开接口不够用，停下来在交付说明里写清楚缺什么，不要自己改 Eclose。
- 不读、不拷用户的任何照片或 RAW，不下载任何东西。
- 不启动真实的 Glint.app 去操作用户的图库；不安装应用（不跑 `make install-dev`）、不 push、不合并到 main。
- 另一个代理可能同时在跑 `make test`；HEIC 编码不是逐字节确定的，看到无关的产物差异先串行重跑再下结论。
- make 时间戳陷阱：`cp` 恢复后 `touch`，确认日志里有对应的 `swiftc` 行。
- 中文注释与界面文字，风格照现有代码与界面规格；零第三方依赖。每个提交 `make test` 全绿；提交信息结尾 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 交付说明

1. 分支与提交列表。
2. 界面上改了哪些文字（旧 → 新）。
3. 截图路径（各窗口尺寸），以及你看图确认了什么。
4. 变异清单与结果。
5. 最后一次 `make test` 计数行。
6. 需要主会话在真实窗口里验的东西。
