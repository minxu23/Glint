# 夹具缺 IIM 日期，等价路径没有真实文件覆盖

Status: resolved
Round: 2
Source: Spec 4（第 2 轮报告，2026-11-09T13:48Z）
Fixed by: (git init 之前)
Review: ../reviews/round-02-spec.md

## 意见原文

> No integration coverage for the reworked rule.

## 结论

夹具补上 `{IPTC}/DateCreated` 与 `TimeCreated`，于是整条 IIM 等价路径不再只跑手搭字典——目标侧的键拼法开始对着真实 ImageIO 输出验。
