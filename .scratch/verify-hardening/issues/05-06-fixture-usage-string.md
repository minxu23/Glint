# fixture 的 stderr 用法串漏了新旗标，且与文件头重复

Status: resolved
Round: 5
Source: Standards 1（第 5 轮报告，2026-11-10T01:29Z）
Fixed by: f2b016a
Review: ../reviews/round-05-aggregate.md

## 意见原文

> fixture 的 stderr 用法串与重复

## 结论

stderr 的用法串漏了新旗标，而文件头那份跟着改了。两份合成一个 `usage` 常量，不再各写一遍。
