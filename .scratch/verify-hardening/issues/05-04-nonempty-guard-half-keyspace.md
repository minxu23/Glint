# 非空守卫只守了一半键空间

Status: resolved
Round: 5
Source: Spec (a)（第 5 轮报告，2026-11-10T01:29Z）
Fixed by: 8028818
Review: ../reviews/round-05-spec.md

## 意见原文

> ### (a) 部分落地：新轮次的非空守卫只守了一半键空间

## 结论

补上 `XMP/exif:OffsetTime*`。这条守卫存在的理由正是「哪天 ImageIO 自己补一个 OffsetTime，上面那条就退化成空跑」——只守一半等于另一半照样会让整轮静默退化。
