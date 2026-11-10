# 第 2 轮 /mp-code-review 报告（原文）

- 报告时间：2026-11-09T13:48Z
- 修复提交：(git init 之前)
- 来源：本仓库开发会话的转写本，逐字复制，未经编辑。

> 下面是当时呈现给用户的聚合报告原文。两轴的措辞保持分开，没有合并也没有重排。

---

两轴都回来了。按规定分开呈现，不合并也不重排。

## Standards

套件跑一遍全绿。标准源：`CLAUDE.md`、`README.md`、`docs/agents/*.md`。中文注释说明"为什么"、零依赖、仅命令行工具这几条成文约定没有违反——新增的每个符号都带着"它防的是哪个 bug"的注释，新测试也确实在功能改坏时会失败。

**Hard finding：那条 `assert` 既是死的，又和测试套件自相矛盾**

`Model.swift:132`。注释对 `-O` 使其失效这件事是诚实的（`Makefile:4` 的 `-O` 作用于应用、命令行和每个测试工具）。但 `Tests/guimodel/main.swift` 第 6 节**故意**驱动了这条断言称为程序员错误的那个条件。于是：断言在本仓库产出的任何构建里都不可能触发，而在它**会**触发的那个构建（`SWIFTFLAGS=-Onone`，`?=` 允许）里，它会让 guimodel 测试直接 abort。两行复原加那个测试已经完整规定了契约。建议删掉断言、保留复原和注释前半句。断言的消息也略有错误——值是在两行之后被复原的，不是被 `start()/reexpand()` 覆盖的。

**Judgement call（基线气味）**

- **Duplicated Code** — `MetadataDiff.swift` 里四个表闭包各自重算字典前缀、各自手拼 `"\(dict)/\(key)"`：`equivalentKeys`、新增的 `iimTimeKeys`、新增的 `utcOffsetKeys`。两个文件级 `exifKey(_:)`/`iptcKey(_:)` 能把它们全收掉。
- **Duplicated Code** — 两个偏移解析器并排放着：`splitIIMTime` 自己拼 `"\(chars[6])\(String(chars[7...]))"`，而 `utcOffset(in:)` 做的是同一件归一化。`splitIIMTime` 可以返回原始尾巴、交给 `utcOffset`。
- **Primitive Obsession** — 偏移是个裸 `String`（"+0800"）在三个函数间传递，`equivalentCarries` 里的元组还得显式标注类型。一个小小的 `UTCOffset` 类型能同时去掉标注和字符串比较。

**值得记一笔的非 finding**：删掉手工 `refresh()` 是安全的——`refresh()` 在运行时会禁用 `settingsControls`，所以唯一的缺口（运行中改 `recursive`，`reexpand()` 的 `guard !isRunning` 直接返回、不通知，与注释「它自己会通知」矛盾）从界面上走不到。只是潜在的，给那条注释加一句说明即可。另有文档漂移：README 列的偏移归宿不含"带偏移的 `{Exif}/DateTimeOriginal`"，而 `offsetSurvives` 实际也会查它。

## Spec

**(c) 实现了但看起来错了**

1. **`utcOffset` 的 `Z` 分支仍然没有形状检查**（`MetadataDiff.swift:162`）。上一轮 finding 2 点的正是这件事。`splitIIMTime` 被改成严格形状了，**目标侧的读取器没有**。任何只要以 `Z` 结尾的值都被读成 `+0000`。单元测试只喂了裸字符串 `"Z"`。
2. **那个"4 位"判断是数字**个数**，不是形状**（`:163-168`）——和 finding 2 的"head 只要求全数字、不限 6 位"是同一个缺陷。它取**最后**一个 `+`/`-`、然后把到末尾的数字全滤出来：`utcOffset(in: "2024-09-15T18")` → `-1518`；`"… -0800mm"` → `-0800`；越界的 `+9999` 也收。`:166` 的注释是用两个例子来辩护，不是用结构。8 条用例全是良构输入，所以这里退化不会被测出来。改法：像 `splitIIMTime` 那样把 `±HHMM`/`±HH:MM`/`Z` 锚定到末尾。
3. **README 对承载集合许诺过头。** `offsetSurvives` 只查该键自己的两个 `alternatives`；`XMP/exif:DateTimeOriginal`、`xmp:ModifyDate`、`tiff:DateTime` 都不查，`TimeCreated` 也从不查 `xmp:CreateDate`。另外 `+0000` 与 `-0000` 作为字符串不等。方向是多报（README 允许），所以改 README 而不是改代码。

