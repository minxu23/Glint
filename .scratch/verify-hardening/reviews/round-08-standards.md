# 第 8 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-10T04:25:50.527Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-08-aggregate.md 里。

---

## 标准轴评审（`9c67039...HEAD`，提交 `851d6d1`）

  ### 硬违规：无
  仓库无 CODING_STANDARDS/CONTRIBUTING；`CLAUDE.md` 只规定 issue 位置与 triage 标签，`README.md ## 测试` 只描述自检覆盖范围、不约束断言计数。本次 diff 未触碰这两处的规则面。README 第 136 行补「秒允许 60，那是闰秒」与代码 `parts[2] <= 60` 一致，文档与实现同步，合格。

  ### 判断题（按严重度）

  **1. 注释说大话（本轮又一例，`Sources/Core/MetadataDiff.swift:205-207`）**
  > `连「宽度前提在本函数内成立」那句注释都重复了三遍。现在只有这里需要那句话`

  同一 diff 的 `normalizedOffset` 里仍留着「宽度前提在本函数内成立，不寄托于调用方的 `for width in [5, 6]`」（新文件 290 行）。说"只有这里需要"当场被自己推翻。另外「下面所有下标都由 template 与 value 的长度在本函数内对齐」也不准确——函数内其实是逐处 `i < value.count` 显式守卫，并没有任何长度对齐前提。

  **2. 模板是陷阱：`"dddddd"` vs `"dd|dd|dd"`（Primitive Obsession）**
  字段边界只由 `|` 决定，而 `d` 的个数在视觉上不传达任何分段信息。`"dddd-dd-dd"`（3 段）和 `"dddddd"`（1 段）字面高度相似、语义天差地别，纯靠文档注释撑着。更坏的是把形状编成 String 后编译期丢失了元数——三个调用点不得不各自在运行时补 `parts.count >= 2` / `== 3` / `== 2`，这正是类型本该做的事。建议把模板做成小类型（枚举或 `[Field]`），`|` 这种不可见分隔符就不必存在。

  **3. `"dddddd"` 这一处不诚实**
  `splitIIMTime`（182 行）只判 `!= nil`、丢弃返回值，`"dd|dd|dd"` 行为完全等价；`"d*"`（319 行）同理。6 个调用点里只有 4 个真用返回值。单测 `expectFields("184207", "dddddd", [184207], "IIM 时间整段当一个字段")` 钉住的是一个没人消费的语义——这条是 Speculative Generality 的真正落点，不是整个函数（10 处模板复用、替掉三段 `switch count`，抽取本身划得来）。

  **4. `isASCII` 冗余条件 + 四行自白（209-212 行注释、单测 492 行）**
  注释与测试都承认"去掉照样过"。留一个自知无法被用例钉住的条件，加四行解释它为什么留着，成本高于它表达的意图。

  **5. `Tests/selftest.sh` 的两段守卫是 Duplicated Code**
  `unit_n` / `gui_n` 两块（382-397、412-415）形状逐字相同：`grep -cE '✓|✗'` → 比常量 → `pass`/`fail` 同模板文案 + 同一句"同上：数执行数，不数通过数"。应抽成 `expect_count 名称 输出 期望`，一处定义两处调用。顺带：`grep -c` 数的是**行**数，一行含两个 ✓ 就少算。

  **6. `EXPECTED_PASSES` 已是 Mysterious Name**
  它现在比的是 `executed=$((PASSED + FAILED))`，即"执行条数"，名字和三处文案（"改动断言后请同步 EXPECTED_PASSES"）却还在说 passes。改名 `EXPECTED_ASSERTIONS`。

  **7. 四常量里 `EXPECTED_ROUNDS` 基本被吞掉**
  整轮消失必然让 `executed` 也对不上（除非该轮零断言，而本脚本每轮都有断言），`EXPECTED_ROUNDS=12` 的独立信息量趋近于零，却要跟着维护。`EXPECTED_UNIT`/`EXPECTED_GUI` 与 `EXPECTED_PASSES` 不重叠（子套件被压成 1 个 pass，确实看不见缩水），该留；建议删 `EXPECTED_ROUNDS`，从四个减到三个。

  ### 做对的地方
  `Makefile` 的 `ARTIFACTS :=` 消掉了真实的双份清单；`print-artifacts` 不再 `2>/dev/null` 吞 Makefile 语法错，并把"失败"与"空输出"分成两条 bail；`Tests/probe-src/main.swift` 把 `Converter.swift:49` 换成行为描述，去掉了会腐坏的行号引用。
