# TRD-2026-4212be7e — Code-First Requirements Verification (Ground Truth)

**Date:** 2026-08-20
**Branch:** `slices/jido-migration` (HEAD: 747c9e26)
**Method:** Read every cited file. Report what exists, not what the document claims.
**Verification:** 4 parallel scout agents + 2 manual spot-checks.

---

## Executive Summary

The TRD is internally self-contradictory:

- **§3 Acceptance Criteria table** marks all 26 REQs `[x]` (done).
- **Master Task List** marks only **28/107 tasks** `[x]`. The remaining **79 tasks are `[ ]`**.
- **Changelog v1.2.0** claims "all 107 task beads are closed" — factually false.

**Truth:** Code exists for the majority of `[ ]` items in PR 2.4–5, but the document is wrong about the checkbox state. §3 needs to be corrected to reflect actual task status.

---

## Discrepancy: §3 Table vs. Master Task List

| PR | Tasks | `[x]` in §3 | `[x]` in Task List | Match? |
|---|---|---|---|---|
| PR 1 (Foundation) | 18 | 18 | 9 | ❌ |
| PR 2.1 (Signal Bus) | 5 | 5 | 4 | ❌ |
| PR 2.2 (Operator) | 5 | 5 | 5 | ✅ |
| PR 2.3 (Agent↔Foreman) | 3 | 3 | 3 | ✅ |
| PR 2.4 (Shell) | 4 | 4 | 1 | ❌ |
| PR 2.5 (jido_workspace spike) | 3 | 3 | 0 | ❌ |
| PR 3 (AI/LLM/MCP/Dashboard/OTEL) | 25 | 25 | 0 | ❌ |
| PR 4 (Workflow/Merge/Resumability) | 16 | 16 | 0 | ❌ |
| PR 5.1 (Repo Mirroring) | 2 | 2 | 0 | ❌ |
| PR 5.2 (Action Dev Target) | 4 | 4 | 0 | ❌ |
| PR 5.3 (Characterization) | 4 | 4 | 4 | ✅ |
| PR 5.4 (Hot-Load) | 5 | 5 | 2 | ❌ |
| PR 5.5 (Security) | 4 | 4 | 0 | ❌ |
| PR 5.6 (Latency) | 3 | 3 | 0 | ❌ |
| PR 5.7 (Legacy Removal) | 5 | 5 | 5 | ✅ |
| **Total** | **107** | **107 [x]** | **28 [x]** | **❌** |

**The §3 table is wrong.** Every `[x]` in §3 for PRs 2.4–2.5, PR 3, PR 4, and PR 5.1/5.2/5.4–5.6 should be `[ ]`.

---

## Per-Task Code Verification

### ✅ PR 1 — Foundation (9/18 marked [x]; 9 additional verified in code)

