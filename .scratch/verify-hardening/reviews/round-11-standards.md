# 第 11 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-10T09:16:17.356Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-11-aggregate.md 里。

---

## Hard: documented-standard violations

  All 63 issue files are touched by this diff, so these are self-inflicted by the rules it adds.

  1. `docs/agents/issue-tracker.md`: "**Bodies use `## 意见原文` and `## 结论`**". **12 of 63 issue files have no `## 结论`** — `issues/07-05-fragile-references.md` ends at the quote; also 01-02, 02-02, 02-03, 02-04, 04-02, 05-04, 05-06, 05-07, 06-05, 07-04, 07-06.
  2. `issue-tracker.md`: "`reviews/` holds the primary sources, **three files per round**". Round 10 has standards + spec but **no `round-10-aggregate.md`** at HEAD. False for the newest round in the same commit. (3/5/6/7 missing an agent side is excused by `spec.md` limitation 2; the missing aggregate is not.)
  3. `issue-tracker.md`: "`Fixed by:` **the commit, or `—`**". 14 files carry a third value, `Fixed by: (git init 之前)`, which the new guard's `[0-9a-f]…` case silently skips.
  4. `.scratch/verify-hardening/spec.md`: agent reports are "一手材料；要引审查当时到底说了什么，引这里", excused only for "第 3、5、6、7 轮". For rounds 1/2/4/8 both agent reports **are** in the repo, yet all 20 of those issues point `Review:` at `round-NN-aggregate.md`, and I verified **none** of their quotes appears in either agent report. 44 of 63 issues quote the aggregate.

  ## Hard: `Tests/selftest.sh` round 10

  (a) **The quote guard passes for the wrong reason.** It checks "the quote is in the file this issue names", not "the quote is the agent's words" — and `Review:` is written by the same hand as the quote. Pointing it at the maintainer-written aggregate makes any paraphrase green, which is precisely the defect `issues/10-08` records: "引了一份不在仓库里的源". It catches a *wrong* report, not a *derivative* one.

  (b) `quote=$(sed -n 's/^> //p' "$issue" | head -1)` takes the first blockquote line **in the whole file**, unscoped to `## 意见原文`. A two-line quote is half-checked.

  (c) **The `Fixed by:` guard has no non-empty witness**, unlike its sibling's `[ "$checked" -gt 0 ]`. Rename the header or let every value become `(git init 之前)` and `rotten` stays 0 — green on the empty set, the "少跑了却宣布通过" mode this file's own header and `expect_count` exist to block. The uncommitted 4th guard names the principle ("不是空集上的恒真"), so HEAD's guard is the outlier.

  `make test` is green on the current tree (64 assertions).

  ## Judgement calls (baseline)

  - **Duplicated Code**: the two guards are the same loop twice (`for issue in "$ledger"/issues/*.md; do … sed -n 's/^X: //p' … | head -1`). `issues/08-03` records the house fix for exactly this shape: "两段守卫抽成 `expect_count`".
  - **Duplicated Code**: the strip is written twice in one hunk — `strip() { tr -d '\`*' < "$1"; }` (re-defined every iteration) beside inline `printf '%s' "$quote" | tr -d '\`*'`.
  - **Primitive Obsession / third restatement**: `return !(shape.separator == nil && shape.widths == [2, 2])` re-describes `.hhmm` by its internals. `DigitShape` isn't `Equatable`, so the honest `shape != .hhmm` is unavailable — the very smell `issues/10-05-third-length-restatement` raised.
  - **Overclaiming comment**: `/// 按用途分组的清单，每张只在这里出现一次` is false — `.hhmm` and `.hhmmColon` each appear in two lists. Repo treats this as a defect class (`10-07`, `08-06`).

  Checked clean: README's "三种形状共用" holds against `normalizedUTCOffset`; `offsetBodyShapes` preserves the old `[5, 6]` order; header order and `Status:` vocabulary conform in all 63 files.
