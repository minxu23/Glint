# 守卫自己会误诊：真失败时制造第二条假失败

Status: resolved
Round: 7
Source: Standards 5/6 + Spec (a) 1/2（第 7 轮报告，2026-11-10T03:43Z）
Fixed by: cb4b42e
Review: ../reviews/round-07.md

## 意见原文

> 修守卫的误诊（`FAILED > 0` 时跳过断言数检查）、把单测与模型层的条数钉进期望值、`round 8` 改成断言 ✓ 数

## 结论

「少跑了却宣布通过」原本只守住了 shell 层：175 条单测压成 1 个 pass，删掉一半用例套件照样打印「全部通过」。第四种走法——被压成一个 pass 的子套件自己缩水——我根本没想到，而那恰恰是断言数最多的两处。
