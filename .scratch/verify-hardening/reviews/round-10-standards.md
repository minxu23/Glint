# 第 10 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-10T08:27:42.863Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-10-aggregate.md 里。

---

## Standards axis

  ### Ledger (`2885887`) — documented-standard breaches

  **1. Issue filenames don't match the documented scheme (hard).** `docs/agents/issue-tracker.md:9`: "Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`"; the Wayfinding section repeats `.scratch/<effort>/issues/NN-<slug>.md`. All 52 files use a two-part `NN-MM-<slug>.md` and restart `MM` at `01` each round. `spec.md` asserts "格式依 [`docs/agents/issue-tracker.md`]" and then defines its own scheme two lines later. Either rename to one running number or amend `issue-tracker.md` to bless `NN-MM`.

  **2. `reviews/` and four header fields are undocumented layout (hard, smaller).** `issue-tracker.md` enumerates `Status:` (and, for wayfinding, `Type:`/`Blocked by:`). Every ticket adds `Round:`, `Source:`, `Fixed by:`, `Review:`, and `reviews/round-NN.md` is a sibling of `issues/` that the doc never mentions. The layout is now single-sourced in `spec.md` instead of `issue-tracker.md`.

  *Not a violation, no action:* `Status: resolved` (47 files) is outside `triage-labels.md`'s five strings, but `issue-tracker.md:26` defines `resolved` and `spec.md` documents the borrowing. Numbering, `Round:`/`Review:` cross-references and header shape are internally consistent with no gaps (checked all 52).

  ### Code (`755285b`)

  **3. The diff strands a doc comment it contradicts (hard).** `/Users/minxu/Claude/jpeg2heif/Sources/Core/MetadataDiff.swift:252-258`, unchanged, still reads: "`normalizedOffset` 里那句「宽度前提在本函数内成立」还在，而且该在，因为那里真有一个按宽度分支的 switch。调用点各自 guard 字段个数也是同一个道理". This diff deleted that `switch` (now `.first(where: { $0.length == body.count })`) and deleted both `parts.count` guards. Both halves of the sentence are now false.

  **4. Possible Duplicated Code (judgement).** `MetadataDiff.swift:316`: `for width in [5, 6] where chars.count >= width`. The new `length` property's own rationale is "由形状自己推出来，不在调用点旁边重述", yet `5`/`6` are `DigitShape.hhmm.length + 1` and `.hhmmColon.length + 1` restated as literals — and line 392 still points at them. `for shape in [DigitShape.hhmm, .hhmmColon]` with `shape.length + 1` closes it.

  **5. Possible Primitive Obsession (judgement).** `if head.count == width { return width != 4 }` plus the new "（四种形状里只有 `hhmm` 长 4，`hhmmColon` 长 5）". The comment exists only to decode the literal; `shape.separator == nil && shape.widths.count == 2` states the condition.

  **6. Overclaiming comment (judgement).** Line 248: "全文件只有 isAllDigits 一处定义「ASCII 数字」". True as worded, but lines 467-468 (`carriesSameValue`) use `filter(\.isNumber)` — a second, looser digit test in the same file. The absolute phrasing invites a reader to miss it.

  ### README

  Prose now matches the code on every normative claim I traced: `20240915+0800`, `995999Z`, `9999-99-99T…`, `+999-09-15T…`, the `202409Z` ambiguity, standalone-`HHMM` rejection, Z's non-empty rule, month 1–12/day 1–31, and the total-minutes offset range. Moving the shared-preamble rule out from under `…Z` is correct. `EXPECTED_UNIT=220` matches the 5 added assertions. Minor: `## 目录结构` gains no row for `.scratch/` though 62 tracked files landed there (`docs/` is likewise absent already, so the table is already non-exhaustive).
