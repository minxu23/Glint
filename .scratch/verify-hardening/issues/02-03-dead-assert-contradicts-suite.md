# 那条 assert 既是死的，又和测试套件自相矛盾

Status: resolved
Round: 2
Source: Standards hard（第 2 轮报告，2026-11-09T13:48Z）
Fixed by: (git init 之前)
Review: ../reviews/round-02-standards.md

## 意见原文

> ### Hard finding: the `assert` is dead *and* contradicted by the test suite

## 结论

删掉。它既走不到，又和测试套件自相矛盾：guimodel 第 6 节正是通过 `updateOptions` 设 `inputs`/`output`，`-O` 下没事，debug 构建会直接 abort 掉测试而不是让它失败。
