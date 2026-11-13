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
- 应用定名「吉光」，设计了图标。
- 项目从 `~/Claude/jpeg2heif` 搬到 `~/Developer/Glint`；标识符改为 `local.minxu.glint`，设置已迁移。

### eclose 第 1 段（已合并，`5ccab4b` … `2612c46`）

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

### eclose 第 2 段（已合并，`72e82ab` … `3db17b5`）

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
- **合并收尾**（`3db17b5`）
  - 接在另一个会话提交的 CMYK 改动（`922a2c7`）之后。
  - RAW 的界面用例并回模型测试。
  - RAW 的「照片」说明也能写进文件。
  - 修了 `selftest.sh` 在 UTF-8 环境下被 `set -u` 中断的问题。

### 交接收尾（`9d878de` … `38a0065`）

- 工具栏副标题：标题栏放不下时去掉「其中」那段，写成「6 张，共 339 KB」（用户选的写法）。
  - 判断放不放得下，问的是标题栏里 AppKit 实际排好的那个文本框（非公开接口）；找不到时照旧用完整写法。
  - 拖窗口、拖侧栏时重新挑写法，排完这一轮布局再挑。
  - 截图核对：900 宽显示短写法，1180 宽显示完整写法。
- 活动条：用 `uisnapshot --onscreen --convert` 截真实窗口，「转完 4 张，省下 181 KB。」和「好」按钮完整显示。
- 问题单结案（改为 resolved）：
  - `.scratch/eclose/` 的规格和三份交接稿；
  - `.scratch/gui-redesign/spec.md`，并补上应用名 Glint、界面转 RAW，`Sources/Core` 改为 `Sources/Eclose`；
  - `verify-hardening/issues/11-16`：根因是并发的两次测试共用 `Tests/.work`，`10c2dfd` 起每次运行用独立的 mktemp 目录；
  - `verify-hardening/issues/01-03`、`02-05`、`03-04`：9 个点逐条对照代码，都已落地。
- README：「把备注写进文件」的张数改成 JPEG 和 RAW 都数（`3db17b5` 起就是这样，旧说法没改）。
- `encoder-variance/issues/01` 改为 wontfix。`.scratch` 里现在没有 needs-triage 的问题单，也没有 ready-for-agent 的文档。

### 验收现状

| 项目 | 结果 |
|---|---|
| `make test` | 全绿：671 项断言，单测 1199 项，界面模型 312 项 |
| 自己改坏代码 | 第 1 段 4 处、第 2 段 3 处、交接收尾 1 处（短副标题不去掉「其中」），测试都变红 |
| 真 RAW：3 个风景 CR3 + 用户指定的 RW2 | 都整块照搬；`--verify` 只剩 MakerNote 一行（已知局限）；CR3 的 39 条 EXIF、12 条 GPS 与源逐字节相同 |
| JPEG 路线 | 与改动前的版本比，测试集原件和 2907 个畸形文件的输出逐行相同（第 2 段合并时量的；交接收尾只动了界面和文档，没有重量） |
| 内存 | 单张 CR3 峰值约 1.2 GB；10 个 RAW 按默认并发 4 转，峰值约 4 GB（本机 48 GB） |
| Glint.app | 已按 `38a0065` 之前的代码重新构建并放到 `~/Developer`（之后的提交只改文档） |

---

## 三、待完成工作小结

### 要用户在真实窗口里做的

1. 用一批 JPEG + RAW 的拷贝，勾「校验无差异后删除源文件」转一遍：JPEG 被删，RAW 留着，提示语写明 RAW 原片保留。
2. 拖窗口宽度、拖侧栏，看副标题在完整写法和短写法之间切换正常。

交接收尾的会话没有操作屏幕的工具，这两项都没做。`uisnapshot --onscreen` 能截真实窗口，但截图工具不支持勾删除，也不会拖窗口。

### 需要真实样本才能确认的

3. CR2、NEF、ARW、PEF、SRW、ORF、RAF 的 EXIF 照搬只用手搭样本测过，没有真样本。有合适的无人像样本时再验。拼错的话自检会退回系统重写，不会写坏文件。
4. CRW、MRW、X3F、IIQ 等格式还不能整块照搬 EXIF，走系统重写。

### 已知局限，暂不处理

5. 厂商私有数据（MakerNote）系统读不出也写不进 HEIF，校验照实报一行。
6. RAW 旁边的 .xmp 附属文件不合并（用户的文件夹里没有）。
7. RAW 和同名 JPEG 转出同名的 HEIF 时，后转的按「输出已存在」跳过；要两份就用 `-o` 分开目录。
8. 动态照片的视频、EOI 之后的厂商私有数据不进产物，`--verify` 照实报出。手机 HEIC 怎么存这些（Android Motion Photo 规范的 `mpvd` 盒子等）没核实过，要做得先拿真机样本。

### 遗留问题单

9. ~~`encoder-variance/issues/01`~~：已改为 wontfix（产物大小偶尔不同，原因在系统编码器里，README 已列为已知限制）。`.scratch` 里现在没有 needs-triage 的问题单。

### 收尾小事

10. 只用第 1 段那版转过的 CR3 缺拍摄时区；如有需要，用现在的版本重转一次。
11. 合并时的两个小瑕疵：
    - ~~提交历史里留着一个误提交的 1.5 MB 测试二进制~~：已改写历史去掉（见下面「改写过历史」）；
    - 中间提交 `72e82ab` 单独检出时，测试计数可能对不上。
12. ~~本机临时目录里留着 3 个风景 CR3 和用户指定的 RW2~~：已删除，由它们转出的 18 个 HEIC 也一并删了。

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
只删了它的那个提交（原 `16a0dcd`）整个消失，其余 9 个换了哈希（原 `bc8bcf7` → `3db17b5`，`4e3fd5a` → `9d878de`，
`6278474` → `38a0065` 等），代码树与改写前逐字节相同。文档里引用的哈希已改成新的；改写之前写的提交说明里
可能还引用旧哈希（例如 `c1d6b37` 说明里的 `bc8bcf7`），对照上面这几对看。备份分支和 filter-branch
留下的 `refs/original` 已删除并 `git gc --prune=now`，二进制已从仓库里彻底消失（`.git` 14 MB → 10 MB）。

## 注意事项

- HEIC 编码不是逐字节确定的：别的进程同时在编码时会改走软件编码器。逐字节比较前确认没有别的转换或测试在跑。
- 同一目录不要同时跑两个 `make test`。
- make 的时间戳陷阱：用 `cp` 恢复文件后要 `touch`，并确认日志里有对应的 `swiftc` 行。
- 子代理不在主仓库里构建或测试；测试不写真实设置域 `local.minxu.glint`。
- 可能有别的会话也在这个仓库里提交（CMYK 改动和交接收尾都是并行会话做的），开工前先看 `git log`。
- 想看真实窗口：`./Tests/uisnapshot <输出.png> --onscreen [--convert] <目录>`，要屏幕录制权限。
