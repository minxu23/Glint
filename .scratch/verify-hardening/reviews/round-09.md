# 第 9 轮 /mp-code-review 报告（原文）

- 报告时间：2026-11-10T06:35Z
- 修复提交：eac5f46（定点 cb4b42e）
- 来源：本仓库开发会话的转写本，逐字复制，未经编辑。

> 下面是当时呈现给用户的聚合报告原文。两轴的措辞保持分开，没有合并也没有重排。

---

两轴都回来了。

## Standards

**README 违反自己那一节的规范性（硬）**

`## --verify 到底比什么` 是 `--verify` 比什么的规范性描述。新加的子句嵌在 **Z 专属规则内部**:

> `` `…Z` 那一种另有一条规则：… 或 `<日期><T 或空格><时刻>Z`（…小数秒可用 `.` 或 `,`；日期也认 EXIF 自己的冒号写法 `2024:09:15`…） ``

但 `isDate` 是经 `isTimestamp` 到达的,而 `normalizedOffset(atEndOf:)` 在**两条分支上**都调用它——所以冒号日期对 `±HHMM`/`±HH:MM` 同样生效。diff 自己的测试就是证据:`Tests/unit/main.swift` 里有 `("2024:09:15 18:42:07+08:00", "+0800")`。同一个结构性错配现在也波及那条项目符号里的闰秒句(`且时分秒各自验范围（秒允许 60…）`),而 diff 也恰好新在 ± 侧行使了它(`("23:59:60+08:00", "+0800")`)。冒号日期和范围规则该放在上面,和「三种形状（`±HHMM`、`±HH:MM`、`…Z`）都锚定在末尾逐字符核对」一起,而不是放在「`…Z` 那一种另有一条规则」里面。

**`MetadataDiff.swift:193` 文档注释挂错对象(硬)**

`struct DigitShape` 的文档注释开头是 `UTCOffset` 的理由:

```
/// UTC 偏移，归一化成「符号 + HHMM」（如 `+0800`）。
/// 做成类型而不是继续传裸 `String`：它要在 splitIIMTime、offsetSurvives…
/// 一串固定位数的数字字段，字段之间可以有一个字面分隔符。
struct DigitShape {
```

这是既有的孤儿注释(在 `cb4b42e` 时悬在 `numericFields` 头上),但 diff 把它重新挂到了一个**新的公开类型**上,于是 `DigitShape` 现在被记载为"UTC 偏移"。应搬回 `struct UTCOffset`。

**`MetadataDiff.swift:337` 代码注释引用了 README 排除的键(判断题)**

`isDate` 的论据说 `{TIFF}/DateTime` 实际写的就是 `2024:09:15 18:42:07`,而 README 说 `别的时间戳（xmp:ModifyDate、tiff:DateTime 之类）不算`。只该引 `{Exif}/DateTimeOriginal`。

**基线气味(均为判断题)**

*Duplicated Code / Data Clumps* — 形状的长度在它旁边被重述一遍,没有任何东西维持两者同步:

```swift
for (width, shape) in [(8, DigitShape([2, 2, 2], ":")), (6, DigitShape([2, 2, 2])),
                       (5, DigitShape([2, 2], ":")), (4, DigitShape([2, 2]))]
```

而同一个"长度 → 形状"映射在 `normalizedOffset` 里以另一种写法再出现一次:`case 4: shape = DigitShape([2, 2]); case 5: shape = DigitShape([2, 2], ":")`。一个 `DigitShape.length` 计算属性能推出 `width` 并把两处收拢。

*Duplicated Code* — 形状词汇只在测试里有名字(`hhmmssColon`、`ymdDash`、`ymdColon`、`hhmm`);生产代码在五处重复匿名字面量,`DigitShape([4, 2, 2], …)` 在 `isDate` 里出现三次。应把命名常量提到 `DigitShape` 旁边。

*次要* — 新文档保证「成功时返回的个数恒等于 `shape.widths.count`」,这让 `isDate` 的 `parts.count == 3` 和 `normalizedOffset` 的 `parts.count == 2` 不可达。(`isTimeOfDay` 的 `count >= 2` 是承重的——它分支。)代码里的理由为它们辩护;记录在案,不强求。

`Tests/selftest.sh` 干净:剩下那一处重复(最外层计数检查没用 `expect_count`)就地解释过了,`^ *[✓✗]` 的锚定仍匹配 215/37。

## Spec

用变异测试在副本上验证(基线 215 条单元断言,`make test` 绿 60/215/37)。

