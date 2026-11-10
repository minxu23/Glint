# 第 1 轮 聚合报告（原文）

- 报告时间：2026-11-09T12:57Z
- 修复提交：(git init 之前)
- 来源：本仓库开发会话的转写本，逐字复制，未经编辑。

> 下面是当时呈现给用户的聚合报告原文。两轴的措辞保持分开，没有合并也没有重排。

---

两轴都回来了。按审查规定分开呈现，不合并也不重排。

## Standards

读的标准源：`CLAUDE.md`、`README.md`、`docs/agents/*.md`（`GLOSSARY.md` 与 `docs/adr/` 不存在，按 `domain.md` 的规定静默跳过）。`make test` 跑一遍全绿，含 guimodel 29 项。

**成文标准违反**

1. **`strippingTimeZone` 与 README 不符（hard）。** README 新段写「只认「全数字 + 号 + 4 位偏移」这一种形状」，代码实际接受三种：4 位、5 位带冒号、以及 README 完全没提的 `Z` 后缀分支。函数自己的注释写「4 位或 5 位」，同样漏了 `Z`——三处说法两种口径，违反本仓库"注释解释为什么"的通行约定。
2. **5 位/冒号那半截没有用例（hard-ish）。** 删掉 `|| offset.count == 5` 和 `|| $0 == ":"`，测试套件仍全绿。IIM 的 `TimeCreated` 规范是 `HHMMSS±HHMM` 不带冒号，所以这也读作 **Speculative Generality**：要么补用例，要么删分支。

**基线气味（judgement call）**

3. **Duplicated Code** — `Tests/guimodel/main.swift` 新增的 `allJpegs(in:)` 与既有 `heics(in:)` 只差一个字面量，一个 `files(in:ext:)` 可以同时服务两者。
4. **Repeated Switches** — `Model.swift` 的 `detailText` 先 `case .skipped, .failed` 再进 `status.reason` 又 switch 一次；`case .skipped(let why), .failed(let why)` 可以直接绑定。`recount()` 里还有第三种分类写法，一个 `isSettled` 能把三处收拢。
5. **`updateOptions` 开的门太宽** — 注释声称「哪些字段变了需要连带做什么」只有一处，但调用方设 `options.inputs`/`options.output` 会被 `start()`/`reexpand()` 静默覆盖。

**干净的**：Makefile `.SECONDEXPANSION:`、`flatten` 删死分支（由新测试组守着）、`Converter.swift` 的 `ConversionReport` 合并。

## Spec

**(c) 实现了但看起来错了**

1. **`strippingTimeZone` 可能让 `--verify` 藏起真丢失（假阴性）。** 违反 `MetadataDiff.swift:140` 自己写的「宁可偶尔多报一条，也不要静默放过」。若源文件的 UTC 偏移**只**存在于 `{IPTC}/TimeCreated = 184207+0800`、且没有 EXIF `OffsetTime*`：HEIC 里 IIM 键不存在，`carriesSameValue` 拿剥完的 `184207` 去比 `DateTimeOriginal`，命中、`continue`——`+0800` 从文件里消失了而**一句都不报**。改之前是多报（安全）。`README:124` 用「时区由 `OffsetTime` 单独承载」来论证剥除，但这句是对**目标文件**的断言，代码从未检查它。
2. **形状判断比它自己的注释宽。** head 只要求"全数字"、不限长度，所以 4 位 head + 4 位尾巴（`2024-0915`）会被剥成 `2024`——正是注释警告的那种静默放过。5 位尾巴接受任意数字/冒号串（`184207-12345`）。`Z` 分支完全不做形状检查。而且它被施加到 `DateCreated`/`DigitalCreationDate` 上，IIM 的日期字段从不带偏移——**有风险、零收益**。限定只对两个 Time 键生效，或要求 `head.count == 6`，两个洞一起堵上。
3. **`flatten` 的删除是成立的。** `Tests/unit/main.swift:32` 送进去的是原生 Swift `[String: …]` 字典、靠桥接被接走，该组通过，所以那个论断是有守卫的，不是空口断言。

**(b) 范围外**：只有一条有分量——`Model.swift:4` 写「状态变化统一通过 onChange 回调通知视图刷新」，但 `updateOptions` 只在 `recursive` 变化时通知，被删掉的四个转发 setter 显然也不通知；`MainViewController` 靠两处手工 `refresh()` 补上（376、393 行）。今天是对的，对未来任何调用方都是静默失效。

**(a) 缺失/部分**：第 6 条的单向包含未动——可接受，因为它「errs safe」，**但 finding 1 正是它不再 errs safe 的那个例外**。`--delete-original` 仍先校验，GUI/CLI 默认值仍共用 `ConversionOptions.default`、`verify` 是唯一分叉（`Tests/unit/main.swift:190-197` 有断言）。`harness.swift` 剩下的两个 `check` 重载都在用。

---

## 我自己核过的部分

两轴的硬结论我都实测了，**都成立**，另有一处要修正 Spec 轴的举例：

```
strippingTimeZone(2024-0915)   = 2024      ← head 不限长度的洞
strippingTimeZone(12-3456)     = 12        ← 两位 head 也放过
strippingTimeZone(184207-12345)= 184207    ← 5 位尾巴照收
carriesSameValue(184207+0800, 2024:09:15 18:42:07) = true   ← 假阴性
```

Spec 轴举的 `2024-0915` vs `2020-01-01` 这个具体例子其实**会**正确报出丢失（`2024` 不在 `20200101000000` 里）。静默放过需要目标值共享开头数字，比如 `2024-0915` vs `2024:01:01 00:00:00` —— 真实日期是 9 月 15 日、目标写着 1 月 1 日，判为「承载」。我实测确认了这个形状。所以结论站得住，只是触发条件比报告写的更窄一点。

删掉 `offset.count == 5` 和 `":"` 后测试全绿，也实测确认了。

**最要紧的一条**：`strippingTimeZone` 是我今天为了消掉一个误报而加的，而它在「偏移只存在于 IIM、目标没有 `OffsetTime`」这个子情形下把方向做反了——从多报变成了漏报。更难看的是，我写的那条用例「带时区的 IIM 时间也认」**恰好把这个漏报钉成了正确行为**。上一轮我刚因为"死分支"删掉 `flatten` 的一半，转身在同一个函数里写了一条新的死分支（5 位/冒号）。

---

每轴条数：Standards 5 条（2 条成文违反 + 3 条气味），最重的是第 1 条 README 与代码的三处口径不一；Spec 4 条，最重的是第 1 条 `--verify` 假阴性。

要我现在动手吗？我的建议顺序是：Spec 1 + Spec 2（把 `strippingTimeZone` 限定到两个 Time 键、要求 `head.count == 6`、删掉走不到的 5 位/冒号分支，并在目标确实没有承载偏移时照样报出来）→ 顺手对齐 README 和注释 → 剩下的气味那批可以押后。
