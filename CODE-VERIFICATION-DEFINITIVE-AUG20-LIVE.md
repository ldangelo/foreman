# Code Verification: TRD-2026-4212be7e — Code-First (Definitive Live)

**Date:** 2026-08-20
**Branch:** `slices/jido-migration` (HEAD: `a6e1b52b` + `1dec338`)
**Method:** Requirements verified against actual source files in `packages/foreman_server/`

---

## Executive Summary

**§3 of the TRD claims all 26 REQs are `[x]` (complete). This is FALSE.**

| REQ | §3 | Code Reality | Severity |
|-----|----|--------------|----------|
| REQ-009 | [x] | LGL-T001–T006 ALL `[ ]` in §1; `LitellmRouter`, `LangfuseTracer` have **ZERO production call sites** | 🔴 CRITICAL |
| REQ-010 | [x] | MCP-T001–T007 ALL `[ ]` in §1; `McpClientPool.safe_tools/1` is stub returning `[]` | 🔴 CRITICAL |
| REQ-019 | [x] | ADT-T001–T004 ALL `[ ]` in §1; no benchmark action found | 🔴 CRITICAL |
| REQ-020 | [x] | LGL-T004 `[ ]` in §1; `LangfuseTracer` ZERO call sites | 🔴 CRITICAL |
| REQ-007 | [x] | JSH-T001, T003, T004 `[ ]` in §1; VFS is **real enforcement** | 🟡 HIGH |
| REQ-008 | [x] | JAI-T001–T003 `[ ]` in §1; `JidoAiRunner` degrades to placeholder | 🟡 HIGH |
| REQ-011 | [x] | JLD-T001–T004 `[ ]` in §1; dashboard exists, latency NOT measured | 🟡 HIGH |
| REQ-012 | [x] | JOT-T001–T005 `[ ]` in §1; spans via OpenTelemetry, not `LangfuseTracer` | 🟡 HIGH |
| REQ-021 | [x] | LGC-T001–T004 `[ ]` in §1; VFS is **real enforcement** | 🟡 HIGH |
| REQ-023 | [x] | LGC-T005–T007 `[ ]` in §1; latency tests exist, not run | 🟡 HIGH |
| REQ-025 | [x] | HLW-T001–T003 `[ ]` in §1; loader exists | 🟡 HIGH |

---

## ⚠️ Correction to Prior Report

The prior version of this report claimed `VfsIsolation.allowed?/2` was a stub returning `true` always. **This was FALSE.** Direct read of `vfs_isolation.ex:107-133` confirms real path-prefix enforcement with security telemetry. This correction retracts the false stub claim for REQ-007 and REQ-021.

---

## Verified COMPLETE in Code ✅

### ✅ REQ-001: Jido Core Runtime

| Evidence | File | Verification |
|----------|------|--------------|
| 10 Jido packages forked+pinned | `mix.exs:55-65` | Confirmed — all Sunstone-Partners forks |
| SignalToCommandAdapter | `agents/signal_to_command_adapter.ex` | Confirmed, wired `application.ex:269` |
| jido_ecto integration | `application.ex:201-207` | Confirmed (`JidoCheckpointStore.Repo`) |
| OTEL spans | `agents/otel_span_emitter.ex` | Confirmed — `agent_runtime.ex`, `cmd_loop.ex` call it |

**Status: ✅ COMPLETE**

---

### ✅ REQ-002: Jido Action Authoring Framework

| Evidence | File | Verification |
|----------|------|--------------|
| Jido.Action behaviour | `actions/git_status_action.ex` | Confirmed |
| validation middleware | `actions/validation_middleware.ex` | Confirmed |
| Character loader | `Catalog.read_prompt/1` | Confirmed |
| Isolation tests | `test/foreman_server/actions/*_test.exs` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-003: Jido Harness Pi Adapter

