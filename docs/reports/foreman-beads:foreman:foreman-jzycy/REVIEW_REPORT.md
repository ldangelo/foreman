# Repository-rules review — `beads:foreman:foreman-jzycy`

## Review engine

**Reviewer**: the repository-rules reviewer (phase 4 of the `fix` workflow) — a review against
this repository's own rules, not a code-review bot.

**Diff range reviewed**: `git diff 796c888c75c4f5a6dbf33b09027d31fea9af7b1f...a441468a`,
where `796c888c` is `FOREMAN_BASE_BRANCH` (`main`) and also the merge-base of `main` and `HEAD`
(`a441468a`). Five files, `+312/−0`:

- `docs/reports/foreman-beads:foreman:foreman-jzycy/PLAN.md` (new)
- `docs/reports/foreman-beads:foreman:foreman-jzycy/FIX_REPORT.md` (new)
- `docs/reports/foreman-beads:foreman:foreman-jzycy/REVIEW_CODERABBIT_REPORT.md` (new)
- `packages/foreman_server/lib/foreman_server/review/analyzer.ex` (+9, comment only)
- `packages/foreman_server/test/foreman_server/review/analyzer_test.exs` (+35, one test)

**Rules applied**: `AGENTS.md` (working rules, §5 typed boundaries / loud failures, documentation
gate, testing and safety) and `CLAUDE.md` (review-artifact format: machine-read findings block and
risk-judgement block; comment accuracy), plus the established idioms of the files the diff
touches. The mission's four checks were each applied: error handling (no error path changed in
the diff), typed/structured boundaries (the new test feeds `ProjectionStore.apply_events/1` plain
maps, which that API's own spec accepts — `rebuild/1`: `[EventData.t() | RecordedEvent.t() | map()]`
— and which the sibling tests in the same file already do, so this is the file's idiom, not a new
untyped boundary), declared-but-unread configuration/manifest/enum values (none added: `foreman-gap`,
`DetachedRun`, `Overwatch` and the manifest `status` the test asserts are all read by real code),
and documentation reconciled against `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`
and `CLAUDE.md` (no user-facing identifier was added, removed or renamed — see the documentation
gate note under **Verification**).

**Carry-forward**: the previous phase's `REVIEW_CODERABBIT_REPORT.md` is present in the tree and
its findings block was readable, so all three of its findings are carried forward below with
their original `source` (`coderabbit`). Note that at `HEAD` that artifact had lost its marker
blocks (finding **F1** below); the carried findings were read from the block as committed in
`137c7c37`, which is the version this phase restored.

**No behaviour change**: the diff adds a decision comment and one test. The decision on the
record (from the plan and fix phases) is that a failed or cancelled run **is** reviewed on
purpose, so request expectation (3) of `foreman-ws23g` is answered by pinning the behaviour with
an explicit test rather than by stopping the review.

## Findings

Received findings and their disposition in this phase:

| # | Source | Severity | Finding | Disposition |
| --- | --- | --- | --- | --- |
| C1 | `coderabbit` | minor | `FIX_REPORT.md:1` — phase-2 deliverable held only the placeholder sentence, so the bead's decision was never stated | fixed (phase 2, re-verified here) |
| C2 | `coderabbit` | minor | `analyzer.ex:57` — the decision comment cited a pinning test that did not exist in `analyzer_test.exs` | fixed (phase 2, re-verified here) |
| C3 | `coderabbit` | minor | `PLAN.md:57` — the plan's proof step tells the implementer to temporarily remove `RunFailed`/`RunCancelled` from the terminal-event list | declined (stale/self-reverting proof step) |
| F1 | `repo-rules` | major | `REVIEW_CODERABBIT_REPORT.md` — committed review artifact with no machine-read findings/risk blocks and a junk first line, while its own prose claims both blocks parse | fixed |
| F2 | `repo-rules` | minor | `analyzer.ex:54` — the new comment states the reviewer "is a read-only `DetachedRun`", presenting `sandbox_mode: :read_only` as an enforced guarantee | fixed |
| F3 | `repo-rules` | nitpick | `analyzer.ex:60` — the `docs/user-guide.md:1114` line-number pointer will drift when the guide is edited | declined |

## Fixed

**F1 — `docs/reports/foreman-beads:foreman:foreman-jzycy/REVIEW_CODERABBIT_REPORT.md`**

- *What was wrong*: the artifact committed at `HEAD` (`a441468a`) had lost both machine-read
  blocks and opened with the junk line `Phase 3 done.`, while its own **Verification** section
  claimed `ReviewFindings.read/1 → {:recorded, …}` and `PrRisk.parse_judgement/1 → status: "recorded",
  level: "LOW"`. That claim was false at `HEAD` (no marker line existed in the file), and
  `CLAUDE.md` requires every review artifact to carry the findings block and the risk-judgement
  block — an artifact without them is invisible to the machine reader and to the operator.
- *What changed*: restored both blocks verbatim from commit `137c7c37` (the phase-2 artifact that
  carried them), deleted the junk first line, and restored the missing trailing newline. The
  markers stand alone at column 0 outside any code fence, exactly one pair each.

**F2 — `packages/foreman_server/lib/foreman_server/review/analyzer.ex:52-63`**

- *What was wrong*: the new decision comment claimed the reviewer "is a read-only `DetachedRun`
  in a scratch cwd". `packages/foreman_server/lib/foreman_server/review/evaluator/agent.ex:152-157`
  states that `sandbox_mode: :read_only` "is not honoured by every provider" and that the scratch
  directory outside any git work tree is what actually guarantees the reviewer is not a second
  writer. The comment therefore presented an unenforced request as a guarantee, in the very
  sentence that carries the safety argument.
