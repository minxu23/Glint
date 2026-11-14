# 引文提取没限定在 ## 意见原文 段内，多行只查第一行

Status: resolved
Round: 11
Source: Standards (b)（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 98869ac
Review: ../reviews/round-11-standards.md

## 意见原文

> `quote=$(sed -n 's/^> //p' "$issue" | head -1)` takes the first blockquote line **in the whole file**, unscoped to `## 意见原文`.

## 结论

当时没有多行引文，所以是潜在洞而非现行洞——但洞是真的。改成 awk 限定段内、整段每行都核。
