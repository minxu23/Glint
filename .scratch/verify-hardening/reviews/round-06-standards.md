# 第 6 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-10T01:48:41.266Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-06-aggregate.md 里。

---

## Standards 轴审查（ecc0f1b…HEAD，f2b016a）

  ### 实质问题（硬）

  **1. `Tests/selftest.sh` 新鲜度守卫有两条静默通道，与提交标题相反**
  - `[ -e "$art" ] || continue`：产物**缺失即视为通过**。`Tests/unit-test`、`guimodel-test`、`mangle-tool`、`uisnapshot` 在上面没有存在性检查，缺一个就无声跳过。
  - `make -q` 对"文件存在但不属于任何规则"也退出 0（"up to date"），所以名字一旦对不上，守卫静默退化成空跑而不是报错。此处 `$BIN` 传的是 `./jpeg2heif`，而 `Makefile:6` 是 `BIN := jpeg2heif`——靠 make 自己归一化 `./` 才碰巧对上，属于不该赌的事。
  - `make -q` 从 `make test` 里反调不会递归，这一条注释是对的。

  **2. 同一守卫把 7 个产物名硬编码 —— Duplicated Code**
  它就是 `Makefile:85 test: $(BIN) Tests/fixture $(TEST_TOOLS)` 那份清单的第二份拷贝。注释自己论证"在这里重写一份依赖表等于复制 Makefile，必然漂移"，却重写了**产物表**：新增一个测试工具不会被检查，且漂移是静默的。建议由 Makefile 把 `$(BIN) Tests/fixture $(TEST_TOOLS)` 当参数传进脚本。

  **3. 新 7b 块复用 `out=`，删掉了实测换来的警告**
  被删的注释原话是"不叫 out……实测会让那条断言变成假阴性"。现在安全只因为新块（234 行）排在读 `$out` 的 216 行之后（216 读的是 202 的值）。谁把 7b 往上挪就复活那个假阴性，而警告已经不在了。

  ### 注释超出代码（重复发现项）

  **4. `terminatesTime` 的 "`HHMMSS`，且整个值就是它：IIM 时间字段之外没有别的东西长这样"**——任意 6 位数字都算：`202409Z`（年月）、`999999Z` 都被读成 `+0000`；`HH:MM:SS` 支也不验范围，`18:99:99Z` 同样过。README ~131 行本轮刚加"分钟本身还要 `< 60`"，Z 门锚的那个"时刻"却完全不验范围；按 `README ## 测试` 的立场（出过事的形状留证人），单测表里也没有这两类反例。

  **5. `Tests/unit/main.swift` 旧标签失真**：`("随便什么Z", "")  // Z 分支零形状检查`——现在已有形状检查，这句与新加的注释块自相矛盾。

  ### 下标安全（重点核查：**过关**）

  `terminatesTime` 的定长下标前提全部**本地建立**：`let t = Array(head[(head.count - 8)...])` 重新基 0，`t[0...7]` 恒安全；`head[head.count - 9]` 被 `head.count == 8 ||` 短路保护，`count >= 8` 来自上一行 guard；小数秒分支的 `dot < head.count - 1` 也自足（空数组时 `lastIndex` 为 nil）。唯一脆弱点：`t` 的 0 基性全靠那层 `Array(...)` 包裹，去掉就错位。姊妹函数 `normalizedOffset(token:precededBy:)` 对"宽度前提必须在本函数内成立"写了显式注释，这里没有——建议补一句同样的话。

  ### 基线气味（判断题）

  **6. Middle Man / Speculative Generality**：`UTCOffset.canBegin(with:)` 的新注释自认"下面的解析路径并不经过本方法""它不是单一事实来源"，只为"同处一处便于对照"而留在类型里。唯一调用方是 `splitIIMTime`——要么内联回去，要么让两个分支真的走它。
  **7. Flag argument**：`metadataKeySpace(of:url:repairing:)` 的布尔量只为测试探针存在（生产路径永不传 false）。鉴于替代方案是让 probe 再拼一份键空间（上一轮刚因此出事），这个取舍可接受，记一笔即可。

  ### 做对的

  `fixture`/`probe` 的 `usage` 常量去重消掉了真实漂移源；probe 的注释"`--no-repair` 只关掉 UserComment 那一处修补、XMP 层照旧"与实现一致（已核对 `Sources/Core/Converter.swift:63`：`repairedProperties` = `imageProperties` + 仅 UserComment 修补）。

  相关文件：`/Users/minxu/Claude/jpeg2heif/Tests/selftest.sh`、`/Users/minxu/Claude/jpeg2heif/Sources/Core/MetadataDiff.swift`、`/Users/minxu/Claude/jpeg2heif/Tests/unit/main.swift`、`/Users/minxu/Claude/jpeg2heif/Makefile`。
