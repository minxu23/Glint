# Fixed by: 有第三种取值，而守卫静默跳过它

Status: resolved
Round: 11
Source: Standards 3（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 61b8213
Review: ../reviews/round-11-standards.md

## 意见原文

> `issue-tracker.md`: "`Fixed by:` **the commit, or `—`**". 14 files carry a third value, `Fixed by: (git init 之前)`, which the new guard's `[0-9a-f]…` case silently skips.

## 结论

14 条 `(git init 之前)` 从没被任何守卫看过一眼。改法：取值成文为三种，并且守卫不按长度猜 SHA——交给 `git rev-parse` 判，未成文的字面值一律出声。
