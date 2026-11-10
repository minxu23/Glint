# Tests/probe 读不了 XMP，与自己声称的理由相反

Status: resolved
Round: 4
Source: 我自己发现（两轴都没提）（第 4 轮报告，2026-11-09T15:02Z）
Fixed by: (git init 之前)
Review: ../reviews/round-04-aggregate.md

## 缺陷

给 `probe` 加上 XMP 读取，让它名副其实

## 结论

probe 的文件头注释写着它刻意复用 --verify 同一个 flatten，理由是「校验探针和校验本身对键路径长什么样的理解必须一致」——但 --verify 会再 merge 一层 xmpTags，probe 不会。一个量不出目标物的测量工具，已经骗过我一次。
