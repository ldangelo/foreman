# Code Verification: TRD-2026-4212be7e — Code-First (Definitive Live)

**Date:** 2026-08-20
**Branch:** `slices/jido-migration` (HEAD: `a6e1b52b`)
**Method:** Requirements verified against actual source files in `packages/foreman_server/`

---

## Executive Summary

**§3 of the TRD claims all 26 REQs are `[x]` (complete). This is FALSE.**

| REQ | §3 Claim | Code Reality | Severity |
|-----|----------|--------------|----------|
| REQ-009 | `[x]` COMPLETE | LGL-T001–T006 ALL `[ ]` in §1; `LangfuseTracer`/`LitellmRouter` ZERO call sites | 🔴 CRITICAL |
| REQ-020 | `[x]` COMPLETE | `LangfuseTracer` ZERO call sites; NFR-07 "LLM trace 100% in Langfuse" NOT MET | 🔴 CRITICAL |
| REQ-010 | `[x]` COMPLETE | MCP-T001–T007 ALL `[ ]` in §1; `McpClientPool.safe_tools/1` is stub returning `[]` | 🔴 CRITICAL |
| REQ-007 | `[x]` COMPLETE | JSH-T001, JSH-T003, JSH-T004 ALL `[ ]` in §1; VFS sandbox stub-only | 🟡 HIGH |
| REQ-008 | `[x]` COMPLETE | JAI-T001–T003 ALL `[ ]` in §1; `JidoAiRunner` degrades to placeholder | 🟡 HIGH |
| REQ-011 | `[x]` COMPLETE | JLD-T001–T004 ALL `[ ]` in §1; dashboard exists but refresh latency NOT measured | 🟡 HIGH |
| REQ-012 | `[x]` COMPLETE | JOT-T001–T005 ALL `[ ]` in §1; OTEL spans emit via OpenTelemetry (not directly to Langfuse) | 🟡 HIGH |
| REQ-019 | `[x]` COMPLETE | ADT-T001–T004 ALL `[ ]` in §1; no benchmark action found | 🟡 HIGH |
| REQ-004 | `[x]` COMPLETE | JSI-T004 `[ ]` in §1; SignalJournal EXISTS and wired | ✅ VERIFIED |
| REQ-005 | `[x]` COMPLETE | All tasks `[x]` in §1 | ✅ VERIFIED |
| REQ-013 | `[x]` COMPLETE | All tasks `[x]` in §1 | ✅ VERIFIED |
| REQ-014 | `[x]` COMPLETE | All tasks `[x]` in §1 | ✅ VERIFIED |
| REQ-015 | `[x]` COMPLETE | All tasks `[x]` in §1 | ✅ VERIFIED |
| REQ-016 | `[x]` COMPLETE | All tasks `[x]` in §1 | ✅ VERIFIED |
| REQ-017 | `[x]` COMPLETE | All tasks `[x]` in §1 | ✅ VERIFIED |
| REQ-022 | `[x]` COMPLETE | All tasks `[x]` in §1 | ✅ VERIFIED |
| REQ-024 | `[x]` COMPLETE | All tasks `[x]` in §1 | ✅ VERIFIED |
| REQ-025 | `[x]` COMPLETE | HLW-T001–T003 `[ ]` in §1; HLW-T004–T005 `[x]` | 🟡 PARTIAL |

---

## Verified COMPLETE in Code ✅

### ✅ REQ-001: Jido Core Runtime
| Evidence | File | Verification |
|----------|------|--------------|
| 10 Jido packages forked+pinned | `mix.exs:55-65` | Confirmed |
| SignalToCommandAdapter | `agents/signal_to_command_adapter.ex` | Confirmed, wired in `application.ex:269` |
| jido_ecto integration | `application.ex:201-207` (`JidoCheckpointStore.Repo`) | Confirmed |
| OTEL spans | `agents/otel_span_emitter.ex` | Confirmed, called in `agent_runtime.ex`, `cmd_loop.ex` |

**Status: ✅ COMPLETE**

---

