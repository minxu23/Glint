# 6 位 SHA 被守卫按长度漏掉

Status: resolved
Round: 11
Source: Spec (a)2（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 61b8213
Review: ../reviews/round-11-spec.md

## 意见原文

> - `Fixed by:` guard's `case` needs ≥7 hex chars.

## 结论

`dbb1e1`（6 位）git 认、守卫的 `[0-9a-f]×7` 模式不认。和 11-03 一起修：不按长度猜，交给 git。
