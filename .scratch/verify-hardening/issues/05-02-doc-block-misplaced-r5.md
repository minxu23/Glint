# 注释块串位 + canBegin 的过度承诺

Status: resolved
Round: 5
Source: Spec (b) + Standards 3（第 5 轮报告，2026-11-10T01:29Z）
Fixed by: f2b016a
Review: ../reviews/round-05-aggregate.md

## 意见原文

> 注释串位 + `canBegin` 的过度承诺（同一处 hunk，一起改）

## 结论

canBegin 的新注释被追加到 init?(parsing:) 的文档块尾部，于是整段挂在 canBegin 上、init?(parsing:) 变成零文档。本项目注释是主要规格载体。
