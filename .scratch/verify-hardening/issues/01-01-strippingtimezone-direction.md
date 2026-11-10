# strippingTimeZone 把方向做反了：从多报变成漏报

Status: resolved
Round: 1
Source: Spec 1 + Spec 2（第 1 轮报告，2026-11-09T12:57Z）
Fixed by: (git init 之前)
Review: ../reviews/round-01-spec.md

## 意见原文

> `strippingTimeZone` can let `--verify` hide a real loss (false negative).

## 结论

这一轮最要紧的一条。它是为消一个误报而加的，却在「偏移只存在于 IIM、目标没有 OffsetTime」这个子情形下把方向做反了。更难看的是我写的用例「带时区的 IIM 时间也认」恰好把这个漏报钉成了正确行为。
