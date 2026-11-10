# 两处注释说大话

Status: resolved
Round: 8
Source: Standards 1（第 8 轮报告，2026-11-10T04:28Z）
Fixed by: b5244c1
Review: ../reviews/round-08-standards.md

## 意见原文

> 注释说大话（本轮又一例，`Sources/Core/MetadataDiff.swift:205-207`）

## 结论

「现在只有这里需要那句话」被同一个 diff 里 normalizedOffset 的同句注释当场推翻。改法不是删掉那句，而是承认它该在——那里真有一个按宽度分支的 switch。
