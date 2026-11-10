# Makefile 两份产物清单 + 重复 .PHONY

Status: resolved
Round: 7
Source: Standards 1/2（第 7 轮报告，2026-11-10T03:43Z）
Fixed by: cb4b42e
Review: ../reviews/round-07-standards.md

## 意见原文

> `Makefile`：`print-artifacts` 被声明了两次 `.PHONY`

## 结论

`ARTIFACTS :=` 消掉真实的双份产物清单；两处 `.PHONY` 里单独那条删掉——两处编辑之一本来就是死的。
