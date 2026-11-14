# [5, 6] 是三处长度重述里漏掉的那一处

Status: resolved
Round: 10
Source: Standards 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: 60b1783
Review: ../reviews/round-10-standards.md

## 意见原文

> **4. Possible Duplicated Code (judgement).** `MetadataDiff.swift:316`: `for width in [5, 6] where chars.count >= width`. The new `length` property's own rationale is "由形状自己推出来，不在调用点旁边重述", yet `5`/`6` are `DigitShape.hhmm.length + 1` and `.hhmmColon.length + 1` restated as literals — and line 392 still points at them. `for shape in [DigitShape.hhmm, .hhmmColon]` with `shape.length + 1` closes it.

## 结论

第 9 轮我收了两处长度重述（isTimestamp、normalizedOffset(_:)），漏了这一处——又是「紧了两侧、留松第三侧」。改法不止换成形状：三张形状清单（timeOfDayShapes / dateShapes / offsetBodyShapes）各命名一次放在 DigitShape 旁边，两个调用点共用同一张表。破坏测试：删掉 offsetBodyShapes 里的 hhmmColon，两个调用点一起红。
