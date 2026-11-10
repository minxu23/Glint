# 第 10 轮 Spec 轴报告（agent 原文）

- 时间：2026-11-10T08:31:19.125Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-10-aggregate.md 里。

---

## Spec axis — round 10

  `make test` green (60/220/37); `EXPECTED_UNIT=220` matches. Mutations run on a scratch copy; repo untouched (`git status` clean).

  **The seven round-9 tickets are genuinely satisfied, not gestured at.** Verified by mutation:
  - 09-01 / req 5 («either make the condition load-bearing or drop the apology»): dropping `isAllDigits` from `numericFields` → 2 red; dropping `isASCII` from `isAllDigits` → 1 red (`全角数字不算——这里没有 Int 兜着`). The condition is now load-bearing with a real witness.
  - 09-06: `DigitShape.length + 1` → 42 red, including all three new `length` assertions; `ymdColon` separator → 5 red; `hhmmColon` → 20 red incl. `2024-09-15T18:42+08:00` (the ± side), which is exactly 09-02's claimed witness.
  - 09-07's constructive argument holds: `fields.append` runs once per width, every failure path returns nil.
  - 09-08 `wontfix` is justified — `reviews/round-08.md:98` does bundle rename + extract + delete in one step, verbatim.

  ### (a) Missing / partial — the ledger's own spec
  spec.md: «`reviews/round-NN.md` —— 每轮两轴报告的**原文**，逐字复制，未经编辑… 要引审查当时到底说了什么，引这里». Checked all 52 issue files: **44 quotes appear literally in the cited review; all 7 round-9 files fail.** Six quote English — `"The apology was relocated, not resolved."`, `"One contiguous /// block opening…"`, `"Stale 模板 at MetadataDiff.swift:343"`, `"a shape's length is restated beside it…"`, `"parts.count == 3 … are now unreachable-false"`, `"Ticket 3 asks only…"` — but `round-09.md` contains no English except one quoted requirement line. 09-02's Chinese quote is likewise a reconstruction, not in the file. So the one round checkable against an in-repo review is the round where `## 意见原文` is paraphrase. (05-01 silently abridges, dropping `，证人用上面那四个`.)

  Also: `round-09.md` has **no 建议顺序 list**, so spec.md's «`MM` 是它在那一轮"建议顺序"里的位次» is unsupported for round 9 — the `MM` numbering is unverifiable exactly where it matters.

  spec.md «格式依 `docs/agents/issue-tracker.md`» is false as written: that doc mandates `issues/<NN>-<slug>.md` "numbered from 01" and comments «under a `## Comments` heading». Files are `NN-MM-<slug>.md` with `## 意见原文`/`## 结论`.

  ### (b) Scope creep
  None. The code diff maps 1:1 onto the seven tickets.

  ### (c) Looks implemented, implemented wrong
  1. **09-02 (`resolved`) is only two-thirds fixed.** README still parks a shared rule inside the Z-only paragraph — one sentence lower than before: «`…Z` 那一种只多一条自己的规则…光一个 `Z` 不算 UTC。唯一消不掉的歧义是 `202409Z`». Verified the ambiguity is not Z-specific: `UTCOffset(parsing: "202409+0800")` → `+0800`, `"202409-1200"` → `-1200`. Same structural error this commit's headline finding was about, with a Z-only example.
  2. **`MetadataDiff.swift:333** (`isTimestamp` doc): «日期是 `YYYY-MM-DD` 或 `YYYYMMDD`» — omits `ymdColon`, which the code accepts and the new README documents. Same req-6 family as 09-05, left behind.
  3. 09-07 traded dead guards for unchecked subscripts: `isDate` reads `parts[1]`/`parts[2]` and `normalizedOffset` reads `parts[0]`/`parts[1]` with no local count check, while `normalizedOffset`'s own comment four lines above insists «宽度前提在本函数内成立，不寄托于调用方». Fails loudly, so req 1 is safe — but it is the repo's own round-4 Standards finding reintroduced.

  README is otherwise honest about the new code: I hand-checked `20240915+0800`, `9999-99-99T18:42:07+08:00`, `995999Z`, `拍摄于 18:42:07Z` against the shapes and all four are rejected as documented.
