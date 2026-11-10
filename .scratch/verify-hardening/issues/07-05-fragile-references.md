# 两处脆弱引用：行号与被吞的 stderr

Status: resolved
Round: 7
Source: Standards 8（第 7 轮报告，2026-11-10T03:43Z）
Fixed by: cb4b42e
Review: ../reviews/round-07-standards.md

## 意见原文

> 两处脆弱引用：

## 结论

`probe-src` 里引 `Converter.swift:49` 改成引函数名（行号必漂）；`print-artifacts` 不再 `2>/dev/null` 吞掉 stderr，否则 Makefile 真出语法错会被报成「问不到产物清单」。
