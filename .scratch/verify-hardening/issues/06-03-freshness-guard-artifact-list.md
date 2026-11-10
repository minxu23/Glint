# 新鲜度守卫复制了 Makefile 的产物清单，且缺产物静默跳过

Status: resolved
Round: 6
Source: Spec (c) 2 + Standards 1/2（第 6 轮报告，2026-11-10T01:51Z）
Fixed by: d717eeb
Review: ../reviews/round-06-standards.md

## 意见原文

> `Tests/selftest.sh` 新鲜度守卫有两条静默通道，与提交标题相反

## 结论

守卫自己的注释说「在这里重写一份依赖表等于复制 Makefile，必然漂移」——只避开了依赖表，没避开产物清单。