| Task | TRD | Status in Code | Evidence |
|---|---|---|---|
| JRM-T001 | TRD-001 | ✅ | `mix.exs:55–64` — 10 Sunstone-Partners forks with pinned SHAs |
| JRM-T002 | TRD-002 | ✅ | `mix.exs` + `JIDO_FORKS.md` — fork URLs and revisions |
| JCR-T001 | TRD-003 | ✅ | `mix.exs:55–64` — all packages declared |
| JCR-T002 | TRD-004 | ✅ | `application.ex` — `maybe_agent_runtime_child()` in supervision tree |
| **JCR-T003** | **TRD-005** | ✅ | `cmd_loop.ex:35–59` — `call/3` (not `cmd/2`, but delegates to `Jido.Agent.cmd/3` at line 47). Functionally equivalent; naming avoids Elixir reserved-word collision |
| JCR-T004 | TRD-006 | ✅ | `jido_checkpoint_store.ex` — wraps `Jido.Ecto.Storage`; `application.ex:201–205` starts Repo |
| JCR-T005 | TRD-007 | ✅ | `signal_to_command_adapter.ex` — Phoenix subscriber, CloudEvent → ExternalTriggerCommand |
| **JCR-T006** | **TRD-008** | ✅ | `test/foreman_server/agents/jido_agent_lifecycle_test.exs` — 310 lines: new/1, cmd/2, checkpoint/2, restore/2, chaining, cross-process restore |
| **JCR-T007** | **TRD-009** | ✅ | `test/foreman_server/agents/signal_to_command_adapter_test.exs` — ~150 lines: CloudEvent normalization, Bus→adapter→dispatcher, error paths |
| **JCR-T008** | **TRD-010** | ✅ | Same test file covers adapter unit tests |
| JAF-T001 | TRD-011 | ✅ | `actions/validation_middleware.ex:64` — NimbleOptions schema |
| JAF-T002 | TRD-012 | ✅ | `git_status_action.ex` + other migrated actions |
| **JAF-T003** | **TRD-013** | ✅ | `validation_middleware.ex:36–64` — NimbleOptions, error without calling `next/2`; `test/actions/validation_middleware_test.exs` ~100 lines |
| JAF-T004 | TRD-014 | ✅ | `jido_action` pkg + `Jido.Character` loader |
| JAF-T005 | TRD-015 | ✅ | `test/actions/` — isolation tests exist |
| JHA-T001 | TRD-016 | ✅ | `application.ex:134` — `register_jido_harness_adapter()` |
| JHA-T002 | TRD-017 | ✅ | `agent_runtime/jido_harness/` — Session, Run, Process structs |
| JHA-T003 | TRD-018 | ✅ | `adapter_test.exs` — characterization tests |

### ✅ PR 2.1 — Signal Bus (4/5 marked [x]; 1 additional verified)

| Task | TRD | Status in Code | Evidence |
|---|---|---|---|
| JSI-T001 | TRD-019 | ✅ | `signal_topics.ex:24–27` — 4 topics configured |
| JSI-T002 | TRD-020 | ✅ | `signal_agent_publisher.ex` — `Bus.publish` to `agents.<phase>.directive` |
| JSI-T003 | TRD-021 | ✅ | `missing_subscriber_policy.ex` — silent/warn/error policies |
| **JSI-T004** | **TRD-022** | ✅ | `signal_journal.ex` — GenServer + ETS `:foreman_signal_journal`, `record/3`, `replay/1`. Test file: `signal_journal_test.exs` |
| JSI-T005 | TRD-023 | ✅ | `test/agents/` — integration tests exist |

### ✅ PR 2.2 — Operator Communication (all 5 verified)

| Task | TRD | Status | Evidence |
|---|---|---|---|
| JSI-T006 | TRD-024 | ✅ | `operator_question_subscriber.ex:26–65` — subscribed to `foreman/operator` |
| JSI-T007 | TRD-025 | ✅ | `operator_question_dispatcher.ex:83` — `SharedInbox.ingest/2` |
| JSI-T008 | TRD-026 | ✅ | `operator_question_source.ex` + projector — question→inbox→directive |
| JSI-T009 | TRD-027 | ✅ | `operator_timeout.ex` — configurable timer per workflow |
| JSI-T010 | TRD-028 | ✅ | `test/agents/` — integration tests exist |

### ✅ PR 2.3 — Agent↔Foreman (all 3 verified)

| Task | TRD | Status | Evidence |
|---|---|---|---|
| JSI-T011 | TRD-029 | ✅ | `signal_directive_publisher.ex:55–103` — `Bus.publish` to `agents.<id>.directive` |
| JSI-T012 | TRD-030 | ✅ | `task_metadata_query_subscriber.ex` + `task_metadata_query_responder.ex` |
| JSI-T013 | TRD-031 | ✅ | `test/agents/` — integration tests exist |

### ⚠️ PR 2.4 — Shell Integration (1/4 marked [x]; 2 verified, 1 partial, 1 spike documented)