| Evidence | File | Verification |
|----------|------|--------------|
| jido_harness adapter | `jido_harness_adapter.ex` | Confirmed |
| Session/Run/Process | `jido_harness/*.ex` (5 modules) | Confirmed |
| Config default | `config/config.exs:29` | Confirmed → `JidoHarnessAdapter` |

**Status: ✅ COMPLETE**

---

### ✅ REQ-004: Inter-Agent Communication (Agent↔Agent)

| Evidence | File | Verification |
|----------|------|--------------|
| 4 topics | `agents/jido_signal_topics.ex` | Confirmed — `foreman_command`, `foreman_operator`, `foreman_inbox`, `agents.*.directive` |
| Pub/sub | `Bus.publish` in signal modules | Confirmed |
| Missing-subscriber policy | configurable silent/warn/error | Confirmed |
| SignalJournal | `agents/signal_journal.ex` | Confirmed — ETS-backed journal, `replay/1`, wired `application.ex:241` |
| SignalLatency regression tests | `test/foreman_server/agents/signal_latency_regression_test.exs` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-005: Agent↔Operator Communication

| Evidence | File | Verification |
|----------|------|--------------|
| Operator topic subscriber | `agents/operator_question_subscriber.ex` | Confirmed, wired `application.ex:332` |
| Directive projector | `agents/operator_directive_projector.ex` | Confirmed |
| Per-workflow timeout | `agents/operator_timeout.ex` | Confirmed |
| Integration tests | `test/integration/operator_question_integration_test.exs` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-006: Agent↔Foreman Communication

| Evidence | File | Verification |
|----------|------|--------------|
| Directive publisher | `agents/signal_directive_publisher.ex` | Confirmed |
| Task metadata query | `agents/task_metadata_query_subscriber.ex` | Confirmed |
| Integration tests | `test/integration/signal_nudge_query_integration_test.exs` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-007: Jido Shell Integration

| Evidence | File | Verification |
|----------|------|--------------|
| jido_shell integration | `agents/jido_shell_runner.ex` | Confirmed — `start_session/2`, `stop_session/1`, `run_command/3` |
| Shell session lifecycle | Process.monitor/:DOWN in `jido_shell_runner.ex:129` | Confirmed — owner exit tears down session |
| VFS isolation per worktree | `agents/vfs_isolation.ex:107-133` | **REAL enforcement** — path-prefix check + security telemetry |
| VFS allowlist | `vfs_isolation.ex:58-73` | Confirmed — `allowlist_check/1` with `enforce_allowlist` config |
| VFS integration test | `test/integration/security_isolation_test.exs` | Confirmed — denies out-of-worktree access |

**Note:** JSH-T001 (jido_shell+VFS integration), JSH-T003 (VFS per-worktree), JSH-T004 (integration tests) are `[ ]` in §1. Code evidence shows implementation exists. The §3 claim `[x]` is **potentially correct** but §1 shows `[ ]`.

**Status: ✅ VERIFIED IN CODE** — VFS is NOT a stub.

---

### 🟡 REQ-008: Jido AI Strategy Integration

| Evidence | File | Verification |
|----------|------|--------------|
| jido_ai runner | `agents/jido_ai_runner.ex` | Confirmed — calls `Jido.AI.Reasoning.ReAct` and `ChainOfThought` |
| req_llm routing | `agent_runtime.ex:423` | Confirmed — `"auto"` → LiteLLM endpoint |
| Error handling | `agents/llm_error_handler.ex` | Confirmed — timeout/error → retry/escalate directive |
| Degrades to placeholder | `jido_ai_runner.ex:76-80` | Confirmed — `Code.ensure_loaded?` check, returns `status: :degraded` |

**Status: 🟡 INFRASTRUCTURE PRESENT** — functional when packages loaded, degrades gracefully otherwise. JAI-T001–T003 `[ ]` in §1.

---

### ❌ REQ-009: LiteLLM+Langfuse Integration — DEAD CODE

**§3: `[x]` COMPLETE. §1: LGL-T001–T006 ALL `[ ]`.**

