# README 的 202409 歧义还留在 Z 段落里

Status: resolved
Round: 10
Source: Spec 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: 60b1783
Review: ../reviews/round-10-spec.md

## 意见原文

> 1. **09-02 (`resolved`) is only two-thirds fixed.** README still parks a shared rule inside the Z-only paragraph — one sentence lower than before: «`…Z` 那一种只多一条自己的规则…光一个 `Z` 不算 UTC。唯一消不掉的歧义是 `202409Z`». Verified the ambiguity is not Z-specific: `UTCOffset(parsing: "202409+0800")` → `+0800`, `"202409-1200"` → `-1200`. Same structural error this commit's headline finding was about, with a Z-only example.

## 结论

已量：`202409+0800` → `+0800`、`202409-1200` → `-1200`，歧义在 ± 侧一模一样。更难看的是代码里 isTimestamp 的注释写的是 `202409`（没有 Z），它本来就知道这不是 Z 专属——只有 README 说成了 Z 专属，而那段 README 是第 9 轮我亲手重排的：搬出了两条，把紧跟其后的第三条留在了里面。
