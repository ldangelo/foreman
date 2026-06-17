## Review — REJECTED

- Correct:
  - TRD/PRD trace is wired: `docs/PRD/...:465-467`, `docs/TRD/...:705-715`, `:1009-1011`.
  - Command routing exists for `PlanningFlowCommand`, `plan.prd`, `plan.trd`: `packages/foreman_server/lib/foreman_server/command_router.ex:7`, `:38-47`, `:225-230`.
  - Traceability projection/task fields exist: `projection_store.ex:666-684`, `command_router.ex:105-126`, `projection_store.ex:194-213`.
  - Tests added: `packages/foreman_server/test/planning_flow_test.exs:29-135`.
  - Validation passed:
    - `cd packages/foreman_server && mix test` → 89 tests, 0 failures.
    - `npx tsc --noEmit` → passed.
    - `git status --short` → clean.

- Fixed:
  - None. No edits per review-only/no-edit.

- Blocker:
  - Planning flow does not actually execute the worker/provider. It fabricates completion.
    - `PlanningFlow.execute_phases/4` calls `WorkerProtocol.start_phase/2`, then immediately calls `WorkerProtocol.ingest_event/1` with `type: "phase_completed"` and hard-coded `output`: `planning_flow.ex:73-107`.
    - Artifact output is only string metadata: `planning_flow.ex:284-290`.
    - No provider/subprocess/adapter execution path invoked. So AC-019-1/2 are not proven for real PRD/TRD artifact generation.
  - Planning runs remain active after “completion”.
    - `PlanningFlowCompleted` only updates `planning_flows`: `projection_store.ex:687-695`.
    - Run status becomes completed only from `RunCompleted`: `projection_store.ex:292-295`.
    - `PlanningFlow` never emits `RunCompleted`: `planning_flow.ex:209-221`.
    - Test even asserts worker remains `"running"` after completion: `planning_flow_test.exs:47-50`.
    - This can skew run status/debug/status counts.

- Note:
  - Alias routing can be overridden by conflicting payload kind. `plan.prd` uses `Map.put_new(:kind, "prd")`, so payload `%{kind: "trd"}` runs TRD: `command_router.ex:225-230`. Use `Map.put`.
  - Idempotent rerun likely fails. Default run id is deterministic: `planning_flow.ex:314-321`; duplicate idempotency returns error: `event_store.ex:108-119`. Decide retry behavior.
  - `progress.md` was requested but missing.
  - Did not write `subagent-outputs/review-trd-022-correctness.md`: user also said no edits; no-edit wins.