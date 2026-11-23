# Repository-rules review — `beads:foreman:foreman-qdt14`

## Review engine

Repository-rules reviewer (`repo-rules`), one pass over this run's committed
diff, then fixes, then one re-read of the same range.

- Base branch: `$FOREMAN_BASE_BRANCH` = `main` (set and non-empty; no
  substitute base was used).
- Range reviewed: `git diff main...HEAD` — merge-base `f0f3b083`, HEAD
  `4a8a7bec` ("Foreman run run-0c30344c74abc80ba7c2b40090d98819 phase 3").
  13 files changed:
  - `packages/foreman_server/lib/foreman_server/projects/recommendations.ex`
  - `packages/foreman_server/lib/foreman_server/projects/recommendations/facts.ex`
  - `packages/foreman_server/test/foreman_server/projects/recommendations_test.exs`
  - `packages/foreman_server/test/foreman_server/projects/recommendations_facts_test.exs`
  - `packages/foreman_server/test/foreman_server/coordinator/setup_proposer_test.exs`
  - `packages/foreman_server/test/foreman_server_web/controllers/recommendations_controller_test.exs`
  - `packages/foreman_server/test/support/recommendations_probe.ex`
  - `docs/cli-reference.md`, `docs/user-guide.md`
  - `docs/reports/foreman-beads:foreman:foreman-qdt14/{PLAN.md,FIX_REPORT.md,REVIEW_CODERABBIT_REPORT.md}`
  - `.plan_full.md` (repo root)
- Rules applied: the repository's own `AGENTS.md` (typed boundaries §5, the
  invariants list, the testing rule, and the documentation gate) plus the
  established patterns of the modules the diff touches
  (`Projects.Recommendations`, `Projects.Recommendations.Facts`,
  `Projects.SourceBranch`, `Exec.Git`).
- Carried-forward findings: none. The previous phase's
  `docs/reports/foreman-beads:foreman:foreman-qdt14/REVIEW_CODERABBIT_REPORT.md`
  exists but is empty (2 bytes, no findings block), so there was nothing to
  carry forward and this phase's findings block starts from zero.

## Findings

| # | Severity | Location | Finding | Disposition |
| --- | --- | --- | --- | --- |
| 1 | major | `packages/foreman_server/lib/foreman_server/projects/recommendations/facts.ex:8` | The module's `Safety rules (asserted by tests)` block still claimed that only fixed file names are checked, that "arbitrary repo content is never read", and that external commands never run in the repo dir — but the diff's new `commits_behind_origin` probe runs `git rev-list --count -C <project repo>` and reads that repo's refs. The documented contract contradicted the code. | Fixed |
| 2 | minor | `docs/cli-reference.md:336` | The recommendations paragraph still described the probes as running only `gh auth status` and asserted "nothing from the repository is executed", which the new `git rev-list` probe makes false. | Fixed |
| 3 | minor | `.plan_full.md:1` | The diff added a 275-line machine-local plan copy at the repository root, byte-identical to the already-committed `docs/reports/foreman-beads:foreman:foreman-qdt14/PLAN.md` and referenced by nothing in the repo. | Fixed (deleted) |
| 4 | minor | `docs/acceptance/parity-audit.md:48` | The audit row still counts "19 recommendations / 17 pure detector functions"; the diff adds an 18th detector. | Declined |
| 5 | nitpick | `packages/foreman_server/lib/foreman_server/projects/source_branch.ex:22` | `SourceBranch.validate/1`'s pattern allows `.` and `/`, so a branch name containing `..` would reach the `rev-list` range argument (`refs/heads/<b>..refs/remotes/origin/<b>`) unescaped. | Declined |

## Fixed

1. **`packages/foreman_server/lib/foreman_server/projects/recommendations/facts.ex`
   (moduledoc, lines 8–19)** — the `Safety rules (asserted by tests)` block
   asserted two things the new probe breaks: that repository content is never
   read and that no command ever runs in the repository directory. Narrow
   fix: the first bullet now ends with "the single command that targets the
   project's own repository is described below", and a new bullet records that
   the one such command is the read-only `git rev-list --count` whose argument
   vector is fixed in `behind_argv/2`, that it never fetches, and that
   `core.fsmonitor` / `extensions.partialclone` are cleared with the pager
   disabled so a repository's own config cannot make git run a program or
   reach the network. No code was changed.
2. **`docs/cli-reference.md:336`** — the probe sentence claimed "nothing from
   the repository is executed". It now reads: "Probes check only fixed file
   names and run external commands (`gh auth status`, and a read-only
   `git rev-list` count against the project's own repository that never
   fetches) by absolute path from the server's `PATH` with a 5 s bound each
   (15 s total, then HTTP 504); nothing from the repository is executed."
