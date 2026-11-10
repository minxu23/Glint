# 第 2 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-09T13:45:01.858Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-02-aggregate.md 里。

---

## Standards axis — jpeg2heif review

  Suite verified green once (`make test`, all sections pass). Standards sources: `CLAUDE.md`, `README.md`, `docs/agents/*.md`. No documented-standard breaches of the Chinese-why-comment, no-dependency, or CLT-only rules — every new symbol carries a why-comment naming the bug it prevents, and the new tests do fail when the feature breaks.

  ### Hard finding: the `assert` is dead *and* contradicted by the test suite
  `/Users/minxu/Claude/jpeg2heif/Sources/GUI/Model.swift:132`

  ```swift
  assert(options.inputs == before.inputs && options.output == before.output,
         "inputs/output 不由 updateOptions 管，改了也会被 start()/reexpand() 覆盖")
  ```

  Its comment is honest about `-O` making it inert (`Makefile:4` applies `-O` to the app, the CLI *and* every test tool). But `Tests/guimodel/main.swift` section 6 deliberately drives exactly the condition the assert calls a programmer error:

  ```swift
  m6.updateOptions { $0.output = URL(fileURLWithPath: "/tmp/不该生效"); $0.inputs = [...] }
  ```

  So the assert can never fire in any build this repo produces, and in the one build where it *would* fire (`SWIFTFLAGS=-Onone`, which `?=` permits) it aborts the guimodel test. The two restore lines plus that test already fully specify the contract. Recommendation: delete the assert; keep the restore lines and the comment's first half. The message is also slightly wrong — the values are restored two lines later, not by `start()/reexpand()`.

  ### Judgement calls (baseline smells)

  - **Duplicated Code** — `MetadataDiff.swift`: four table closures each re-derive dictionary prefixes and hand-format `"\(dict)/\(key)"`: `equivalentKeys` (`let iptc`, `let exif`, nested `iptcKey`), the new `iimTimeKeys` (`let iptc` again), the new `utcOffsetKeys` (`let exif` again). Two file-level helpers `exifKey(_:)`/`iptcKey(_:)` would collapse all of it.
  - **Duplicated Code** — two offset parsers side by side: `splitIIMTime` assembles `"\(chars[6])\(String(chars[7...]))"` while `utcOffset(in:)` normalizes the same thing. `splitIIMTime` could return the raw tail and defer to `utcOffset`.
  - **Primitive Obsession** — the offset is a bare `String` ("+0800") threaded through `splitIIMTime`/`utcOffset`/`offsetSurvives`, and the tuple needs an explicit annotation in `equivalentCarries` (`let parts: (time: String, offset: String?) =`). A small `UTCOffset` type would remove the annotation and the stringly comparisons.

  ### Non-finding worth noting (region 3 vs 2)
  Deleting the manual `refresh()` calls is safe: `refresh()` disables `settingsControls` while running, so the one gap — `updateOptions` changing `recursive` mid-run, where `reexpand()`'s `guard !isRunning` returns without notifying, contradicting the comment "它自己会通知" — is unreachable from the GUI. Latent only; a one-line caveat on that comment would close it.

  Also minor doc drift: README (line ~124) lists the offset's possible homes as `{Exif}/OffsetTime*`, `XMP/exif:OffsetTime*`, or an offset-bearing XMP timestamp, but `offsetSurvives` searches `utcOffsetKeys + alternatives`, so an offset-bearing `{Exif}/DateTimeOriginal` also counts.
