# Glint 交接文档

更新于 2026-11-13，main 位于最后一次修改本文件的那个提交（`git log -1 -- HANDOVER.md`）。

---

## 一、需求总结

**产品**：Glint（中文名「吉光」），macOS 原生的照片格式转换工具。

- 技术约束：Swift + ImageIO + AppKit，零第三方依赖，只用 Command Line Tools 构建。
- 注释、输出、界面都用中文。

**转换模块 eclose（羽化）**：独立的 Swift 模块 `Eclose`，代码在 `Sources/Eclose`。

- `jpeg2heif`：JPEG 转 HEIF，完整保留元数据：
  - EXIF、GPS、IPTC、XMP；
  - 扩展属性、文件时间戳、访达备注与标签。
  - CMYK 的 JPEG 默认跳过，`--allow-cmyk` 强制转换。
- `raw2heif`：相机 RAW 转 HEIF。
  - 系统默认显影，产物 10 位。
  - RAW 原片永远不删（`--delete-original` 直接报错拒绝）。
  - 原始 EXIF 整块搬进产物。
- 删除源文件只对 JPEG，且要同时满足：校验无差异、产物不比原图大。

**图形界面 Glint.app**

- 三栏布局：浏览、查看、转换。
- JPEG 和 RAW 都能转，可以混在一批里。
- 只放在 `~/Developer/Glint.app`（`make install-dev`，与 Spark 同一做法），**不装进 /Applications**。
- 标识符 `local.minxu.glint`，可执行文件 `Glint`。
- 图标：极简线条羽毛加一颗星芒，两款——「浅色」（米白底、青到靛渐变线条，默认）和「渐变」（渐变底、白线条），用户在「Glint › 应用图标」里选（`Tools/make_icon.swift`、`Sources/GUI/AppIcon.swift`）。

**质量原则**

- `--verify` 宁可多报，绝不悄悄放过真实的元数据丢失。
- 功能坏了，测试必须变红。
- 没有真实数据支撑，就不加放行规则。
- 合并前必须用测试集原件验（`/Users/minxu/Developer/Taihe_HMOS/artifacts/TEMP测试集-20261111/`，带 `-r -o <临时目录>`），不能只用拷贝或自造的样本。

**隐私规则**

- 用户的照片、RAW 只在本机临时目录里用，不提交、不上传、不交给子代理。
- 测试样本不带人像；以家人名字命名的文件夹整个不取样。人像检测（Vision）漏判过小孩，不能当许可。
- 仓库是公开的（`github.com/minxu23/Glint`）：真实照片、照片里读出的名字、个人邮箱都不进仓库；
  测试要相机照片的结构时，照着它在 `Tests/CameraJPEG.swift` 里自造。

**工作方式**

1. 先测量，列出分级清单和建议，由用户划线。
2. 在 `.scratch/<功能>/` 写交接稿，派 Opus 在独立 worktree 里实现。
3. 主会话独立验收：
   - 干净副本跑 `make test`；
   - 自己改坏代码，确认测试变红；
   - 测试集原件、2907 个畸形样本，与上一版逐行比；
   - 真样本。
4. 验收通过后 ff 合并，清理 worktree 和分支，重新构建并放置应用。

---

## 二、前期工作小结

### 校验加固（第 17–25 轮）

交接稿在 `.scratch/verify-hardening/`。主要内容：

- EXIF 整块照搬：不再交给系统按字典重写。
- UserComment 的可靠读法与原文核对。
- XMP 按命名空间归一。
- 扩展属性纳入核对，系统管的属性（quarantine、provenance 等）跳过。
- 产物比原图大时重编一次。
- `--embed-caption`：把「照片」App 的说明写进 XMP。

### 界面与品牌

- 三栏界面：规格在 `.scratch/gui-redesign/`。
- 应用定名「吉光」，设计了图标；后来改名 Glint，图标换成极简风格的两款（`d285187`，并行会话做的）。
- 项目从 `~/Claude/jpeg2heif` 搬到 `~/Developer/Glint`；标识符改为 `local.minxu.glint`，设置已迁移。

### eclose 第 1 段（已合并，`c48b6bb` … `2e888c1`）

