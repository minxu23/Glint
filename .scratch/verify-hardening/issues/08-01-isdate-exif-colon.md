# isDate 不认 EXIF 自己的日期格式（本轮唯一行为缺陷）

Status: resolved
Round: 8
Source: Spec (c)（第 8 轮报告，2026-11-10T04:28Z）
Fixed by: b5244c1
Review: ../reviews/round-08.md

## 意见原文

> `isDate` 加 `"dddd:dd:dd"`（唯一行为缺陷，带用例，并补 EXIF 冒号日期进"真实写法"那一组）

## 结论

讽刺的地方在于：被拒的恰恰是这个项目读得最多的格式。上一轮我还在总结里说「从规范定义出发列全集」是解法，这轮就被同一个思路坑了——我列全了 ISO 8601 的全集，而 EXIF 的日期不是 ISO 8601。
