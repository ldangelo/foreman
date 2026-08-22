# Code Context

## Files Retrieved
1. `docs/user-guide.md` (lines 16-47, 52-151, 171-178, 194-203, 1082-1086) - audited operator docs.
2. `packages/foreman_server/lib/foreman_server_web/router.ex` (lines 20-34) - API routes.
3. `packages/foreman_server/lib/foreman_server_web/controllers/command_controller.ex` (lines 20-182) - `POST /api/commands` allowlist + aggregate id checks.
4. `packages/foreman_server/lib/foreman_server_web/controllers/work_controller.ex` (lines 1-16) - `GET /api/work/:id`.
5. `packages/foreman_server/lib/foreman_server_web/controllers/run_controller.ex` (lines 1-28) - `GET /api/runs/:id`.
6. `packages/foreman_server/lib/foreman_server/command_gateway.ex` (lines 307-345, 798-845) - work submit project checks, reserved-field enrichment.
7. `packages/foreman_server/lib/foreman_server/work/submission.ex` (lines 35-62, 68-102) - work submit required fields + snapshot derivation.
8. `packages/foreman_server/lib/foreman_server/aggregates/task.ex` (lines 1-42, 98-111, 117-131, 443-485) - task lifecycle state.
9. `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` (lines 441-445) - Overwatch worker runtime handoff.
10. `packages/foreman_server/lib/foreman_server/overwatch/launch_worker.ex` (lines 3-36, 104-156, 180-202) - WorkerStarted/register/activate flow.
11. `packages/foreman_server/lib/foreman_server/overwatch/adapters/jido_harness_worker.ex` (lines 1-23, 74-95, 98-125) - heartbeat/result/exited flow.
12. `packages/foreman_server/lib/foreman_server/agent_runtime/adapters/jido_harness_adapter.ex` (lines 1-19, 50-67) - provider support/readiness.
13. `packages/foreman_server/config/config.exs` (lines 21-28, 39-47) - JidoHarnessAdapter sole backend config.
14. `ops/otel-collector/config.template.yaml` (lines 46-58, 78-80) - Langfuse v3 OTLP HTTP exporter.
15. `ops/otel-collector/entrypoint.sh` (lines 38-54) - Langfuse host/auth env.
16. `devbox.json` (lines 37-43, 105-123, 164-189) - devbox env and workflows.
17. `packages/foreman_server/lib/foreman_server/aggregates/beads_db_lease.ex` (lines 1-11, 93-106, 314-323, 329-397) - per-DB lease state/stream.
18. `packages/foreman_cli/cmd/foreman/run.go` (lines 18-24, 82-131) - CLI run submit flags/backend validation.

## Key Code
- Accurate: API surface.
  - Docs: `docs/user-guide.md:54-60` says mutations via `POST /api/commands`, allowlist incl `work.submit`, aggregate id derived/verified.
  - Source: `command_controller.ex:21`, `:23-32`, `:137-181` matches.
  - Routes: `router.ex:22-29` has `post /commands`, `get /runs/:id`, `get /work/:id`.
- Accurate: read endpoints.
  - Docs: `docs/user-guide.md:91-94`.
  - Source: `work_controller.ex:6-15`, `run_controller.ex:12-22`.
- Accurate w/ nuance: task lifecycle.
  - Docs correctly explain operator shorthand terminal = completed/failed at event/run level, `closed`/`failed` in task read model: `docs/user-guide.md:98-111`.
  - Source: `task.ex:42`, `:98-111`, `:117-131`, retry accepts `in_progress`/`failed` at `:476-485`.
- Accurate: Overwatch/Jido worker flow.
  - Docs: `docs/user-guide.md:115-126`.
  - Source: `run_executor.ex:441-445`, `launch_worker.ex:3-36`, `:104-156`, `jido_harness_worker.ex:1-23`, `:74-95`, `:98-125`.
- Accurate: PiAdapter removed / JidoHarnessAdapter sole bundled backend.
  - Docs: `docs/user-guide.md:128-129`, `:431-442`.
  - Source: config sole adapter at `packages/foreman_server/config/config.exs:21-28`; no `PiAdapter` file found.
- Stale/minor: JidoHarnessAdapter config docs omit kill switch/providers.
  - Docs current section says `JidoHarnessAdapter.available?/0` checks either bundled provider installed, lines `171-178`, and per-adapter table lines `198-203` only lists request provider/timeouts.
  - Source still has `:jido_harness, enabled: false` in test config and comments in `config/test.exs:37-42`; app registration appears only gated by adapter list in `application.ex:144-156`. Need impl decision: docs no longer mention `:foreman_server, :jido_harness, :enabled` / `:providers`; older docs did. If flags are dead, source/config stale. If flags live elsewhere, docs incomplete.
