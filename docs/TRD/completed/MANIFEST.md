# Completed documents

Moved here on 2026-08-30. Placement was decided by **reading the code**, not by
each document's `status:` frontmatter — that field is unreliable in this repo:
nearly every document in `docs/` still said `Draft`, including the durable run
log store that shipped as PR #422 and projects-crud whose TRD was already
sitting in this folder.

Four dispositions land a document here:

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
| `TRD-2026-08ab9445-smoke-plan-workflow-phase-retry.md` | `HISTORICAL_RECORD` | smoke-run artifact paired with its PRD |
| `TRD-2026-4212be7e-jido-migration-CODE-VERIFICATION-FINAL.md` | `HISTORICAL_RECORD` | point-in-time code audit of the jido migration |
| `TRD-2026-4212be7e-jido-migration-CODE-VERIFICATION.md` | `HISTORICAL_RECORD` | point-in-time code audit of the jido migration |
| `TRD-2026-4212be7e-jido-migration-VERIFICATION-REBUILD.md` | `HISTORICAL_RECORD` | point-in-time audit of the jido migration |
| `TRD-2026-4212be7e-jido-migration-VERIFICATION.md` | `HISTORICAL_RECORD` | point-in-time audit of the jido migration |
| `TRD-2026-4212be7e-jido-migration-VERIFIED.md` | `HISTORICAL_RECORD` | point-in-time audit of the jido migration |
| `TRD-2026-6b79b694-smoke-run-after-br-close-array-unwrap-fix.md` | `HISTORICAL_RECORD` | smoke-run artifact paired with its PRD |
| `TRD-2026-8066e22d-smoke-run-after-closed-issue-schema-fix.md` | `HISTORICAL_RECORD` | smoke-run artifact paired with its PRD |
| `TRD-2026-b86c4907-smoke-run-with-plan-workflow-task-type.md` | `HISTORICAL_RECORD` | smoke-run artifact paired with its PRD |
| `TRD-2026-c7004f12-smoke-plan-workflow-v5-seqfix.md` | `HISTORICAL_RECORD` | smoke-run artifact paired with its PRD |
| `verify-batch-1.md` | `HISTORICAL_RECORD` | verification sweep, not a spec |
| `verify-batch-2.md` | `HISTORICAL_RECORD` | verification sweep, not a spec |
| `verify-batch-3.md` | `HISTORICAL_RECORD` | verification sweep, not a spec |
| `verify-batch-4.md` | `HISTORICAL_RECORD` | verification sweep, not a spec |
| `TRD-2026-4212be7e-jido-migration.md` | `IMPLEMENTED` | paired with its PRD; all migration tasks traced to agent_runtime + signals + MCP |
| `TRD-2026-48f7b420-foreman-beads-task-provider.md` | `IMPLEMENTED` | JsonSchemaCache, SystemBrRunner, ConcurrencyLimiter, BootReconciliation, doctor integration all present |
| `TRD-2026-54236004-workflow-simplification.md` | `IMPLEMENTED` | TRD-001..008 + TRD-017 traced; commit_phase_worktree at run_executor.ex |
| `TRD-2026-6af02293-otp-agent-runtime.md` | `IMPLEMENTED` | AdapterCatalog/Router/FailurePolicy/BackendAdapter/Invocation match the design |
| `TRD-2026-7b4a3944-go-elixir-cqrs-parity-gaps.md` | `IMPLEMENTED` | TRD-001..011 traced: SharedInbox, ProjectRegistry, ProjectSupervisor, ProjectStore, Project/Phase/Run aggregates, BoardItemStateMachine, Overwatch |
| `TRD-2026-81315f37-atomic-beads-task-create-and-watcher.md` | `IMPLEMENTED` | PR1-3 all present incl. compensation path + in-flight cache + Registry.project_config/1 |
| `TRD-2026-8a1f3c2e-jido-harness-integration.md` | `IMPLEMENTED` | JidoHarnessAdapter + Driver/Session/DetachedRun/ReadinessCheck |
| `TRD-2026-96872fc5-go-elixir-cqrs-parity.md` | `IMPLEMENTED` | the two items the scout could not confirm are present: event_store_enforcement_test.exs is the TRD-007 architecture test, and EventCodec's registry is auto-derived via @external_resource + __mix_recompile__?/0 (event_codec.ex:49,55) |
| `TRD-2026-cd07a086-durable-run-log-store.md` | `IMPLEMENTED` | shipped as PR #422 / b1c3a920; 15/15 REQs |
| `TRD-2026-3d41f677-add-full-vcs-worktree-support-configured-via-wor.md` | `SUPERSEDED` | Decision 1 chose phase-level and explicitly rejected workflow-level; beb7dea6 shipped the rejected option. phase_lineage_base_ref/2 and run_executor_phase_lineage_test.exs were deleted |
| `TRD-2026-80ba0665-branch-parent-resolution.md` | `SUPERSEDED` | goal reached WITHOUT its PlanContext/Dispatcher plumbing, via resolve_run_base/2 + remember_run_base_branch/1 reading the registered checkout HEAD; per-phase chaining is now moot by design |
| `TRD-2026-e8d3f5f2-create-a-foreman-mcp-server-covering-all-existin.md` | `SUPERSEDED` | superseded by TRD-2026-0eac69b3; shipped MCP uses named tools, not the Bucket A/B/C generic dispatch model |

`TRD-2026-002184c6-projects-crud.md` predates this sweep and was already here;
its PRD counterpart joined it in `docs/PRD/completed/`.

`VERIFICATION/` holds two point-in-time jido-migration audits, moved wholesale.
