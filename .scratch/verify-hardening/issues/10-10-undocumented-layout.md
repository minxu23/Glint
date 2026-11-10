# reviews/ 与四个头部字段是未成文布局

Status: resolved
Round: 10
Source: Standards 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: dbb1e1e
Review: ../reviews/round-10-standards.md

## 意见原文

> **2. `reviews/` and four header fields are undocumented layout (hard, smaller).** `issue-tracker.md` enumerates `Status:` (and, for wayfinding, `Type:`/`Blocked by:`). Every ticket adds `Round:`, `Source:`, `Fixed by:`, `Review:`, and `reviews/round-NN.md` is a sibling of `issues/` that the doc never mentions. The layout is now single-sourced in `spec.md` instead of `issue-tracker.md`.

## 结论

和 09 一起处理：issue-tracker.md 新增 `## Review-round efforts` 一节，把两段式编号、resolved/wontfix 的用法、四个头部字段、`## 意见原文`/`## 结论`、reviews/ 的三文件结构、以及引文逐字守卫全部写下来。布局的单一来源从 spec.md 回到 issue-tracker.md。