- 转换核心做成独立模块 Eclose：
  - 交付用的静态库只暴露 `public` 接口；
  - 测试用另一份带 `-enable-testing` 的库。
- 命令行拆成 `jpeg2heif`、`raw2heif`，`glint` 命令行取消。
- 应用改名 Glint.app，删除两份旧的吉光.app。
- RAW 管线：
  - ImageIO 系统默认显影；
  - 产物必须 10 位，否则失败；
  - 修整 CR3 被写坏的 ExifVersion、FlashPixVersion。
- RAW 校验：
  - RAW 结构字段（`{raw}`、`{DNG}`、CFAPattern 等）白名单不比，每类都写了理由；
  - 系统重写导致的 GPS 取整压成一行，偏差超过 1 米仍逐字段报。
- 测试现场生成 DNG 夹具（`Tests/DNG.swift`）。256×192 以上才会被 ImageIO 认作 RAW。

### eclose 第 2 段（已合并，`e03a0e9` … `f4d4d75`）

- **2a：RAW 的 EXIF 整块照搬**（`Sources/Eclose/CameraRawExif.swift`）
  - 各格式取 EXIF 的地方：
    - CR3：CMT1/CMT2/CMT4 盒子；
    - RW2：内嵌 JPEG 预览（JpgFromRaw）的 APP1；
    - DNG 等 TIFF 系：IFD0 指向的 Exif、GPS IFD。
  - 拼成干净的 TIFF 块：不带 MakerNote，也不带描述图像数据的标签。
  - 自检与 `--verify` 改成按字节比：ImageIO 读 RAW 和读 HEIC 的视图对同一组字节给出不同结果，比视图必然误报。
  - 根治了：GPS 取整、空值丢失、拍摄时区（OffsetTime）被 ImageIO 的 CR3 读法隐藏而悄悄丢失。
- **2b：Glint.app 转 RAW**
  - 图库认 RAW，「可以转换」和统计都算上 RAW。
  - JPEG 和 RAW 可以混在一批里转。
  - 删除只对 JPEG 生效，界面写明 RAW 原片始终保留。
  - RAW 缩略图优先用内嵌预览。
- **合并收尾**（`f4d4d75`）
  - 接在另一个会话提交的 CMYK 改动（`74e16b6`）之后。
  - RAW 的界面用例并回模型测试。
  - RAW 的「照片」说明也能写进文件。
  - 修了 `selftest.sh` 在 UTF-8 环境下被 `set -u` 中断的问题。

### 交接收尾（`f2854df` … `e330292`）

- 工具栏副标题：标题栏放不下时去掉「其中」那段，写成「6 张，共 339 KB」（用户选的写法）。
  - 判断放不放得下，问的是标题栏里 AppKit 实际排好的那个文本框（非公开接口）；找不到时照旧用完整写法。
  - 拖窗口、拖侧栏时重新挑写法，排完这一轮布局再挑。
  - 截图核对：900 宽显示短写法，1180 宽显示完整写法。
- 活动条：用 `uisnapshot --onscreen --convert` 截真实窗口，「转完 4 张，省下 181 KB。」和「好」按钮完整显示。
- 问题单结案（改为 resolved）：
  - `.scratch/eclose/` 的规格和三份交接稿；
  - `.scratch/gui-redesign/spec.md`，并补上应用名 Glint、界面转 RAW，`Sources/Core` 改为 `Sources/Eclose`；
  - `verify-hardening/issues/11-16`：根因是并发的两次测试共用 `Tests/.work`，`3bbf37d` 起每次运行用独立的 mktemp 目录；
  - `verify-hardening/issues/01-03`、`02-05`、`03-04`：9 个点逐条对照代码，都已落地。
- README：「把备注写进文件」的张数改成 JPEG 和 RAW 都数（`f4d4d75` 起就是这样，旧说法没改）。
- `encoder-variance/issues/01` 改为 wontfix。`.scratch` 里现在没有 needs-triage 的问题单，也没有 ready-for-agent 的文档。

### 整理与清理（`f4062e9` … `1b978e7`）

