# 第 4 轮 Spec 轴报告（agent 原文）

- 时间：2026-11-09T14:59:05.845Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-04-aggregate.md 里。

---

## Spec axis — jpeg2heif

  Checked: `Sources/Core/MetadataDiff.swift`, `Tests/unit/main.swift`, `Tests/fixture.swift`, README. Ran `./Tests/unit-test` (all green) and three throwaway ImageIO probes.

  ### (a) Missing / partial

  **1. Item 3's limitation claim is half wrong — the XMP leg *is* reachable end-to-end (verified).**
  Spec: *"the XMP carrier leg of `equivalentKeys` was never verified against real ImageIO output"*; the new comment says *"要造出『只有 XMP 承载』的样本得用 exiftool 之类的外部写入器"*.
  I wrote a JPEG with only `{IPTC}/DateCreated=20240915` + `TimeCreated=184207+0800` and no `OffsetTime*`. ImageIO synthesizes `{Exif}/DateTimeOriginal` (claim confirmed) **and** `XMP/photoshop:DateCreated=2024-09-15T18:42:07+08:00`. Converting it, the HEIC has no `OffsetTime*` at all, so `--verify` passes *only* because `offsetSurvives` finds the offset via the XMP alternative key. The XMP leg is therefore decisive end-to-end today for the offset half; only the time-carrying half is blocked. `Tests/fixture.swift:44` sets `OffsetTimeOriginal: "+08:00"` — deleting that one line is the whole missing test. Item 3 stays open for a reason the comment misstates.

  **2. Guard #1 (length) is necessary but untested — mutation-verified.**
  README: *"自检…测试必须在功能坏掉时失败"*; comment: *"三个条件缺一不可"*. I deleted `chars.count == 7 || 11 || 12` and recompiled: **all 10 `splitIIMTime` cases still pass**, while `184207+12+0800` → `("184207", "+0800")`, silently dropping `+12` — the forbidden 静默放过 direction. Worse, the comment's own witness is wrong: `184207123+0800` is already rejected by the `chars[6]` guard. A digit-after-sign spelling is needed.

  ### (b) Scope creep
  None. `xmpKey` appears in exactly the five documented places (incl. `xmpTags`) and is string-identical; the parser extraction is behaviour-neutral.

  ### (c) Looks implemented but wrong
  Nothing further. `splitIIMTime` now accepts exactly `HHMMSS`, `HHMMSSZ`, `HHMMSS±HHMM`, `HHMMSS±HH:MM`: for length 11 only the width-5 token at index 6 can match (width-6 would start on a digit), for 12 only width-6 (width-5's preceding char is the sign) — so no accepted shape drops characters, and no legitimate IIM spelling is rejected. Sign-dependent range: `-12:00` parses, and no real zone/EXIF offset is below it, so nothing real is rejected. Key spellings confirmed in `test_pic/`: both photos expose `XMP/photoshop:DateCreated` and `XMP/xmp:CreateDate` (e.g. `2011-01-19T22:01:00.00`) and both survive into the `.heic` — but neither has IIM dates, so they cannot close item 3 alone.
