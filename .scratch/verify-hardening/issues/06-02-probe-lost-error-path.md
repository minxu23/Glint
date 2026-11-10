# probe 丢了「读不出来」与「键不存在」的区分

Status: resolved
Round: 6
Source: Spec (c) 3（第 6 轮报告，2026-11-10T01:51Z）
Fixed by: d717eeb
Review: ../reviews/round-06-aggregate.md

## 意见原文

> probe 恢复"读不出来"与"键不存在"的区分，并给第 6 节那条前提补上非空守卫

## 结论

旧 --raw 读不出时打印 <无法读取> 并 exit 1；新路径对 nil 返回 [:]，于是一律打印 <无>。于是第 6 节的前提断言在「整个文件都读不出来」时也会通过——本轮要堵的那类静默通道被换了个地方重开。
