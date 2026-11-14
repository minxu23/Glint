# Z 门按 ISO 8601 的时刻定义重写

Status: resolved
Round: 6
Source: Spec (c) 5 + (c) 6 + Standards 4（第 6 轮报告，2026-11-10T01:51Z）
Fixed by: 909cd1e
Review: ../reviews/round-06-standards.md

## 意见原文

> `terminatesTime` 的 "`HHMMSS`，且整个值就是它：IIM 时间字段之外没有别的东西长这样"

## 结论

两个方向：零范围校验（995999Z、99:99:99Z、拍摄于 18:42:07Z 读成 +0000）与误拒真实形状（2024-09-15T18:42Z、20240915T184207Z、逗号小数秒）。
