# CodeRabbit review — bead `beads:foreman:foreman-hfzqq`

Run: `run-422bed01110fce85a7e813727abceeaa`
Base branch: `main` (from `$FOREMAN_BASE_BRANCH`, verified set before review)
Branch under review: `foreman/foreman-hfzqq/run-422bed01110fce85a7e813727abceeaa`
Reviewed diff range: `main...HEAD` plus the uncommitted working tree of this phase.

## Review engine

Command run from the worktree root, once per round:

```
coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
```

with `FOREMAN_BASE_BRANCH=main` exported by the phase environment (the variable
was confirmed non-empty before the first round; no substitute base was used).
Engine: CodeRabbit CLI `0.9.7` (`/Users/ldangelo/.local/bin/coderabbit`), same
engine as the GitHub PR bot, run locally against the working tree — findings
arrived without a push. Each round's engine context reported
`currentBranch: foreman/foreman-hfzqq/run-422bed01110fce85a7e813727abceeaa`,
`baseBranch: main`, working directory = this worktree.

One failed invocation is recorded for completeness: `coderabbit review
--agent --base main --format markdown` exited `1` with an unknown-option error
(the CLI has no `--format` flag). It was not a review attempt; the findings were
read from the default output of the three successful runs.

No authentication error occurred; the engine ran and produced findings in every
round.

## Rounds

