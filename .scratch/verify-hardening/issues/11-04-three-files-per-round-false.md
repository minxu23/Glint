# 「每轮三份」这条规则写下来的当场就不成立

Status: resolved
Round: 11
Source: Standards 2 + Spec 3（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 98869ac
Review: ../reviews/round-11-standards.md

## 意见原文

> `issue-tracker.md`: "`reviews/` holds the primary sources, **three files per round**". Round 10 has standards + spec but **no `round-10-aggregate.md`** at HEAD.

## 结论

这条我在启动两个 agent 之前就自己数出来了。第 10 轮的聚合不是丢失、是我根本没存。改法：从转写本取回第 10 轮聚合入库，规则改成「聚合每轮必有（有守卫），agent 原文能找回就归档、找不回就在 spec.md 列明」。
