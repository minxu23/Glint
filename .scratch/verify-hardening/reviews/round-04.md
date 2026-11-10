# 第 4 轮 /mp-code-review 报告（原文）

- 报告时间：2026-11-09T15:02Z
- 修复提交：(git init 之前)
- 来源：本仓库开发会话的转写本，逐字复制，未经编辑。

> 下面是当时呈现给用户的聚合报告原文。两轴的措辞保持分开，没有合并也没有重排。

---

两轴都回来了。这一轮我自己先栽了一跤，先说结论再排报告。

## Standards

**Hard：`normalized(token:precededBy:)` 仍然接受 README 范围外的偏移**（`MetadataDiff.swift:246-247`）。README 第 130 行写明范围是 `-12:00…+14:00`，而新的检查只分别约束时和分（`hours <= (token[0] == "-" ? 12 : 14)`、`minutes <= 59`），于是 `+1430`、`+14:59`、`-1230` 都能解析通过。这和这段代码被写出来要拒的是同一类不存在的偏移，失效方向也一样——目标侧读取器过宽，`offsetSurvives` 就会宣称偏移还在。没有任何用例覆盖 `+1430`。

**数组下标**

- `splitIIMTime` 的 `chars[6]`：**安全，且是本地保证的**。Swift 的 `guard` 从左到右短路，`chars.count == 7 || 11 || 12` 在它前面，所以 count ≥ 7，不依赖调用方。
- `normalized(token:precededBy:)` 的 `token[0]` 与 else 分支里的 `token[3..5]`：**不是本地保证的**。函数从不检查 `token.count`，else 分支直接假定 6。唯一兜着它的是那个唯一调用方的 `for width in [5, 6]`（grep 确认只有一个调用点）。将来任何调用方传空数组或 3 字符就会 trap。值得一提的是：同一轮里 `splitIIMTime` 恰恰为这个失效形状加了长度检查，而这个新私有方法是整个 diff 里唯一把它留作隐含的地方。

**Judgement call**

- **Mysterious Name** —— 两个 `normalized` 重载。`normalized` 是个光秃秃的形容词：normalized 什么？而且重载对暗示"同一操作的两种粒度"，实际上两者干的是不同的活（定位候选 vs 核对转换）。`normalizedOffset(atEndOf:)` / `normalizedOffset(token:precededBy:)` 会老实些。
- **Duplicated Code / Feature Envy（轻）** —— `splitIIMTime` 里的 `chars[6] == "+" || "-" || "Z"` 重述了 `UTCOffset` 自己那套"偏移起始字符"的字母表。注释解释了为什么需要第三个条件，没解释为什么这个字符集住在拥有它的类型之外。
- 不是 Middle Man：三行 `init?` 委托给 `normalized(atEndOf:)` 是正当的接缝。

**干净的**：`xmpKey` 用在文件级 `let` 初始化里安全（它是函数，不是需要初始化的全局；文件级全局经 `swift_once` 惰性初始化）。测试里手写 `"XMP/photoshop:DateCreated"` 字面量而不调 `xmpKey` 不算违规——借用生产端助手的测试在前缀改变时根本不会失败，这与 README 的测试标准相悖，字面量是对的。

## Spec

**(a) 缺失/部分**

**1. 第 3 项的"做不出来"结论一半是错的——XMP 腿端到端**是**可达的（已验证）。** 我写了个只有 `{IPTC}/DateCreated` + `TimeCreated=184207+0800`、没有任何 `OffsetTime*` 的 JPEG。ImageIO 不仅合成了 `{Exif}/DateTimeOriginal`（这半句成立），**还合成了 `XMP/photoshop:DateCreated=2024-09-15T18:42:07+08:00`**。转换后 HEIC 完全没有 `OffsetTime*`，于是 `--verify` 能通过**只因为** `offsetSurvives` 从 XMP 那个等价键里找到了偏移。所以 XMP 腿今天就是端到端决定性的那条（偏移这一半）；被挡住的只有承载时间那一半。`Tests/fixture.swift:44` 设的 `OffsetTimeOriginal: "+08:00"`——删掉这一行就是那个缺失的测试。第 3 项该开着，但理由和注释写的不是一回事。