### ✅ REQ-002: Jido Action Authoring Framework
| Evidence | File | Verification |
|----------|------|--------------|
| Jido.Action behaviour | `actions/git_status_action.ex`, `actions/read_prompt_action.ex` | Confirmed |
| validation middleware | `actions/validation_middleware.ex` | Confirmed |
| Character loader | `Catalog.read_prompt/1` | Confirmed |
| Isolation tests | `test/foreman_server/actions/*_test.exs` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-003: Jido Harness Pi Adapter
| Evidence | File | Verification |
|----------|------|--------------|
| jido_harness integration | `jido_harness_adapter.ex` | Confirmed |
| Session/Run/Process | `jido_harness/*.ex` (5 modules) | Confirmed |
| Config default | `config/config.exs:29` → `JidoHarnessAdapter` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-004: Inter-Agent Communication (Agent↔Agent)
| Evidence | File | Verification |
|----------|------|--------------|
| 4 topics | `agents/jido_signal_topics.ex` | Confirmed |
| Pub/sub | `Bus.publish` in signal modules | Confirmed |
| Missing-subscriber policy | configurable silent/warn/error | Confirmed |
| SignalJournal | `agents/signal_journal.ex`, wired `application.ex:238-246` | Confirmed |
| Integration tests | `test/foreman_server/agents/signal_latency_regression_test.exs` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-005: Agent↔Operator Communication
| Evidence | File | Verification |
|----------|------|--------------|
| Operator topic subscriber | `agents/operator_question_subscriber.ex` | Confirmed |
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

## Verified INCOMPLETE in Code ❌

### ❌ REQ-007: Jido Shell Integration

**§3 claims: `[x]` COMPLETE. §1 reality: JSH-T001, JSH-T003, JSH-T004 are `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| jido_shell integration | `jido_shell_runner.ex` | Present, stub-only |
| VFS isolation | `vfs_isolation.ex` | Stub with `allowed?/2` returning `true` |

**Proof of stub:**
```elixir
# vfs_isolation.ex
def allowed?(_path, _bindings), do: true  # Always permissive
```

**Status: ❌ INCOMPLETE** — JSH-T001 (integration), JSH-T003 (VFS per-worktree), JSH-T004 (integration tests) are ALL `[ ]` in §1.

---

### 🟡 REQ-008: Jido AI Strategy Integration

**§3 claims: `[x]` COMPLETE. §1 reality: JAI-T001–T003 ALL `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| jido_ai runner | `agents/jido_ai_runner.ex` | Present, degrades to placeholder |
| ReAct/CoT | Calls to `Jido.AI.Reasoning` | Present but conditional on `Code.ensure_loaded?` |

**Code reality:**
```elixir
# jido_ai_runner.ex — graceful degradation to placeholder
if Code.ensure_loaded?(Jido.AI.Reasoning.ReAct) do
  # actual call
else
  {:ok, %{strategy: :react, output: "...", status: :degraded, error: "not loaded"}}
end
```

**Status: 🟡 INFRASTRUCTURE PRESENT** — functional only when jido packages loaded. JAI-T001–T003 are ALL `[ ]` in §1.

---

### ❌ REQ-009: LiteLLM+Langfuse Integration — STRUCTURAL GAP

**§3 claims: `[x]` COMPLETE. §1 reality: LGL-T001–T006 ALL `[ ]`.**

**Functional routing WORKS** via `config.exs` model_aliases (`"auto"` → LiteLLM port 4000).

**Structural requirements NOT met:**

| Module | Defined | Production Call Sites |
|--------|---------|----------------------|
| `LitellmRouter.route/2` | ✅ | **0** |
| `LangfuseTracer.emit_trace/6` | ✅ | **0** |
| `ZeroCandidatesHandler.format_error/1` | ✅ | **0** |
| `LitellmUnavailableHandler.handle/1` | ✅ | 1 test only |

**Verified by:**
```bash
grep -rn "LitellmRouter\." lib/ --include="*.ex" | grep -v "_test.exs"
# → 0 results

grep -rn "LangfuseTracer\." lib/ --include="*.ex" | grep -v "_test.exs"
# → 0 results
```

**Actual tracing uses:** `OtelSpanEmitter.emit_llm_span/4` via OpenTelemetry — NOT Langfuse directly.

**Status: ❌ INCOMPLETE** — LGL-T001–T006 ALL `[ ]` in §1. Prescriptive API is dead code.

