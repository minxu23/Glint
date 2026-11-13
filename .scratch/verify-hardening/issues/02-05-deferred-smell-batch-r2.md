# 第 2 轮押后的三条气味与通知缺口

Status: resolved
Round: 2
Source: Standards 判断题 + Spec 5（第 2 轮报告，2026-11-09T13:48Z）
Fixed by: (git init 之前)
Review: ../reviews/round-02-standards.md

## 意见原文

> ### Judgement calls (baseline smells)

## 结论

三条气味是 MetadataDiff 四个表各自手拼键路径（Duplicated Code）、两个偏移解析器并排（Duplicated Code）、偏移是裸 String（Primitive Obsession）。后两条可确认已落地（UTCOffset 类型在第 3 轮已存在）。通知缺口（reexpand 的 guard !isRunning 与注释矛盾）需复核。

## Comments

2026-11-13 复核：逐条对照 `16a0dcd` 的代码，都已落地：

1. 四个表各自手拼键路径：已有 `metadataKey` / `exifKey` / `iptcKey`（`Sources/Eclose/MetadataDiff.swift`）。
2. 两个偏移解析器并排：`splitIIMTime` 现在返回 `UTCOffset?`，偏移只由 `UTCOffset` 解析。
3. 偏移是裸 String：已是 `UTCOffset` 类型。
4. 通知缺口：`updateOptions` 里调 `reexpand()` 的地方写明了 `guard !isRunning` 会一声不响地返回、
   界面上走不到、哪天有别的调用方就得一起改（`Sources/GUI/Model.swift`）。

各处修法在仓库第一个提交 `ecc0f1b`（基线）里就已经在了，具体是哪一轮改的，从转写本里对不出来。