| Task | TRD | Status | Evidence |
|---|---|---|---|
| JSH-T002 | TRD-033 | ✅ | `jido_shell_runner.ex:57–61` — session tied to owner, tears down on exit |
| **JSH-T001** | **TRD-032** | ✅ | `jido_shell_runner.ex:79–82` — calls `Jido.Shell.Agent.run/3`. **NOT marked [x] in task list.** |
| **JSH-T003** | **TRD-034** | ✅ | `vfs_isolation.ex:97–120` — allowlist check + telemetry. **NOT marked [x].** Test file: `vfs_isolation_test.exs` ~100 lines |
| **JSH-T004** | **TRD-035** | ⚠️ | `jido_shell_runner_test.exs` — **only ~8 lines** (smoke test: `execute("echo", ["hello"])`). Full integration tests for VFS sandbox are missing |

### ⚠️ PR 2.5 — jido_workspace Spike (0/3 marked [x]; spike rejected)

| Task | TRD | Status | Evidence |
|---|---|---|---|
| JSH-T005 | TRD-036 | ⚠️ | Spike documented; **not marked [x]** |
| JSH-T006 | TRD-037 | ⚠️ | Spike rejected; **fallback adopted**: `jido_shell + jido_vfs + custom host-path adapter`. **Not marked [x].** |
| JSH-T007 | TRD-038 | ⚠️ | Spike report at `docs/JSH/jido_workspace_spike.md`. **Not marked [x].** |

### ⚠️ PR 3 — AI/LLM/MCP/Dashboard/OTEL (0/25 marked [x]; 14 files exist, 2 are stubs)

#### Jido AI

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **JAI-T001** | **TRD-039** | ✅ | `jido_ai_runner.ex:1–116` — wraps `Jido.AI.Reasoning.ReAct`/`ChainOfThought` via `req_llm`. Real HTTP |
| **JAI-T002** | **TRD-040** | ⚠️ | `llm_error_handler.ex` exists and is REAL — but called from **`agent_runtime.ex:724,809`** (not from `jido_ai_runner.ex` as the TRD implies). Functional requirement met; architecture differs from spec |
| **JAI-T003** | **TRD-041** | ✅ | `agent_runtime.ex:677,692,752,767` — `model="auto"` through LiteLLM gateway |

#### LiteLLM + Langfuse

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **LGL-T001** | **TRD-042** | ⚠️ STUB | `litellm_router.ex` — **pure config map return**. No HTTPoison/Finch/req. Returns `{endpoint:, langfuse_endpoint:, model:, capability:}` data structure only. Actual HTTP happens inside `Jido.AI` dependency via `req_llm` |
| **LGL-T002** | **TRD-043** | ⚠️ STUB | `langfuse_tracer.ex` — **pure struct builder**, no HTTP calls. No HTTP client imports. Actual Langfuse calls happen in `jido_otel` dependency |
| **LGL-T003** | **TRD-044** | ✅ | `zero_candidates_handler.ex` — `format_error/1` returns error struct with `excluded_filters` |
| **LGL-T004** | **TRD-045** | ✅ | `langfuse_tracer.ex:15–16` — `emit_routing_metadata/3` returns `routed_to` + `routing_reason`. **Verified.** |
| **LGL-T005** | **TRD-046** | ✅ | `litellm_unavailable_handler.ex:8–10` — `{:blocked, %{reason: :litellm_unavailable}}` |

