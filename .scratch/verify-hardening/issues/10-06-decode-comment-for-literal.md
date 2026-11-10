# 用注释解码一个字面量，不如直接写出条件

Status: resolved
Round: 10
Source: Standards 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: dbb1e1e
Review: ../reviews/round-10-standards.md

## 意见原文

> **5. Possible Primitive Obsession (judgement).** `if head.count == width { return width != 4 }` plus the new "（四种形状里只有 `hhmm` 长 4，`hhmmColon` 长 5）". The comment exists only to decode the literal; `shape.separator == nil && shape.widths.count == 2` states the condition.

## 结论

改成 `!(shape.separator == nil && shape.widths == [2, 2])`。破坏测试把它翻成 `true`，`2024Z` 和 `2024+0800` 同时红——正好印证重排后的 README 说的「这条三种形状共用」。
