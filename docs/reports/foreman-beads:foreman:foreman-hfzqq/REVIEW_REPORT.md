# Repository-rules review — bead `beads:foreman:foreman-hfzqq`

## Review engine

Reviewer: `repo-rules` (Foreman phase 4, `repo-rules-review`), applying this
repository's own rules as written in `AGENTS.md` and
`docs/lessons/phase-execution-and-pr-mechanics.md`, plus the established
idioms of the code the diff touches.

Diff range reviewed: `git diff 39303e89...HEAD` — merge-base of
`origin/main` and `HEAD` (11 files, +368/−2). `FOREMAN_BASE_BRANCH` was set to
`main`, but the local `main` ref in this run worktree is stale (`main` ==
`origin/main` == `4f37fa96`), so the review used the merge-base `39303e89`,
which is the commit this run's branch was actually cut from. Commits in range:
`11abfc35` (PLAN.md), `aca39923` (implementation + tests + docs),
`67f73051` (fix report), `40e8db7a` (phase-3 review report),
`b8040fbf` (phase-3 commit by Foreman).

The previous phase's `REVIEW_CODERABBIT_REPORT.md` was read in two states: as
committed at `HEAD` (a 21-line prose file with **no** machine-readable block,
written by Foreman's phase-3 commit `b8040fbf`, which replaced the phase
agent's own compliant 204-line report committed in `40e8db7a`) and as committed
in `40e8db7a` (the phase agent's original report, with a readable findings
block of 6 findings and a risk block). The six carried findings below come
from the `40e8db7a` version; restoring that file into the working tree is
recorded as finding R6.

## Findings

Carried from `REVIEW_CODERABBIT_REPORT.md` (source `coderabbit`) — all six were
fixed in phase 3 and re-verified in this phase:

| # | Severity | Path | Finding | Disposition |
| --- | --- | --- | --- | --- |
| C1 | major | `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs:791` | The `PI_SUBAGENT_CHILD` assertion sat next to a namespace assertion requiring every delivered env key to start with `FOREMAN_`, so the test failed even when the marker was delivered correctly. | fixed |
| C2 | minor | `docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md:189` | The plan's documentation-gate procedure exempted `CLAUDE.md`, `README.md` and `docs/cli-reference.md` from the new identifier on the grounds of its non-`FOREMAN_` prefix. | fixed |
| C3 | minor | `docs/user-guide.md:2043` | The guide claimed the marker also stands down `advisorCompletionGate`, `advisorPlanGate` and `advisorBlockOnBlocked`, which it does not. | fixed |
| C4 | minor | `docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md:189` | The plan still reconciled the new identifier across only the user guide, leaving the other three gate documents without guidance. | fixed |
| C5 | minor | `docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md:167` | The planned user-guide text claimed advisor gating applies only to interactive sessions, contradicting the shipped guide. | fixed |
| C6 | minor | `CLAUDE.md:414` | The new identifier was documented in `CLAUDE.md` only, with no corresponding guidance in `README.md` or `docs/cli-reference.md`. | fixed |

Own findings against this repository's rules (source `repo-rules`):

| # | Severity | Path | Finding | Disposition |
| --- | --- | --- | --- | --- |
| R1 | minor | `docs/user-guide.md:2031` | §7.3 named `RunExecutor.prepare_agent_launch/5` as the place that sets the marker; the marker is merged in `build_agent_launch/10` (the function that also builds `foreman_env/4`). | fixed |
| R2 | minor | `docs/user-guide.md:2032` | §7.3 claimed the marker is set "in the environment of every **pi** worker it starts"; only pi *phase* workers are marked — the review evaluator starts pi on a separate path. | fixed |
| R3 | minor | `docs/lessons/phase-execution-and-pr-mechanics.md:309` | The lessons paragraph repeated both errors: wrong injection point (`prepare_agent_launch/5`) and over-broad scope ("Every pi worker Foreman launches"). | fixed |
| R4 | minor | `CLAUDE.md:413` | The injected-env-var list said "Every **pi** worker"; only pi phase workers carry the marker. | fixed |
| R5 | nitpick | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:1251` | The code comment said "every pi worker it launches"; narrowed to "every pi phase worker it launches" for consistency with the corrected documents. | fixed |
| R6 | minor | `docs/reports/foreman-beads:foreman:foreman-hfzqq/REVIEW_CODERABBIT_REPORT.md:1` | The committed phase-3 review report had lost both machine-readable blocks, so its findings were invisible to the operator and to this phase's carry-forward. | fixed |
| R7 | minor | `docs/reports/foreman-beads:foreman:foreman-hfzqq/FIX_REPORT.md:1` | The committed fix report was a 63-byte fragment ("Now Edit 3 … and Edit 4 (docs)."), which does not satisfy the six-section contract of `priv/defaults/workflows/prompts/fix.md`. | fixed |
| R8 | nitpick | `docs/lessons/phase-execution-and-pr-mechanics.md:305` | The pre-existing `foreman_env/3` references (here and in `AGENTS.md`) are stale against the code's `foreman_env/4`. | declined |

Accepted scope limit (not a rules violation, recorded so the operator sees it):
the review evaluator (`ForemanServer.Review.Evaluator.Agent`) starts pi on its
own path and is therefore not marked; a machine-wide pi extension can still
override the reviewer's model. `PLAN.md` §6 puts that path out of scope, and
the coordinator harness already runs with `no_extensions: true`.

## Fixed

- `docs/user-guide.md` (§7.3, line 2031-2033) — the operator-facing paragraph
  named a function that does not set the marker. Changed
  `RunExecutor.prepare_agent_launch/5` to `RunExecutor.build_agent_launch/10`,
  the function that merges `foreman_env/4` and then the marker, and changed
  "every **pi** worker it starts" to "every **pi** phase worker it starts".
- `docs/lessons/phase-execution-and-pr-mechanics.md` (line 309-313) — the
  added lessons paragraph carried the same two errors. It now names
  `build_agent_launch/10` as the injection point and says "Every pi phase
  worker Foreman launches".
- `CLAUDE.md` (line 413) — "Every **pi** worker additionally gets" became
  "Every **pi** phase worker additionally gets", matching the already-correct
  wording in `README.md:308` and `docs/cli-reference.md:759`.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  (comment above `maybe_put_pi_child_marker/2`, line 1251-1252) — "every pi
  worker it launches" became "every pi phase worker it launches".
- `docs/reports/foreman-beads:foreman:foreman-hfzqq/REVIEW_CODERABBIT_REPORT.md`
  — restored from `git show 40e8db7a:…` , the phase agent's own compliant
  report (sections Review engine / Rounds / Fixed / Declined / Verification,
  findings block with 6 findings, risk block with level `MEDIUM`). Nothing was
  re-authored: the file is the phase-3 agent's output that Foreman's phase-3
  commit had overwritten.
- `docs/reports/foreman-beads:foreman:foreman-hfzqq/FIX_REPORT.md` — rewritten
  with the six sections `fix.md` requires: Root cause, Change, Deviations from
  the plan, Tests, Local verification, Follow-ups. The committed version was a
  63-byte fragment.

Re-read of `git diff 39303e89...HEAD` plus the working-tree changes after the
fixes found no new violation: the only code edit is a comment, the document
edits narrow claims to what the code does, and the two report artifacts now
satisfy the contract of their bundled prompts
(`priv/defaults/workflows/prompts/fix.md`,
`priv/defaults/workflows/prompts/review-coderabbit.md`).

## Declined

- `docs/lessons/phase-execution-and-pr-mechanics.md:305` and `AGENTS.md` —
  "export in `foreman_env/3`" is stale; the code has `foreman_env/4`
  (`run_executor.ex:5232-5285`). Declined: pre-existing text that this run's
  diff did not introduce and that does not trace to this bead, so changing it
  would widen the diff beyond the task (the corrected paragraph added by this
  run already names `foreman_env/4`).
- "Mark the review evaluator's pi launch with `PI_SUBAGENT_CHILD=1`" —
  declined: outside this run's scope (`PLAN.md` §6) and not required by any
  repository rule; recorded as a follow-up in the fix report instead.
- "Change the bead text, which claims the marker disables the advisor gates" —
  declined: the bead lives in the tracker, not in this repository, and the
  repository-side correction (documentation) is already made.

## Verification

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55433/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs test/foreman_server/workflow/run_executor_command_test.exs'
# => 25 tests, 0 failures, exit 0

devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55433/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs test/foreman_server/workflow/run_executor_command_test.exs test/foreman_server/workflow/run_executor_project_model_test.exs test/foreman_server/workflow/run_executor_project_context_test.exs test/foreman_server/workflow/run_executor_resume_test.exs test/foreman_server/workflow/run_executor_fork_test.exs test/foreman_server/overwatch/adapters/jido_harness_worker_env_test.exs test/foreman_server/library_delivery_test.exs'
# => 87 tests, 0 failures, exit 0

devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
# => exit 0

devbox run -- bash -c 'cd packages/foreman_cli && go build ./cmd/foreman && go vet ./... && go test ./...'
# => exit 0 (includes usage_drift_test.go, which parses docs/cli-reference.md)
```

The database used here is the `foreman-pg-phase0` container published on port
`55433`; the port recorded in `PLAN.md` §5 (`55432`, container
`foreman-postgres`) was not running in this worktree.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs", "line": 791, "description": "The new PI_SUBAGENT_CHILD value assertion sat next to a namespace assertion requiring every delivered env key to start with FOREMAN_, so the test failed even when the marker was delivered correctly.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md", "line": 189, "description": "The plan's documentation-gate procedure exempted CLAUDE.md, README.md and docs/cli-reference.md from the new PI_SUBAGENT_CHILD identifier on the grounds of its non-FOREMAN_ prefix.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 2043, "description": "The guide claimed PI_SUBAGENT_CHILD=1 also stands down advisorCompletionGate, advisorPlanGate and advisorBlockOnBlocked, which the marker does not do.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md", "line": 189, "description": "The plan still reconciled the new identifier across only the user guide, leaving the other three gate documents without guidance.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md", "line": 167, "description": "The planned user-guide text and helper example claimed advisor gating applies only to interactive sessions, contradicting the shipped guide.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "CLAUDE.md", "line": 414, "description": "The new PI_SUBAGENT_CHILD identifier was documented in CLAUDE.md only, with no corresponding guidance in README.md or docs/cli-reference.md.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 2031, "description": "Section 7.3 named RunExecutor.prepare_agent_launch/5 as the place that sets PI_SUBAGENT_CHILD, but the marker is merged in build_agent_launch/10.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 2032, "description": "Section 7.3 claimed the marker reaches every pi worker the executor starts, while only pi phase workers are marked and the review evaluator starts pi on a separate path.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/lessons/phase-execution-and-pr-mechanics.md", "line": 309, "description": "The lessons paragraph repeated both errors: it named prepare_agent_launch/5 as the injection point and claimed the marker covers every pi worker Foreman launches.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "CLAUDE.md", "line": 413, "description": "The injected-environment list said every pi worker gets PI_SUBAGENT_CHILD=1, which overstates the implementation, since only pi phase workers are marked.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/lib/foreman_server/workflow/run_executor.ex", "line": 1251, "description": "The comment above maybe_put_pi_child_marker/2 said every pi worker it launches, and was narrowed to every pi phase worker it launches for consistency with the corrected documents.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-hfzqq/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "The committed phase-3 review report had lost both machine-readable blocks, so its findings were invisible to the operator and to this phase's carry-forward.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-hfzqq/FIX_REPORT.md", "line": 1, "description": "The committed fix report was a 63-byte fragment that did not satisfy the six-section contract of the bundled fix prompt.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "nitpick", "path": "docs/lessons/phase-execution-and-pr-mechanics.md", "line": 305, "description": "The pre-existing foreman_env/3 references in this file and in AGENTS.md are stale against the code's foreman_env/4, but predate this run's diff and do not trace to the bead.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change is one env key on the pi phase launch path plus documentation and tests, but it alters the runtime of every Foreman-launched pi phase: pi-advisor-flow stops overriding the phase model and pi-subagents registers nothing, so a phase agent can no longer spawn pi subagents. The change also corrects the bead's premise that the marker silences the advisor gates, which it does not, so operators must configure the gates in the extension itself."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
