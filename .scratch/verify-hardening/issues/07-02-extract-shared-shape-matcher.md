# 三个 shape 解析器构成重复 switch

Status: resolved
Round: 7
Source: Standards 4（第 7 轮报告，2026-11-10T03:43Z）
Fixed by: cb4b42e
Review: ../reviews/round-07-aggregate.md

## 意见原文

> 抽出共用的模板匹配，让"同一把尺子"从约定变成代码事实，顺带收掉 `isASCII` 那处名实不符

## 结论

结构性修法：把共用的尺子变成代码事实，这样一侧不可能再被单独收紧。
