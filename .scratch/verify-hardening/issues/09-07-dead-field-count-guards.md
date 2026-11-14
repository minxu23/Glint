# 两条恒真的字段个数守卫

Status: resolved
Round: 9
Source: Standards 次要 + Spec (c) 4（第 9 轮报告，2026-11-10T06:35Z）
Fixed by: 755285b
Review: ../reviews/round-09-spec.md

## 意见原文

> `parts.count == 3` (`isDate`) and `parts.count == 2` (`normalizedOffset`) are now unreachable-false

## 结论

没法用破坏测试证明（删掉的东西没有证人），改用构造性论证：fields.append 在每个 width 上恰好执行一次，所有失败路径都是 return nil，没有路径返回短数组。isTimeOfDay 的 >= 2 留着——Standards 说它「承重因为它分支」这个理由不准确（守卫是 >= 2，分支是 == 2），但留的结论我同意。
