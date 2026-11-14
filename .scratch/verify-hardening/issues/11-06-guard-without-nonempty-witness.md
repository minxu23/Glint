# Fixed by: 那条守卫没有「清单非空」的证人

Status: resolved
Round: 11
Source: Standards (c)（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 98869ac
Review: ../reviews/round-11-standards.md

## 意见原文

> **The `Fixed by:` guard has no non-empty witness**, unlike its sibling's `[ "$checked" -gt 0 ]`.

## 结论

空集上的「全都满足」恒真。更难看的是：我同一时间未提交的那第四条守卫注释里恰好写着「不是空集上的恒真」这个原则——我说得出，却没对已提交的那条用上。现在四条守卫共用一个 `checked > 0` 证人。
