# 模板字符串是陷阱，改成小类型

Status: resolved
Round: 8
Source: Standards 2/3（第 8 轮报告，2026-11-10T04:28Z）
Fixed by: b5244c1
Review: ../reviews/round-08.md

## 意见原文

> `numericFields` 的模板改成小类型（消掉 `"dddddd"`/`"dd|dd|dd"` 那个陷阱和三处运行时 `parts.count` 检查）

## 结论

重构时发现审查没提的一点：模板里「分几段」那个语义在两个调用点根本没人消费，所以 "dddddd" 和 "dd|dd|dd" 在那里行为完全等价。那两处换成 isAllDigits。
