# README:35 与两条注释的文档对齐

Status: resolved
Round: 2
Source: Spec 3 + Standards（第 2 轮报告，2026-11-09T13:48Z）
Fixed by: (git init 之前)
Review: ../reviews/round-02-spec.md

## 意见原文

> README over-promises the carrier set.

## 结论

改 README 而不是改代码——方向上它是多报，是 README 自己许诺过头了：写的是「或带偏移的 XMP 时间戳」，而 `offsetSurvives` 只查该键自己的两个等价时间戳。
