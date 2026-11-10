# 同一个提交里删掉了注释的论据，却把注释留在原地

Status: resolved
Round: 10
Source: Standards 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: c0a0cf2
Review: ../reviews/round-10-standards.md

## 意见原文

> **3. The diff strands a doc comment it contradicts (hard).** `/Users/minxu/Claude/jpeg2heif/Sources/Core/MetadataDiff.swift:252-258`, unchanged, still reads: "`normalizedOffset` 里那句「宽度前提在本函数内成立」还在，而且该在，因为那里真有一个按宽度分支的 switch。调用点各自 guard 字段个数也是同一个道理". This diff deleted that `switch` (now `.first(where: { $0.length == body.count })`) and deleted both `parts.count` guards. Both halves of the sentence are now false.

## 结论

第 8 轮 Standards 的头号意见就是这块注释说大话；我第 8 轮改写它时，理由恰恰是「那里真有一个按宽度分支的 switch」；第 9 轮报告里我还写了「这条守住了」；而第 9 轮的 ⑥⑦ 把这个理由本身删掉了。同一块注释连续第四轮说大话。改法：把两个分句都按现状重写，并写明「注释写成"因为 X 所以 Y"时，X 必须跟着代码一起维护」。