- Accurate: OTel collector -> Langfuse v3.
  - Docs: `docs/user-guide.md:140-151`.
  - Source: `ops/otel-collector/config.template.yaml:46-58` endpoint `http://${LANGFUSE_HOST}/api/public/otel`, Basic auth; `:78-80` exporter; `entrypoint.sh:38-54` defaults `langfuse-web:3000` and computes Basic auth.
- Accurate: Beads per-DB lease + Aggregate.State migration.
  - Docs: `docs/user-guide.md:130-138`.
  - Source: per-aggregate `State` in `task.ex:11-35`, `beads_db_lease.ex:93-106`; stream id `beads_db_lease:#{db_path}` at `beads_db_lease.ex:314`; code comments say configured absolute db_path and no symlink normalization in lease at `beads_db_lease.ex:1-11`.
- Accurate: devbox workflow.
  - Docs: `docs/user-guide.md:16-47`.
  - Source: `devbox.json:37-43` env, `:105-123` up, `:164-189` server/iex/tests.
- Accurate: CLI backend flags/operator expectations.
  - Docs: `docs/user-guide.md:1082-1086` says backend accepts `pi`, `claude`, `codex`, `opencode`, default `pi` omitted.
  - Source: `packages/foreman_cli/cmd/foreman/run.go:18`, `:82-131` matches.

## Architecture
- Phoenix routes `/api/*` to controllers.
- `CommandController` validates envelope + aggregate id, then delegates to `CommandGateway.dispatch_operator/1`.
- `work.submit` is enriched by `CommandGateway` via `Work.Submission.prepare/1`, then aggregate/event/projection path supplies `/api/work/:id` and `/api/runs/:id` reads.
- Run execution goes `RunExecutor -> Overwatch.start_phase -> LaunchWorker -> JidoHarnessWorker`; LaunchWorker owns `WorkerStarted`, worker owns heartbeats/exit/result.
- Jido runtime is in-process via `JidoHarnessAdapter`; OTel traces go to local collector, which forwards to Langfuse v3 with Basic auth.
- Beads-backed flows serialize by DB path through `BeadsDbLease` aggregate stream.

## Start Here
Open `docs/user-guide.md:52-151` first. It contains issue #410 surface and is mostly accurate. Then inspect the possible stale Jido kill-switch/provider config mismatch in `packages/foreman_server/config/test.exs:37-42` and `packages/foreman_server/lib/foreman_server/application.ex:144-156`.

## Findings
- minor: `docs/user-guide.md:78-79` says `work.submit` requires non-empty `workflow` and `prompt`. Source only enforces `work_id` and `project_id` non-empty (`command_gateway.ex:311-329`) and only checks `workflow_name`/`prompt` are binaries, not non-empty (`work/submission.ex:41-43`). Empty workflow fails later as workflow load; empty prompt can build a snapshot. Docs are stricter than code.
- minor: `docs/user-guide.md:198-203` no longer documents `:foreman_server, :jido_harness, :enabled` / `:providers`, but `config/test.exs:37-42` still references `:jido_harness, enabled: false`. App registration source checked (`application.ex:144-156`) appears gated only by adapter list. Either remove dead config or document live config if implemented elsewhere.
- no blocker: operator API docs match routes/controllers for `POST /api/commands`, `work.submit`, `/api/work/{id}`, `/api/runs/{id}`.
- no blocker: lifecycle, Overwatch events, JidoHarnessAdapter/PiAdapter removal, OTel Langfuse v3 forwarding, Beads lease, Aggregate.State migration, devbox, and CLI backend docs match audited code.

## Supervisor coordination
None.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Concrete findings include severities and exact source/docs paths/lines for operator API, lifecycle, Overwatch, Jido, OTel, Beads, Aggregate.State, devbox, CLI."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "grep/read/bash inspection only",
      "result": "passed",
      "summary": "Audited docs/user-guide.md against targeted source files; no tests run."
    }
  ],
  "validationOutput": [
    "Findings written to context.md. No edits to docs/source."
  ],
  "residualRisks": [
    "Did not run test suite or compile; audit based on static inspection.",
    "Jido :jido_harness enabled/providers config may be implemented outside inspected paths; flagged as minor open question."
  ],
  "noStagedFiles": true,
  "diffSummary": "Only context.md artifact written per task; no code/docs edits.",
  "reviewFindings": [
    "minor: docs/user-guide.md:78-79 vs packages/foreman_server/lib/foreman_server/work/submission.ex:41-43 - docs claim non-empty workflow/prompt; code only requires binaries, so empty prompt can pass snapshot prep and empty workflow fails as workflow_load_failed rather than missing_required_fields.",
    "minor: docs/user-guide.md:198-203 vs packages/foreman_server/config/test.exs:37-42 and packages/foreman_server/lib/foreman_server/application.ex:144-156 - docs omit :jido_harness enabled/providers config while test config still references enabled; decide dead config vs missing docs."
  ],
  "manualNotes": "No blockers found for issue #410 docs accuracy."
}
```