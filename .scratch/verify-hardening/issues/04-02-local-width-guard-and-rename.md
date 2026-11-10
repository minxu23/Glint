# normalized 缺本地宽度守卫，且是个 Mysterious Name

Status: resolved
Round: 4
Source: Standards + Spec（第 4 轮报告，2026-11-09T15:02Z）
Fixed by: (git init 之前)
Review: ../reviews/round-04-standards.md

## 意见原文

> the two `normalized` overloads. `normalized` is a bare adjective: normalized *what*?

## 结论

三件一起：`token.count` 守卫落到函数内（不再依赖调用方的 `for width in [5, 6]`）、两个 `normalized` 重载改名成 `normalizedOffset(atEndOf:)` / `(token:precededBy:)`、「偏移起始字符」那套字母表收回 `UTCOffset`。