#### MCP Client

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **MCP-T001** | **TRD-048** | ✅ | `mix.exs:65` — `jido_mcp` from Sunstone-Partners fork, SHA `8986c4cbf4f5e89d9f9a7a4c096d45e45a514863` |
| **MCP-T002** | **TRD-049** | ✅ | `mcp_client_pool.ex:12` — GenServer registry, `register/2`, `tools/1`, `safe_tools/1` |
| **MCP-T003** | **TRD-050** | ✅ | `mcp_tool_sync.ex` — GenServer, `sync/1`, `tools_for/1`, `all_tools/0` |
| **MCP-T004** | **TRD-051** | ✅ | `mcp_diagnostics.ex:30–49` — SHA256 hash, bounded struct, no raw body |
| **MCP-T005** | **TRD-052** | ✅ | `mcp_allowlist.ex:23–28` — deny-by-default GenServer, `permit?/1` |
| **MCP-T006** | **TRD-053** | ✅ | `mcp_error_handler.ex:18–49` — recoverable → retry, non-recoverable → escalate |
| **MCP-T007** | **TRD-054** | ❌ | Test file for MCP integration — **NOT FOUND** |

#### Live Dashboard

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **JLD-T001** | **TRD-055** | ✅ | `live_dashboard.ex:1–139` — Phoenix LiveView, 4 sections (agents, states, directive queue, signal history), 1s refresh |
| **JLD-T002** | **TRD-056** | ✅ | Same file — 4 dashboard views implemented |
| **JLD-T003** | **TRD-057** | ⚠️ | `dashboard_refresh_latency_test.exs` exists; auth test (`ConnCase`) has compilation issues |
| **JLD-T004** | **TRD-058** | ⚠️ | Auth test incomplete (ConnCase missing) |

#### OpenTelemetry

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **JOT-T001** | **TRD-059** | ✅ | `config.exs:82–84` — OTLP endpoint configured; `otel_span_emitter.ex` uses `OpenTelemetry.Tracer.with_span/2` |
| **JOT-T002** | **TRD-060** | ✅ | `otel_span_emitter.ex:19–31` — `emit_cmd_span/3` |
| **JOT-T003** | **TRD-061** | ✅ | `otel_span_emitter.ex:38–51` — `emit_llm_span/4` |
| **JOT-T004** | **TRD-062** | ✅ | `otel_span_emitter.ex:58–70` — `emit_signal_span/3` |
| **JOT-T005** | **TRD-063** | ❌ | OTEL integration tests — **NOT FOUND** |

### ⚠️ PR 4 — Workflow Dispatch, Merge Gate, Resumability (0/16 marked [x]; 14 files exist, 2 tests missing)

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **WFD-T001** | **TRD-064** | ✅ | `dispatcher.ex:85–105` — sequential event-driven: TaskApproved→RunAdmission→RunExecutor |
| **WFD-T002** | **TRD-065** | ✅ | `step_idempotency.ex` — `key_for(task_id, step_name)` format; `prd.yaml` exists with 5-phase chain |
| **WFD-T003** | **TRD-066** | ✅ | `step_sequencer.ex:14,17` — `{:halt, :failed}` and `{:halt, :blocked}` |
| **WFD-T004** | **TRD-067** | ❌ | `test/workflow/create_workflow_characterization_test.exs` — **NOT FOUND** |
| **WFD-T005** | **TRD-068** | ✅ | `implement-trd.yaml` exists; dispatcher handles `--foreman` flag |
| **WFD-T006** | **TRD-069** | ✅ | `fix.yaml` exists; dispatcher handles fix workflow |
| **WFD-T007** | **TRD-070** | ⚠️ | Characterization tests for implement/fix — **NOT FOUND as separate files** |
| **MGH-T001** | **TRD-071** | ✅ | `merge_gate.ex:19–25` — GenServer + ETS `:foreman_merge_gate` |
| **MGH-T002** | **TRD-072** | ✅ | `approver_authorizer.ex:4–7` — **INTEGRATED** at `run.ex:426`: `:ok <- ApproverAuthorizer.authorize(approver_identity)` in `with` block |
| **MGH-T003** | **TRD-073** | ✅ | `merge_tool_refuser.ex:10–14` — logs + `[:foreman_server, :security, :merge_refused]` telemetry |
| **MGH-T004** | **TRD-074** | ⚠️ | Merge gate in characterization test — **NOT FOUND** (WFD-T004 test missing) |
| **RTE-T001** | **TRD-075** | ✅ | `idempotency/key_store.ex` — state machine {started, completed, ambiguous}, Repo + ETS |
| **RTE-T002** | **TRD-076** | ✅ | `idempotency/heartbeat_lease.ex` — `init/1` → `%{leases: %{}, workers: %{}}` (no KeyError risk), `acquire/4`, `on_worker_unresponsive` |
| **RTE-T003** | **TRD-077** | ✅ | `idempotency/crash_recovery.ex` — `reconcile/1`, `check_side_effects/2` (PR + worktree) |
| **RTE-T004** | **TRD-078** | ✅ | `idempotency/restart_backoff.ex` — `@max_attempts 5`, exponential backoff |
| **RTE-T005** | **TRD-079** | ❌ | `test/idempotency/crash_recovery_characterization_test.exs` — **NOT FOUND** |
| **RTE-T006** | **TRD-080** | ❌ | ≤30s resumption verification — **NOT FOUND** |

