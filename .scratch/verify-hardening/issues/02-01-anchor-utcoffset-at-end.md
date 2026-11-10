# utcOffset 未锚定末尾，Z 不走形状检查

Status: resolved
Round: 2
Source: Spec 2 + Spec 1（第 2 轮报告，2026-11-09T13:48Z）
Fixed by: (git init 之前)
Review: ../reviews/round-02.md

## 意见原文

> 把 `utcOffset` 锚定到末尾、`Z` 也走形状检查，并补畸形输入的用例

## 结论

两轴各自指向同一件事：我把源侧改成了精确形状，却把目标侧的读取器留在松散状态。上一轮的 finding 原话就是「Z 分支不做形状检查」，我修了调用方、漏了被调用方。
