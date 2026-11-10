# isDate 注释拿 README 排除的键当论据

Status: resolved
Round: 9
Source: Standards 3（第 9 轮报告，2026-11-10T06:35Z）
Fixed by: eac5f46
Review: ../reviews/round-09-standards.md

## 意见原文

> `isDate`'s justification says `{TIFF}/DateTime` 实际写的就是 `2024:09:15 18:42:07`, but README says `别的时间戳（xmp:ModifyDate、tiff:DateTime 之类）不算`. Cite only `{Exif}/DateTimeOriginal`.

## 结论

事实没错（TIFF 确实那么写），但用它来论证这个决定是误导。
