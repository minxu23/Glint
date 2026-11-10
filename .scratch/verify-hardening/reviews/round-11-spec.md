# 第 11 轮 Spec 轴报告（agent 原文）

- 时间：2026-11-10T09:18:43.273Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-11-aggregate.md 里。

---

## Spec axis — round 11

  Caveat: the worktree is **dirty** (round-10-aggregate.md untracked, selftest.sh/issue-tracker.md modified), so `make test` (64 assertions, all green) does **not** test HEAD. Findings are against HEAD.

  ### (a) Missing / partial

  **1. The new quote guard does not enforce the property spec.md claims it does (headline).**
  spec.md: «要引审查当时到底说了什么，引这里» (= the agent reports) and «没有这个守卫，账本会无声退回成我自己的转述». issue-tracker.md: «the first is a **verbatim** quote of the finding».
  10-08 archived all 16 agent reports but repointed `Review:` only for round 9. **44 of 63 tickets (rounds 1–8) quote the maintainer's own «建议顺序：…» sentence in his own aggregate**, not a finding — e.g. 08-06's entire 意见原文 is `修那两处注释说大话`, absent from both `round-08-standards.md` and `round-08-spec.md`, which are now in the repo. The guard passes because it only asks "is this string in the named file". spec.md boundary #2 excuses only rounds 3/5/6/7; rounds 1, 2, 4, 8 have both agent sides archived.

  **2. Guard holes (mutation-verified on a scratch copy).**
  - Abridgement passes: cutting 10-02's quote to `omits ymdColon, which the code accepts` → `unsupported=0`. issue-tracker.md says «a paraphrased or abridged quote fails the build» — false.
  - `head -1` means only the first `> ` line is checked; I appended a fabricated second quote line → still green.
  - `Fixed by:` guard's `case` needs ≥7 hex chars. `Fixed by: dbb1e1` (git accepts it) → `rotten=0`. A 6-char rotten SHA is invisible.
  - Confirmed working as spec.md claims: one-word paraphrase → red; `Review:` repointed to the same round's other report → red. Reachability independently verified (0 rotten; 19 skipped `—`/`(git init 之前)`).

  **3. issue-tracker.md's «`reviews/` holds the primary sources, three files per round»** is false at HEAD: round 10 has no aggregate, rounds 3/5/6/7 have two files. (The dirty worktree already rewrites this bullet.)

  **4. spec.md still says «连续九轮» and «## 复盘：九轮里反复出现的三种失效»** while this diff adds round 10 (11 tickets) and issue-tracker.md says "ten rounds so far". Same stale-doc family as 09-04.

  **5. 10-11's `## 意见原文` is `44 quotes appear literally in the cited review`** — a true fragment of round-10-spec.md that is not the finding (the ticket says «两轴都没提»). The field is decorative and the guard blesses it.

  ### (b) Scope creep
  None. Every code change is behaviour-preserving: `[5,6]` → `offsetBodyShapes` keeps width order 5,6; `width != 4` ≡ `!(separator == nil && widths == [2,2])` over `timeOfDayShapes`; `dateShapes` is the same literal. Unit suite unchanged (220).

  ### (c) Implemented but wrong
  **6. 10-07 replaced one absolute claim with another.** New comment: «carriesSameValue 另有一处 `filter(\.isNumber)`…（只会少判承载、多报丢失）». Not one-way — `isNumber` keeps non-ASCII numerals, enlarging the haystack: `carriesSameValue("٢٣","x٢٣")` = `true` where an ASCII-only filter gives `false`. The slack points toward "carried", i.e. toward req #1's bad direction. Unreachable in practice, but the sentence asserts a guarantee it doesn't have.

  ### Witnesses that do hold (mutation-verified)
  10-05's claim («删掉 offsetBodyShapes 里的 hhmmColon，两个调用点一起红») → 18 red. 10-06's («翻成 true，`2024Z` 和 `2024+0800` 同时红») → exactly those 2 red. Dropping `.ymdColon` → 4 red; dropping `.hhmm` → `20240915T1842Z` red. `widths == [2,2]` vs `widths.count == 2` and reordering `offsetBodyShapes` are both green — equivalent, not gaps. Tickets 10-01/02/03/04 verified against the files; `EXPECTED_ASSERTIONS` 60→63 matches the three new assertions.

  Minor: 10-05's 结论 says «四张形状清单» then names three; three exist.
