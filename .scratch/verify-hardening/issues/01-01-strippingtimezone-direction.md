# strippingTimeZone 把方向做反了：从多报变成漏报

Status: resolved
Round: 1
Source: Spec 1 + Spec 2（第 1 轮报告，2026-11-09T12:57Z）
Fixed by: (git init 之前)
Review: ../reviews/round-01-aggregate.md

## 意见原文

> 把 `strippingTimeZone` 限定到两个 Time 键、要求 `head.count == 6`、删掉走不到的 5 位/冒号分支，并在目标确实没有承载偏移时照样报出来

## 结论

这一轮最要紧的一条。它是为消一个误报而加的，却在「偏移只存在于 IIM、目标没有 OffsetTime」这个子情形下把方向做反了。更难看的是我写的用例「带时区的 IIM 时间也认」恰好把这个漏报钉成了正确行为。
