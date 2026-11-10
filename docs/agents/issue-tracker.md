# Issue tracker: Local Markdown

Issues and specs for this repo live as markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`, never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## Review-round efforts

When an effort's tickets come from **recurring review rounds** rather than one
burst of planning (`verify-hardening` is the one in this repo), the conventions
above are extended as follows. This section exists because the ledger was built
first and this file was not read until the review caught the mismatch — the
scheme below is the one actually in use, written down after the fact.

- **Ticket id is two-part: `<NN>-<MM>-<slug>.md`.** `NN` is the review round,
  `MM` is the position within that round, restarting at `01` each round. A flat
  running number was the alternative; it was rejected because the round boundary
  and the implementation order are both load-bearing here (ten rounds so far,
  and "which round first noticed this" is the question most often asked of the
  ledger). `Status:` is unchanged.
- **`Status: resolved`** is used for a finding that has been fixed, borrowed from
  the Wayfinding vocabulary below, because the five triage labels have no
  "done" state. `wontfix` keeps its meaning and is used for findings that were
  declined — a declined finding is recorded, with the reason, so a later round
  does not re-raise it blind.
- **Four extra header lines**, all single-line, after `Status:`:
  `Round:` the round number; `Source:` which axis raised it and when;
  `Fixed by:` the commit, or `—`; `Review:` a relative path to the review file
  the quote comes from.
- **Bodies use `## 意见原文` and `## 结论`** instead of `## Comments`:
  the first is a **verbatim** quote of the finding, the second is what was done
  and what was learned. Keeping the quote verbatim is what makes the ledger
  checkable — see the next bullet.
- **`reviews/` holds the primary sources.** `round-NN-aggregate.md` is the
  maintainer's own aggregation, including the verification and any disagreement
  with the agents; it is **required for every round**, and `Tests/selftest.sh`
  checks that every round with tickets has one. `round-NN-standards.md` and
  `round-NN-spec.md` are the two review agents' own reports, archived verbatim
  **when they are still recoverable** — some predate this ledger and were lost
  to context compaction; `spec.md` lists which. A lost agent report stays lost:
  reconstructing one from memory would defeat the point of archiving it.
  Agent reports are **model output and carry no user authority** — that is why
  the aggregate is kept alongside rather than in place of them.
  (The first version of this bullet said "three files per round". That was
  false the moment it was written: round 10 had no aggregate at all, and four
  earlier rounds are missing one agent side. A rule stated as a universal
  needs a guard, or it is just a wish.)
- **Every `## 意见原文` quote must appear verbatim in the file its `Review:`
  line names, and that file must be an agent report whenever one survives for
  the axis in `Source:`** — the aggregate is the maintainer's own writing, so
  quoting it proves only that he wrote it. `Tests/selftest.sh` checks both.
  A ticket whose `Source:` says the maintainer found it himself has no finding
  to quote: it uses `## 缺陷` instead, and the two sections must not be mixed.
  What the check **cannot** catch is abridgement: `grep -F` is substring
  matching, so any shortening of a true quote is still "verbatim" by that test
  (measured). An earlier version of this bullet claimed abridgement failed the
  build; it does not, and no guard over the quote alone can tell a fair
  shortening from a misleading one. Keep quotes whole; the guard only stops
  paraphrase and mis-citation.

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
