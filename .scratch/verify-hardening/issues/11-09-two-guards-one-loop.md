# 两条守卫是同一个循环写了两遍

Status: resolved
Round: 11
Source: Standards 判断题（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 98869ac
Review: ../reviews/round-11-standards.md

## 意见原文

> **Duplicated Code**: the two guards are the same loop twice

## 结论

`08-03` 记的就是这个房规（「两段守卫抽成 `expect_count`」），我隔两轮又犯一次。合成一个循环，顺带 `strip` 那两份（函数定义 + 内联）也归一。
