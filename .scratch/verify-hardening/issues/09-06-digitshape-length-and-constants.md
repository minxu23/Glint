# 形状的长度在调用点旁边被重述，命名只在测试里

Status: resolved
Round: 9
Source: Standards 基线气味（第 9 轮报告，2026-11-10T06:35Z）
Fixed by: 755285b
Review: ../reviews/round-09-standards.md

## 意见原文

> **Duplicated Code / Data Clumps** — a shape's length is restated beside it and nothing keeps them in sync:

## 结论

加 DigitShape.length 与命名常量。测试改成引用生产常量，于是用例同时钉住了常量本身：破坏测试第 4 轮把 ymdColon 的分隔符改成 - ，四条 EXIF 冒号日期用例全红。
