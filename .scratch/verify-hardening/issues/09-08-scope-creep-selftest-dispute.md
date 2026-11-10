# Spec 说 selftest 的改名与抽函数是范围蔓延

Status: wontfix
Round: 9
Source: Spec (b)（第 9 轮报告，2026-11-10T06:35Z）
Fixed by: —
Review: ../reviews/round-09-spec.md

## 意见原文

> Ticket 3 asks only *"delete it, and record in a comment why"*. The diff also renames `EXPECTED_PASSES`→`EXPECTED_ASSERTIONS`, extracts `expect_count`/`count_assertions`, changes the count regex `'✓|✗'` → `'^ *[✓✗]'`, and swaps the summary from `$PASSED` to `$executed`. Behaviour-neutral here, but unrequested.

## 结论

它按拿到的工单判是对的，错在工单：那份工单是我凭对话转述的，第 8 轮报告的第 3 步本来就把改名、抽函数和删除捆在一起讲。这条正是本目录存在的理由——审查记录以前只活在对话里。
