# Spec 说全角数字那条是「永不会红的断言」

Status: wontfix
Round: 8
Source: Spec (b) 1（第 8 轮报告，2026-11-10T04:28Z）
Fixed by: —
Review: ../reviews/round-08-spec.md

## 意见原文

> `numericFields` 里的 `isASCII`：注释自承「去掉它不改变任何输入的结果——也就不可能有用例钉住它」

## 结论

我不认这条，理由见上。第 8 轮破坏测试第 4 轮证明了这点：行为真坏掉它会红。注意这不影响 08-05——那一条我接了。
