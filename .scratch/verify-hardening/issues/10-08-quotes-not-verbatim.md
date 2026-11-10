# 账本的引文不可核：九条对不上

Status: resolved
Round: 10
Source: Spec 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: c0a0cf2
Review: ../reviews/round-10-spec.md

## 意见原文

> spec.md: «`reviews/round-NN.md` —— 每轮两轴报告的**原文**，逐字复制，未经编辑… 要引审查当时到底说了什么，引这里». Checked all 52 issue files: **44 quotes appear literally in the cited review; all 7 round-9 files fail.** Six quote English — `"The apology was relocated, not resolved."`, `"One contiguous /// block opening…"`, `"Stale 模板 at MetadataDiff.swift:343"`, `"a shape's length is restated beside it…"`, `"parts.count == 3 … are now unreachable-false"`, `"Ticket 3 asks only…"` — but `round-09.md` contains no English except one quoted requirement line. 09-02's Chinese quote is likewise a reconstruction, not in the file. So the one round checkable against an in-repo review is the round where `## 意见原文` is paraphrase. (05-01 silently abridges, dropping `，证人用上面那四个`.)

## 结论

我自己跑了一遍脚本，结果比报告多一条：9/52（第 9 轮全部 8 条 + 05-01）。根因不是写错引文，是**账本结构有缺陷**：reviews/ 只存了我的聚合报告，而第 9 轮那些 issue 引的是两个 agent 的原话，那两份报告从没入库。

讽刺的是这个检查是我自己设计并交给 Spec 轴的。它抓到的不是改写，是引了一份不在仓库里的源：我上一轮说「记录来源不是我的回忆」，而最新那一轮的记录来源恰恰只有我的回忆。

改法三步：从转写本找回 16 份 agent 原文入库（第 3、5、6、7 轮各只找回一侧）、把六条加工过的引文换成原文、给这条性质加一个守卫（selftest 第 10 轮）。守卫对两种失效都有证人：改一个词、以及把 Review: 指向同一轮的另一份报告。
