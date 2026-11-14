# EXPECTED_ROUNDS 被吞掉、EXPECTED_PASSES 已名不副实、计数未锚行首

Status: resolved
Round: 8
Source: Standards 5/6/7（第 8 轮报告，2026-11-10T04:28Z）
Fixed by: 72dd2d0
Review: ../reviews/round-08-standards.md

## 意见原文

> 四常量里 `EXPECTED_ROUNDS` 基本被吞掉

## 结论

EXPECTED_ROUNDS 这条我原本不同意，量完是审查对：每轮断言数 0:2 1:2 2:16 3:2 4:5 4b:9 5:5 6:3 7:8 7b:3 8:2 9:3，没有零断言的轮。我上一轮拿「标题绕过 round()」当证人，那种改动不破坏任何覆盖；真该挡的「新增一轮却用 echo」它反而挡不住。