Functional routing WORKS via `config.exs` model_aliases (`"auto"` → LiteLLM port 4000).

Structural requirements NOT met:

| Module | Defined | Production Call Sites |
|--------|---------|----------------------|
| `LitellmRouter.route/2` | ✅ `litellm_router.ex` | **0** |
| `LangfuseTracer.emit_trace/6` | ✅ `langfuse_tracer.ex` | **0** |
| `ZeroCandidatesHandler.format_error/1` | ✅ `zero_candidates_handler.ex` | **0** |
| `LitellmUnavailableHandler.handle/1` | ✅ `litellm_unavailable_handler.ex` | 1 test only |

**Verified:**
```bash
grep -rn "LitellmRouter\." lib/ --include="*.ex" | grep -v "_test.exs"
# → 0 results (only module definition)

grep -rn "LangfuseTracer\." lib/ --include="*.ex" | grep -v "_test.exs"
# → 0 results (only module definition)
```

**Actual tracing:** `OtelSpanEmitter.emit_llm_span/4` via `OpenTelemetry.Tracer` — NOT the Langfuse-specific API.

**Status: ❌ INCOMPLETE** — LGL-T001–T006 ALL `[ ]` in §1. Prescriptive API is dead code.

---

### ❌ REQ-010: Jido MCP Client Integration — STUB

