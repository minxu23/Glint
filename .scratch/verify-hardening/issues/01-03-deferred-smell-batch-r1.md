# 第 1 轮押后的基线气味

Status: resolved
Round: 1
Source: Standards 判断题（第 1 轮报告，2026-11-09T12:57Z）
Fixed by: (git init 之前)
Review: ../reviews/round-01-standards.md

## 意见原文

> ### Baseline smells (judgement calls)

## 结论

后续被 2026-11-09T14:09Z「那三条气味也一起处理了吧」与 14:43Z「把剩下的判断题也修了」两次明确要求覆盖，但哪一条对应哪一次从转写本里对不出来。需要人工复核是否全部落地。

## Comments

2026-11-13 复核：三条逐条对照 `f4d4d75` 的代码，都已落地：

1. 测试里重复的 `allJpegs(in:)` / `heics(in:)`：已合成 `files(in:ext:deep:)`（`Tests/guimodel/main.swift`）。
2. `detailText` 的重复 switch：现在是 `case .skipped(let why), .failed(let why)` 直接绑定；
   `RowStatus.isSettled` 已有，`recount()` 用它数完成的行（`Sources/GUI/Model.swift`）。
3. `updateOptions` 放宽了口子：现在改完会把 `inputs`、`output` 还原成改之前的值，调用方改不动这两项。

各处修法在仓库第一个提交 `fada564`（基线）里就已经在了，具体是哪一轮改的，从转写本里对不出来。
