# 守卫查的是「引文在它自己指名的文件里」，而那个文件由同一只手指定

Status: resolved
Round: 11
Source: Standards (a) + Spec (a)1（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 98869ac
Review: ../reviews/round-11-spec.md

## 意见原文

> **1. The new quote guard does not enforce the property spec.md claims it does (headline).**

## 结论

两轴独立撞上同一条，这是十一轮里最锋利的一条。数字：44/63 指向我的聚合；第 1/2/4/8 轮两侧 agent 原文都在库里，那 20 条却一条都不引它们（20/20）。

改法是把 `Review:` 从自由指定变成受约束：某轮某轴的 agent 原文在库里时，引文**必须**出自它；聚合只在那一侧确实丢失、或这条本来不是审查提的时才允许。守卫先写、后修数据，于是它在 35 条真实缺陷上变红，然后我逐条从 agent 原文取verbatim 替换（预检 35/35 通过）。