**§3: `[x]` COMPLETE. §1: MCP-T001–T007 ALL `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| MCP client pool | `agents/mcp_client_pool.ex` | Defined — GenServer with client registry |
| MCP tool sync | `agents/mcp_tool_sync.ex` | Defined — calls `McpClientPool.tools/1` |
| MCP policy/allowlist | `mcp/policy.ex` | Present |
| MCP auth | `mcp/auth.ex` | Present |

**Critical stub:**
```elixir
# mcp_client_pool.ex:30 — ALWAYS returns empty list
defp safe_tools(_client), do: []
```

Tools are NEVER extracted from MCP clients. MCP-T003 (`McpToolSync`) calls `McpClientPool.tools/1` which returns `[]`.

**Status: ❌ INCOMPLETE** — MCP-T001–T007 ALL `[ ]` in §1. Tool extraction is stub-only.

---

### 🟡 REQ-011: Jido Live Dashboard Integration

| Evidence | File | Verification |
|----------|------|--------------|
| 4-view layout | `live_dashboard.ex` | Confirmed — active agents, current state, directive queue, signal history |
| Auto-refresh | `schedule_refresh/1` (1s interval) | Confirmed |
| Auth deferred | Comment in `live_dashboard.ex` | Confirmed |
| Dashboard tests | `test/foreman_server_web/live_dashboard_test.exs` | Confirmed |

**Unverified:** JLD-T003 (refresh latency ≤1s measurement), JLD-T004 (integration tests for auth/freshness) — `[ ]` in §1.

**Status: 🟡 INFRASTRUCTURE PRESENT** — JLD-T001–T004 ALL `[ ]` in §1.

---

### 🟡 REQ-012: Jido OpenTelemetry Integration

| Evidence | File | Verification |
|----------|------|--------------|
| OTEL span emitter | `agents/otel_span_emitter.ex` | Confirmed |
| Cmd/2 spans | `cmd_loop.ex:56` | Confirmed |
| LLM spans | `agent_runtime.ex:677,692,752,767` | Confirmed — `emit_llm_span/4` |
| Signal spans | `signal_directive_publisher.ex:99` | Confirmed |
| OTLP endpoint config | `config/config.exs:80` | Langfuse-compatible OTLP endpoint configured |

**Note:** Spans go through `OpenTelemetry.Tracer` → OTLP endpoint → Langfuse. `LangfuseTracer.emit_trace/6` is NOT called. NFR-07 ("LLM trace 100% in Langfuse") technically satisfied via OTLP path, but prescriptive API per LGL-T002/T004 is dead code.

**Status: 🟡 INFRASTRUCTURE PRESENT** — JOT-T001–T005 ALL `[ ]` in §1.

---

### ✅ REQ-013: Workflow Dispatch — create

| Evidence | File | Verification |
|----------|------|--------------|
| Sequential dispatcher | `workflow/dispatcher.ex` | Confirmed |
| Step sequencing | `workflow/step_sequencer.ex` | Confirmed |
| Idempotency keys | `workflow/step_idempotency.ex` | Confirmed |
| StepIdempotency tests | `test/workflow/step_idempotency_test.exs` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-014: Workflow Dispatch — implement

| Evidence | File | Verification |
|----------|------|--------------|
| Implement dispatcher | `workflow/dispatcher.ex` | Confirmed |
| `--foreman` flag | `run_executor.ex` | Confirmed — passes to RunExecutor |
| Characterization tests | `test/workflow/implement_fix_characterization_test.exs:370` | Confirmed — CTH-T002 |

**Status: ✅ COMPLETE**

---

### ✅ REQ-015: Workflow Dispatch — fix

| Evidence | File | Verification |
|----------|------|--------------|
| Fix dispatcher | `workflow/dispatcher.ex` | Confirmed |
| Characterization tests | `test/workflow/implement_fix_characterization_test.exs:641` | Confirmed — CTH-T003 |

**Status: ✅ COMPLETE**

---

### ✅ REQ-016: Merge Gate — Human Review Required

| Evidence | File | Verification |
|----------|------|--------------|
| Approval flow | `workflow/approval.ex` | Confirmed |
| Approver authorization | `workflow/approver_authorizer.ex` | Confirmed |
| Merge tool refusal | `workflow/merge_tool_refuser.ex` | Confirmed |
| MergeGate GenServer | `workflow/merge_gate.ex` | Confirmed — ETS-backed with `request_approval/2`, `approve_by_key/3` |
| Merge gate characterization | `test/workflow/merge_gate_characterization_test.exs` | Confirmed — MGH-T004 |
| PrGate record_pending | `pr_gate.ex` | Confirmed — calls `MergeGate.request_approval` |
| Run aggregate gate | `aggregates/run.ex:544` | Confirmed — `ensure_pr_gate_ok/2` enforces `:approved` before merge |

**Status: ✅ COMPLETE**

---

### ✅ REQ-017: Resumable Task Execution with Idempotent Invocation

| Evidence | File | Verification |
|----------|------|--------------|
| Idempotency key store | `idempotency/key_store.ex` | Confirmed — `mark_started/completed/ambiguous`, dual ETS/Postgres backend |
| Heartbeat lease | `idempotency/heartbeat_lease.ex` | Confirmed — TTL-based with expiry detection, `on_worker_unresponsive/2`, `mark_ambiguous/2` |
| Crash recovery | `idempotency/crash_recovery.ex` | Confirmed — `reconcile/2`, side-effects check (PR/worktree), `has_no_side_effects?/1` |
| 5-restart backoff | `idempotency/restart_backoff.ex` | Confirmed — `should_restart?/1`, `backoff_ms/1` (exponential), `next_attempt/1` |
| KeyStore tests | `test/foreman_server/idempotency/key_store_test.exs` | Confirmed |
| HeartbeatLease tests | `test/foreman_server/idempotency/heartbeat_lease_test.exs` | Confirmed |
| CrashRecovery tests | `test/foreman_server/idempotency/crash_recovery_test.exs` | Confirmed |
| RestartBackoff tests | `test/foreman_server/idempotency/restart_backoff_test.exs` | Confirmed |
| Characterization | `test/foreman_server/idempotency/crash_recovery_characterization_test.exs` | Confirmed — CTH-T004 |

**Status: ✅ COMPLETE**

---

### ✅ REQ-018: Jido Repository Mirroring

| Evidence | File | Verification |
|----------|------|--------------|
| 10 packages forked+pinned | `mix.exs:55-65` | Confirmed — all Sunstone-Partners forks with pinned SHAs |
| CI trigger script | `scripts/trigger-jido-upgrade.sh` | Confirmed — `repository_dispatch` type `jido_release` |

**Status: ✅ COMPLETE**

---

### ❌ REQ-019: Action Development Speed Target

**§3: `[x]` COMPLETE. §1: ADT-T001–T004 ALL `[ ]`.**

No representative benchmark action found in code. ADT-T001–T004 are ALL `[ ]` in §1.

**Status: ❌ NOT IMPLEMENTED**

---

### ❌ REQ-020: LiteLLM Routing Auditability — ZERO CALL SITES

**§3: `[x]` COMPLETE. §1: LGL-T004 `[ ]`.**

`LangfuseTracer` is defined (`agents/langfuse_tracer.ex`) but never called in production:

```bash
grep -rn "LangfuseTracer\." lib/ --include="*.ex" | grep -v "_test.exs"
# → 0 results
```

**NFR-07:** "LLM trace 100% in Langfuse"

**Reality:** OTEL spans via `OpenTelemetry.Tracer` → OTLP endpoint → Langfuse. The prescriptive `LangfuseTracer.emit_trace/6` API is dead code. NFR-07 technically satisfied via OTLP path, but the explicit auditability API (LGL-T004) is not implemented.

**Status: ❌ INCOMPLETE** — LGL-T004 `[ ]` in §1. Prescriptive API dead code.

---

### ✅ REQ-021: Security — Agent Isolation

**§3: `[x]` COMPLETE. §1: LGC-T001–T004 ALL `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| VFS sandbox | `agents/vfs_isolation.ex:107-133` | **REAL enforcement** — path-prefix check + `:security :vfs_denied` telemetry |
| VFS allowlist | `vfs_isolation.ex:58-73` | Confirmed — `allowlist_check/1` with configurable enforcement |
| Approver authorization | `workflow/approver_authorizer.ex` | Confirmed |
| Merge tool refusal | `workflow/merge_tool_refuser.ex` | Confirmed |
| Security integration tests | `test/integration/security_isolation_test.exs` | Confirmed — 3 vectors tested (VFS, approver, merge refusal) |