---

### ❌ REQ-010: Jido MCP Client Integration — STUB

**§3 claims: `[x]` COMPLETE. §1 reality: MCP-T001–T007 ALL `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| MCP client pool | `agents/mcp_client_pool.ex` | Defined but `safe_tools/1` returns `[]` |
| MCP tool sync | `agents/mcp_tool_sync.ex` | Defined, calls `McpClientPool.tools/1` |
| MCP policy/allowlist | `mcp/policy.ex` | Present |
| MCP auth | `mcp/auth.ex` | Present |

**Proof of stub:**
```elixir
# mcp_client_pool.ex:30
defp safe_tools(_client), do: []  # Always returns empty list — never extracts tools
```

**Status: ❌ INCOMPLETE** — MCP-T001–T007 ALL `[ ]` in §1. Tool extraction is stub-only.

---

### 🟡 REQ-011: Jido Live Dashboard Integration

**§3 claims: `[x]` COMPLETE. §1 reality: JLD-T001–T004 ALL `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| 4-view layout | `live_dashboard.ex` | Confirmed (Active agents, Current state, Directive queue, Signal history) |
| Auto-refresh | `schedule_refresh/1` with 1s interval | Confirmed |
| Auth deferred | Comment notes auth deferred | Confirmed |

**Unverified:**
- JLD-T003: Dashboard refresh latency ≤1 second — NOT measured in code
- JLD-T004: Dashboard integration tests — NOT confirmed

**Status: 🟡 INFRASTRUCTURE PRESENT** — JLD-T003 (latency verification), JLD-T004 (integration tests) are `[ ]` in §1.

---

### 🟡 REQ-012: Jido OpenTelemetry Integration

**§3 claims: `[x]` COMPLETE. §1 reality: JOT-T001–T005 ALL `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| OTEL span emitter | `agents/otel_span_emitter.ex` | Confirmed |
| Cmd/2 spans | Called in `cmd_loop.ex:56` | Confirmed |
| LLM spans | Called in `agent_runtime.ex:677,692,752,767` | Confirmed |
| Signal spans | Called in `signal_directive_publisher.ex:99` | Confirmed |
| OTLP endpoint config | `config/config.exs:80` | Langfuse-compatible OTLP |

**Note:** Spans go through OpenTelemetry OTLP (Langfuse-compatible) — NOT directly to `LangfuseTracer`. NFR-07 ("LLM trace 100% in Langfuse") is NOT directly violated since Langfuse accepts OTLP, but `LangfuseTracer.emit_trace/6` is never called.

**Status: 🟡 INFRASTRUCTURE PRESENT** — OTEL spans via OpenTelemetry. NFR-07 technically met via OTLP→Langfuse path. JOT-T005 (integration tests) are `[ ]` in §1.

---

### ✅ REQ-013: Workflow Dispatch — create
| Evidence | File | Verification |
|----------|------|--------------|
| Sequential dispatcher | `workflow/dispatcher.ex` | Confirmed |
| Step sequencing | `workflow/step_sequencer.ex` | Confirmed |
| Idempotency keys | `workflow/step_idempotency.ex` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-014: Workflow Dispatch — implement
| Evidence | File | Verification |
|----------|------|--------------|
| Implement dispatcher | `workflow/dispatcher.ex` | Confirmed |
| `--foreman` flag | Called via `RunExecutor` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-015: Workflow Dispatch — fix
| Evidence | File | Verification |
|----------|------|--------------|
| Fix dispatcher | `workflow/dispatcher.ex` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-016: Merge Gate — Human Review Required
| Evidence | File | Verification |
|----------|------|--------------|
| Approval flow | `workflow/approval.ex` | Confirmed |
| Approver authorization | `workflow/approver_authorizer.ex` | Confirmed |
| Merge tool refusal | `workflow/merge_tool_refuser.ex` | Confirmed |
| MergeGate GenServer | `workflow/merge_gate.ex` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-017: Resumable Task Execution with Idempotent Invocation
| Evidence | File | Verification |
|----------|------|--------------|
| Idempotency key store | `idempotency/key_store.ex` | Confirmed |
| Heartbeat lease | `idempotency/heartbeat_lease.ex` | Confirmed |
| Crash recovery | `idempotency/crash_recovery.ex` | Confirmed |
| 5-restart backoff | `idempotency/backoff.ex` | Confirmed |

**Status: ✅ COMPLETE**

---

### ✅ REQ-018: Jido Repository Mirroring
| Evidence | File | Verification |
|----------|------|--------------|
| 10 packages forked+pinned | `mix.exs:55-65` (Sunstone-Partners forks) | Confirmed |
| CI trigger script | `scripts/trigger-jido-upgrade.sh` | Confirmed |

**Status: ✅ COMPLETE**

---

### ❌ REQ-019: Action Development Speed Target

**§3 claims: `[x]` COMPLETE. §1 reality: ADT-T001–T004 ALL `[ ]`.**

No representative benchmark action found in code. ADT-T001–T004 are ALL `[ ]` in §1.

**Status: ❌ NOT IMPLEMENTED**

---

### ❌ REQ-020: LiteLLM Routing Auditability — ZERO CALL SITES

**§3 claims: `[x]` COMPLETE. §1 reality: LGL-T004 is `[ ]`.**

**Critical finding:** `LangfuseTracer` is defined but never called in production.

```bash
grep -rn "LangfuseTracer\." lib/ --include="*.ex" | grep -v "_test.exs"
# → 0 results
```

**NFR-07 states:** "LLM trace 100% in Langfuse"

**Reality:** OTEL spans use `OpenTelemetry.Tracer` directly — routed to Langfuse via OTLP endpoint with auth headers, but `LangfuseTracer.emit_trace/6` is never called. The prescriptive API is dead code.

**Status: ❌ INCOMPLETE** — LGL-T004 is `[ ]` in §1. NFR-07 technically met via OTLP but prescriptive API is dead code.

---

### 🟡 REQ-021: Security — Agent Isolation

**§3 claims: `[x]` COMPLETE. §1 reality: LGC-T001–T004 ALL `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| VFS sandbox | `vfs_isolation.ex` | Stub-only (`allowed?/2` always returns `true`) |
| Approver authorization | `approver_authorizer.ex` | Confirmed |
| Merge tool refusal | `merge_tool_refuser.ex` | Confirmed |
| Security tests | `test/integration/security_isolation_test.exs` | Exists |

