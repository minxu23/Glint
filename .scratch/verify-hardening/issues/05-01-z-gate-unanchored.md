# Z 分支是目标侧唯一还没锚定形状的路

Status: resolved
Round: 5
Source: Spec (c)（第 5 轮报告，2026-11-10T01:29Z）
Fixed by: f2b016a
Review: ../reviews/round-05.md

## 意见原文

> (c) 的 Z 分支（唯一会静默隐藏真实丢失的一条，连带 `splitIIMTime` 要拒 `184207+0800Z`）

## 结论

实测 abc0Z / 未知9Z / 镜头型号RF50mm1Z / +08:00 (approx)5Z / 0Z 全部读成 +0000；splitIIMTime(184207+0800Z) 把 +0800 改读成 +0000——这比丢更坏，因为连差异都不剩。
