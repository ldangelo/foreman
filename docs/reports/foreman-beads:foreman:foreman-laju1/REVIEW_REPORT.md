Phase 4 (repo-rules review) complete.

## What was reviewed
`git diff main...HEAD` (`FOREMAN_BASE_BRANCH=main`, HEAD `ec308218`) — 10 files, +661/−4: the `foreman_run_status` pending-run fallback (`tools.ex` → `ProjectionStore.pending_run/1` → `pending_run_status_dto/1`), the terminal-task deny-list in `dispatcher.ex:1464`, and the bead's regression tests. Rules applied: `AGENTS.md` (documentation gate, §5 typed boundaries, failing-test-is-a-failed-build).

## Findings — 3 fixed, 1 declined
- **fixed** `README.md:385` — `foreman_run_status` paragraph documented neither the queued nor deferred pending-projection status that this diff adds, while the other three documentation-gate files did.
- **fixed** `packages/foreman_server/lib/foreman_server/mcp/tools.ex:913` — the `foreman_run_status` schema description (the tool's user-facing contract) omitted the new fallback.
- **fixed** `CLAUDE.md:1036` §19 — said only `"queued"`, while `docs/cli-reference.md:1610` and `docs/user-guide.md:2207` also say `"deferred"`; the three disagreed about behavior this diff introduces.
- **declined** `dispatcher.ex:1464` — deny-list `"merged"` is not producible by the task aggregate (`aggregates/task.ex:46` `@valid_statuses` = open/ready/in_progress/blocked/closed/failed); kept as deliberate defence for legacy/foreign projections carrying no `:status`, and narrowing it would weaken admission.
- Noted for the operator, not filed: the pending DTO carries the deferral code in `RunStatus.failure_reason`, a field the run projection only fills for failed runs.

## Carry-forward
The previous phase's `REVIEW_CODERABBIT_REPORT.md` has **no machine-readable findings block** (no markers in it, `FIX_REPORT.md` or `PLAN.md`) — recorded under §1; its 5 prose findings were already fixed in `HEAD`.

## Verification
- `mix format --check-formatted lib/foreman_server/mcp/tools.ex` → exit 0
- `MIX_ENV=test mix test --warnings-as-errors test/foreman_server/mcp/tools_test.exs test/foreman_server/workflow/dispatcher_slot_promoted_test.exs test/foreman_server/command_gateway_cancel_queued_run_test.exs` → exit 0, **44 passed** (own DB `foreman_test_laju1p4`)
- Both machine-read blocks validated with the repo's own parsers: `ReviewFindings.read/1` → `{:recorded, …}` 4 findings `[:fixed, :fixed, :fixed, :declined]`; `PrRisk.parse_judgement/1` → `status: "recorded"`, `level: "LOW"`.

## Artifacts
`docs/reports/foreman-beads:foreman:foreman-laju1/REVIEW_REPORT.md` written (5 sections + findings block + risk judgement `LOW`, last). Fixes left uncommitted (`CLAUDE.md`, `README.md`, `mcp/tools.ex`) for Foreman to commit. kata `5fgj` created, claimed and closed with test evidence. Progress notes sent via `foreman_task_add_comment` and `foreman_inbox_send`.