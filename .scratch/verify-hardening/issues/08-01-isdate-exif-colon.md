# isDate 不认 EXIF 自己的日期格式（本轮唯一行为缺陷）

Status: resolved
Round: 8
Source: Spec (c)（第 8 轮报告，2026-11-10T04:28Z）
Fixed by: b5244c1
Review: ../reviews/round-08-spec.md

## 意见原文

> ### (c) 实现看起来不对：`±` 侧新引入了一处真实误拒

## 结论

讽刺的地方在于：被拒的恰恰是这个项目读得最多的格式。上一轮我还在总结里说「从规范定义出发列全集」是解法，这轮就被同一个思路坑了——我列全了 ISO 8601 的全集，而 EXIF 的日期不是 ISO 8601。