**Status: 🟡 INFRASTRUCTURE PRESENT** — LGC-T001–T004 ALL `[ ]` in §1. VFS is stub-only.

---

### ✅ REQ-022: Legacy Backend Removal
| Evidence | File | Verification |
|----------|------|--------------|
| pi-sdk-runner.ts absent | `grep -rn "pi-sdk-runner" packages/` → 0 | Confirmed |
| Archive branch | `archived/pre-migration-code` at `320e9445` | Confirmed |
| Jido harness adapter | `jido_harness_adapter.ex` | Confirmed |

**Status: ✅ COMPLETE**

---

### 🟡 REQ-023: Signal Delivery Latency

**§3 claims: `[x]` COMPLETE. §1 reality: LGC-T005–T007 ALL `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| Agent→Agent latency | `test/foreman_server/agents/signal_latency_regression_test.exs` | Exists |
| Operator→inbox latency | `test/foreman_server_web/operator_inbox_latency_regression_test.exs` | Exists |
| Dashboard refresh latency | `test/foreman_server_web/dashboard_refresh_latency_test.exs` | Exists |

**Status: 🟡 TESTS EXIST** — Cannot run to verify p95 < 1s thresholds without `erlexec`.

---

### ✅ REQ-024: Characterization Test Harness
| Evidence | File | Verification |
|----------|------|--------------|
| Create workflow characterization | `test/workflow/create_workflow_characterization_test.exs` | Confirmed |
| Implement characterization | `test/workflow/implement_fix_characterization_test.exs` (805 lines) | Confirmed |
| Crash recovery characterization | `test/idempotency/crash_recovery_characterization_test.exs` | Confirmed |
| Merge gate characterization | `test/workflow/merge_gate_characterization_test.exs` | Confirmed |

**Status: ✅ COMPLETE**

---

### 🟡 REQ-025: Hot-Loadable Workflow Format

**§3 claims: `[x]` COMPLETE. §1 reality: HLW-T001–T003 are `[ ]`.**

| Evidence | File | Verification |
|----------|------|--------------|
| Workflow loader | `workflow/loader.ex` | YAML + Elixir DSL loading |
| Hot-load integration tests | `test/workflow/hot_load_integration_test.exs` | Confirmed |
| Invalid workflow error handling | `workflow/loader.ex` | Graceful nil on unknown ext |

**Missing:** HLW-T001 (format spec), HLW-T002 (loader — basic), HLW-T003 (validation) are `[ ]` in §1.

**Status: 🟡 PARTIAL** — HLW-T001–T003 `[ ]`, HLW-T004–T005 `[x]` in §1.

---

### ✅ REQ-026: Ensemble --foreman Mode Idempotency Enhancement

Implementation is part of REQ-013, REQ-014, REQ-015, REQ-017 which are verified complete.

**Status: ✅ COMPLETE**

---

## §1 vs §3 Discrepancy Summary

The TRD has a critical internal inconsistency:

- **§1 Master Task List**: Shows `[ ]` for ALL incomplete tasks (correct)
- **§3 Acceptance Criteria Table**: Claims ALL 26 REQs are `[x]` complete (FALSE)

### §3 Claims `[x]` but §1 Tasks are `[ ]`:

| REQ | §3 | §1 Tasks | Severity |
|-----|----|----------|----------|
| REQ-007 | [x] | JSH-T001[ ], T003[ ], T004[ ] | 🔴 |
| REQ-008 | [x] | JAI-T001[ ], T002[ ], T003[ ] | 🟡 |
| REQ-009 | [x] | LGL-T001[ ], T002[ ], T003[ ], T004[ ], T005[ ], T006[ ] | 🔴 |
| REQ-010 | [x] | MCP-T001[ ], T002[ ], T003[ ], T004[ ], T005[ ], T006[ ], T007[ ] | 🔴 |
| REQ-011 | [x] | JLD-T001[ ], T002[ ], T003[ ], T004[ ] | 🟡 |
| REQ-012 | [x] | JOT-T001[ ], T002[ ], T003[ ], T004[ ], T005[ ] | 🟡 |
| REQ-019 | [x] | ADT-T001[ ], T002[ ], T003[ ], T004[ ] | 🟡 |
| REQ-020 | [x] | LGL-T004[ ] | 🔴 |
| REQ-021 | [x] | LGC-T001[ ], T002[ ], T003[ ], T004[ ] | 🟡 |
| REQ-023 | [x] | LGC-T005[ ], T006[ ], T007[ ] | 🟡 |
| REQ-025 | [x] | HLW-T001[ ], T002[ ], T003[ ] | 🟡 |

---

## Critical Structural Gaps (Dead Code)

### 1. `LangfuseTracer` — Never Called
```elixir
# Defined: agents/langfuse_tracer.ex
# Production call sites: 0
# NFR-07: "LLM trace 100% in Langfuse" — prescriptive API not used
```

### 2. `LitellmRouter` — Never Called
```elixir
# Defined: agents/litellm_router.ex
# Production call sites: 0
# Actual routing: OpenTelemetry spans via OtelSpanEmitter
```

### 3. `ZeroCandidatesHandler` — Never Called
```elixir
# Defined: agents/zero_candidates_handler.ex
# Production call sites: 0
```

### 4. `McpClientPool.safe_tools/1` — Stub
```elixir
# Defined: agents/mcp_client_pool.ex:30
defp safe_tools(_client), do: []  # Always empty — tools never extracted
```

---

## Action Required

1. **Fix TRD §3**: Remove `[x]` from incomplete REQs. Mark REQ-007, 009, 010, 019, 020 as `[ ]` in §3 to match §1.
2. **Close dead code**: Either wire `LangfuseTracer`, `LitellmRouter`, `ZeroCandidatesHandler` to production call sites, or remove them.
3. **Close MCP stub**: Implement actual tool extraction in `McpClientPool.safe_tools/1`.
4. **Close VFS stub**: Implement actual sandbox enforcement in `vfs_isolation.ex`.
5. **Benchmark action**: Implement ADT-T001–T004 for REQ-019.
