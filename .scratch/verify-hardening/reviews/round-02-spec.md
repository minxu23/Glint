# 第 2 轮 Spec 轴报告（agent 原文）

- 时间：2026-11-09T13:47:00.043Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-02-aggregate.md 里。

---

## Spec axis review

  Verified: `./Tests/unit-test` all green; `./jpeg2heif --verify test_pic/IMG_1225.JPG` reports only `xmpMM:InstanceID` + the merged MakerNote line.

  ### (c) Implemented but looks wrong

  **1. `utcOffset`'s `Z` branch still has no shape check** — `MetadataDiff.swift:162`: `if value.hasSuffix("Z") { return "+0000" }`. Previous-round finding 2 named exactly this: *"The `Z` branch did no shape check."* `splitIIMTime` was made exact-shape; the destination-side reader was not. Any searched value merely ending in `Z` is read as `+0000`, so a source `184207Z`/`184207+0000` is judged carried. The unit test feeds it only the bare string `"Z"`.

  **2. The 4-digit guard is a digit *count*, not a shape** (`MetadataDiff.swift:163-168`) — same defect as finding 2's *"the head was only required to be all digits, not 6 long."* It takes the **last** `+`/`-` anywhere and filters all digits to end: `utcOffset(in: "2024-09-15T18")` → `-1518`; `utcOffset(in: "... -0800mm")` → `-0800`; out-of-range `+9999` accepted. The comment at :166 defends it by two examples, not by structure. All 8 unit cases are well-formed, so a regression here wouldn't fail. Fix: anchor `±HHMM`/`±HH:MM`/`Z` to the end, as `splitIIMTime` does.

  **3. README over-promises the carrier set.** README:124 allows "`{Exif}/OffsetTime*`、`XMP/exif:OffsetTime*`，**或带偏移的 XMP 时间戳**", but `offsetSurvives` consults only two specific timestamps (that key's `alternatives`). `XMP/exif:DateTimeOriginal`, `xmp:ModifyDate`, `tiff:DateTime` aren't looked at, and `TimeCreated` never consults `xmp:CreateDate` (nor vice versa). Also `+0000` ≠ `-0000` as strings. Direction is over-reporting (README-sanctioned), so: fix the README, not the code.

  ### (a) Missing / partial

  **4. No integration coverage for the reworked rule.** `Tests/fixture.swift:67-73` writes an IPTC dict but **no `DateCreated`/`TimeCreated`**, and I confirmed no `test_pic/` photo carries them. So the whole IIM-equivalence path is unit-only over hand-built dictionaries; the destination key spellings are never checked against real ImageIO output. Spec part 2: "tests must fail when the feature is broken." One fixture line closes it.

  **5. One notify path still missing** (finding 3's own standard, "silently stale for any future caller"): `updateOptions { $0.recursive = ... }` while `isRunning` → `reexpand()` returns at `Model.swift:178` `guard !isRunning` → **no `notify()`**, while `options.recursive` already changed and `rows` weren't re-expanded. UI-unreachable today (controls disabled), untested in section 6. Also `refresh()` never re-syncs the four checkboxes or the slider from `model.options` (set once at `MainViewController.swift:178,224-227`), so onChange is now the sole path but still can't repair a divergence in the very controls `updateOptions` governs.

  **6. Section 6 depends on asserts being off.** `Tests/guimodel/main.swift:226-231` sets `inputs`/`output` through `updateOptions`, which trips `Model.swift:126`'s `assert`. Fine under `-O`, but a debug build aborts the test instead of failing it.

  ### (b) Scope creep (both minor, both defensible)

  - `RowStatus.isSettled` + `recount()` rewrite — a third status-switch site, not on either axis's list.
  - The section-2 progress invariant + `sawRunning` guard — unrelated test strengthening.

  Nit: README:35 names `Options.default`; the type is `ConversionOptions.default`.
