# Issue tracker: Local Markdown

Issues and specs for this repo live as markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`, never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## Review-round efforts

`verify-hardening` is the one effort in this repo whose tickets came from
recurring review rounds. Its ledger (`issues/`, `reviews/`) is **frozen at
round 11 and kept as an archive**: no new tickets are added, and nothing in
`Tests/selftest.sh` or anywhere else checks its format any more. From round 12
on, findings are handed to the implementer as a single self-contained handoff
(`.scratch/verify-hardening/round-12-handoff.md`) instead of one ticket per
finding.

How to read the archived ledger:

- **Ticket id is two-part: `<NN>-<MM>-<slug>.md`.** `NN` is the review round,
  `MM` is the position within that round, restarting at `01` each round.
- **`Status: resolved`** marks a finding that was fixed (borrowed from the
  Wayfinding vocabulary below, because the five triage labels have no "done"
  state). `wontfix` marks a declined finding, recorded with the reason.
- **Four extra header lines** after `Status:`: `Round:` the round number;
  `Source:` which axis raised it and when; `Fixed by:` the commit, or `—`;
  `Review:` a relative path to the review file the quote comes from.
- **Bodies use `## 意见原文` and `## 结论`** instead of `## Comments`: the first
  quotes the finding, the second is what was done. A ticket the maintainer found
  himself has no finding to quote and uses `## 缺陷` instead.
- **`reviews/` holds the primary sources.** `round-NN-aggregate.md` is the
  maintainer's own aggregation; `round-NN-standards.md` and `round-NN-spec.md`
  are the two review agents' reports, archived verbatim where they survived
  (`spec.md` lists which were lost). Agent reports are model output and carry
  no user authority.

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` (the Notes / Decisions-so-far / Fog body).
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:` line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are open, unblocked, and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set `Status: resolved`, then append a context pointer (gist + link) to the map's Decisions-so-far in `map.md`.
