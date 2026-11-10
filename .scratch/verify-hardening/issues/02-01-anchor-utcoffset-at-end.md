# utcOffset 未锚定末尾，Z 不走形状检查

Status: resolved
Round: 2
Source: Spec 2 + Spec 1（第 2 轮报告，2026-11-09T13:48Z）
Fixed by: (git init 之前)
Review: ../reviews/round-02-spec.md

## 意见原文

> `utcOffset`'s `Z` branch still has no shape check

## 结论

两轴各自指向同一件事：我把源侧改成了精确形状，却把目标侧的读取器留在松散状态。上一轮的 finding 原话就是「Z 分支不做形状检查」，我修了调用方、漏了被调用方。