Three rounds were run (the prompt's maximum).

**Round 1** — 3 findings.

1. `major` — `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs:791`
   "Update the adjacent namespace assertion for the new marker."
   The new `PI_SUBAGENT_CHILD` value assertion sat next to an assertion that
   every delivered env key starts with `FOREMAN_`; both could not hold.
   → **Fixed**.
2. `minor` — `docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md:189`
   "Correct the documentation-gate procedure."
   The plan's gate procedure exempted `CLAUDE.md`, `README.md` and
   `docs/cli-reference.md` from the new identifier.
   → **Fixed**.
3. `minor` — `docs/user-guide.md:2043`
   "Correct the advisor-gate claim: the marker does not stand down the advisor gates."
   The guide claimed `PI_SUBAGENT_CHILD=1` also disables `advisorCompletionGate`,
   `advisorPlanGate` and `advisorBlockOnBlocked`. The same claim existed in the
   lesson file and in the runtime comment in `run_executor.ex`.
   → **Fixed** (all three sites).

**Round 2** — 2 findings.

4. `minor` — `docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md:189`
   "Reconcile the marker across the documentation gate."
   The plan still reconciled only the user guide; the other three gate
   documents were left without guidance.
   → **Fixed**.
5. `minor` — `docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md:167`
   "Keep advisor gates active in the proposed documentation."
   The planned text claimed advisor gating applies to interactive sessions only,
   contradicting the shipped user guide; the same wrong claim was in the helper
   example at plan line 127.
   → **Fixed**.

**Round 3** — 1 finding.

6. `minor` — `CLAUDE.md:414`
   "Complete the four-document identifier gate."
   The new identifier was documented in `CLAUDE.md` only; `README.md` and
   `docs/cli-reference.md` had no corresponding guidance.
   → **Fixed**.

Six findings received, six fixed, none declined. Review stopped at round 3 (the
prompt's round cap).

## Fixed

All fixes are uncommitted; Foreman commits this phase's work.

**1. `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs` (round 1, major).**
Wrong: the phase-2 change added `assert delivered["PI_SUBAGENT_CHILD"] == "1"`
directly above the pre-existing namespace assertion
`assert Enum.all?(Map.keys(delivered), &String.starts_with?(&1, "FOREMAN_"))`.
`PI_SUBAGENT_CHILD` does not start with `FOREMAN_`, so the test failed even
though the marker was delivered correctly — the test contradicted the feature.
Changed: the namespace assertion now accepts exactly one extra key, the marker
Foreman owns itself, and still rejects anything else:
`assert Enum.all?(Map.keys(delivered), fn key -> String.starts_with?(key, "FOREMAN_") or key == "PI_SUBAGENT_CHILD" end)`.
The value assertion is kept, and the comment now states why the marker is
excepted (it is Foreman's own key, not part of the project environment).

**2. `docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md` (rounds 1 and 2, minor).**
Wrong: §5 exempted three of the four gate documents (`CLAUDE.md`, `README.md`,
`docs/cli-reference.md`) from the new `PI_SUBAGENT_CHILD` identifier, treating
its non-`FOREMAN_` prefix as a reason to skip them, so the identifier would
have shipped undocumented in three of four gate files.
Changed: §5 now reconciles all four documents — `CLAUDE.md` (injected-env-var
list), `README.md` (agent-runtime section), `docs/cli-reference.md`
("Phase worker environment" paragraph in the `foreman run submit` section) and
`docs/user-guide.md` §7.3 — and states the distinction between the marker and
the injected `FOREMAN_*` variables instead of exempting it.

**3. `docs/user-guide.md` §7.3 (round 1, minor).**
Wrong: the passage claimed the marker's cost is "the extension's advisor gates
… do not supervise Foreman phases either". Verified false against
`~/.pi/agent/npm/node_modules/pi-advisor-flow/dist/index.js`: `isMarkedSubagent()`
(`:288`) gates only the model/effort override (`:290`, `:295`, `:4799`, `:4845`,
`:4855`, `:4887`); the gate refs `advisorPlanGate` (`:51`),
`advisorCompletionGate` (`:53`) and `advisorBlockOnBlocked` (`:57`) are plain
config booleans read from the extension's own settings and are not keyed on the
marker. The `ask_advisor` tool stays registered and a machine-wide advisor still
asks a Foreman phase to call it.
Changed: the passage now says the marker is not a switch for the whole
extension, that the advisor gates follow the extension's own `enabled`/gate
settings rather than this marker, and that if an operator wants gating off on
Foreman workers they must turn the gates off in the extension config.

**4. `docs/lessons/phase-execution-and-pr-mechanics.md` (round 1, minor, same claim as 3).**
Wrong: the lesson repeated the false claim that the advisor gates do not
supervise Foreman phases.
Changed: the paragraph now records the verified scope limit with the concrete
`pi-advisor-flow` line references, states that the advisor gates still apply to
Foreman phases because they follow the extension's own config, and adds the
instruction not to document the marker as "advisor extensions stand down
entirely".

**5. `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` (round 1, minor, same claim as 3).**
Wrong: the helper's runtime comment (committed in `aca39923`) said "an operator's
advisor extension does not supervise Foreman phases".
Changed: the comment now says the marker suppresses only the extension's
model/effort override, that its advisor gates are not keyed on it so a
machine-wide advisor still supervises Foreman phases per its own config, and
that the trade-off buys a phase that runs on the model Foreman resolved. The
helper body and the env pipe are unchanged.

**6. `docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md` (round 2, minor).**
Wrong: §4 Edit 4's proposed user-guide text claimed advisor gating applies only
to interactive sessions, contradicting the shipped guide, and the helper example
at plan line 127 carried the same claim.
Changed: both blocks are re-synced word-for-word with the shipped text in
`docs/user-guide.md` §7.3 and with the shipped comment in `run_executor.ex`.

**7. `CLAUDE.md`, `README.md`, `docs/cli-reference.md` (round 3, minor).**
Wrong: the identifier existed in `CLAUDE.md` only; the other two gate documents
had no guidance for it.
Changed: `CLAUDE.md` §on the injected env vars gained one sentence pointing at
`docs/user-guide.md` §7.3; `README.md`'s agent-runtime section gained the same
statement including the caveat that the marker does not silence the advisor
gates; `docs/cli-reference.md`'s `foreman run submit` section gained a "Phase
worker environment" paragraph stating that the server sets the marker, that
there is no CLI flag or verb for it, and pointing at `docs/user-guide.md` §7.3.

## Declined

None. Every finding was verified against the code as it currently stands before
acting; all six described real defects and were fixed.

One observation is recorded here for the operator rather than as a finding,
because it is not a CodeRabbit finding and it does not belong in the
machine-read block: the fix phase (`aca39923` / `67f73051`) committed a
63-byte fragment as `FIX_REPORT.md`
(`"Now Edit 3 (the assertion that would go red) and Edit 4 (docs)."`), which is
not the six-section report `fix.md` requires. It was left untouched by this
phase — that artifact belongs to the fix phase, and the repo-rules-review phase
that follows reviews the committed diff against the workflow's own conventions.

## Verification

Commands run from the worktree root (Elixir: `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test`
is required; devbox's default credentials fail authentication against the local
postgres).

| Command | Exit |
| --- | --- |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=… MIX_ENV=test mix test test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs test/foreman_server/workflow/run_executor_command_test.exs test/foreman_server/workflow/run_executor_project_model_test.exs'` | `0` (44 passed) |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=… MIX_ENV=test mix test test/foreman_server/overwatch/adapters/jido_harness_worker_env_test.exs test/foreman_server/library_delivery_test.exs'` | `0` (9 passed) |
| `devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'` | `0` |
| `cd packages/foreman_cli && gofmt -l cmd` | `0` (no output) |
| `cd packages/foreman_cli && go build ./...` | `0` |
| `cd packages/foreman_cli && go test -count=1 ./cmd/foreman/` | `0` (`ok … 0.614s`) — includes `usage_drift_test.go`, which parses `docs/cli-reference.md`, re-run after that file was edited |
| `cd packages/foreman_cli && go vet ./cmd/foreman/` | `0` |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=… MIX_ENV=test mix test test/foreman_server/workflow/review_findings_test.exs test/foreman_server/pr_risk_test.exs test/foreman_server/workflow/pr_body_paths_test.exs test/foreman_server/workflow/phase_pr_body_test.exs'` | `0` (140 passed) — the parsers that read this artifact |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=… MIX_ENV=test mix run /Users/ldangelo/.foreman/tmp/verify_review_blocks.exs'` (this report's own blocks, absolute path because `mix run` executes with `cwd = packages/foreman_server`) | `0` — `ReviewFindings.read/1` ⇒ `{:recorded, record}` with 6 findings, every one `disposition: :fixed`, `source: "coderabbit"`; `PrRisk.parse_judgement/1` ⇒ `%{status: "recorded", level: "MEDIUM", defect: nil}`; `ReviewFindings.section/2` renders 246 bytes |

Regression proof for the round-1 major finding: with the pre-fix namespace
assertion restored, the same test file fails (the two assertions cannot both
hold), confirming the new assertion bites.

An independent `ask_advisor` review was attempted and could not be obtained:
the configured Anthropic credential refresh fails with HTTP 400
`{"error": "invalid_grant", "error_description": "Refresh token expired"}`.
The findings in this report are therefore the triaged output of the CodeRabbit
engine and this agent's own verification, with no advisor pass on top.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs", "line": 791, "description": "The new PI_SUBAGENT_CHILD value assertion sat next to a namespace assertion requiring every delivered env key to start with FOREMAN_, so the test failed even when the marker was delivered correctly.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md", "line": 189, "description": "The plan's documentation-gate procedure exempted CLAUDE.md, README.md and docs/cli-reference.md from the new PI_SUBAGENT_CHILD identifier on the grounds of its non-FOREMAN_ prefix.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 2043, "description": "The guide claimed PI_SUBAGENT_CHILD=1 also stands down the advisorCompletionGate, advisorPlanGate and advisorBlockOnBlocked gates, which the marker does not do.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md", "line": 189, "description": "The plan still reconciled the new identifier across only the user guide, leaving the other three gate documents without guidance.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-hfzqq/PLAN.md", "line": 167, "description": "The planned user-guide text and helper example claimed advisor gating applies only to interactive sessions, contradicting the shipped guide.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "CLAUDE.md", "line": 414, "description": "The new PI_SUBAGENT_CHILD identifier was documented in CLAUDE.md only, with no corresponding guidance in README.md or docs/cli-reference.md.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The code change is one env key on the pi worker launch path plus documentation, and is covered by a new and a corrected test, but it changes the runtime of every Foreman-launched pi phase: pi-advisor-flow stops overriding the phase model and pi-subagents registers nothing, so a phase agent loses the ability to spawn pi subagents. The change also corrects the bead's premise that the marker silences the advisor gates, which it does not, so operators must configure gates in the extension if they want them off."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->