**需求 1、2、3、4 是真满足,不是做样子。** 变异:从 `isDate` 移除 `DigitShape([4, 2, 2], ":")` → 4 红;移除月/日范围检查 → 3 红(含新的 `9999:99:99` 用例);`parts[2] <= 60` → `<= 59` → 4 红,其中 3 条是新增的 ± 闰秒用例;对 `numericFields` 做"分隔符放宽"和"去掉用尽检查"的变异 → 两条新增的否定 `expectFields` 用例红。`EXPECTED_ROUNDS` 已删除,理由注释准确。

**(a) 部分完成**

**需求 5** — *"either make the condition load-bearing or drop the apology; do not leave prose standing in for a decision."* 道歉被**搬走了,不是解决了**。`MetadataDiff.swift:233` 仍是 `guard value[i].isASCII, value[i].isNumber`,现在**没有**注释,而 `Tests/unit/main.swift` 替它背着那段道歉:「numericFields 里还有 Int(String) 兜着,实测去掉 isASCII 它照样拒」。实测确认:从 `numericFields` 去掉 `isASCII`,215 条里红 0 条。只有新的 `isAllDigits` 那一份是承重的(1 红)。那个具名条件仍然冗余、仍然没有钉子、仍然被道歉。

**(b) 范围蔓延**

工单第 3 条只要求*"delete it, and record in a comment why"*。diff 还顺手把 `EXPECTED_PASSES` 改名成 `EXPECTED_ASSERTIONS`、抽出 `expect_count`/`count_assertions`、把计数正则从 `'✓|✗'` 改成 `'^ *[✓✗]'`、把结论里的 `$PASSED` 换成 `$executed`。此处行为中立,但没人要求。

**(c) 看着实现了但做错了**

1. **文档注释错位**(`MetadataDiff.swift:188-204`)——违反需求 6 *"correct the overclaiming comments"*。
2. **残留的"模板"**(`MetadataDiff.swift:343`):`/// 按模板核对一个时刻并验范围` —— 需求 4 已经把模板取消了。
3. **README 的改动低估了作用范围。**`±` 的前缀规则完全没有文档(`20240915+0800`/`ISO100+0800` 会被拒)。方向上只多报,没有静默丢失,但契约描述错了新代码。
4. **新产生的死守卫**:`parts.count == 3` 与 `parts.count == 2` 现在恒真,而新注释却为它们辩护。

---

**两轴各 6 条。Standards 轴最严重:README 把两条通用规则写进 Z 专属段落——那是规范性那一节,而且是我上一轮亲手改的。Spec 轴最严重:需求 5 只部分完成——`isASCII` 的道歉从生产代码搬进测试文件,变异测试证明去掉它 215 条红 0 条。**

我自己核过的几点,和两边报告分开讲:

**三条在两轴独立撞上了同一处**(错位的文档注释、README 的作用范围、死守卫)。两条互不通信的审查线各自走到同一个点,这个信号比任何一条单独的意见都重。

**需求 5 这条我认,而且它比两份报告写的更难看一点。** 测试文件第 289-291 行那段注释,内容本身是**对的、而且有用**——它正是上一轮我用来反驳 Spec「永不会红的断言」那个论点的东西,我那个反驳也站得住。但同一段注释顺手承认了生产代码里那个条件是冗余的。所以我上一轮报告里写「在 `numericFields` 里仍然冗余」,等于我自己知道这个决定没做,还把它当成已完成报了出去。

**(b) 范围蔓延这条我不往下传,因为它很可能是我的工单写漏了。** 我上一轮报告的第 3 步本来就把改名、抽函数和删除捆在一起讲;原始审查到底要了哪几样,我从仓库里查不出来——那份审查只活在对话里。这正是我在启动两个 agent **之前**就点明的风险:工单是我转述的,我转述得不全,Spec 轴就会把我自己的多做判成蔓延。它按拿到的工单判是对的,错在工单。

**(c)3 里「`±` 前缀规则完全没有文档」我要削一句。** README 有那条反例:「曾经用"取最后一个加减号、后面数字数够 4 位"来凑,`2024-09-15T18` 会被读成偏移 `-1518`」。所以不是完全没提,而是**只有反例、没有正面规则**——读者得从一个失败算法反推出当前算法要求什么。够不上"完全没有",但确实不是契约该有的写法。

**残留的"模板"只有一处**(`:343`);第 250-251 行那两处是在讲历史(为什么旧模板是错的),该留。
