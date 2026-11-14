# issue 文件名不符合仓库自己成文的命名方案

Status: resolved
Round: 10
Source: Standards 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: 60b1783
Review: ../reviews/round-10-standards.md

## 意见原文

> **1. Issue filenames don't match the documented scheme (hard).** `docs/agents/issue-tracker.md:9`: "Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`"; the Wayfinding section repeats `.scratch/<effort>/issues/NN-<slug>.md`. All 52 files use a two-part `NN-MM-<slug>.md` and restart `MM` at `01` each round. `spec.md` asserts "格式依 [`docs/agents/issue-tracker.md`]" and then defines its own scheme two lines later. Either rename to one running number or amend `issue-tracker.md` to bless `NN-MM`.

## 结论

两条路选了「改文档」：`NN-MM` 编码的是真实信息（轮次边界 + 动手次序），而「这条最早是哪一轮发现的」正是账本被问得最多的问题。但要说清这不是为了躲审查——真正的事实是我当时**没读** issue-tracker.md 第 9 行就开始生成文件，而 spec.md 里「格式依 issue-tracker.md」那句是我顺手写的、没核过。所以文档是后补的，新增那一节里就这么写了。