- *What changed*: the comment now says the reviewer is "a `DetachedRun` in a scratch cwd outside
  any git work tree" and adds the caveat "(Read-only is only requested: `sandbox_mode: :read_only`
  is not honoured by every provider, so the scratch cwd is the guarantee — see
  review/evaluator/agent.ex.)". No code changed; only the comment text.

## Declined

**C3 — `docs/reports/foreman-beads:foreman:foreman-jzycy/PLAN.md:57`** (carried from `coderabbit`)

- *Finding*: the plan's proof step tells the implementer to temporarily remove `RunFailed` and
  `RunCancelled` from the terminal-event list, then run the new test and expect it to fail.
- *Reason*: declined — it is a proof sketch, not a rule violation, and it is self-reverting by
  design (`git checkout -- lib/foreman_server/review/analyzer.ex` restores the file). The
  behaviour it proves was delivered as the committed test instead, so no change is warranted.

**F3 — `packages/foreman_server/lib/foreman_server/review/analyzer.ex:60`**

- *Finding*: the comment cites `docs/user-guide.md:1114`, a line-number pointer that drifts when
  the guide is edited.
- *Reason*: declined — file-and-line pointers into documentation are an established convention in
  this codebase (many `*.ex:[0-9]` references exist in `lib/`), the pointer is accurate today
  (`docs/user-guide.md:1113-1116` states that failed runs are reviewed on purpose), and the
  comment also cites the stable section title "Session archive and automated review"
  (`docs/user-guide.md:3088`), so a reader is not left with a dangling reference when the line
  number moves. Removing the pointer would make the comment less, not more, findable.

## Verification

Run from `packages/foreman_server` with `DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/foreman_test_jzycy`
and `TEST_DB_POOL_SIZE=5` (this suite takes a per-database advisory lock, so it needs its own
database):

| Command | Exit | Result |
| --- | --- | --- |
| `MIX_ENV=test mix test test/foreman_server/review/analyzer_test.exs --warnings-as-errors` | 0 | 42 tests, 0 failures (16.4 s); `ProjectionLeakGuard: judged 1 of 1 modules, no run left behind` |
| `MIX_ENV=test mix format --check-formatted lib/foreman_server/review/analyzer.ex test/foreman_server/review/analyzer_test.exs` | 0 | both files formatted |
| `MIX_ENV=test mix credo --min-priority higher` | 0 | 1490 files, "found no issues" |
| `MIX_ENV=test mix doctor --raise` | 0 | "Doctor validation has passed!" — Failed Modules: 0 |
| `git diff $(git merge-base "$FOREMAN_BASE_BRANCH" HEAD) HEAD --stat` | 0 | 5 files, `+312/−0` |
| `grep -rn "docs/reports" CLAUDE.md README.md docs/user-guide.md docs/cli-reference.md` | 1 | no hits — the new report directory is not indexed in any of the four files, so no doc edit is owed |
| `git diff HEAD` (re-read after the fixes) | 0 | 2 files, `+16/−8`; no new violation introduced |

**Documentation gate**: this diff adds, removes and renames no externally visible identifier — no
command or event type, no MCP tool, no HTTP route, no CLI verb or flag, no env var, no config key,
no workflow or prompt name. `CLAUDE.md`, `README.md`, `docs/user-guide.md` and
`docs/cli-reference.md` therefore needed no edits: the behaviour the diff touches (failed and
cancelled runs are reviewed) was already documented at `docs/user-guide.md:1113-1116` and in the
"Session archive and automated review" section (`docs/user-guide.md:3088`), and this phase's only
production-file change is a comment that now points at that documentation more precisely. There is
no `CHANGELOG.md` in this repository.

**Not run**: the full `mix test` suite (this repository's own tooling pins it per database and the
narrow analyzer suite covers the changed files); CI partition 1's remaining checks are the three
lint/doc commands above, which pass.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-jzycy/FIX_REPORT.md", "line": 1, "description": "The phase-2 deliverable contained only the placeholder sentence instead of the implementation report, so the bead's decision was never stated.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/review/analyzer.ex", "line": 57, "description": "The decision comment cited a pinning test that did not exist in analyzer_test.exs.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-jzycy/PLAN.md", "line": 57, "description": "The plan's proof step tells the implementer to temporarily remove RunFailed and RunCancelled from the terminal-event list.", "disposition": "declined", "source": "coderabbit"}, {"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-jzycy/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "The committed review artifact carried no machine-read findings or risk-judgement block and opened with a junk line, while its own prose claimed both blocks parse.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/review/analyzer.ex", "line": 54, "description": "The new decision comment stated the reviewer \"is a read-only DetachedRun\", presenting sandbox_mode: :read_only as an enforced guarantee although review/evaluator/agent.ex documents that not every provider honours it.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/lib/foreman_server/review/analyzer.ex", "line": 60, "description": "The comment's docs/user-guide.md:1114 line-number pointer will drift when the guide is edited, though the stable section title is cited alongside it.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The branch adds one decision comment and one test and writes the phase reports; no production behaviour, configuration value or externally visible identifier changes, and the only code touched is a comment plus a test that pins already-documented behaviour. The two fixes made here restore a review artifact's machine-read blocks and correct a comment that overstated an unenforced guarantee."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