**Prior report retraction:** The prior version claimed VFS was "stub-only always returns true." This was **FALSE**. `allowed?/2` at lines 107-133 does real path-prefix enforcement with security telemetry.

**Status: ✅ VERIFIED IN CODE** — LGC-T001–T004 `[ ]` in §1 but code evidence shows real implementation with tests.

---

### ✅ REQ-022: Legacy Backend Removal

| Evidence | File | Verification |
|----------|------|--------------|
| pi-sdk-runner.ts absent | `grep -rn "pi-sdk-runner" packages/` | Confirmed — 0 results |
| Archive branch | `archived/pre-migration-code` | Confirmed — at commit `320e9445` |
| Jido harness adapter | `jido_harness_adapter.ex` | Confirmed |

**Status: ✅ COMPLETE**

---

### 🟡 REQ-023: Signal Delivery Latency

**§3: `[x]` COMPLETE. §1: LGC-T005–T007 ALL `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| Agent→Agent latency test | `test/foreman_server/agents/signal_latency_regression_test.exs` | Confirmed |
| Operator→inbox latency test | `test/foreman_server_web/operator_inbox_latency_regression_test.exs` | Confirmed |
| Dashboard refresh latency test | `test/foreman_server_web/dashboard_refresh_latency_test.exs` | Confirmed |

Tests exist but cannot be executed without `erlexec`.

**Status: 🟡 TESTS EXIST** — LGC-T005–T007 ALL `[ ]` in §1.

---

### ✅ REQ-024: Characterization Test Harness

| Evidence | File | Verification |
|----------|------|--------------|
| Create workflow characterization | `test/workflow/create_workflow_characterization_test.exs` | Confirmed |
| Implement characterization (805 lines) | `test/workflow/implement_fix_characterization_test.exs` | Confirmed — CTH-T002, CTH-T003, CTH-T004 |
| Crash recovery characterization | `test/idempotency/crash_recovery_characterization_test.exs` | Confirmed — CTH-T004 |
| Merge gate characterization | `test/workflow/merge_gate_characterization_test.exs` | Confirmed — MGH-T004 |

**Status: ✅ COMPLETE**

---

### 🟡 REQ-025: Hot-Loadable Workflow Format

**§3: `[x]` COMPLETE. §1: HLW-T001 `[ ]`, T002 `[x]`, T003 `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| Workflow loader | `workflow/loader.ex` | Confirmed — YAML + Elixir DSL, reads `priv/workflows` |
| Validator | `workflow/validator.ex` | Confirmed — `validate/1` for known skill, valid idempotency keys |
| Hot-load integration tests | `test/foreman_server/workflow/hot_load_integration_test.exs` | Confirmed — HLW-T005 |
| Invalid workflow error | `workflow/loader.ex:27` | Confirmed — returns `nil` for unknown extension, no crash |

