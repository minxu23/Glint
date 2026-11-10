# 失真的 // Z 分支零形状检查 标签

Status: resolved
Round: 6
Source: Standards 5（第 6 轮报告，2026-11-10T01:51Z）
Fixed by: d717eeb
Review: ../reviews/round-06-standards.md

## 意见原文

> `Tests/unit/main.swift` 旧标签失真

## 结论

删掉 `// Z 分支零形状检查` 这个已经失真的标签（当时已有形状检查），并给 `terminatesTime` 补上「前提本地成立」那句。