**2. 第一个守卫（长度）必要但无覆盖——已用变异验证。** 我删掉 `chars.count == 7 || 11 || 12` 重新编译：**10 条 `splitIIMTime` 用例全过**，而 `184207+12+0800` → `("184207", "+0800")`，静默丢掉 `+12`。更糟的是注释自己举的证人是错的：`184207123+0800` 本来就被 `chars[6]` 那条拒掉了。需要一个"符号后面还有数字"的拼法当证人。

**(b) 范围外**：没有。

**(c) 实现了但错了**：没有别的。`splitIIMTime` 现在恰好接受那四种形状——长度 11 时只有 index 6 的宽 5 token 能匹配，长度 12 时只有宽 6 能匹配，所以没有被接受的形状会丢字符，也没有合法 IIM 拼法被拒。按符号的范围：`-12:00` 仍能解析，没有真实时区低于它。

---

## 我核过的部分，以及我自己的一次误判

Standards 的 hard finding 实测成立，而且**不能**按它建议的"hours==14 时拒绝 minutes!=0"那样简单处理——`+05:30`、`+05:45`、`+09:30`、`+13:45` 都是真实存在的偏移，必须继续通过。老实的写法是直接约束总分钟数 `-720…+840`，这正是 README 那句 `-12:00…+14:00` 的字面意思，一个表达式同时管住代码和文档。

**这是同一个守卫连续第三轮出错，每次深一层**：先是不分符号（`-14:00` 照收），然后分了符号但按分量各自约束（`+14:30` 照收）。我每次都只收紧了"时"，从没问过这一对数合起来是什么。

`normalized(token:precededBy:)` 无本地长度保证，读代码确认：全函数没有一处 `count` 检查。

**Spec 轴第 1 条是对的，我上一轮的结论是错的。** 我当时做实验得出"ImageIO 不合成 XMP 日期"，依据是 `./Tests/probe` 返回 `<无>`。查了才发现——**`Tests/probe` 根本不读 XMP**，它只 flatten `CGImageSourceCopyPropertiesAtIndex`。所以我那些 `XMP/...` 探测**无条件**返回 `<无>`，结论完全是仪器的产物。换成真正的读取器重测：

```
a.jpg   XMP/photoshop:DateCreated = 2024-09-15T18:42:07.42+08:00   ← 带着偏移
a.heic  XMP/photoshop:DateCreated = 2024-09-15T18:42:07.42+08:00   ← 活着过来了
```

这是今天第六次栽在「命令整体没报错，但我要的那一步根本没发生」上，而这次换了个新形式：**量了，但仪器不测这个量**。

顺带带出一条两轴都没提的问题：`Tests/probe` 的文件头注释写着它刻意复用 `--verify` 同一个 `flatten`，理由是「校验探针和校验本身对键路径长什么样的理解必须一致」——但 `--verify` 会再 merge 一层 `xmpTags`，probe 不会。所以它对任何 XMP 键都静默答 `<无>`，与自己声称的理由相反。`selftest.sh` 现有断言没有一条探测 XMP 键，所以今天没有空断言，但这是个已经骗过我一次的陷阱。

---

每轴条数：Standards 4 条（1 hard + 3 judgement），最重的是范围仍未真正等于 README 承诺的范围；Spec 2 条，最重的是长度守卫无覆盖、且注释里的证人举错了。

建议顺序：**范围改成总分钟数约束**（带 `+1430`/`-1230` 用例）→ **`normalized` 加本地 `token.count` 守卫**，顺带改名 `normalizedOffset`，并把"偏移起始字符"收回 `UTCOffset` → **补长度守卫的用例并改正注释里的证人**（`184207+12+0800`）→ **删掉夹具的 `OffsetTimeOriginal`、改正那段"做不出来"的注释**，让 XMP 腿真正端到端 → **给 `probe` 加上 XMP 读取**，让它名副其实。要我按这个顺序动手吗？
