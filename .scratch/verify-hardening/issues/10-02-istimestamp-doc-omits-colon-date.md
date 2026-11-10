# isTimestamp 的日期清单漏了 EXIF 冒号写法

Status: resolved
Round: 10
Source: Spec 轴（第 10 轮报告，2026-11-10T08:27Z / 08:31Z）
Fixed by: c0a0cf2
Review: ../reviews/round-10-spec.md

## 意见原文

> 2. **`MetadataDiff.swift:333** (`isTimestamp` doc): «日期是 `YYYY-MM-DD` 或 `YYYYMMDD`» — omits `ymdColon`, which the code accepts and the new README documents. Same req-6 family as 09-05, left behind.

## 结论

和 09-05 同一族。补上 `YYYY:MM:DD` 并指向 isDate。