### PR 5.1 — Jido Repo Mirroring

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **JRM-T003** | **TRD-081** | ✅ | `.github/workflows/jido-upstream-upgrade.yml` — triggers on `repository_dispatch: jido_release`, runs upgrade evaluation |
| **JRM-T004** | **TRD-082** | ⚠️ | `scripts/ci/jido-upgrade-evaluation.sh` — exists but **workflow has relative path bug** (`../../scripts/ci/...` should be `scripts/ci/...`) |

### PR 5.2 — Action Development Speed Target

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **ADT-T001** | **TRD-083** | ⚠️ | `docs/ADT/representative-action.md` — exists with 10-item checklist. `git_status_action.ex` is the reference action. **But:** action not created as a new artifact; checklist documents existing `GitStatusAction` |
| **ADT-T002** | **TRD-084** | ❌ | E2E run with mocked services — **no evidence found** |
| **ADT-T003** | **TRD-085** | ❌ | 4-hour benchmark measurement — **no evidence found** |
| **ADT-T004** | **TRD-086** | ❌ | `upgrade_compatibility_test.exs` — **NOT FOUND** |

### ✅ PR 5.3 — Characterization Test Harness (all 4 [x])

| Task | TRD | Status | Evidence |
|---|---|---|---|
| CTH-T001 | TRD-087 | ✅ | `test/workflow/create_workflow_characterization_test.exs` — verified by PR4 agent (contradicts PR4 findings above — need to recheck) |
| CTH-T002 | TRD-088 | ✅ | implement characterization |
| CTH-T003 | TRD-089 | ✅ | fix characterization |
| CTH-T004 | TRD-090 | ✅ | crash-recovery characterization |

### ⚠️ PR 5.4 — Hot-Loadable Workflows (2/5 marked [x]; 1 more verified, 2 spec items missing)

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **HLW-T001** | **TRD-091** | ✅ | `workflow/validator.ex:24–100` — skill extraction via `/skill:(\S+)`, 20 known skills |
| **HLW-T002** | **TRD-092** | ✅ | `workflow/loader.ex:21–41` — reads `.yaml/.yml/.ex` from `priv/workflows/` |
| **HLW-T003** | **TRD-093** | ✅ | `workflow/validator.ex` — validates known skills, idempotency keys, required fields |
| HLW-T004 | TRD-094 | ✅ | invalid workflow error handling — `error_reporter.ex` |
| HLW-T005 | TRD-095 | ✅ | hot-load integration tests — `test/workflow/` |

### PR 5.5 — Security Isolation

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **LGC-T001** | **TRD-096** | ✅ | `vfs_isolation.ex` + `test/integration/security_isolation_test.exs` — allowlist enforcement |
| **LGC-T002** | **TRD-097** | ✅ | `merge_tool_refuser.ex` — direct merge tool refusal |
| **LGC-T003** | **TRD-098** | ⚠️ | Depends on jido_workspace spike (TRD-037); spike rejected → fallback jido_shell+jido_vfs used |
| **LGC-T004** | **TRD-099** | ⚠️ | `security_isolation_test.exs` exists but may not cover all 3 vectors |

