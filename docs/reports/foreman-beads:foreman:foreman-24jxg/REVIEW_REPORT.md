# Repo-Rules Review — beads:foreman:foreman-24jxg

## Review engine

Reviewer: the repository-rules pass required by this run's `fix` workflow phase 4
(an in-agent review against this repository's own conventions, no external CLI).
Conventions source: `AGENTS.md` at the repository root (Working Rules,
Documentation Gate, "Typed Boundaries, Loud Failures" §5.1–§5.7, Invariants) and
the established patterns in the files the diff touches.

Diff range reviewed: `git diff main...HEAD` with `FOREMAN_BASE_BRANCH=main`
(merge-base of `main` and this run's branch, head `2afec107`). Nine files:
`CLAUDE.md`, `README.md`, `docs/cli-reference.md`, `docs/user-guide.md`,
`docs/reports/foreman-beads:foreman:foreman-24jxg/{PLAN,REVIEW_CODERABBIT_REPORT,FIX_REPORT}.md`,
`packages/foreman_server/lib/foreman_server/mcp/tools.ex` (45 added, 2 removed),
and `packages/foreman_server/test/foreman_server/mcp/tools_test.exs` (+49).

Carry-forward: the previous phase's artifact
`docs/reports/foreman-beads:foreman:foreman-24jxg/REVIEW_CODERABBIT_REPORT.md`
is present and readable as prose, but it contains **no machine-read findings
block** — there are no `FOREMAN_REVIEW_FINDINGS_*` marker lines in it, so there
was no `findings` array to copy. Its two prose-described CodeRabbit findings are
re-listed below under their own `coderabbit` source as findings this phase
received, both already fixed on the branch by that phase.

## Findings

| # | severity | path | disposition | source |
| - | -------- | ---- | ----------- | ------ |
| 1 | minor | README.md:385 and docs/user-guide.md:2202 | fixed | repo-rules |
| 2 | minor | docs/reports/foreman-beads:foreman:foreman-24jxg/REVIEW_CODERABBIT_REPORT.md | declined (recorded open) | repo-rules |
| 3 | minor | docs/reports/foreman-beads:foreman:foreman-24jxg/FIX_REPORT.md | declined (recorded open) | repo-rules |
| 4 | minor | docs/reports/foreman-beads:foreman:foreman-24jxg/PLAN.md:1 | fixed (by phase 3) | coderabbit |
| 5 | minor | packages/foreman_server/lib/foreman_server/mcp/tools.ex:1891 | fixed (by phase 3) | coderabbit |

The implementation itself (`tools.ex`, `tools_test.exs`) raised no repo-rule
violation. Checked and found compliant, not findings:

- **Honest failure vs. generic success (§5.3 "Absent ≠ malformed").** A
  slot-waiting or admission-deferred run now answers through
  `pending_run_status/1` (`tools.ex:3594`) with `queued`/`deferred`; an unknown
  id still returns the typed `NOT_FOUND` `ToolError`, and a run that starts
  between the two projection reads is re-read rather than reported missing.
- **One boundary, not a duplicate (§5.7).** The MCP read reuses
  `ProjectionStore.pending_run/1` (`projection_store.ex:330`), the same function
  `ForemanServerWeb.RunController.show_pending/2` (`run_controller.ex:42`)
  serves, so the HTTP and MCP transports cannot drift.
- **Loud failure on a malformed boundary (§5.2/§5.3).**
  `pending_run_status_dto/1` (`tools.ex:3605`) raises `ArgumentError` when
  `run_id`/`status` are not binaries instead of substituting a plausible value.
- **Declared-but-unread value.** The new `RunStatus.reason` field
  (`tools.ex:33`, `:3620`) is populated from
  `ProjectionStore.pending_run/1`'s `:reason` and is `@derive Jason.Encoder`ed
  to clients, so it is read, not decorative. `foreman_run_get` deliberately
  keeps returning `NOT_FOUND` for pending runs — `CLAUDE.md` §19 says to keep
  that shape distinct, so this is documented intent, not an inconsistency.
- **Doc gate.** Files needing edits: `README.md`, `docs/user-guide.md` (the
  `reason` field enumeration, fixed below). Files already reconciled by the
  implementation commit and needing nothing: `CLAUDE.md` §19 and
  `docs/cli-reference.md` both already name `reason` and the
  `queued`/`deferred` fallback. `docs/user-guide.md:934,940-943` already
  documented the equivalent HTTP pending-run shape. There is no `CHANGELOG`
  file in this repository. No removed or renamed identifier: the diff only adds
  a field and changes one error path into a status answer.
- **Client-side structs.** `packages/foreman_cli` (Go) and
  `packages/foreman_client` have no run-status DTO struct — neither greps for
  `provider_session_id` — and `packages/foreman_cli/cmd/foreman/main.go`
  dispatches no `run status` verb, so there is no CLI surface to update; the
  MCP tool set is unchanged in names, so
  `packages/foreman_server/test/foreman_server/mcp/tool_inventory_test.exs`
  needs nothing either (verified passing).

## Fixed

- **`README.md:385` and `docs/user-guide.md:2202`** — both sentences enumerate
  the `foreman_run_status` DTO field list (`run_id`, `status`, `terminal`,
  `project_id`, `task_id`, `workflow_name`, `current_phase`, timestamps,
  `failure_reason`, …) and this diff added a DTO field to that same interface
  without adding it to those lists. Only `docs/cli-reference.md:1599-1601` was
  updated by the implementation commit, leaving the documented field list
  inconsistent across the repository's own docs (Documentation Gate item 3:
  document the addition everywhere the old shape was enumerated). Added
  `` `reason` (the admission refusal that deferred a pending run, else `null`) ``
  after `failure_reason` in both places, matching the `docs/cli-reference.md`
  wording. No behavior change; `reason` was already in the struct and already
  serialized as `null` for non-pending runs, so this reconciles docs to code
  rather than changing code.

## Declined

- **`docs/reports/foreman-beads:foreman:foreman-24jxg/REVIEW_CODERABBIT_REPORT.md`**
  — the phase-3 report's Verification section claims "Both JSON blocks
  re-parsed ... `{:recorded, ...}` / MEDIUM", but the committed file contains no
  findings block and no risk-judgement block. Declined to edit it: it is
  another phase's artifact, and the fields it claims to have emitted are not the
  ones Foreman parses — `RunExecutor.record_review_findings/3`
  (`run_executor.ex:2795`) reads the **last** phase's completion artifact
  (`completion_artifact_path/1`, `run_executor.ex:6332`), i.e. this file, so
  writing marker lines into the phase-3 report would change nothing
  machine-read while rewriting a phase's own claims about what it did. The
  operator-facing consequence is recorded as an **open** minor finding so it is
  visible on the PR rather than silently dropped.
- **`docs/reports/foreman-beads:foreman:foreman-24jxg/FIX_REPORT.md`** — a
  4-byte placeholder (`"\n...\n"`) where the fix phase's Work Log should be.
  Declined to author it: it is phase 2's first-person artifact. Its substance
  is not lost — the implementation is on the branch (`6007d1db`) and `PLAN.md`
  plus the phase-3 report describe it. Recorded as an **open** minor finding so
  the operator sees that the run's fix-phase report is empty.

Neither decline hides a correctness problem in the shipped code; both are
run-artifact quality issues owned by other phases.

## Verification

All run in `packages/foreman_server` through `devbox run --` with
`MIX_ENV=test DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test_r24jxg TEST_DB_POOL_SIZE=5`
(a database created for this run with `mix event_store.init`, because the
advisory lock in `mix.exs:202` is per database and `foreman_test` is held by
another run; `localhost` not `127.0.0.1` because `config_test.exs:73,87` assert
on the URL string).

| command | exit |
| ------- | ---- |
| `mix format --check-formatted lib/foreman_server/mcp/tools.ex test/foreman_server/mcp/tools_test.exs` | 0 |
| `mix test test/foreman_server/mcp/tools_test.exs --warnings-as-errors` | 0 — 31 passed |
| `mix test test/foreman_server/mcp/ --warnings-as-errors` | 0 — 217 passed |
| `mix test test/foreman_server/mcp/tool_inventory_test.exs --warnings-as-errors` | 0 — 8 passed |
| `mix test test/foreman_server/docs_per_project_queue_test.exs test/foreman_server/observability/docs_test.exs --warnings-as-errors` | 0 — 6 passed |
| `mix run --no-start -e 'ForemanServer.Workflow.ReviewFindings.read/1 … ForemanServer.PrRisk.parse_judgement/1 …'` (this artifact's own two machine-read blocks, parsed by the server's own parsers) | 0 — findings `{:recorded, %Record{findings: 5}}`, judgement `%{status: "recorded", level: "MEDIUM", defect: nil}` |

`mix test test/foreman_server/dispatcher_test.exs --warnings-as-errors` (it
covers `RunAdmission`/slot-queueing) was attempted and **exit 1**, with no test
result printed at all: the suite aborted during startup with
`** (Mix) ProjectionLeakGuard never saw the end of the suite; nothing was judged`
after `idempotency store is not durable: no repo is configured (ETS fallback)`.
The cause of that abort was not established here (the log names no failing
test and no port), so no claim about which tests would pass or fail is made.
The run's own changed code is covered by the MCP suite above, and the
pre-existing `run_controller_test.exs` pending-run case at
`packages/foreman_server/test/foreman_server_web/controllers/run_controller_test.exs:112`
is unchanged by this diff.

After fixing, the diff was re-read once (`git diff main...HEAD` plus the
uncommitted doc edits): the only changed lines are the two documentation field
lists, which introduce no new identifier and no code path.

Fixes are left uncommitted for Foreman to commit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "docs/user-guide.md", "line": 2202, "description": "The foreman_run_status DTO field enumeration in docs/user-guide.md and README.md omitted the new `reason` field that docs/cli-reference.md documents, so the same interface was documented three different ways.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-24jxg/REVIEW_CODERABBIT_REPORT.md", "line": 30, "description": "The previous phase's report claims its findings and risk-judgement JSON blocks were re-parsed, but the committed file contains no marker blocks at all, so nothing was carried forward from it.", "disposition": "open", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-24jxg/FIX_REPORT.md", "line": 1, "description": "The fix phase's report artifact is a 4-byte placeholder, so the run has no first-person record of what the fix phase did or how it verified.", "disposition": "open", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-24jxg/PLAN.md", "line": 1, "description": "PLAN.md committed a truncated 15-line copy of the 225-line plan and referenced an unnamed section 5.3.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/mcp/tools.ex", "line": 1891, "description": "When pending_run/1 returned nil because the run started between the two projection reads, the tool still answered NOT_FOUND for a run that exists.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The code change is narrow and reuses the projection boundary the HTTP read model already serves, but it changes an existing MCP tool's contract: a run id that previously returned NOT_FOUND now returns a queued/deferred DTO, so any caller that treated NOT_FOUND as \"not a Foreman run\" sees new behavior. The new `reason` field is also added to a DTO returned by every foreman_run_status call."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
