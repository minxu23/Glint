# 「全文件只有一处」这种绝对化措辞

Status: resolved
Round: 10
Source: Standards 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: dbb1e1e
Review: ../reviews/round-10-standards.md

## 意见原文

> **6. Overclaiming comment (judgement).** Line 248: "全文件只有 isAllDigits 一处定义「ASCII 数字」". True as worded, but lines 467-468 (`carriesSameValue`) use `filter(\.isNumber)` — a second, looser digit test in the same file. The absolute phrasing invites a reader to miss it.

## 结论

字面不假（isAllDigits 确实是唯一定义 **ASCII** 数字的地方），但绝对化会让读者漏掉 carriesSameValue 那处故意更松的 `filter(\.isNumber)`。改成点名它、并说明它为什么不是第二份定义（只会少判承载、多报丢失）。
