# 第 2 轮押后的三条气味与通知缺口

Status: needs-triage
Round: 2
Source: Standards 判断题 + Spec 5（第 2 轮报告，2026-11-09T13:48Z）
Fixed by: —
Review: ../reviews/round-02.md

## 意见原文

> 气味那三条和 Spec 5 的潜在通知缺口押后

## 结论

三条气味是 MetadataDiff 四个表各自手拼键路径（Duplicated Code）、两个偏移解析器并排（Duplicated Code）、偏移是裸 String（Primitive Obsession）。后两条可确认已落地（UTCOffset 类型在第 3 轮已存在）。通知缺口（reexpand 的 guard !isRunning 与注释矛盾）需复核。
