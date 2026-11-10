# 第 1 轮 Standards 轴报告（agent 原文）

- 时间：2026-11-09T12:54:14.346Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-01-aggregate.md 里。

---

## Standards axis — jpeg2heif review

  Standards sources read: `CLAUDE.md`, `README.md`, `docs/agents/*.md`. (`GLOSSARY.md` and `docs/adr/` don't exist — per `docs/agents/domain.md` I proceed silently.) `make test` run once: all green, 29 guimodel checks included.

  ### Documented-standard breaches

  **1. `Sources/Core/MetadataDiff.swift` `strippingTimeZone` vs `README.md` (hard).**
  README's new `--verify` paragraph states: 「只认「全数字 + 号 + 4 位偏移」这一种形状」. The code accepts three shapes:
  ```swift
  if value.hasSuffix("Z") { return String(value.dropLast()) }
  ...
  offset.count == 4 || offset.count == 5,
  offset.allSatisfy({ $0.isNumber || $0 == ":" })
  ```
  The `Z` suffix and the 5-char `+08:00` form are undocumented in README. The function's own doc comment is also out of step with its first line: it says 「4 位或 5 位偏移」 and never mentions the `Z` branch at all — against the repo-wide convention (visible in every neighbouring comment) that comments explain the *why* of each rule.

  **2. Same function, `offset.count == 5` / `":"` is untested (hard-ish).**
  README 测试 states tests must fail when the feature breaks. `Tests/unit/main.swift` covers `184207+0800`, `184207-0500`, `184207Z`, `2024-09-15` — but no `+08:00`. Removing `|| offset.count == 5` and `|| $0 == ":"` leaves the suite green. Since IIM `TimeCreated` is `HHMMSS±HHMM`, this also reads as **Speculative Generality**: either add a case or delete the branch.

  ### Baseline smells (judgement calls)

  **3. Duplicated Code — `Tests/guimodel/main.swift`.** New `allJpegs(in:)` is identical to the existing `heics(in:)` but for the literal: `.filter { $0.pathExtension.lowercased() == "jpg" }` vs `== "heic"`. One `files(in:ext:)` would serve both.

  **4. Repeated Switches — `Sources/GUI/Model.swift` `detailText`.** `case .skipped, .failed: if let reason = status.reason` switches on the status, then `reason` switches again. `case .skipped(let why), .failed(let why)` binds directly. A third classification shape exists in `recount()` (`status != .pending && status != .running`) — an `isSettled` property on `RowStatus` would collapse all three.

  **5. `updateOptions` widens the door.** Its comment claims 「哪些字段变了需要连带做什么」 lives in one place, but a caller setting `options.inputs`/`options.output` is silently overwritten by `start()`/`reexpand()`. Worth a comment.

  ### Clean
  Makefile `.SECONDEXPANSION:` hunk, the `flatten` dead-branch deletion (guarded by the new flatten test group), and the `ConversionReport` collapse in `Converter.swift` all follow the repo's "comment the why, including the past bug" convention. No third-party deps, Command Line Tools only — unchanged.