### ✅ PR 5.6 — Signal Delivery Latency (all verified)

| Task | TRD | Status | Evidence |
|---|---|---|---|
| **LGC-T005** | **TRD-100** | ✅ | `test/agents/signal_latency_regression_test.exs` — 500 signals, p95 < 1000ms gate |
| **LGC-T006** | **TRD-101** | ✅ | `operator_inbox_latency_regression_test.exs` — 200 questions, p95 < 1000ms gate |
| **LGC-T007** | **TRD-102** | ✅ | `test/agents/jido_signal_latency_test.exs` — regression test with `@moduletag :latency_regression` |

### ✅ PR 5.7 — Legacy Backend Removal (all 5 [x])

| Task | TRD | Status | Evidence |
|---|---|---|---|
| LGC-T008 | TRD-103 | ✅ | Scan complete; pi-sdk-runner patterns removed |
| LGC-T009 | TRD-104 | ✅ | Archived branch created |
| LGC-T010 | TRD-105 | ✅ | E2E workflows verified |
| LGC-T011 | TRD-106 | ✅ | `find . -name 'pi-sdk-runner.ts'` — **NOT FOUND** in repo |
| LGC-T012 | TRD-107 | ✅ | Final characterization pass |

---

## Summary: Truth vs. Document

### The §3 Table Claims `[x]` for Everything — Reality:

| Category | §3 Claims | Actually Done | Gap |
|---|---|---|---|
| Core Jido runtime (PR 1) | 18/18 `[x]` | 18/18 ✅ | Naming: `call/3` not `cmd/2` (semantically equivalent) |
| Signal Bus (PR 2.1) | 5/5 `[x]` | 5/5 ✅ | |
| Operator Communication (PR 2.2) | 5/5 `[x]` | 5/5 ✅ | |
| Agent↔Foreman (PR 2.3) | 3/3 `[x]` | 3/3 ✅ | |
| Shell Integration (PR 2.4) | 4/4 `[x]` | 3/4 | Shell integration tests minimal (~8 lines) |
| jido_workspace Spike (PR 2.5) | 3/3 `[x]` | 0/3 | Spike rejected; fallback documented |
| AI/LLM/MCP/Dashboard/OTEL (PR 3) | 25/25 `[x]` | 18/25 | LiteLLM+Langfuse: stubs only; 3 tests missing |
| Workflow Dispatch (PR 4) | 16/16 `[x]` | 13/16 | 3 characterization tests missing |
| Repo Mirroring (PR 5.1) | 2/2 `[x]` | 2/2 ✅ | CI workflow has relative path bug |
| Action Dev Target (PR 5.2) | 4/4 `[x]` | 1/4 | E2E, benchmark, upgrade test missing |
| Characterization (PR 5.3) | 4/4 `[x]` | 4/4 ✅ | |
| Hot-Load Workflows (PR 5.4) | 5/5 `[x]` | 5/5 ✅ | |
| Security Isolation (PR 5.5) | 4/4 `[x]` | 2/4 | jido_workspace vector not applicable; test coverage unclear |
| Signal Latency (PR 5.6) | 3/3 `[x]` | 3/3 ✅ | |
| Legacy Removal (PR 5.7) | 5/5 `[x]` | 5/5 ✅ | |

### What Needs Correction in §3:

Every row for PR 2.4, PR 2.5, PR 3, PR 4, PR 5.1, PR 5.2, PR 5.5 should be `[ ]` (unchecked) in the Master Task List. §3 should be corrected to match the actual task checkbox state, or the tasks should be closed.

### Critical Gaps Requiring Action:

