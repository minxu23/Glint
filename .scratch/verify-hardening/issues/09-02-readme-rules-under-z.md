# README 把两条通用规则塞进了 Z 专属段落

Status: resolved
Round: 9
Source: Standards 1 + Spec (c) 3（第 9 轮报告，2026-11-10T06:35Z）
Fixed by: eac5f46
Review: ../reviews/round-09-standards.md

## 意见原文

> `## --verify 到底比什么` is the normative description of what `--verify` compares. The new clause is nested **inside the Z-only rule**:

## 结论

这个会话连着四轮的主题是「守卫只紧了一侧」，这回代码是对称的、文档不对称，而上一轮我亲手改的正是这段 README。破坏测试第 6 轮替它作证：删掉 hhmmColon 后红的里面有 2024-09-15T18:42+08:00，± 侧的值。
