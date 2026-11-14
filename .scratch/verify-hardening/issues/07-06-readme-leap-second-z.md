# README 没写 Z 侧的闰秒例外

Status: resolved
Round: 7
Source: Standards 3 + 7（第 7 轮报告，2026-11-10T03:43Z）
Fixed by: 851d6d1
Review: ../reviews/round-07-standards.md

## 意见原文

> `README.md` `## --verify 到底比什么` 与代码不符（小）

## 结论

README 补上「秒允许 60，那是闰秒」——单测早把 `("23:59:60Z", "+0000")` 断言为必须认，而 README 对 `±` 侧逐条写明了边界，Z 侧这条例外却没写。trap 的措辞也收了一收：脚本只有 `set -uo pipefail`，没有 `-e`。
