# --raw 把 XMP 盲区搬到了旗标后面

Status: resolved
Round: 5
Source: Standards 4（第 5 轮报告，2026-11-10T01:29Z）
Fixed by: f2b016a
Review: ../reviews/round-05-aggregate.md

## 意见原文

> `--raw` 改成 `--no-repair`

## 结论

代理建议「遇 XMP/ 前缀直接 exit 2」，那是给盲区加告示牌。第 6 节真正需要的只是「不要 UserComment 修补」，和 XMP 无关——改成 --no-repair 并继续 merge XMP，分歧从源头消失。