**Missing:** HLW-T001 (format specification document), HLW-T003 (validation — `Validator` exists but HLW-T003 is `[ ]` in §1).

**Status: 🟡 PARTIAL** — HLW-T001 `[ ]`, T002 `[x]`, T003 `[ ]` in §1.

---

### ✅ REQ-026: Ensemble --foreman Mode Idempotency Enhancement

Implementation verified through REQ-013, REQ-014, REQ-015, REQ-017.

**Status: ✅ COMPLETE**

---

## §1 vs §3 Discrepancy Summary

| REQ | §3 | §1 Tasks `[ ]` | Verdict |
|-----|----|---------------|---------|
| REQ-007 | [x] | JSH-T001[ ], T003[ ], T004[ ] | ✅ Code verified real |
| REQ-008 | [x] | JAI-T001[ ], T002[ ], T003[ ] | 🟡 Infrastructure present |
| REQ-009 | [x] | LGL-T001[ ]–T006[ ] | ❌ Dead code |
| REQ-010 | [x] | MCP-T001[ ]–T007[ ] | ❌ Stub tool extraction |
| REQ-011 | [x] | JLD-T001[ ]–T004[ ] | 🟡 Infrastructure present |
| REQ-012 | [x] | JOT-T001[ ]–T005[ ] | 🟡 Via OpenTelemetry |
| REQ-019 | [x] | ADT-T001[ ]–T004[ ] | ❌ Not implemented |
| REQ-020 | [x] | LGL-T004[ ] | ❌ Dead code |
| REQ-021 | [x] | LGC-T001[ ]–T004[ ] | ✅ Code verified real |
| REQ-023 | [x] | LGC-T005[ ]–T007[ ] | 🟡 Tests exist |
| REQ-025 | [x] | HLW-T001[ ], T003[ ] | 🟡 Partial |

---

## Critical Dead Code

| Module | Production Call Sites | Verdict |
|--------|---------------------|---------|
| `LangfuseTracer` | 0 | ❌ Dead code |
| `LitellmRouter` | 0 | ❌ Dead code |
| `ZeroCandidatesHandler` | 0 | ❌ Dead code |
| `McpClientPool.safe_tools/1` | 0 (always `[]`) | ❌ Stub |

---

## Action Required

1. **Fix TRD §3**: Mark REQ-009, 010, 019, 020 as `[ ]` to match §1.
2. **Wire or remove dead code**: `LangfuseTracer`, `LitellmRouter`, `ZeroCandidatesHandler` — either wire to production call sites or delete.
3. **Close MCP stub**: Implement actual tool extraction in `McpClientPool.safe_tools/1`.
4. **Implement ADT-T001–T004**: Representative benchmark action for REQ-019.
5. **Correct §3 table**: 5 REQs (009, 010, 019, 020, and partial 025) should be `[ ]`.
