# README 与注释跟实现对齐

Status: resolved
Round: 1
Source: Standards + Spec（第 1 轮报告，2026-11-09T12:57Z）
Fixed by: (git init 之前)
Review: ../reviews/round-01-standards.md

## 意见原文

> The function's own doc comment is also out of step with its first line: it says 「4 位或 5 位偏移」 and never mentions the `Z` branch at all

## 结论

两处都对齐了：`strippingTimeZone` 的文档注释原本说「4 位或 5 位偏移」、完全不提 `Z` 分支；README 的 `--verify` 段也只写了「全数字 + 号 + 4 位偏移」一种形状，而代码认三种。
