# 删节能通过，而文档声称它不能

Status: resolved
Round: 11
Source: Spec (a)2（第 11 轮报告，2026-11-10T09:16Z / 09:18Z）
Fixed by: 98869ac
Review: ../reviews/round-11-spec.md

## 意见原文

> - Abridgement passes: cutting 10-02's quote to `omits ymdColon, which the code accepts` → `unsupported=0`.

## 结论

这条**守卫原理上查不出来**：`grep -F` 是子串匹配，任何缩短仍是子串；而光看引文本身，没法区分「公正的节选」和「误导的删节」。所以我没假装加强守卫，改掉了文档里那句「转述或删节都会让构建变红」，并写明守卫实际只能挡转述和引错来源。
