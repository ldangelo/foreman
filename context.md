# Code Context

## Files Retrieved
1. `docs/user-guide.md` (lines 52-221) - issue #410 operator API/runtime claims audited.
2. `packages/foreman_server/lib/foreman_server_web/router.ex` (lines 1-37) - HTTP route anchors for `/api/commands`, `/api/work/:id`, `/api/runs/:id`.
3. `packages/foreman_server/lib/foreman_server_web/controllers/command_controller.ex` (lines 1-220) - `/api/commands` allowlist, aggregate_id derivation, response shape.
4. `packages/foreman_server/lib/foreman_server_web/controllers/work_controller.ex` (lines 1-16) - `/api/work/:id` response shape.
5. `packages/foreman_server/lib/foreman_server_web/controllers/run_controller.ex` (lines 1-25) - `/api/runs/:id` response shape.
6. `packages/foreman_server/lib/foreman_server/command_gateway.ex` (lines 45-135, 780-844, 969-991) - operator dispatch, `work.submit` enrichment/reserved fields.
7. `packages/foreman_server/lib/foreman_server/work/submission.ex` (lines 1-91) - required work fields, workflow snapshot/run_id/submission_id derivation.
8. `packages/foreman_server/lib/foreman_server/projection_store.ex` (lines 221-224, 1382-1450) - work projection statuses and fields.
9. `packages/foreman_server/lib/foreman_server/aggregates/task.ex` (lines 1-170, 240-498) - task lifecycle/retry states.
10. `packages/foreman_server/lib/foreman_server/overwatch/launch_worker.ex` (lines 1-31, 107-150, 198-201) - WorkerStarted ordering and activation.
11. `packages/foreman_server/lib/foreman_server/overwatch/adapters/jido_harness_worker.ex` (lines 1-174) - heartbeat/exited/result behavior.
12. `packages/foreman_server/lib/foreman_server/agent_runtime/adapters/jido_harness_adapter.ex` (lines 1-177) - bundled adapter defaults and provider behavior.
13. `packages/foreman_server/config/config.exs` (lines 21-94) - runtime/Overwatch/OTel dev defaults.
14. `packages/foreman_server/config/dev.exs` (lines 13-38) - Phoenix dev port and dev runtime overrides.
15. `packages/foreman_server/config/prod.exs` (lines 81-119) - OTel/Langfuse v3 Basic auth.
16. `devbox.json` (lines 1-220) - devbox commands/env and otel stack behavior.

## Key Code

- Routes exist:
  - `router.ex:18-24`: `post /api/commands`, `get /api/runs/:id`, `get /api/work/:id`.
- `/api/commands`:
  - `command_controller.ex:18`: allowlist includes `project.register`, `project.update`, `project.archive`, `task.create`, `task.approve`, `task.retry`, `run.cancel`, `work.submit`, `work.cancel`.
  - `command_controller.ex:82-150`: derives/verifies `aggregate_id` from payload id fields.
  - `command_controller.ex:24-28`: success response is `201 %{status: "accepted", result: serialize(result)}`.
- `work.submit`:
  - `command_gateway.ex:798-831`: enriches with server-derived `submission_id`, `run_id`, `workflow_snapshot`; reserved fields rejected.
  - `work/submission.ex:30-55`: requires binary non-empty `work_id`, binary `project_id`, binary `workflow`, binary `prompt`; loads `<workflow>.yaml`; derives UUID `submission_id` and deterministic `run_id`.
  - `projection_store.ex:1392-1401`: work projection fields: `work_id`, `status`, `project_id`, `run_id`, `submission_id`, `queue_position: nil`, `backend`.
  - `projection_store.ex:1394, 1416, 1433, 1447`: statuses are `:submitted`, `:cancelled`, `:succeeded`, `:failed`.
- Task lifecycle:
  - `aggregates/task.ex:60-170`: events map to `open`, `ready`, `in_progress`, `closed`, `failed`, `blocked`.
  - `aggregates/task.ex:247-256`: dispatch requires approved/bound state and emits `TaskDispatched`.
  - `aggregates/task.ex:316-340, 394-425, 476-498`: retry accepts `in_progress` or `failed`, requires bound acknowledged run, clears run-bound fields and returns to `open`.
- Overwatch/Jido:
  - `config/config.exs:21-36`: runtime enabled by default, sole adapter `JidoHarnessAdapter`, Overwatch enabled outside tests.
  - `launch_worker.ex:24-31, 107-150`: start worker, register Tracker, emit `WorkerStarted`, then activate.
  - `jido_harness_worker.ex:73-119`: after activation, periodic `WorkerHeartbeat`; on result emits `WorkerExited`, sends `{:worker_result, result}`, exits normal.
  - `jido_harness_worker.ex:142-174`: normalizes Jido.Harness result to `{:ok, text}` or `{:error, reason}`; metadata dropped.
- JidoHarness defaults:
  - `jido_harness_adapter.ex:17-19`: timeout `60_000`, await `:infinity`, supported providers `[:pi, :claude]`.
  - `jido_harness_adapter.ex:46-49`: `available?/0` checks installed `:pi` or installed `:claude` directly.
  - `jido_harness_adapter.ex:110-118`: `timeout_ms` translated to `:timeout`; cwd/env passed when present.
