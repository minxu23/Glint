# XMP 承载腿从未被验证

Status: resolved
Round: 3
Source: Spec (a)（第 3 轮报告，2026-11-09T14:22Z）
Fixed by: (git init 之前)
Review: ../reviews/round-03.md

## 意见原文

> XMP 承载腿的覆盖

## 结论

Spec 轴当时说「夹具根本没写 DigitalCreationDate/DigitalCreationTime」，这半句我实测推翻了（ImageIO 自己合成了这两个键）。真正成立的是另一半：XMP/photoshop:DateCreated 和 XMP/xmp:CreateDate 在两个文件里都是 <无>，承载永远走 EXIF 腿。
