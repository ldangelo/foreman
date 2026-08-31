# Completed documents

Moved here on 2026-08-30. Placement was decided by **reading the code**, not by
each document's `status:` frontmatter — that field is unreliable in this repo:
nearly every document in `docs/` still said `Draft`, including the durable run
log store that shipped as PR #422 and projects-crud whose TRD was already
sitting in this folder.

Three dispositions land a document here:

| Disposition | Meaning |
|---|---|
| `IMPLEMENTED` | the specified behavior exists in code now |
| `SUPERSEDED` | the goal was achieved, but by a different mechanism than this document specifies |
| `HISTORICAL_RECORD` | never a spec of future work: a smoke-run artifact or a point-in-time audit |

A document with remaining specified-but-absent surface stays in the parent
directory instead. `docs/PRD` and `docs/TRD` are point-in-time design specs, not
living docs (AGENTS.md, Documentation Discipline), so nothing below was rewritten
to match later reality — a `SUPERSEDED` row records the divergence rather than
editing the document to hide it.

| Document | Disposition | Evidence |
|---|---|---|
| `PRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md` | `HISTORICAL_RECORD` | smoke-run artifact, pinned to run-08ab944587c983489434fc648cf3eb5f |
| `PRD-2026-39d2f88f-beads-as-backlog-foreman-as-execution-driver.md` | `HISTORICAL_RECORD` | positioning/strategy record rather than a spec of pending surface |
| `PRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md` | `HISTORICAL_RECORD` | smoke-run artifact, run-6b79b6948c5b2de0cb679a6d92c44e9a; the br close fix it validates is in beads_adapter.ex |
| `PRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md` | `HISTORICAL_RECORD` | smoke-run artifact, run-8066e22db819f69002468779cafeee11; schema validation in json_schema_cache.ex |
| `PRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md` | `HISTORICAL_RECORD` | smoke-run artifact, run-b86c4907ee6b7d6bf0a5dcc6e89cf5fe |
| `PRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md` | `HISTORICAL_RECORD` | smoke-run artifact of the plan-workflow sequence fix |
| `PRD-2026-002184c6-projects-crud.md` | `IMPLEMENTED` | project.{register,update,archive,reactivate} + project_controller + aggregate; its TRD was already in completed/ |
| `PRD-2026-016-jido-harness-integration.md` | `IMPLEMENTED` | jido_harness_adapter.ex + AgentRuntime.JidoHarness.{Driver,Session,DetachedRun}; all 12 REQs traced |
| `PRD-2026-017-jido-signal-inter-agent-messaging.md` | `IMPLEMENTED` | agents/jido_signal_topics.ex all 4 topics; bus supervised application.ex:214; all 14 REQs traced |
| `PRD-2026-020-full-orchestration-cutover.md` | `IMPLEMENTED` | legacy removals confirmed: pi-sdk-runner/RunActor/PhaseActor/WorkflowInterpreter absent from all source (only stale cover/ HTML + ElixirLS PLT match); jido feature flags gone from config |
| `PRD-2026-4212be7e-jido-migration.md` | `IMPLEMENTED` | 26/26 REQs traced to code across agent_runtime, signals, MCP, OTEL, merge gate |
| `PRD-2026-48f7b420-foreman-beads-task-provider.md` | `IMPLEMENTED` | TaskProvider behaviour 11 callbacks + BeadsAdapter + Registry + SystemBrRunner sole br entry |
| `PRD-2026-54236004-workflow-simplification.md` | `IMPLEMENTED` | foreman run submit (run.go:131-244); curated prd/trd/fix manifests; backend enum in MCP schema; AutoPR wired |
| `PRD-2026-6af02293-otp-agent-runtime.md` | `IMPLEMENTED` | agent_runtime/{supervisor,adapter_catalog,backend_adapter,router,failure_policy,invocation}.ex; 9/9 REQs |
| `PRD-2026-81315f37-atomic-beads-task-create-and-watcher.md` | `IMPLEMENTED` | Actor.do_dispatch/4 two-stage finalization (actor.ex:282-381) + BeadsWatcher + BeadsOrphanJanitor + external_id round-trip |
| `PRD-2026-cd07a086-durable-run-log-store.md` | `IMPLEMENTED` | shipped as PR #422 / b1c3a920: WorkerStdout / WorkerStderr events, worker_log_policy.ex, ProjectionStore.run_logs/1 |
| `go-elixir-cqrs-parity-prd.md` | `IMPLEMENTED` | REQ-001..010 traced: command_controller ingress, projection_store, Overwatch, PR lifecycle, recovery, 66 typed events |
| `PRD-2026-3d41f677-add-full-vcs-worktree-support-configured-via-wor.md` | `SUPERSEDED` | specifies PHASE-level worktree for v1; beb7dea6 shipped WORKFLOW-level, one worktree per run. Phase-level declarations are now REFUSED by Interpreter.validate_no_phase_worktree!/2 |
| `PRD-2026-7b4a3944-go-elixir-cqrs-parity-gaps.md` | `SUPERSEDED` | a point-in-time gap audit (28 absent modules) whose gaps are closed; its TRD is the implementation record |
| `PRD-2026-019-jido-behaviortree-phase-sequencing.md` | `SUPERSEDED` | zero matches for BehaviorTree/jido_behaviortree in all source; phase sequencing done by workflow/step_sequencer.ex; never implemented |
