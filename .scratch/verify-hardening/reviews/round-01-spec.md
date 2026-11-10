# 第 1 轮 Spec 轴报告（agent 原文）

- 时间：2026-11-09T12:55:21.802Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-01-aggregate.md 里。

---

## Spec axis — jpeg2heif

  Verified by reading + one build/run of `./Tests/unit-test` (all green).

  ### (c) Implemented but looks wrong — highest value

  **1. `strippingTimeZone` can let `--verify` hide a real loss (false negative).** Spec: 「`--verify` 必须报出真丢失」/ MetadataDiff.swift:140 「宁可偶尔多报一条，也不要静默放过」.
  `/Users/minxu/Claude/jpeg2heif/Sources/Core/MetadataDiff.swift:144-168`. If a source's UTC offset lives **only** in `{IPTC}/TimeCreated = 184207+0800` and the file has no EXIF `OffsetTime*`, then: the IIM key is absent in the HEIC, `carriesSameValue` compares the stripped `184207`, matches `DateTimeOriginal`, `continue` — and the `+0800` is gone from the file with **nothing reported**. Before this change it over-reported (safe). README:124 justifies stripping with 「时区由 `OffsetTime` 单独承载」, which is asserted about the *destination* and never checked. Minimal fix: strip for containment, but also require the offset digits to appear in a dest offset field, else emit the issue.

  **2. The shape test is looser than its own comment claims.** MetadataDiff.swift:157 says it only accepts 「全数字 + 号 + 4 位或 5 位偏移」 to avoid 「`2024-09-15` 被砍成 `2024`」. But the head is only required to be *all digits*, not 6 long, so a 4-digit head with a 4-digit tail — `2024-0915` — strips to `2024`, which 「几乎出现在任何日期里」: precisely the silent-pass the comment warns about. The 5-char tail accepts any numeric/colon run (`184207-12345`). The `Z` branch (line 160) does no shape check at all. And it is applied to `DateCreated`/`DigitalCreationDate`, which in IIM never carry an offset — risk with zero benefit. Gating on the two Time keys, or `head.count == 6`, closes both.
  Confirmed correct on the rest: `184207+0800`→`184207`, `184207Z`, `20240915`, `2024:09:15 18:42:07`, `2024-09-15T18:42:07.42` and `…+08:00` all untouched.

  **3. The `flatten` deletion is sound.** Tests/unit/main.swift:32 passes a *native* Swift `[String: …]` dict through and it bridges into `as? [CFString: Any]`; the group passes, so the claim is guarded, not asserted.

  ### (b) Scope creep
  Only one with teeth: Model.swift:4 states 「状态变化统一通过 onChange 回调通知视图刷新」, but `updateOptions` (Model.swift:109) notifies **only** when `recursive` changes; the four removed forwarding setters evidently did. `MainViewController` compensates with a manual `refresh()` at both call sites (lines 376, 393). Correct today, silently stale for any future caller. Everything else (RowStatus payloads, one-pass `summary`, `allJpegs`, the 递归 fixture, the README paragraph) traces to backlog items 4/「tests must fail when broken」.

  ### (a) Missing / partial
  Backlog item 6's one-directional containment is untouched — acceptable, it 「errs safe」, but finding 1 is the exception where it no longer does. `--delete-original` still verifies first (Converter.swift:40, 229) and GUI/CLI defaults still share `ConversionOptions.default` with `verify` as the single divergence (asserted at Tests/unit/main.swift:190-197). Both remaining `check` overloads in `Tests/harness.swift` are in use.
