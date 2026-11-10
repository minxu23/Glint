# 第 4 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-09T14:56:36.278Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-04-aggregate.md 里。

---

## Standards axis review — `jpeg2heif`

  Sources read: `CLAUDE.md`, `README.md` (§`--verify` 到底比什么, §测试), `docs/agents/domain.md` (no `GLOSSARY.md`/`docs/adr/` exist — per that doc, silently fine). Files: `/Users/minxu/Claude/jpeg2heif/Sources/Core/MetadataDiff.swift`, `/Users/minxu/Claude/jpeg2heif/Tests/unit/main.swift`.

  ### Hard violation of a documented standard

  **`normalized(token:precededBy:)` still accepts offsets outside the README's range** (MetadataDiff.swift:246-247). README line 130 states the range is exactly `-12:00…+14:00`. The new check bounds only the hour: `hours <= (token[0] == "-" ? 12 : 14), … minutes <= 59`, so `+1430`, `+14:59`, `-1230` parse successfully. These are the same class of nonexistent offset the hunk was written to reject, failing in the same direction the file's own comment calls 静默放过 (a too-permissive target-side reader lets `offsetSurvives` claim an offset survived). Fix: reject minutes != 0 when `hours == 14` (and when `hours == 12` on the negative side). No test covers `+1430`.

  ### Array indexing

  - `splitIIMTime` / `chars[6]` (line 174): **safe and locally guaranteed.** Swift `guard` short-circuits left to right, and `chars.count == 7 || 11 || 12` precedes it, so count ≥ 7. Nothing depends on the caller.
  - `normalized(token:precededBy:)` / `token[0]`, and `token[3..5]` in the `else` (lines 231, 238-240): **not locally guaranteed.** The function never checks `token.count`; the `else` branch simply assumes 6. The only thing keeping it in bounds is the sole caller's `for width in [5, 6]` (line 218, verified by grep: one call site). Any future caller passing an empty or 3-char token traps. Add `guard token.count == 5 || token.count == 6 else { return nil }` — it also replaces `token.count == 5` as a *checked* discriminator. Noteworthy because hunk 1 added a length check to `splitIIMTime` for exactly this failure shape; the new private method is the one place in the diff that leaves it implicit.

  ### Baseline smells (judgement calls)

  - **Mysterious Name** — the two `normalized` overloads. `normalized` is a bare adjective: normalized *what*? And the overload pair implies one operation at two granularities when the two actually do different jobs (locate a candidate vs. validate/convert one). `normalizedOffset(atEndOf:)` and `normalizedOffset(token:precededBy:)` would read honestly; the label-only distinction is otherwise idiomatic Swift and fine.
  - **Duplicated Code / Feature Envy (mild)** — `chars[6] == "+" || chars[6] == "-" || chars[6] == "Z"` in `splitIIMTime` restates `UTCOffset`'s own alphabet of offset-start characters (`token[0] == "+" || token[0] == "-"` plus the `Z` branch at line 214). The comment justifies *why* a third condition is needed, not why the character set lives outside the type that owns it. A `static func isOffsetStart(_:)` on `UTCOffset` would keep the one ruler the comments insist on.
  - No Middle Man: the 3-line `init?` delegating to `normalized(atEndOf:)` is a legitimate seam (parse → validated type), not pass-through. No Speculative Generality, Shotgun Surgery, or Divergent Change in these hunks.

  ### Clean

  - **`xmpKey` inside `let volatileKeyPrefixes` (line 117): safe.** `xmpKey` is a function, not a global requiring initialization, and file-scope globals outside `main.swift` are lazily initialized via `swift_once` on first access. Same shape as the pre-existing `volatileKeys`/`equivalentKeys`/`utcOffsetKeys` initializers. Hunk 4 correctly kills the last hand-written `"XMP/"` prefixes, matching the rule stated at lines 74-77.
  - Tests hand-write `"XMP/photoshop:DateCreated"` rather than calling `xmpKey`. Not a violation — a test that borrows the producer's helper cannot fail when the prefix changes, which the README's testing standard (line 181ff, tests must break when the feature breaks) argues against. Leave as literals.
  - Doc comments match behaviour (four lengths, offset starts at index 6) and keep the repo's convention of naming the past bug; the `1842071+0800` vs `184207+1+080` note correctly explains why both new conditions are load-bearing. The two new XMP-leg cases plus the ImageIO-synthesizes-`DateTimeOriginal` comment are the right call under the zero-dependency rule (README line 9).

  I ran no build or test (reading sufficed); the range gap above is from code reading, not an observed failure.
