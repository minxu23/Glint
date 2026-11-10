# 10-07 把一条绝对化论断换成了另一条，而且方向错在危险那侧

Status: resolved
Round: 11
Source: Spec (c)6（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 61b8213
Review: ../reviews/round-11-spec.md

## 意见原文

> **6. 10-07 replaced one absolute claim with another.**

## 结论

实测：`carriesSameValue("٢٣", "x٢٣")` 是 `true`，而 ASCII-only 过滤会让源侧成空串、返回 `false`。所以那处 `filter(\.isNumber)` 偏向「算承载」——正是本项目叫静默放过的方向，不是我写的「只会少判承载、多报丢失」。注释改成只记实测事实，不给它给不出的保证。

**行为本身我没动**：改成 ASCII-only 会让 `--verify` 更多报（安全方向、符合要求 1），但那是一次没人要求的行为变更，我把选择权留给用户。