**(a) 缺失/部分**

4. **重做的规则没有集成覆盖。** `Tests/fixture.swift:67-73` 写了 IPTC 字典但**没有 `DateCreated`/`TimeCreated`**，`test_pic/` 里也没有照片带它们。于是整条 IIM 等价路径只有单元测试、跑在手搭的字典上，**目标侧的键拼法从未与真实 ImageIO 输出对过**。一行夹具就能补上。
5. **还有一条通知路径缺着**：运行中 `updateOptions { $0.recursive = ... }` → `reexpand()` 在 `Model.swift:178` 的 `guard !isRunning` 处返回，**不通知**，而 `options.recursive` 已经变了、`rows` 没有重扫。今天界面走不到，第 6 节也没测。另外 `refresh()` 从不把四个复选框和滑块从 `model.options` 重新同步（只在 `MainViewController.swift:178,224-227` 设过一次）。
6. **第 6 节依赖断言被关掉。** 调试构建会 abort 测试而不是让它失败。

**(b) 范围外**（两条都小、都站得住）：`RowStatus.isSettled` + `recount()` 重写是第三个状态分支点，不在任何一轴的清单上；第 2 节的进度不变式 + `sawRunning` 是无关的测试加固。

小疵：README:35 写的是 `Options.default`，类型实际叫 `ConversionOptions.default`。

---

## 我核过的部分

Spec 轴那些可验证的说法**全部成立**，实测输出：

```
[2024-09-15T18]      → "-1518"     ← 从日期里读出了"时区"
[184207 -0800mm]     → "-0800"     ← 尾巴有垃圾也收
[+9999]              → "+9999"     ← 越界不拦
[随便什么Z]           → "+0000"     ← Z 分支零形状检查
[-0000] vs [+0000]   → 字符串不等
```

对照同样的尾巴，**源侧是严格的**：`splitIIMTime("184207+08:00")` 不拆（返回 offset=nil）。这就是两轴各自指向的同一件事——**我把源侧改成了精确形状，却把目标侧的读取器留在松散状态**。上一轮的 finding 2 原话就是"Z 分支不做形状检查"，我修了调用方、漏了被调用方。

Standards 的 hard finding 也实测确认：`-Onone` 构建下 guimodel 测试在 `Model.swift:126` 处 abort，消息正是那条断言。`SWIFTFLAGS ?=` 允许这种构建，所以不是假想。

夹具确实不写 IIM 日期（`selftest.sh` 里与时间相关的断言只有 `{Exif}/OffsetTimeOriginal`），README:35 的 `Options.default` 也确实对不上类型名。

一处要修正 Spec 轴：我在提示里让它核的 `2024-09-15T18:42:07.4200`（小数秒恰好 4 位）**是安全的**，返回 nil。它没有声称这条会中招，但我当时最担心的正是这个形状——结果真正的洞在另外两种。

---

每轴条数：Standards 4 条（1 条 hard + 3 条气味），最重的是那条自相矛盾的 `assert`；Spec 6 条，最重的是第 2 条——`utcOffset` 用数字个数冒充形状判断，使得目标侧仍可能把非时区读成时区，方向上就是静默放过。

建议顺序：**Spec 2 + Spec 1**（把 `utcOffset` 锚定到末尾、`Z` 也走形状检查，并补畸形输入的用例）→ **Spec 4**（夹具加 `DateCreated`/`TimeCreated`，让这条路径有真实文件覆盖）→ **删掉那条 assert**（Standards hard）→ **Spec 3 + README:35 + 两条注释**的文档对齐 → 气味那三条和 Spec 5 的潜在通知缺口押后。要我按这个顺序动手吗？