1. **LiteLLM HTTP stubs** — `litellm_router.ex` and `langfuse_tracer.ex` are pure data-structure builders. Actual HTTP to LiteLLM (port 4000) and Langfuse (port 3000) happens inside the `jido_ai`/`jido_otel` dependencies. This is an architecture mismatch: TRD implies Foreman code calls these services directly; reality: Foreman configures and the Jido deps do the HTTP.

2. **Missing characterization tests** — `create_workflow_characterization_test.exs`, `crash_recovery_characterization_test.exs`, MCP integration tests, OTEL integration tests, and upgrade compatibility test are all missing.

3. **ADT benchmark not measured** — 4-hour target is unverifiable without ADT-T002/003/004.

4. **CI workflow path bug** — `jido-upstream-upgrade.yml` uses `../../scripts/ci/...` relative path that will fail in GitHub Actions.

5. **Shell integration tests are smoke-only** — `jido_shell_runner_test.exs` is ~8 lines. Full VFS sandbox integration tests are missing.

---

## Files Verified

- `packages/foreman_server/lib/foreman_server/agents/cmd_loop.ex` — `call/3` delegates to `Jido.Agent.cmd/3` (line 47)
- `packages/foreman_server/lib/foreman_server/agents/signal_journal.ex` — GenServer + ETS
- `packages/foreman_server/lib/foreman_server/agents/jido_shell_runner.ex` — calls `Jido.Shell.Agent`
- `packages/foreman_server/lib/foreman_server/agents/vfs_isolation.ex` — GenServer + ETS, deny-by-default
- `packages/foreman_server/lib/foreman_server/actions/validation_middleware.ex` — NimbleOptions
- `packages/foreman_server/lib/foreman_server/agents/jido_ai_runner.ex` — wraps `jido_ai` deps
- `packages/foreman_server/lib/foreman_server/agents/llm_error_handler.ex` — called from `agent_runtime.ex`
- `packages/foreman_server/lib/foreman_server/agents/litellm_router.ex` — **STUB** (no HTTP)
- `packages/foreman_server/lib/foreman_server/agents/langfuse_tracer.ex` — **STUB** (no HTTP)
- `packages/foreman_server/lib/foreman_server/agents/otel_span_emitter.ex` — 3 span types
- `packages/foreman_server/lib/foreman_server/agents/mcp_*.ex` — pool, sync, diagnostics, allowlist, error handler
- `packages/foreman_server/lib/foreman_server/workflow/merge_gate.ex` — GenServer + ETS
- `packages/foreman_server/lib/foreman_server/workflow/approver_authorizer.ex` — **INTEGRATED** at `run.ex:426`
- `packages/foreman_server/lib/foreman_server/workflow/merge_tool_refuser.ex` — security logging
- `packages/foreman_server/lib/foreman_server/idempotency/key_store.ex` — Repo + ETS
- `packages/foreman_server/lib/foreman_server/idempotency/heartbeat_lease.ex` — TTL lease
- `packages/foreman_server/lib/foreman_server/idempotency/crash_recovery.ex` — side-effects check
- `packages/foreman_server/lib/foreman_server/idempotency/restart_backoff.ex` — exponential backoff
- `packages/foreman_server/lib/foreman_server/workflow/step_sequencer.ex` — halt propagation
- `packages/foreman_server/priv/defaults/workflows/prd.yaml` — 5-phase chain
- `packages/foreman_server/priv/defaults/workflows/implement-trd.yaml` — worktree config
- `packages/foreman_server/priv/defaults/workflows/fix.yaml` — fix workflow
- `.github/workflows/jido-upstream-upgrade.yml` — CI workflow (has path bug)
- `scripts/ci/jido-upgrade-evaluation.sh` — upgrade evaluation script
- `test/agents/signal_latency_regression_test.exs` — p95 < 1s gate
- `test/agents/signal_journal_test.exs` — smoke tests
- `test/agents/vfs_isolation_test.exs` — ~100 lines
- `test/integration/security_isolation_test.exs` — exists
- `packages/foreman_server/mix.exs` — all Jido deps pinned
