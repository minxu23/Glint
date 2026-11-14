# 第 9 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-10T06:30:17.327Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-09-aggregate.md 里。

---

## Standards axis

  ### README.md — hard violation of its own normative section

  `## --verify 到底比什么` is the normative description of what `--verify` compares. The new clause is nested **inside the Z-only rule**:

  > `…Z` 那一种另有一条规则：… 或 `<日期><T 或空格><时刻>Z`（如 …，小数秒可用 `.` 或 `,`；日期也认 EXIF 自己的冒号写法 `2024:09:15`…）

  But `isDate` is reached through `isTimestamp`, which `normalizedOffset(atEndOf:)` calls on **both** branches — so colon dates work for `±HHMM`/`±HH:MM` too. The diff's own test proves it: `("2024:09:15 18:42:07+08:00", "+0800")` in Tests/unit/main.swift. Same structural mismatch now affects the leap-second sentence in that bullet (`且时分秒各自验范围（秒允许 60…）`), which the diff also newly exercises on the ± side (`("23:59:60+08:00", "+0800")`). The colon-date and range rules belong above, with "三种形状（`±HHMM`、`±HH:MM`、`…Z`）都锚定在末尾逐字符核对", not inside "`…Z` 那一种另有一条规则".

  ### Sources/Core/MetadataDiff.swift:193 — misattached doc comment (hard)

  `struct DigitShape`'s doc comment opens with `UTCOffset`'s rationale:

  ```
  /// UTC 偏移，归一化成「符号 + HHMM」（如 `+0800`）。
  /// 做成类型而不是继续传裸 `String`：它要在 splitIIMTime、offsetSurvives…
  /// 一串固定位数的数字字段，字段之间可以有一个字面分隔符。
  struct DigitShape {
  ```

  Pre-existing orphan (it hung over `numericFields` at 851d6d1), but the diff re-parents it onto a *new public type*, so `DigitShape` is now documented as "UTC 偏移". Move it back onto `struct UTCOffset`.

  ### MetadataDiff.swift:337 — code comment cites a key the README excludes (judgement call)

  `isDate`'s justification says `{TIFF}/DateTime` 实际写的就是 `2024:09:15 18:42:07`, but README says `别的时间戳（xmp:ModifyDate、tiff:DateTime 之类）不算`. Cite only `{Exif}/DateTimeOriginal`.

  ### Baseline smells (judgement calls)

  **Duplicated Code / Data Clumps** — a shape's length is restated beside it and nothing keeps them in sync:

  ```swift
  for (width, shape) in [(8, DigitShape([2, 2, 2], ":")), (6, DigitShape([2, 2, 2])),
                         (5, DigitShape([2, 2], ":")), (4, DigitShape([2, 2]))]
  ```

  and the same length→shape map appears a second way in `normalizedOffset`: `case 4: shape = DigitShape([2, 2]); case 5: shape = DigitShape([2, 2], ":")`. A `DigitShape.length` computed property would derive `width` and collapse both.

  **Duplicated Code** — the shape vocabulary is named only in the tests (`hhmmssColon`, `ymdDash`, `ymdColon`, `hhmm`); production repeats the anonymous literals at five sites, `DigitShape([4, 2, 2], …)` three times inside `isDate`. Hoist the named constants next to `DigitShape`.

  **Minor** — the new doc guarantees `成功时返回的个数恒等于 shape.widths.count`, which makes `isDate`'s `parts.count == 3` and `normalizedOffset`'s `parts.count == 2` unreachable. (`isTimeOfDay`'s `count >= 2` is load-bearing — it branches.) The in-code rationale defends them; noted, not pressed.

  Tests/selftest.sh is clean: the one duplication left (the outermost count check not using `expect_count`) is explained in place, and the `^ *[✓✗]` anchoring still matches 215/37.
