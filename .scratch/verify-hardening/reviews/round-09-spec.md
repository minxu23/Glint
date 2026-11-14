# 第 9 轮 Spec 轴报告（agent 原文）

- 时间：2026-11-10T06:33:46.815Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-09-aggregate.md 里。

---

## Spec axis — round 9 (`72dd2d0`)

  Verified by mutation testing a scratch copy (baseline 215 unit assertions, `make test` green at 60/215/37).

  **Req 1, 2, 3, 4 are genuinely satisfied, not gestured at.** Mutations: removing `DigitShape([4, 2, 2], ":")` from `isDate` → 4 red; removing the month/day range check → 3 red (incl. the new `9999:99:99` case); `parts[2] <= 60` → `<= 59` → 4 red, 3 of them the new `±` leap-second cases; separator-lenient and exhaustiveness-dropped mutations of `numericFields` → the two new negative `expectFields` cases red. `EXPECTED_ROUNDS` is deleted with an accurate rationale comment.

  ### (a) Partial
  **Req 5** — *"either make the condition load-bearing or drop the apology; do not leave prose standing in for a decision."* The apology was relocated, not resolved. `Sources/Core/MetadataDiff.swift:233` still has `guard value[i].isASCII, value[i].isNumber`, now with **no** comment, and `Tests/unit/main.swift` carries the apology instead: "numericFields 里还有 Int(String) 兜着，实测去掉 isASCII 它照样拒". Confirmed: dropping `isASCII` from `numericFields` fails 0/215 assertions. Only the new `isAllDigits` copy is load-bearing (1 red). The named condition is still redundant, still unpinned, still apologised for.

  ### (b) Scope creep
  Ticket 3 asks only *"delete it, and record in a comment why"*. The diff also renames `EXPECTED_PASSES`→`EXPECTED_ASSERTIONS`, extracts `expect_count`/`count_assertions`, changes the count regex `'✓|✗'` → `'^ *[✓✗]'`, and swaps the summary from `$PASSED` to `$executed`. Behaviour-neutral here, but unrequested.

  ### (c) Implemented but wrong
  1. **Misplaced doc comment** (`MetadataDiff.swift:188-204`) — against Req 6 *"correct the overclaiming comments"*. One contiguous `///` block opening `/// UTC 偏移，归一化成「符号 + HHMM」…做成类型而不是继续传裸 String` is attached to `struct DigitShape` (line 205). `struct UTCOffset` (line 261) keeps only the `+0000/-0000` note. Pre-diff the block sat on `func numericFields`; this diff moved it onto the new type rather than onto its subject.
  2. **Stale "模板"** at `MetadataDiff.swift:343`: `/// 按模板核对一个时刻并验范围` — Req 4 removed templates.
  3. **README edit understates reach.** The new sentence sits inside the Z-only rule: "`…Z` 那一种另有一条规则". But `isDate` feeds `isTimestamp`, which both branches use — the diff's own tests pin `("2024:09:15 18:42:07+08:00", "+0800")`. The `±` prefix rule is undocumented entirely ("读偏移时三种形状…都锚定在末尾逐字符核对，还要验范围"), though `20240915+0800`/`ISO100+0800` are rejected. Over-report direction, so no hidden loss — but the contract mis-describes the new code.
  4. **Newly dead guards**: `parts.count == 3` (`isDate`) and `parts.count == 2` (`normalizedOffset`) are now unreachable-false given "成功时返回的个数恒等于 `shape.widths.count`", yet the new comment defends them.