- 改写历史去掉误提交的 1.5 MB 二进制，备份和 `refs/original` 删除后 gc，详见下面「改写过历史」。
- `e03a0e9` 单独检出跑 `make test`：全部通过（673 项断言），计数与它自己写的一致，「计数可能对不上」不成立。
- 验收用的 3 个 CR3、1 个 RW2 和由它们转出的 18 个 HEIC 已从临时目录删除。
- 新图标（`d285187`）合进来后重新构建，放到 `~/Developer/Glint.app`，签名校验通过。
- 工作目录清理：`make clean`，删掉 `.DS_Store`、`test_pic/` 里两个旧的 HEIC 转换产物（`.JPG` 原件留着）、
  空的 `.claude/worktrees`，`git gc`。之后从干净状态重新构建，`make test` 全过。

### 自造样本与健壮性（`1ac84df` 起）

- 测试改用 `fixture --camera panasonic|canon` 自造的相机样本（`Tests/CameraJPEG.swift`，手搭 EXIF 与
  MakerNote、自带基线 JPEG 编码器出 4:2:2），真实照片从历史里去掉，详见「改写过历史」第二次。
- 边界情形扫了一遍（灰度、渐进式、1×1、奇数尺寸、9000×6000、空文件、文本冒充、DNG 改名 .CR3、
  方向 6、只剩文件头的 DNG），行为都正常。查出并修掉四处：
  - 截断的 JPEG（没有 EOI）原来转换、校验都「成功」，`--delete-original` 会删掉它；现在报
    「源文件不完整」，不删源（`728fdbb`）。
  - 截断的 RAW 原来报「HEIC 编码失败」；现在说清是读不出 RAW 的图像数据（`728fdbb`）。
  - 源是符号链接时，文件时间、扩展属性（访达备注与标签、「照片」的说明）读的是符号链接自己的，
    悄悄丢了、校验也发现不了，体积按几十字节算成「大 5000%」；现在解开符号链接再读，删源时不删
    （`ce11449`）。没有读权限、输出目录写不进时说清原因。
  - `--delete-original` 删不掉（源所在目录只读）原来一声不响；现在说「没能删除源文件：…」。界面
    原来自己推一遍删除规则，删失败或符号链接时会把还在磁盘上的源从图库拿掉；现在认 Eclose 报告里的
    `sourceDeleted`（`4e77aa7`）。

### 打断、输出路径与磁盘满（`0f903cd` … `a854414`）

- 转换被打断（Ctrl-C、kill、关掉终端）原来在输出目录里留下看不见的 `.glint-*.heic`；现在登记正在写的
  临时文件，打断时删掉、等正在编码的收手（最多 3 秒），说「已中断」，退出码 128 + 信号；nohup 照旧。
  应用在转换中途退出时同样清理。
- `make test` 原来不建应用本身，入口 `main.swift` 编不过也全绿；现在 Glint.app 在 ARTIFACTS 里。
- `-o` 收紧：多个输入给 `.heic` 文件名、给 `.jpg` 这类别的图片后缀、多个输入指向已有文件，都直接报错
  （原来分别是悄悄建目录、写出名叫 .jpg 的 HEIF、英文系统错误）。
- 卷满了：剩余空间不到源文件大小时报「磁盘空间不够」，ImageIO 写到一半的 `..glint-*.heic-XXXXXX`
  一并删掉。磁盘满的那条只手动量过（2 MB 磁盘映像），没有自动测试。

### 解不出的源与坏掉的 ICC（`d222804`）

- 「源解得出吗」原来看 `CGImageSourceCreateImageAtIndex` 拿不拿得到图，可它先不解码：量化表坏了的
  iPhone 照片照样给一张图，于是报「HEIC 编码失败」。现在真取一次像素（`imageDecodes`），报「读不出图像数据」。
- iPhone 写的 JPEG（JFIF 段末尾带 `AMPF`）里 ICC 坏了，ImageIO 一张图都解不出来；畸形样本里有 20 个这样的，
  原来都失败。现在去掉 ICC 再编一次，颜色按 sRGB 解释，报一条差异，`--delete-original` 不删源。这条差异
  只能由转换自己报：两边的色彩描述名都读成 sRGB，改坏代码去掉它时校验通过、源被删掉。
