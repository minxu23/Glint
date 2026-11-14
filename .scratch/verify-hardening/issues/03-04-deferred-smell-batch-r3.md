# 第 3 轮押后：xmpKey 与「解析器藏在 init 里」

Status: resolved
Round: 3
Source: Standards 判断题（第 3 轮报告，2026-11-09T14:22Z）
Fixed by: (git init 之前)
Review: ../reviews/round-03-standards.md

## 意见原文

> ### Judgement calls (baseline)

## 结论

xmpKey 在第 4 轮报告里已出现（说明落地了）。「解析器藏在 init 里」即 UTCOffset 的约 30 行 failable init，现在仍是 init?(parsing:) 转调 normalizedOffset(atEndOf:)，需复核是否算解决。

## Comments

2026-11-13 复核：对照 `f4d4d75` 的代码，两条都已落地：

1. `xmpKey`：已有 `xmpKey(_:)`，`MetadataDiff.swift` 里手拼的 `"XMP/` 只剩它自己这一处。
2. 「解析器藏在 init 里」：`UTCOffset.init?(parsing:)` 只转调私有的静态函数
   `normalizedOffset(atEndOf:)`，解析不在构造器本体里了。

各处修法在仓库第一个提交 `fada564`（基线）里就已经在了，具体是哪一轮改的，从转写本里对不出来。
