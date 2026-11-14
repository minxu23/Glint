# UTCOffset 的文档注释被挂到了 DigitShape 上

Status: resolved
Round: 9
Source: Standards 2 + Spec (c) 1（第 9 轮报告，2026-11-10T06:35Z）
Fixed by: 755285b
Review: ../reviews/round-09-spec.md

## 意见原文

> One contiguous `///` block opening `/// UTC 偏移，归一化成「符号 + HHMM」…做成类型而不是继续传裸 String` is attached to `struct DigitShape` (line 205).

## 结论

既有的孤儿注释（851d6d1 时悬在 numericFields 头上），但上一轮我把它搬到了一个新引入的类型头上，从悬空变成错配。
