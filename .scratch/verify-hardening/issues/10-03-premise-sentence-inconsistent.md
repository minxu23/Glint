# 「不寄托于调用方」那句和代码不再一致

Status: resolved
Round: 10
Source: Spec 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: dbb1e1e
Review: ../reviews/round-10-spec.md

## 意见原文

> 3. 09-07 traded dead guards for unchecked subscripts: `isDate` reads `parts[1]`/`parts[2]` and `normalizedOffset` reads `parts[0]`/`parts[1]` with no local count check, while `normalizedOffset`'s own comment four lines above insists «宽度前提在本函数内成立，不寄托于调用方». Fails loudly, so req 1 is safe — but it is the repo's own round-4 Standards finding reintroduced.

## 结论

我接这条，但要改它的定性：第 4 轮那条是**可达**的越界，这一条不可达（构造性论证成立）。真正的问题不是下标危险，而是那句注释和代码被同一个提交拆散了。改成按现状陈述：形状是在本函数内按长度挑出来的。