- 普通 JFIF 的 JPEG 里 ICC 坏了，ImageIO 不理会、照常按 sRGB 解码，原来悄悄换掉描述文件、校验通过。
  现在校验比描述文件的字节（`iccCarryIssue`），没原样搬过去就报。比之前把 Profile ID（第 84–99 字节，MD5）抹掉：
  ImageIO 写 HEIF 时把它清零，iPhone 照片的描述文件都带着它——第一版没抹，畸形样本里 185 张 iPhone 样本全部误报，
  是跑语料时发现的。现在测试集里 6 张带 ICC 的都不报；畸形样本只多报 1 张（标志位被改成 FF，产物里清成 0，确实变了）。
- 造样本：`mangle --break-icc`（描述文件签名改成 0，没有 ICC 就先插一份 Display P3）、`--icc-profile-id`
  （填上算对的 Profile ID）、`--apple-jfif`、`--dqt-clobber`。ImageIO 只在 iPhone 的 JFIF 段下才因坏 ICC、缺量化表解不出来，所以样本要配 `--apple-jfif`；
  系统的 sRGB 描述文件是 v2，签名、版本号改坏了照样解得出，所以插的是 v4 的 Display P3。

### 验收现状

| 项目 | 结果 |
|---|---|
| `make test` | 全绿：694 项断言，单测 1212 项，界面模型 319 项（也建应用本身） |
| 自己改坏代码 | 第 1 段 4 处、第 2 段 3 处、交接收尾 1 处（短副标题不去掉「其中」）、健壮性 1 处（不解开符号链接）、打断清理 2 处（去掉信号处理、去掉收尾等待）、坏 ICC 与解码判断 5 处（不真解码、不重编、不报去掉 ICC、不比 ICC 字节、不抹 Profile ID），测试都变红 |
| 真 RAW：3 个风景 CR3 + 用户指定的 RW2 | 都整块照搬；`--verify` 只剩 MakerNote 一行（已知局限）；CR3 的 39 条 EXIF、12 条 GPS 与源逐字节相同 |
| JPEG 路线 | 与 `fe8734c` 比：测试集原件 `-v --verify` 的输出逐行相同。2907 个畸形文件（单线程，标准输出、错误输出分开比）只有预期的不同：122 条「源文件不完整」（89 张原来校验通过）；20 张坏 ICC 的从失败变成转出并报差异；581 张解不出的失败原因从「HEIC 编码失败」变成「读不出图像数据」；ICC 字节比对多报 1 张（见上） |
| 内存 | 单张 CR3 峰值约 1.2 GB；10 个 RAW 按默认并发 4 转，峰值约 4 GB（本机 48 GB） |
| Glint.app | 按 `d222804` 的代码重新构建，放在 `~/Developer` |
| 工作目录 | 只有 `main`，没有 worktree、没有未提交的改动，没有推送过；`.scratch` 里没有 needs-triage 或 ready-for-agent 的单子 |

---

## 三、待完成工作小结

### 要用户做的

0. **推送到 GitHub**：远端 `origin` 已配好（`https://github.com/minxu23/Glint.git`，公开仓库，目前是空的），
   本机钥匙串里没有 GitHub 凭据，会话推不上去。在终端里跑 `git push -u origin main`，按提示登录。

### 要用户在真实窗口里做的

1. 用一批 JPEG + RAW 的拷贝，勾「校验无差异后删除源文件」转一遍：JPEG 被删，RAW 留着，提示语写明 RAW 原片保留。
2. 拖窗口宽度、拖侧栏，看副标题在完整写法和短写法之间切换正常。
3. 「Glint › 应用图标」切换两款图标，看程序坞（运行中、没运行）和访达里都换上；选回「浅色」应用包恢复原样。
   图标是并行会话做的，它在真实窗口里看过没有，这里没有记录。

交接收尾的会话没有操作屏幕的工具，这几项都没做。`uisnapshot --onscreen` 能截真实窗口，但截图工具不支持勾删除，也不会拖窗口。

### 需要真实样本才能确认的

4. CR2、NEF、ARW、PEF、SRW、ORF、RAF 的 EXIF 照搬只用手搭样本测过，没有真样本。有合适的无人像样本时再验。拼错的话自检会退回系统重写，不会写坏文件。
5. CRW、MRW、X3F、IIQ 等格式还不能整块照搬 EXIF，走系统重写。

### 已知局限，暂不处理

