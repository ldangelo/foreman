# Repository-rules review — `beads:foreman:foreman-laju1`

## 1. Review engine

- **Reviewer:** `repo-rules` — this phase's own repository-rules reviewer (no external
  review CLI runs here; the pass is a read of the diff against the repository's own
  contributor guidance plus the codebase's established patterns in the touched files).
- **Rules applied:** `AGENTS.md` — the documentation gate (§ Documentation Gate: an
  identifier/behavior change must be reconciled across `CLAUDE.md`, `README.md`,
  `docs/user-guide.md`, `docs/cli-reference.md`), the typed-boundary rules
  (§5.1–§5.7), the invariants, and "a failing test is a failed build".
- **Diff range reviewed:** `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with
  `FOREMAN_BASE_BRANCH=main` (the branch this run was cut from; `HEAD=ec308218`),
  10 files, +661/−4:
  - `CLAUDE.md`, `docs/cli-reference.md`, `docs/user-guide.md`
  - `docs/reports/foreman-beads:foreman:foreman-laju1/{FIX_REPORT.md,PLAN.md,REVIEW_CODERABBIT_REPORT.md}`
  - `packages/foreman_server/lib/foreman_server/mcp/tools.ex`
  - `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`
  - `packages/foreman_server/test/foreman_server/mcp/tools_test.exs`
  - `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs`
- **Behavior under review:** the diff adds a pending-run fallback to
  `foreman_run_status` (`tools.ex` → `ProjectionStore.pending_run/1` →
  `pending_run_status_dto/1`, status `"queued"`/`"deferred"`, `terminal` `false`),
  a deny-list in `dispatcher.ex` `start_promoted_run/2` that refuses to start a
  promoted run whose task is already terminal, and the regression tests the bead
  asked for.
- **Carry-forward of the previous phase:** the previous phase's
  `REVIEW_CODERABBIT_REPORT.md` sits beside this artifact but carries **no
  machine-readable findings block** — no `FOREMAN_REVIEW_FINDINGS` marker lines
  appear in it, nor in `FIX_REPORT.md` or `PLAN.md`. There was therefore no
  `findings` array to copy forward into this block. Its five prose findings were
  already fixed in `HEAD` (C1–C5 below) and carry no finding objects to carry.
- **Re-read after fixing:** `git diff main...HEAD` plus this phase's uncommitted
  fixes were re-read once; no new violation was introduced (see §3 and §5).

## 2. Findings

| ID | Severity | Location | Disposition | Source | Finding |
| --- | --- | --- | --- | --- | --- |
| R1 | minor | `README.md:385` | fixed | repo-rules | `README.md` — one of the four files the documentation gate names — did not describe the pending-run fallback this diff adds, while `CLAUDE.md`, `docs/cli-reference.md` and `docs/user-guide.md` all did. |
| R2 | minor | `packages/foreman_server/lib/foreman_server/mcp/tools.ex:913` | fixed | repo-rules | The `foreman_run_status` MCP tool schema description — the tool's own user-facing contract — did not mention that a run still waiting for a slot is answered from its pending projection with status `"queued"`. |
| R3 | minor | `CLAUDE.md:1036` | fixed | repo-rules | `CLAUDE.md` §19 stated only `status` `"queued"`, while `docs/cli-reference.md` and `docs/user-guide.md` also state `"deferred"` while the project is deferred; the three documents disagreed about behavior this diff introduced. |
| R4 | minor | `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1464` | declined | repo-rules | The deny-list value `"merged"` is not a task status the aggregate can produce (`@valid_statuses` in `packages/foreman_server/lib/foreman_server/aggregates/task.ex:46` is `open, ready, in_progress, blocked, closed, failed`). |

### Previous phase's prose findings (already fixed in `HEAD`; nothing to carry forward)

| ID | Finding | State in `HEAD` |
| --- | --- | --- |
| C1 | `FIX_REPORT.md` had been committed as a captured tool-error wrapper instead of a report. | fixed (report text restored) |
| C2 | `PLAN.md` had been replaced by a short chat summary instead of the real plan. | fixed (restored from git history) |
| C3 | The plan gate command did not unset `DATABASE_URL`, so it could not run in isolation. | fixed |
| C4 | A new dispatcher test mocked `ForemanServer.CommandGateway` globally (`:meck.new(..., [:no_link])`), breaking 168 unrelated tests. | fixed (`:passthrough, :no_link]` + `on_exit` unload, matching `dispatcher_slot_release_test.exs:44`, `dispatcher_slot_rebalance_test.exs:193`, `run_admission_slot_gate_test.exs:226`) |
| C5 | Bead item (a) (cancelling a queued run removes its waiter and ends it) had no test of its own. | already covered by `packages/foreman_server/test/foreman_server/command_gateway_cancel_queued_run_test.exs:42` — no duplicate test written |

## 3. Fixed

- **R1 — `README.md:385`.** Wrong: `README.md` is one of the four files the documentation
  gate names, and it described `foreman_run_status` without the queued/deferred
  pending-projection behavior this diff adds (the other three gate files had it).
  Changed: the `foreman_run_status` paragraph now states that a run still waiting for a
  slot has no run projection yet, that the DTO then comes from the pending projection with
  `status` `"queued"` (`"deferred"` while the project is deferred), `terminal` `false` and
  `current_phase` `null`, and that `NOT_FOUND` means the run id is unknown — worded to
  match `docs/cli-reference.md` and `docs/user-guide.md`.
- **R2 — `packages/foreman_server/lib/foreman_server/mcp/tools.ex:913`.** Wrong: the
  `@schema_foreman_run_status` description is the MCP tool's user-facing contract and did
  not mention the new pending-projection fallback, so the tool advertised less than it
  does. Changed: the description is now "Get a bounded run status DTO from run and phase
  projections; a run still waiting for a slot answers from its pending projection with
  status \"queued\"". (Description only — no schema, name, or payload change.)
- **R3 — `CLAUDE.md:1036`.** Wrong: §19 said the fallback answers `status` `"queued"` only,
  while `docs/cli-reference.md` and `docs/user-guide.md` also document `"deferred"` while
  the project is deferred, so the repository's own three user-facing documents disagreed
  about the behavior this diff introduced. Changed: §19 now reads `status` `"queued"`
  (`"deferred"` while the project is deferred), matching the other two files.

All three fixes are documentation-only and leave the code and the MCP payload untouched.

## 4. Declined

- **R4 — `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1464`.** Finding:
  the deny-list in `start_promoted_run/2` admits the task status `"merged"`, which the
  task aggregate cannot produce (`@valid_statuses` in
  `packages/foreman_server/lib/foreman_server/aggregates/task.ex:46` contains `open`,
  `ready`, `in_progress`, `blocked`, `closed`, `failed` — no `merged`), so the value is
  currently unreachable. Reason for declining: the deny-list is deliberately defensive —
  the adjacent comment records that older task projections carry no `:status` key at all,
  and a foreign or legacy projection could carry any terminal-shaped status; narrowing the
  list to exactly the values today's aggregate emits would make the guard weaker against
  projections this run does not own. Removing a defensive branch is outside this run's
  scope and would change admission behavior without a test that justifies it.

### Observed but not filed as a finding

- `packages/foreman_server/lib/foreman_server/mcp/tools.ex` (`pending_run_status_dto/1`):
  the pending DTO carries the deferral code (`daily_thread_cap_exceeded`,
  `run_limit_exceeded`, `project_paused` — `packages/foreman_server/lib/foreman_server/aggregates/project.ex:721`)
  in `RunStatus.failure_reason`, a field the run projection otherwise only populates for
  failed runs (`packages/foreman_server/lib/foreman_server/projection_store.ex:4657-4665`).
  Not filed: `RunStatus` has no deferral slot, no in-repo consumer reads `failure_reason`
  for a pending run (MCP-only; no CLI consumer), and giving the DTO a new field would
  change the externally visible MCP payload — a larger, operator-visible change than this
  review pass should make unilaterally. Noted here for the operator instead.

## 5. Verification

All commands were run from `packages/foreman_server` with the run's own test database
(`DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test_laju1p4`,
`TEST_DB_POOL_SIZE=5`; one database per concurrent run because `mix.exs` takes a
PostgreSQL advisory lock per database).

| Command | Exit code | Result |
| --- | --- | --- |
| `mix format --check-formatted lib/foreman_server/mcp/tools.ex` | 0 | formatted |
| `MIX_ENV=test mix test --warnings-as-errors test/foreman_server/mcp/tools_test.exs test/foreman_server/workflow/dispatcher_slot_promoted_test.exs` | 0 | `Result: 39 passed` |
| `MIX_ENV=test mix test --warnings-as-errors test/foreman_server/mcp/tools_test.exs test/foreman_server/workflow/dispatcher_slot_promoted_test.exs test/foreman_server/command_gateway_cancel_queued_run_test.exs` | 0 | `Result: 44 passed` |

- The first run against the freshly created test database exited 1 with
  `ERROR 42P01 (undefined_table) relation "snapshots" does not exist`: the new database
  had no event-store schema. `MIX_ENV=test mix event_store.init` (exit 0) created it and
  the re-run passed. Not a code defect; recorded so the exit code of the first attempt is
  not mistaken for a green run.
- The `README.md` and `CLAUDE.md` edits are prose only and have no test surface; they
  were re-read against the wording in `docs/cli-reference.md` and `docs/user-guide.md`.
- Full-suite run was not repeated here: the previous phase already ran the whole
  `foreman_server` suite green (9,172 passed) on this branch, and this phase changed only
  documentation plus one tool-description string.
- Operator progress notes were sent with `foreman_task_add_comment` and
  `foreman_inbox_send` (both returned `status: comment_added` / `status: sent`).

Fixes are left uncommitted for Foreman to commit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "README.md", "line": 385, "description": "README.md did not document the queued/deferred pending-run status that this diff adds to foreman_run_status, while the other three documentation-gate files did.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/mcp/tools.ex", "line": 913, "description": "The foreman_run_status MCP tool schema description did not mention the new pending-projection fallback, so the tool advertised less than it returns.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "CLAUDE.md", "line": 1036, "description": "CLAUDE.md section 19 documented only the queued status for a run waiting for a slot, disagreeing with docs/cli-reference.md and docs/user-guide.md, which also document the deferred status.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex", "line": 1464, "description": "The promoted-run deny-list admits the task status \"merged\", which the task aggregate cannot produce.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The change is a narrow fallback in the run-status DTO plus a defensive admission guard and its regression tests; the only defects this review found were three stale documentation statements and one unreachable deny-list value that was declined as deliberate defence. All fixes are prose, and the narrow test run (44 passed) and formatter are green."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
