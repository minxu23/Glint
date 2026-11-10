# 第 3 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-09T14:19:43.359Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-03-aggregate.md 里。

---

## Standards axis — jpeg2heif (no git; reviewed the listed regions)

  Sources read: `CLAUDE.md`, `README.md`, `docs/agents/*.md` (no `GLOSSARY.md`/`docs/adr/` — per `docs/agents/domain.md` I proceed silently). Verified two findings by compiling `/Users/minxu/Claude/jpeg2heif/Sources/Core/MetadataDiff.swift` against a 4-line driver.

  ### Hard: documented range not enforced (`MetadataDiff.swift:210-212`)
  Code comment and `README.md:130-131` both state the offset is range-checked to `-12:00…+14:00`. The guard is `hours <= 14` for both signs, with no lower bound. Confirmed: `UTCOffset(parsing: "-1400")` → `-1400`, `"-13:00"` → `-1300`. Direction is the one the repo repeatedly warns against (a lax *destination* reader silently passes a lost offset). `Tests/unit/main.swift` has `("-12:00","-1200")` but no out-of-range negative case, so the suite does **not** fail when this is broken — against `README.md:181-187`'s "tests that must fail when the feature is broken".

  ### Hard: `splitIIMTime` accepts a fourth shape (`MetadataDiff.swift:149-159`)
  Its doc comment says "只认 IIM 规范的三种确切形状". The guard only checks `chars.count > 6`, the first 6 digits, and an offset **anchored at the end** — nothing requires the offset to start at index 6. Confirmed: `splitIIMTime("1842071+0800")` → `("184207", +0800)`, silently dropping the stray `1`. Same failure family as the `2024-0915` → `2024` bug the surrounding comments exist to prevent. Needs `chars.count == 11 || chars.count == 12` (or an offset-start check), plus a case in the new `splitIIMTime` group.

  ### Judgement calls (baseline)
  - **Primitive Obsession — resolved well.** `UTCOffset` earns its place: `text` is a *normalization guarantee* the bare `String` couldn't express, and it is passed between three functions. Synthesized `Equatable` on the normalized text is the right identity given `README.md:128-129` requires `+0000` ≠ `-0000`; `Z` → `+0000` is consistent. Only nit: a ~30-line failable `init` doing all parsing (`for width in [5, 6]`) reads as a parser hiding in a constructor.
  - **Duplicated Code (minor, pre-existing, widened).** `metadataKey`/`exifKey`/`iptcKey` correctly kill the four-way duplication. But the hand-built `"XMP/..."` prefix now sits in `volatileKeys`, `equivalentKeys`, `utcOffsetKeys` and `xmpTags` with no `xmpKey` counterpart — the one remaining string the tables hand-format.
  - **File-scope, no access modifier: not a problem here.** Every symbol in the file is already internal, the unit tests compile the sources directly (so `private` would break `Tests/unit`), and there is no library boundary. Consistent, not new surface.

  `Model.swift`, `Tests/fixture.swift`, `README.md` hunks: no violations. The assert deletion keeps the "why" comment the repo convention asks for, and the `reexpand()` note correctly flags the un-notified path.
