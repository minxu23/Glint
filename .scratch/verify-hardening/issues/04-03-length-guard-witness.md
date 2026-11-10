# 长度守卫必要但无覆盖，注释自举的证人还是错的

Status: resolved
Round: 4
Source: Spec (a) 2（第 4 轮报告，2026-11-09T15:02Z）
Fixed by: (git init 之前)
Review: ../reviews/round-04-spec.md

## 意见原文

> Guard #1 (length) is necessary but untested — mutation-verified.

## 结论

变异验证：删掉 chars.count == 7 || 11 || 12 后 10 条 splitIIMTime 用例全过，而 184207+12+0800 静默丢掉 +12。注释原本举的证人 184207123+0800 本来就被 chars[6] 拒掉了。