- OTel/Langfuse:
  - `config/config.exs:69-94`: dev defaults `http://localhost:4318`, `:http_protobuf`.
  - `prod.exs:81-119`: reads `OTEL_EXPORTER_OTLP_ENDPOINT`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`; builds Basic `Authorization` header for both `:jido_otel` and `:opentelemetry_exporter`.
  - `devbox.json:105-135`: `devbox run up` starts litellm-langfuse stack, waits on Langfuse, then starts `ops/otel-collector` with stack env.
- Devbox/env:
  - `devbox.json:15-45`: sources repo `.env`, then `$LITELLM_LANGFUSE_STACK/.env`; defaults `LITELLM_LANGFUSE_STACK`; exports `FOREMAN_API_URL=http://127.0.0.1:4766`.
  - `devbox.json:46-220`: documented commands exist: `info`, `env:list`, `setup`, `up`, `down`, `reset`, `ps`, `logs`, `logs:stack`, `deps`, `fmt`, `compile`, `server`, `iex`, `db:*`, `test*`.

## Architecture

- External mutation flow: `POST /api/commands` -> `CommandController.build_envelope/1` -> `CommandGateway.dispatch_operator/2` -> `CommandRouter` -> aggregate event -> projections.
- Work submit flow: HTTP payload -> canonical `work:<work_id>` aggregate id -> gateway validates/enriches -> `WorkSubmitted` -> `ProjectionStore.works[work_id]` -> `GET /api/work/:id`.
- Run read flow: run events projected in `ProjectionStore` -> `GET /api/runs/:id` returns `%{run: stringify_keys(projection)}`.
- Runtime flow: `RunExecutor` starts phase via `Overwatch.start_phase/2` -> `WorkerSupervisor` -> `LaunchWorker` -> `WorkerProtocol.start_worker/3` -> `JidoHarnessAdapter.start_link/1` -> `JidoHarnessWorker`. Tracker owns sequenced `WorkerHeartbeat`/`WorkerExited`; LaunchWorker emits initial `WorkerStarted` after registration.

## Findings / stale doc lines needing edits

- **high: `docs/user-guide.md:168-170`, `183-187`, `208`, `211-212`** - stale/unsupported config claims. Docs say `JidoHarnessAdapter.available?/0` self-gates on configured `:jido_harness, :providers`, and that `:foreman_server, :jido_harness, :providers` defaults to `[:pi, :claude]`; source has no `:foreman_server, :jido_harness, :providers` config and adapter uses hard-coded `@supported_providers [:pi, :claude]` plus direct readiness checks. `:jido_harness, :enabled` kill-switch is only configured false in test; no source anchor found where it disables production adapter registration.
- **medium: `docs/user-guide.md:145-148`** - mostly correct, but prod source sets `OTEL_EXPORTER_OTLP_ENDPOINT` default to `http://localhost:4318`; if doc implies prod must always set endpoint, clarify default exists. Basic auth claim is correct.
- **low: `packages/foreman_server/config/config.exs:88-91` source comment stale, not doc** - comment says prod adds `Authorization: Bearer` from `LANGFUSE_PUBLIC_KEY`; `prod.exs` now correctly builds Basic from public+secret. Optional source cleanup.
- **none: `docs/user-guide.md:54-94`** - operator API/read endpoint claims match source.
- **none: `docs/user-guide.md:78-85`** - `work.submit` derivation/reserved-field/response/projection claims match source, with note that code requires non-empty `work_id` and binary `project_id/workflow/prompt`; only `work_id` has explicit non-empty guard in `Work.Submission.prepare/1`.
- **none: `docs/user-guide.md:97-111`** - task lifecycle/retry summary matches aggregate source.
- **none: `docs/user-guide.md:115-126`** - Overwatch/JidoHarnessWorker lifecycle summary matches source.
- **none: `docs/user-guide.md:128-137`** - sole bundled adapter, per-aggregate `State` structs, and Beads lease keying summary match inspected source (`beads_db_lease:<db_path>` route in `CommandRouter`, `BeadsDbLease.State` exists). Residual caveat: did not trace path canonicalization fully beyond source comments/tests.
- **none: `docs/user-guide.md:140-148`** - local OTel/Langfuse v3 claims align with `devbox.json`, collector docs/config grep, and prod Basic auth source.
- **none: `docs/user-guide.md:16-47`** - devbox command/env quickstart matches `devbox.json` and `dev.exs` port 4766.

## Start Here

Open `docs/user-guide.md` around lines 168-212 first. Main likely edit: remove/adjust unsupported `:foreman_server, :jido_harness, :providers` and kill-switch availability language, or implement missing config elsewhere if intended.

## Supervisor coordination

None.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Concrete findings include stale docs with severities and source anchors for operator API, work.submit, projections, runtime, JidoHarness, OTel, Beads, State structs, devbox."
    }
  ],
  "changedFiles": [
    "context.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "grep/read/ls/find inspections only",
      "result": "passed",
      "summary": "Mapped relevant source and docs anchors."
    }
  ],
  "validationOutput": [
    "Findings written to /Users/ldangelo/Development/Fortium/foreman.jido-migration/context.md"
  ],
  "residualRisks": [
    "Did not run test suite or server.",
    "Beads DB path canonicalization was not fully traced beyond aggregate/route anchors and existing doc/source comments.",
    "Collector compose/config was inferred via devbox and grep context; no live Docker validation."
  ],
  "noStagedFiles": true,
  "diffSummary": "Wrote scout findings to context.md only.",
  "reviewFindings": [
    "high: docs/user-guide.md:168-170,183-187,208,211-212 - JidoHarness provider/kill-switch claims not supported by inspected source.",
    "medium: docs/user-guide.md:145-148 - prod endpoint wording may overstate requirement; source has localhost:4318 default.",
    "low: packages/foreman_server/config/config.exs:88-91 - source comment still says Bearer though prod uses Basic."
  ],
  "manualNotes": "Audit-only scout. No source/docs edits made beyond context artifact."
}
```
