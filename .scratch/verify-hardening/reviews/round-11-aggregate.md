# 第 11 轮 聚合报告（原文）

- 报告时间：2026-11-10T09:16Z / 09:18Z
- 定点：2885887（覆盖 60b1783、a36c55b、214fe00）
- 来源：本轮直接写成，不是从转写本找回的——前十轮的聚合是事后从会话里挖出来的，
  这一份是当场落盘。两轴的措辞保持分开，没有合并也没有重排。

---

## Standards

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

## Spec

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

---

## 我核过的部分

两轴**独立撞上同一条头号问题**：我上一轮加的引文守卫查的是「引文在这个 issue
自己指名的文件里」，而 `Review:` 和引文是同一只手写的——把它指向我自己的聚合，
任何转述都是绿的。实测数字：

```
缺 ## 结论                    12 / 63
Fixed by: 取值                sha 44、— 5、(git init 之前) 14
Review: 指向                  aggregate 44、spec 10、standards 9
第 1/2/4/8 轮（两侧 agent 原文都在库）共 20 条，引文在任何 agent 报告里找不到：20
```

20/20。不是「有些漂了」，是没有一条。

**Spec 的三个守卫洞我只堵得了两个。** `head -1` 和 6 位 SHA 都修了；**删节能通过
这条守卫原理上查不出来**——`grep -F` 是子串匹配，任何缩短仍是子串，而光看引文
本身也没法区分「公正的节选」和「误导的删节」。所以我没假装加强守卫，改掉了文档里
那句「转述或删节都会让构建变红」，并写明它实际只能挡转述和引错来源。

**Spec (c)6 我接，而且它比报告写的更要紧。** 实测 `carriesSameValue("٢٣", "x٢٣")`
是 `true`，ASCII-only 过滤会返回 `false`——松的那一侧偏向「算承载」，正是本项目
叫静默放过的方向。我上一轮写的「只会少判承载、多报丢失」是错的，而且错在危险那边。
注释改成只记实测事实。**行为我没动**：改成 ASCII-only 会更多报（安全方向），但那是
一次没人要求的行为变更。

**Standards 第 11 条（「每张只在这里出现一次」）的读法我不同意，但不争。** 按原意
「每张**清单**只出现一次」为真；agent 读成「每个形状只属于一张」。考虑到本项目在
「注释说大话」上栽过四次，直接把歧义写死比争读法划算。

**一条两轴都没提、我自己撞上的：`make test` 不可复现。** 同一棵树连跑两次，一次
全过、一次红在五处，之后再跑两次又都过，至今没复现。没定位根因，所以记成
`needs-triage`（见 `issues/11-16`）。做的只是把「工作目录被擦干净」从假设变成查过。
这条意味着：**这个会话里每一句「全部通过」，都只在「那一次目录恰好是干净的」这个
前提下成立**，而这个前提当时没人查。
