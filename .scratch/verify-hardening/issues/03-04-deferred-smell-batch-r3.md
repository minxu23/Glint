# 第 3 轮押后：xmpKey 与「解析器藏在 init 里」

Status: needs-triage
Round: 3
Source: Standards 判断题（第 3 轮报告，2026-11-09T14:22Z）
Fixed by: —
Review: ../reviews/round-03-aggregate.md

## 意见原文

> `xmpKey` 和「解析器藏在 init 里」两条判断题押后

## 结论

xmpKey 在第 4 轮报告里已出现（说明落地了）。「解析器藏在 init 里」即 UTCOffset 的约 30 行 failable init，现在仍是 init?(parsing:) 转调 normalizedOffset(atEndOf:)，需复核是否算解决。