3. **`.plan_full.md`** — deleted (staged deletion). The file was a duplicate
   of the committed report-directory `PLAN.md`; no file, script, or workflow
   references it, and the repository root carries no other machine-local plan
   artifacts.

## Declined

1. **`docs/acceptance/parity-audit.md:48`** — the row's "19 recommendations /
   17 pure detector functions" counts are stale after the diff adds
   `branch.behind_origin`. Declined: the file is a point-in-time audit
   ("Audited tree: `origin/main` at `126ff019` (2026-10-23)"), and `AGENTS.md`
   treats such pinned specs as a snapshot rather than living documentation;
   re-counting it would rewrite history for a commit that no longer exists.
   The audit is not in the documentation-gate set
   (`CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`),
   and none of those four needs a change beyond what the run already made:
   `docs/user-guide.md:684-686` and `docs/cli-reference.md:336` both carry the
   new id, while `README.md` and `CLAUDE.md` contain no detector-id list.
2. **`packages/foreman_server/lib/foreman_server/projects/source_branch.ex:22`**
   — a branch name containing `..` would reach the `rev-list` range argument
   unescaped. Declined: the value is passed as a single argv element and is
   never interpolated into a shell, so there is no injection; `..` is not a
   legal git branch name, so such a ref cannot be the checked-out branch the
   fact is derived from; and the failure mode would be a wrong count in a
   state the repository cannot reach. Not a repository-convention violation
   and not reachable, so no change was made.

## Verification

Commands run from `packages/foreman_server` (the repository's own build
system is Mix/ExUnit; `mix quality` = format + compile + credo + dialyzer +
doctor):

| Command | Exit code | Result |
| --- | --- | --- |
| `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/projects/recommendations_test.exs test/foreman_server/projects/recommendations_facts_test.exs test/foreman_server/coordinator/setup_proposer_test.exs test/foreman_server_web/controllers/recommendations_controller_test.exs` | 0 | 40 passed (re-run after the moduledoc wording tweak: 40 passed) |
| `mix format --check-formatted lib/foreman_server/projects/recommendations/facts.ex lib/foreman_server/projects/recommendations.ex` | 0 | formatted |
| `MIX_ENV=test mix compile --warnings-as-errors` | 0 | compiles clean — every `Probe` implementor satisfies the new `cmd_out/3` callback |
| `MIX_ENV=test mix credo --min-priority higher lib/foreman_server/projects/recommendations/facts.ex lib/foreman_server/projects/recommendations.ex` | 0 | 82 mods/funs, no issues |

Notes: the first test invocation failed before any test ran
(`DBConnection.ConnectionError` / `FATAL 28P01`) because the ambient
`DATABASE_URL` pointed at a different container than the Foreman test
database; the run above exports the Foreman database explicitly
(container `foreman-postgres`, host port 55432). `mix dialyzer` and
`mix doctor --raise` were not run: the phase changed comments and Markdown
only, and those two checks are slow.

Fixes are left uncommitted, as the phase requires
(`git status --porcelain`: `D  .plan_full.md`, `M docs/cli-reference.md`,
`M packages/foreman_server/lib/foreman_server/projects/recommendations/facts.ex`).

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/lib/foreman_server/projects/recommendations/facts.ex", "line": 8, "description": "The module's documented safety rules still claimed that repository content is never read and that no external command runs in the repository, which the new `git rev-list --count -C <project repo>` probe contradicts.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/cli-reference.md", "line": 336, "description": "The recommendations probe description still claimed that only `gh auth status` runs and that nothing from the repository is executed, which the new bounded `git rev-list` probe makes false.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": ".plan_full.md", "line": 1, "description": "The diff committed a machine-local duplicate of the report-directory PLAN.md at the repository root that nothing in the repository references.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/acceptance/parity-audit.md", "line": 48, "description": "The audit row's recommendation and detector-function counts are stale after the diff adds the `branch.behind_origin` detector.", "disposition": "declined", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/lib/foreman_server/projects/source_branch.ex", "line": 22, "description": "`SourceBranch.validate/1` permits a branch name containing `..`, which would reach the `rev-list` range argument unescaped.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The change adds one bounded, read-only `git rev-list --count` probe and a warn-level detector that fires only on a positive integer count; it never fetches, never writes, and clears `core.fsmonitor`/`extensions.partialclone` with the pager disabled so a repository's own config cannot make git run a program. Unobservable states stay `:unavailable`, so the detector stays silent rather than guessing, and the fixes in this phase are documentation and one duplicate file deletion."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
