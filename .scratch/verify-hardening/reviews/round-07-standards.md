# 第 7 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-10T03:40:18.895Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-07-aggregate.md 里。

---

## 第 7 轮 Standards 轴审查报告

  ### 硬违规

  **1. `/Users/minxu/Claude/jpeg2heif/Makefile:87-88` 注释宣称的事实不成立**（本轮「注释超出代码」的复发点）
  > `# selftest.sh 的新鲜度守卫用它来问「该检查哪些产物」。清单只在这里定义一份：`
  > `# 脚本里抄一份就会在往 TEST_TOOLS 加工具时静默落后（上一版正是如此）。`

  而 `$(BIN) Tests/fixture $(TEST_TOOLS)` 紧接着在下面出现第二份：`print-artifacts:` 的 `@echo`（第 90 行）与 `test:` 的依赖列表（第 92 行）。清单仍是两份拷贝，只是都搬进了 Makefile——往 `TEST_TOOLS` 加工具不会漂移（两处都展开同一个变量），但这两行的「产物集合」定义本身仍可各自被改成不一致。应提 `ARTIFACTS := $(BIN) Tests/fixture $(TEST_TOOLS)`，`print-artifacts` 与 `test` 共用。

  **2. `Makefile`：`print-artifacts` 被声明了两次 `.PHONY`** —— 第 10-11 行加进了主 `.PHONY` 续行，第 89 行又单独写了一条 `.PHONY: print-artifacts`。两处编辑之一是死的，删掉第 89 行那条。

  **3. `README.md` `## --verify 到底比什么` 与代码不符（小）**：文中写「且时分秒各自验范围」，未说明秒允许 60（闰秒），而 `Tests/unit/main.swift` 恰好把 `("23:59:60Z", "+0000")` 断言为必须认。README 既然对 `±` 侧逐条写明了边界（`+14:00`/`-12:00`/分钟 `<60`），Z 侧这条例外也该写出来。

  ### 判断题

  **4. 三个 shape 解析器构成重复 switch（Repeated Switches + Duplicated Code）**
  `/Users/minxu/Claude/jpeg2heif/Sources/Core/MetadataDiff.swift` 里 `isTimeOfDay`、`isDate` 与既有的 `normalizedOffset(token:precededBy:)` 形状完全同构：`switch count` → 查分隔符位 → 攒 `digits` → `Int(String(...))` 验范围；三条 doc 注释还各自重写了一遍「宽度前提在本函数内成立」这同一段推理。值得抽一个 `match(_ chars:, 模板:, 字段范围:)`（模板如 `"dd:dd:dd"` / `"dddddd"` / `"dddd-dd-dd"`），三处共用一张模板表。

  **下标安全这一关是过的**：每个 guard 的前提都在本函数内由 `switch t.count` / `switch d.count` 就地建立，不依赖调用方的 `for width in [8, 6, 5, 4]`（注释说的和代码做的一致）；`digits[4...5]` 被前面的 `if digits.count == 4 { return true }` 挡住，`digits.count ∈ {4, 6}`，无越界路径；`terminatesTime` 里所有切片都由 `head.count >= width` 守着。

  一处名实不符：`allSatisfy(\.isNumber)` 会放过全角及其他数系的数字字符，目前靠后续 `Int(String(...))` 返回 nil 兜住——想让这个证人名实相符，写成 `isASCII && isNumber`。（`splitIIMTime` 的 `chars[0..<6].allSatisfy(\.isNumber)` 同理，是既有问题，本轮在新函数里复制了这个写法。）

  删掉 `UTCOffset.canBegin` 并内联成 `chars[6] == "+" || chars[6] == "-" || chars[6] == "Z"` 是合理的（原方法的 doc 注释自己就承认它不是单一事实来源，典型 Middle Man）。

  **5. `Tests/selftest.sh`：`EXPECTED_PASSES` 用精确值会在真失败时制造第二条假失败**
  断言失败走 `fail`，`PASSED` 不自增，于是任何一条真实失败都会额外打印「通过 N 项，预期 58 项——有断言没有执行」，`FAILED` 从 1 变 2，并给出误导性的原因。第 6 轮那个 `if Tests/mangle-tool …; else fail` 的 else 分支一跳就少 3 项 pass，放大这个效应。应比 `PASSED + FAILED` 的总数，或在 `FAILED > 0` 时跳过这条检查。

  **6. `EXPECTED_ROUNDS` 几乎被 `EXPECTED_PASSES` 包含**（整轮消失必然带走它名下的 pass，PASSED 那条也会报），却要维护第二个魔数；只有「轮次标题还在、但整轮一条断言都不剩」这种边角才由它独占。另外第 2 轮的 pass 数由 `KEYS` 列表的行数决定，改 `KEYS` 要跑到文件顶部改 `EXPECTED_PASSES`（小 Shotgun Surgery + 魔数）。

  **7. trap 注释略超实际**：脚本只有 `set -uo pipefail`（无 `-e`），现存的提前 `exit` 全部走 `bail`（已置 `REACHED_END=1`，trap 静默）。所以 trap 实际兜住的是 `set -u` 的未定义变量中止与信号，不是注释说的「提前 exit 吞掉后半（结尾的检查本身都执行不到）」。守卫便宜、可留，措辞该收一收。

  **8. 两处脆弱引用**：
  - `Tests/probe-src/main.swift` 新注释硬写 `Converter.swift:49 的 ?? [:]`——今天确实对得上（`imageProperties` 里那行），但行号必漂，改引函数名。
  - `Tests/selftest.sh` 的 `make --no-print-directory print-artifacts 2>/dev/null` 吞掉 stderr，Makefile 真出语法错时会被报成「问不到产物清单（make print-artifacts 没出声）」，掩盖真实原因。

  ### 未计为违规
  `docs/adr/` 与 `GLOSSARY.md` 均不存在，而 `docs/agents/domain.md` 明确要求「不存在就静默跳过、不要提醒补建」，故本轮没有把「设计史写在行内注释里而非 ADR」当成违规——但 `MetadataDiff.swift` 与 `selftest.sh` 的注释里「上一版/上一轮/实测」正在逐轮累积，可读性成本值得留意。
