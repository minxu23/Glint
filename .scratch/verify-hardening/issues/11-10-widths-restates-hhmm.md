# 用内部字段重述 .hhmm，等于第三遍犯同一个毛病

Status: resolved
Round: 11
Source: Standards 判断题（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 61b8213
Review: ../reviews/round-11-standards.md

## 意见原文

> **Primitive Obsession / third restatement**: `return !(shape.separator == nil && shape.widths == [2, 2])` re-describes `.hhmm` by its internals.

## 结论

agent 说「`DigitShape` 不是 `Equatable`，所以老实的 `shape != .hhmm` 用不上」——那就让它 `Equatable`。现在写的是 `shape != .hhmm`。
