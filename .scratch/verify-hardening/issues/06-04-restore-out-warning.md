# 7b 复用 out 时删掉了实测换来的警告注释

Status: resolved
Round: 6
Source: Standards 3 + Spec (c) 4（第 6 轮报告，2026-11-10T01:51Z）
Fixed by: d717eeb
Review: ../reviews/round-06.md

## 意见原文

> 恢复 `out` 那条警告注释

## 结论

现在的正确性只靠「7b 排在那条断言之后」的位置关系维持，挪动即复发。
