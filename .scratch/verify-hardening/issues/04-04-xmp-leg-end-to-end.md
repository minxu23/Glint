# XMP 腿其实端到端可达，「做不出来」的结论是错的

Status: resolved
Round: 4
Source: Spec (a) 1（第 4 轮报告，2026-11-09T15:02Z）
Fixed by: (git init 之前)
Review: ../reviews/round-04-spec.md

## 意见原文

> Item 3's limitation claim is half wrong — the XMP leg *is* reachable end-to-end (verified).

## 结论

我上一轮的结论「ImageIO 不合成 XMP 日期」完全是仪器的产物：Tests/probe 当时根本不读 XMP，所有 XMP/ 探测无条件返回 <无>。
