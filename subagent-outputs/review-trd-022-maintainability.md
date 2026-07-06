## Review — REJECTED

- Correct:
  - `plan.prd`, `plan.trd`, `PlanningFlowCommand` route to `PlanningFlow.run/1`: `command_router.ex:6-46`.
  - Planning flow emits worker events, trace events, and planning tasks: `planning_flow.ex:79-179`.
  - Planning projections added: `projection_store.ex:666-694`.
  - Planning input normalization avoids atom growth: `planning_flow.ex:323-343`; command router uses allowlisted keys: `command_router.ex:267-326`.
  - Tests cover AC-019 basics: worker path, traceability, command aliases, compat commands: `planning_flow_test.exs:29-135`.
  - Validation passed: `mix test` in `packages/foreman_server` = 89 tests, 0 failures.

- Fixed:
  - None. Review-only/no-edit. Did not write requested output file because “No edits” conflicts with artifact writing.

- Blocker:
  - Completed planning flows leave run projection active/in-progress. `PlanningFlowCompleted` only updates `planning_flows`, not `runs`: `projection_store.ex:687-694`. `PhaseCompleted` updates phase status only: `projection_store.ex:337-353`. Repro showed returned planning status completed, but `runs[run_id].status == "in_progress"` and worker statuses remain `"running"`. This creates stale active runs/status counts.

- Note — fix worth doing now:
  - Default run IDs are deterministic from kind/project/description: `planning_flow.ex:314-320`. Re-running same plan input fails with duplicate idempotency: `event_store.ex:108-118`. Repro: first `PlanningFlow.run/1` ok; second returned `{:error, {:duplicate_idempotency_key, ...}}`. Prefer command_id/unique run id unless explicit idempotent replay is intended.
  - Worker HTTP boundary still has unsafe atom growth via `String.to_atom/1`: `worker_protocol.ex:131-140`. Planning path itself uses static keys, but public worker endpoints remain risky.
  - Docs are minimal. Only package README one-line mention: `packages/foreman_server/README.md:28`. Add payload/error examples when exposing operator-facing API/CLI.

- Note:
  - `progress.md` missing (`ENOENT`).
  - `plan.md` appears stale/unrelated to TRD-022; it describes Postgres Testcontainers migration.

- Commands:
  - `git status --short && git log --oneline -n 12` — passed.
  - `git show --stat ... && git diff --stat 0fabfb91..HEAD` — passed.
  - `git diff --check 0fabfb91..HEAD` — passed.
  - `cd packages/foreman_server && mix test test/planning_flow_test.exs` — passed, 4 tests.
  - `cd packages/foreman_server && mix test` — passed, 89 tests.
  - `cd packages/foreman_server && MIX_ENV=test mix run ...` — repro for duplicate default run id / stale run status.