6. 厂商私有数据（MakerNote）系统读不出也写不进 HEIF，校验照实报一行。
7. RAW 旁边的 .xmp 附属文件不合并（用户的文件夹里没有）。
8. RAW 和同名 JPEG 转出同名的 HEIF 时，后转的按「输出已存在」跳过；要两份就用 `-o` 分开目录。
9. 动态照片的视频、EOI 之后的厂商私有数据不进产物，`--verify` 照实报出。手机 HEIC 怎么存这些（Android Motion Photo 规范的 `mpvd` 盒子等）没核实过，要做得先拿真机样本。
10. 选了「渐变」图标后，应用包上有自定义图标，严格的签名校验不过（本机编译的应用照常打开；`make` 签名前会先去掉，下次启动再补上）。见 README「应用图标」。

### 收尾小事

11. 只用第 1 段那版转过的 CR3 缺拍摄时区；如有需要，用现在的版本重转一次（验收用的那 3 个 CR3 已删）。
12. ~~推送前要处理的两件事（真实照片、作者邮箱）~~：已处理，见下面「改写过历史」第二次。远端是
    `https://github.com/minxu23/Glint`（公开仓库）。

---

## 常用命令

```bash
make test          # 全套测试
make all           # 编两个命令和 Glint.app
make install-dev   # 把 Glint.app 放到 ~/Developer
./raw2heif -v --verify -o <输出目录> <RAW 文件或目录>
./jpeg2heif -r -v --verify -o <输出目录> <JPEG 目录>
```

## 改写过历史

2026-11-13 用 `git filter-branch` 从 `bc8bcf7` 起的 10 个提交里去掉了误提交的 `Tests/guiraw-test`（1.5 MB）：
只删了它的那个提交（原 `16a0dcd`）整个消失，其余 9 个换了哈希（原 `bc8bcf7` → `f4d4d75`，`4e3fd5a` → `f2854df`，
`6278474` → `e330292` 等），代码树与改写前逐字节相同。文档里引用的哈希已改成新的；改写之前写的提交说明里
可能还引用旧哈希（例如 `64350e6` 说明里的 `bc8bcf7`），对照上面这几对看。备份分支和 filter-branch
留下的 `refs/original` 已删除并 `git gc --prune=now`，二进制已从仓库里彻底消失（`.git` 14 MB → 10 MB）。

2026-11-14 第二次改写（推送到公开仓库之前），整段历史 118 个提交全部换了哈希：
- 去掉两张真实照片 `test_pic/*.JPG`；测试改用 `fixture --camera panasonic|canon` 自造的相机样本
  （`Tests/CameraJPEG.swift`），照片本身留在本机 `test_pic/`，整个目录不入库（`.gitignore`）。
- 照片里的作者名换成占位名 `Zhang San;Li Si`（README、selftest.sh、第 13 轮交接稿里引用过）。
- 6 个提交的作者邮箱是个人邮箱，改成与其余提交相同的 `Min Xu <minxu@MacBook-van-Min.local>`。
- 代码树与改写前逐字节相同；文档里引用的提交哈希按新旧对照换成了新的。提交说明里写的哈希没法改，
  是改写前的（例如上面第一次那几对里的旧哈希），以文档为准。
- 改写之前的提交单独检出时，`selftest.sh` 还在拷 `test_pic/` 里的照片，照片不在就跑不通；
  只有 `1ac84df`（测试改用自造样本）之后的提交能直接 `make test`。

## 注意事项

- HEIC 编码不是逐字节确定的：别的进程同时在编码时会改走软件编码器。逐字节比较前确认没有别的转换或测试在跑。
- 同一目录不要同时跑两个 `make test`。
- make 的时间戳陷阱：用 `cp` 恢复文件后要 `touch`，并确认日志里有对应的 `swiftc` 行。
- 子代理不在主仓库里构建或测试；测试不写真实设置域 `local.minxu.glint`。
- 可能有别的会话也在这个仓库里提交（CMYK、交接收尾、图标都是并行会话做的），开工前先看 `git log` 和 `git status`。
- 工作目录清理过，构建产物不在：开工先 `make all`（`make test` 会自己构建它要的）。
- 想看真实窗口：`./Tests/uisnapshot <输出.png> --onscreen [--convert] <目录>`，要屏幕录制权限。
