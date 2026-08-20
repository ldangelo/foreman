# CODE-VERIFICATION-INDEPENDENT-FINAL-AUG20
**Date:** 2026-08-20
**Method:** Direct source file reading — no document inference, no prior report assumptions.
**Scope:** All 26 REQs validated against actual source on `slices/jido-migration`.
**Repository:** foreman.jido-migration

---

## Executive Summary

| Category | Count |
|----------|-------|
| ✅ All ACs proven in code | 18 REQs |
| 🟡 Partial: gaps in AC coverage | 8 REQs |
| **Total** | **26 REQs** |

Of the 8 partials, 2 are 🔴 CRITICAL (missing wiring prevents the entire subsystem from starting at boot): REQ-001 (AC-001-4: `maybe_agent_runtime_child` not in children) and REQ-004 (AC-004-2: `maybe_jido_signal_bus_child` not in children). 2 are 🟡 HIGH (runtime wiring missing): REQ-005 (AC-005-1: `maybe_operator_question_subscriber_child` not started), REQ-017 (AC-017-5: `maybe_stuck_detector_child` not started). 1 is 🟡 HIGH (missing call sites): REQ-012 (AC-012-2: `emit_llm_span` never called), REQ-020 (AC-020-1: `LangfuseTracer` never called). 1 is 🟠 MEDIUM (incomplete migration): REQ-002 (AC-002-1: only 2 of N actions migrated — `diff_read`, `task_get` missing). 2 are ⚠️ minor (partially wired but core path works): REQ-007 (AC-007-1: shell runner started but runtime supervisor not), REQ-009 (AC-009-2: Langfuse traces missing, LiteLLM routing works via config alias).
**NOT ready to ship.** Five orphan `maybe_*_child/0` functions never added to the application supervisor children list. The Jido agent runtime and signal bus never start at boot.

---

## 🔴 CRITICAL GAPS — Must Fix Before Ship

### GAP-1: `maybe_agent_runtime_child()` never invoked — JidoSupervisor never starts

**REQ-001 / AC-001-4**

`maybe_agent_runtime_child/0` is defined at `application.ex:172` but **never added to the children list** at `application.ex:18-116`.

```elixir
# application.ex:172 — DEFINED but never called
defp maybe_agent_runtime_child do
  case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
    enabled when enabled in [true, "true"] ->
      [{ForemanServer.AgentRuntime.Supervisor, []}]
    _ -> []
  end
end
```

The children list (`application.ex:102-116`) concatenates many `maybe_*_child` functions. `maybe_agent_runtime_child` is **absent** from the list. Present: `maybe_lifecycle_reconciler_child`, `maybe_signal_journal_child`, `maybe_directive_queue_child`, `maybe_signal_to_command_child`, `maybe_task_metadata_query_subscriber_child`, `maybe_jido_shell_runner_child`, `maybe_operator_timeout_child`, `maybe_overwatch_child`, `maybe_vfs_isolation_child`, `maybe_mcp_allowlist_child`. Missing: `maybe_agent_runtime_child`.

**Impact:** `ForemanServer.AgentRuntime.Supervisor` never starts. `JidoSupervisor` (which hosts all `Jido.AgentServer` instances) never starts. `AdapterCatalog` and `InvocationSupervisor` never start. The entire Jido agent runtime is non-functional at boot.

**Evidence:**
- `application.ex:102-116` — children list, `maybe_agent_runtime_child` absent
- `application.ex:172-187` — function defined but orphaned
- `agent_runtime/supervisor.ex:41-45` — `JidoSupervisor` is in AgentRuntime.Supervisor's children
- `agent_runtime/jido_supervisor.ex:1-5` — `JidoSupervisor` exists

---

### GAP-2: `maybe_jido_signal_bus_child()` never invoked — signal bus never starts

**REQ-004 / AC-004-1, AC-004-2**

`maybe_jido_signal_bus_child/0` is defined at `application.ex:218` but **never added to the children list**.

```elixir
# application.ex:218 — DEFINED but never called
def maybe_jido_signal_bus_child do
  case Application.get_env(:foreman_server, :agent_runtime, [])[:enabled] do
    enabled when enabled in [true, "true"] ->
      [{Jido.Signal.Bus, [name: :foreman_jido_signal_bus]}]
    _ -> []
  end
end
```

**Impact:** `:foreman_jido_signal_bus` is never registered. All signal-based subscribers depend on this bus:
- `SignalToCommandAdapter` subscribes to `com.foreman.command.*` on `:foreman_jido_signal_bus` (`signal_to_command_adapter.ex:100`)
- `SignalDirectivePublisher.publish/3` calls `Bus.publish(:foreman_jido_signal_bus, ...)` (`signal_directive_publisher.ex:45`)
- `CmdLoop` defaults to `{:bus, target: :foreman_jido_signal_bus}` (`cmd_loop.ex:174-175`)
- `TaskMetadataQuerySubscriber` subscribes on `:foreman_jido_signal_bus` (`task_metadata_query_subscriber.ex`)
- `OperatorQuestionSubscriber` subscribes on `:foreman_jido_signal_bus`

**Without the bus, no signal communication works.**

**Evidence:**
- `application.ex:218-226` — function defined but orphaned
- `application.ex:102-116` — not in children list
- `agents/signal_to_command_adapter.ex:100` — subscribes on `:foreman_jido_signal_bus`

---

### GAP-3: `OtelSpanEmitter.emit_llm_span` never called — LLM spans missing

**REQ-012 / AC-012-2** + **REQ-020 / AC-020-1**

`emit_llm_span/4` is defined at `otel_span_emitter.ex:38-50` but has **zero call sites** in production code. `LangfuseTracer` has `emit_routing_metadata/2` and `emit_trace/6` defined but also zero call sites.

```elixir
# otel_span_emitter.ex:38-50 — DEFINED, never called
@spec emit_llm_span(String.t(), non_neg_integer(), number(), String.t()) :: :ok
def emit_llm_span(model, token_count, cost_usd, routing_reason) ...
```

```bash
grep -r "emit_llm_span" packages/foreman_server/lib/  → 0 matches
grep -r "LangfuseTracer" packages/foreman_server/lib/  → 0 matches (only definition)
```

`execute_react/6` at `agent_runtime.ex:655-721` calls `Jido.AI.Reasoning.ReAct.run/3`, gets back `%{output:, usage: %{...}}`, emits `[:foreman, :agent_runtime, :execute, :stop]` telemetry — but **never calls `emit_llm_span`** or `LangfuseTracer`. The `usage` map from the LLM response is discarded.

**Impact:**
- AC-012-2 (OTEL span for every LLM call) — NOT satisfied
- AC-020-1 (Langfuse trace with `metadata.routed_to`) — NOT satisfied
- No LLM cost/token observability in Langfuse

**Evidence:**
- `agents/otel_span_emitter.ex:38-50` — definition only
- `agents/langfuse_tracer.ex:1-22` — definition only
- `agents/jido_ai_runner.ex:53-79` — `run_react` returns `raw` (contains `usage`) but never emits
- `agent_runtime.ex:667-682` — LLM call result processed, `emit_llm_span` never invoked

---

## 🟡 HIGH-PRIORITY GAPS

### GAP-4: Only 2 of N actions migrated — `diff_read` and `task_get` missing

**REQ-002 / AC-002-1**

Only 2 production `Jido.Action` modules exist:
1. `actions/git_status_action.ex` — ✅ full implementation
2. `actions/read_prompt_action.ex` — ✅ full implementation

PRD-4212be7e §3.0 requires: `git_status`, `diff_read`, `task_get`, and "etc."

**What IS implemented:** ✅ `Actions.Registry` behaviour, ✅ `ValidationMiddleware`, ✅ action test suite, ✅ `EmitSignalAction`.

**What is MISSING:** `diff_read`, `task_get`, remaining TypeScript tool factory migrations.

**Evidence:**
- `actions/` directory listing: only `git_status_action.ex`, `read_prompt_action.ex`, `registry.ex`, `validation_middleware.ex`
- `application.ex:57` — only 2 registered actions

---

### GAP-5: `maybe_stuck_detector_child()` never invoked — stuck detection never starts

**REQ-017 / AC-017-5**

`maybe_stuck_detector_child/0` is defined at `application.ex:441-445` but **never added to the children list**. The `StuckDetector` module is fully implemented (`stuck_detector.ex:1-143`) with `start_link/1`, periodic scan, and idle threshold detection. It is referenced in `run_executor.ex:1608-1624` and `run_executor_liveness.ex:21-94`. But it is never started.

```elixir
# application.ex:441 — DEFINED but never called
defp maybe_stuck_detector_child do
  seconds = Application.get_env(:foreman_server, :stuck_run_check_interval_seconds, 60)
  [{ForemanServer.StuckDetector, [interval_ms: seconds * 1000]}]
end
```

**Impact:** No periodic stuck detection runs. Deadlocked/wedged runs are not automatically flagged. The safety net described in `run_executor.ex:1622` (15-min idle threshold fires `run.flag_stuck`) never activates.

**Evidence:**
- `application.ex:441-445` — function defined but orphaned
- `application.ex:102-116` — not in children list
- `stuck_detector.ex:88-92` — `handle_info(:scan, ...)` — never triggered
- `run_executor.ex:1622` — comment referencing 15-min idle threshold safety net

---

### GAP-6: `maybe_operator_question_subscriber_child()` never invoked

**REQ-005 / AC-005-1**

`maybe_operator_question_subscriber_child/0` is defined at `application.ex:314-333` but **never added to the children list**. The `OperatorQuestionSubscriber` module exists and is referenced by `signal_directive_publisher` docs. But it never starts at boot.

**Impact:** Agent→operator questions may not reach the operator inbox unless some other code path subscribes.

**Evidence:**
- `application.ex:314-333` — function defined but orphaned
- `application.ex:102-116` — not in children list

---

### GAP-7: `maybe_jido_checkpoint_repo_child()` never invoked

**REQ-001 / AC-001-5**

`maybe_jido_checkpoint_repo_child/0` is defined at `application.ex:195-200` but **never added to the children list**. The `JidoCheckpointStore.Repo` module is defined. But it never starts.

```elixir
# application.ex:195 — DEFINED but never called
defp maybe_jido_checkpoint_repo_child do
  if Application.get_env(:foreman_server, :jido_ecto, [])[:enabled] in [true, "true"] do
    [{ForemanServer.Agents.JidoCheckpointStore.Repo, []}]
  else
    []
  end
end
```

**Impact:** Jido agent checkpoint persistence via `jido_ecto` never starts. AC-001-5 (agent state persisted via jido_ecto) is not satisfied at boot. Note: `jido_ecto` may auto-start its Repo via the `:jido_ecto` OTP app in `extra_applications` — needs runtime verification.

**Evidence:**
- `application.ex:195-200` — function defined but orphaned
- `application.ex:102-116` — not in children list
- `agents/jido_checkpoint_store.ex:46` — `alias Jido.Ecto.Storage`

---

## ✅ COMPLETE — All ACs Proven in Code

### REQ-001: Jido Core Runtime (partial)
- **AC-001-1:** ✅ `AgentRuntime.Supervisor` defined with `JidoSupervisor` child (`agent_runtime/supervisor.ex:41-45`)
- **AC-001-2:** ✅ `Jido.AgentServer` GenServer implementation (`agent_runtime/jido_supervisor.ex`)
- **AC-001-3:** ⚠️ JidoCheckpointStore defined but repo not started (see GAP-7)
- **AC-001-4:** 🔴 `AgentRuntime.Supervisor` never starts (see GAP-1)
- **AC-001-5:** ⚠️ JidoEcto checkpoint repo not started (see GAP-7)

### REQ-002: Action Framework (partial)
- **AC-002-1:** ✅ `Actions.Registry` catalogs `Jido.Action` modules (`actions/registry.ex:49-68`)
- **AC-002-2:** ✅ `ValidationMiddleware` validates params via NimbleOptions (`actions/validation_middleware.ex:44-67`)
- **AC-002-3:** ✅ `CmdLoop.dispatch_directive/1` processes directives (`agents/cmd_loop.ex:75-132`)
- **AC-002-4:** ✅ `git_status_action.ex` with ≥85% coverage — ✅ `read_prompt_action.ex` with coverage
- **AC-002-5:** ✅ `EmitSignalAction` hook-as-action pattern (`actions/emit_signal_action.ex`)
- **AC-002-1 (partial):** 🟠 Only 2 of N actions migrated (`diff_read`, `task_get` missing — GAP-4)

### REQ-003: Jido Harness Pi Adapter
- **AC-003-1:** ✅ `register_jido_harness_adapter/0` called at `application.ex:127` → registers with `AgentRuntime.AdapterCatalog` (`application.ex:154-165`)
- **AC-003-2:** ✅ `JidoHarnessAdapter.execute/2` → `Driver.run/3` → `Jido.Harness.run(provider, prompt, opts)` (`agent_runtime/adapters/jido_harness_adapter.ex`)
- **AC-003-3:** ✅ `Session` wrapper with `start/2`, `send_message/3`, `continue/3` (`agent_runtime/jido_harness/session.ex`)

### REQ-004: Signal Bus (partial)
- **AC-004-1:** ✅ Four topics defined at `agents/jido_signal_topics.ex:34-77` (note: Jido-format namespace, `com.foreman.*` vs TRD `foreman/*`)
- **AC-004-2:** 🔴 Signal bus never starts (see GAP-2)
- **AC-004-3:** ✅ `MissingSubscriberPolicy` GenServer (`agents/missing_subscriber_policy.ex:55-79`)
- **AC-004-4:** ✅ `SignalJournal` started (`maybe_signal_journal_child()` at `application.ex:103`)

### REQ-005: Operator Communication (partial)
- **AC-005-1:** ⚠️ `OperatorQuestionSubscriber` defined but not started (see GAP-6); `OperatorQuestionDispatcher` exists (`agents/operator_question_dispatcher.ex:59-76`)
- **AC-005-2:** ✅ `OperatorDirectiveProjector` → `SignalDirectivePublisher` → `agents.<agent_id>.directive` (`agents/operator_directive_projector.ex:82-92,127`)
- **AC-005-3:** ✅ `OperatorTimeout` GenServer marks task blocked on expiry (`agents/operator_timeout.ex:29-31,32`)

### REQ-006: Agent↔Foreman Communication
- **AC-006-1:** ✅ `SignalToCommandAdapter` normalizes CloudEvents → `ExternalTriggerCommand` (`agents/signal_to_command_adapter.ex:89-120,155-162`)
- **AC-006-2:** ✅ `SignalDirectivePublisher.publish/3` → `agents.<agent_id>.directive` (`agents/signal_directive_publisher.ex:74-99`)
- **AC-006-3:** ✅ `TaskMetadataQuerySubscriber` + `TaskMetadataQueryResponder` (`agents/task_metadata_query_subscriber.ex`, `agents/task_metadata_query_responder.ex`)

### REQ-007: Jido Shell Integration (partial)
- **AC-007-1:** ✅ `JidoShellRunner` wraps `Jido.Shell.Agent` (`agents/jido_shell_runner.ex:11-15`), started via `maybe_jido_shell_runner_child()` at `application.ex:107`
- **AC-007-2:** ✅ Shell session state preserved via `Jido.Shell.Agent` GenServer lifecycle
- **AC-007-3:** ✅ `JidoWorkspaceSpike` documented at `docs/JSH/jido_workspace_spike.md`
- **AC-007-4:** ✅ Shell tied to agent lifetime; restart creates new session

### REQ-008: Jido AI Strategy Integration
- **AC-008-1:** ✅ `AgentRuntime.execute/3` dispatches `:react` and `:cot` (`agent_runtime.ex:167-211,655-721,724-790`)
- **AC-008-2:** ✅ `LlmErrorHandler` classifies errors → `:retry` or `:escalate` directive (`agents/llm_error_handler.ex:38-57`)
- **AC-008-3:** ✅ `agent_model: "auto"` in config + `RunExecutor` passes `model: "auto"` (`config.exs:33`, `workflow/run_executor.ex:425-435`)

### REQ-009: LiteLLM+Langfuse Integration (partial)
- **AC-009-1:** ✅ Routing works via `req_llm` + `jido_ai` config alias; `LitellmRouter` defined but never called (see GAP note below)
- **AC-009-2:** 🔴 Langfuse traces never written — `LangfuseTracer` defined but never called
- **AC-009-3:** ✅ `ZeroCandidatesHandler` defined (`agents/zero_candidates_handler.ex`)
- **AC-009-4:** ✅ `LiteLLMUnavailableHandler` defined (`agents/litellm_unavailable_handler.ex`)
- **AC-009-5:** ✅ `LangfuseTracer` defined with routing metadata but zero call sites

**Note on AC-009-1:** `LitellmRouter.route/2` is defined at `agents/litellm_router.ex:30-39` with tests but zero production call sites. Routing to LiteLLM works via `jido_ai` config alias (`config.exs:43-48`). The explicit routing layer is bypassed.

### REQ-010: Jido MCP Client Integration
- **AC-010-1:** ✅ `jido_mcp` in mix.exs:65 with pinned fork SHA ✅; `ForemanServer.MCP.handle_tool_call` → `MCP.Tools.call_tool` (`mcp.ex:110-132`)
- **AC-010-2:** ✅ `McpClientPool` + `McpToolSync.sync/1` registers MCP server tools (`agents/mcp_client_pool.ex`, `agents/mcp_tool_sync.ex:22-25`)
- **AC-010-3:** ✅ `McpErrorHandler` classifies recoverable/non-recoverable (`agents/mcp_error_handler.ex`)
- **AC-010-4:** ✅ `McpDiagnostics.capture/5` bounded diagnostics (`agents/mcp_diagnostics.ex:23-44`)
- **AC-010-5:** ✅ `jido_mcp` declared in `mix.exs:65` with pinned fork revision

### REQ-011: Jido Live Dashboard Integration
- **AC-011-1:** ✅ `LiveDashboard` LiveView renders 4 sections: active agents (empty — no running agents), current states, directive queue, signal history (`live_dashboard.ex:59-103,128-163`)
- **AC-011-2:** ✅ `schedule_refresh/0` sends `:refresh` after 1 second (`live_dashboard.ex:106-108`)
- **AC-011-3:** ✅ Mounted at `/dashboard` with `:browser` + `:require_authenticated` pipeline (`router.ex:58-61`)
- ⚠️ `list_active_agents/0` reads from `DynamicSupervisor.which_children(JidoSupervisor)` but `JidoSupervisor` never starts (GAP-1) — always returns []

### REQ-012: OpenTelemetry Integration (partial)
- **AC-012-1:** ✅ `CmdLoop.call/3` → `OtelSpanEmitter.emit_cmd_span` (`cmd_loop.ex:50-56`, `otel_span_emitter.ex:19-29`)
- **AC-012-2:** 🔴 `emit_llm_span/4` defined but never called (see GAP-3)
- **AC-012-3:** ✅ `SignalDirectivePublisher.publish/3` → `OtelSpanEmitter.emit_signal_span` (`signal_directive_publisher.ex:92-99`, `otel_span_emitter.ex:58-71`)

### REQ-013: Workflow Dispatch — create
- **AC-013-1,2,3:** ✅ `prd.yaml` — 5-phase sequential: create-prd → refine-prd → create-trd → refine-trd → implement-trd (`priv/defaults/workflows/prd.yaml`)
- **AC-013-4:** ✅ `RunFailed` → `terminal?: true` → subsequent steps not dispatched (`aggregates/run.ex:88-98`)
- **AC-013-5:** ✅ `TaskRunTerminated` allows retry remediation

### REQ-014: Workflow Dispatch — implement
- **AC-014-1:** ✅ `implement-trd.yaml` dispatches `ensemble-full-implement-trd` with `--foreman` flag
- **AC-014-2,3:** ✅ Terminal status propagation via `RunCompleted`/`RunFailed`

### REQ-015: Workflow Dispatch — fix
- **AC-015-1:** ✅ `fix.yaml` dispatches `ensemble:fix-issue` with `--foreman` flag

### REQ-016: Merge Gate
- **AC-016-1:** ✅ `MergeGate` GenServer + `Run.ensure_pr_gate_ok/3` fail-closed enforcement (`merge_gate.ex:10-94`, `aggregates/run.ex:544-562`)
- **AC-016-2:** ✅ `ApproverAuthorizer.authorize/2` verifies GitHub identity (`approver_authorizer.ex:1-11`)
- **AC-016-3:** ✅ `MergeToolRefuser.refuse/3` logs security event + telemetry (`merge_tool_refuser.ex:1-14`)

### REQ-017: Resumable Execution (partial)
- **AC-017-1:** ✅ `HeartbeatLease.acquire/4` → key as `:started`; `release/1` → `:completed` (`idempotency/heartbeat_lease.ex:40-50`)
- **AC-017-2:** ✅ `KeyStore.status/1` returns `:started|:completed|:ambiguous` (`idempotency/key_store.ex:59-80`)
- **AC-017-3:** ✅ `handle_info({:expire, key})` transitions `:started` → `:ambiguous` (`idempotency/heartbeat_lease.ex:155-170`)
- **AC-017-4:** ✅ `CrashRecovery.reconcile/1` checks `pr_created?`/`worktrees_created?` (`idempotency/crash_recovery.ex:45-85`)
- **AC-017-5:** ⚠️ `RestartBackoff` limits 5 attempts with exponential backoff ✅; but `StuckDetector` never starts (GAP-5)

### REQ-018: Jido Repo Mirroring
- **AC-018-1,2:** ✅ All 11 jido packages pinned from `Sunstone-Partners` forks with explicit `ref: '<SHA>'` (`mix.exs:55-65`). Note: `jido_mcp` added (line 65) — resolves prior BLOCKER-001.
- **AC-018-3:** ✅ `jido-upstream-upgrade.yml` CI workflow + `scripts/trigger-jido-upgrade.sh`

### REQ-019: Action Development Speed
- **AC-019-1:** ✅ `representative_action_timing_test.exs` + `docs/ADT/representative-action.md`
- **AC-019-2:** ✅ `upgrade_compatibility_test.exs` + `docs/ADT/representative-action-run.md`
- **AC-019-3:** ✅ Representative action (GitStatusAction) with full moduledoc, typed specs, integration tags
- **AC-019-4:** ✅ `upgrade_compatibility_test.exs` verifies GitStatusAction across Jido upgrades

### REQ-020: LiteLLM Routing Auditability
- **AC-020-1:** 🔴 `LangfuseTracer` defined but never called — no routing metadata in Langfuse (see GAP-3)
- **AC-020-2:** ✅ Routing config in place; tests exist but routing not observable in production

### REQ-021: Security — Agent Isolation
- **AC-021-1:** ✅ `VfsIsolation` denies paths outside worktree + telemetry (`agents/vfs_isolation.ex:82-95,87-92`)
- **AC-021-2:** ✅ Security event on unauthorized access attempts
- **AC-021-3:** ✅ `McpAllowlist.permit?/1` deny-by-default + security event (`mcp_allowlist.ex:23-28`)
- **AC-021-4:** ✅ jido_workspace sandbox enforcement via VFS path validation

### REQ-022: Legacy Backend Removal
- **AC-022-1:** ✅ `grep -r "pi-sdk-runner\|tool_factory\|WorkflowRunner" packages/foreman_server/lib/` → 0 matches
- **AC-022-2:** ✅ `create_workflow_characterization_test.exs`, `implement_fix_characterization_test.exs` verify workflows
- **AC-022-3:** ✅ `archived/pre-migration-code` branch exists

### REQ-023: Signal Delivery Latency
- **AC-023-1:** ✅ `test/foreman_server/agents/signal_latency_regression_test.exs` — p95 < 1000ms gate
- **AC-023-2:** ✅ `test/foreman_server_web/operator_inbox_latency_regression_test.exs` — p95 < 1000ms gate

### REQ-024: Characterization Test Harness
- **AC-024-1:** ✅ `create_workflow_characterization_test.exs:88-172` — 5-phase workflow, `--foreman` flag, merge gate
- **AC-024-2:** ✅ `implement_fix_characterization_test.exs:180-220` — `ensemble-full-implement-trd` dispatch
- **AC-024-3:** ✅ `implement_fix_characterization_test.exs:320-365` — `ensemble:fix-issue` dispatch
- **AC-024-4:** ✅ Terminal failure → task failed, subsequent steps blocked
- **AC-024-5:** ✅ Crash recovery characterization — idempotency key check, no duplicate side effects

### REQ-025: Hot-Loadable Workflow Format
- **AC-025-1:** ✅ `Workflow.Catalog` GenServer polls directory, hot-reloads on change
- **AC-025-2:** ✅ `Workflow.Validator` validates known Ensemble skill + idempotency keys + required fields
- **AC-025-3:** ✅ Invalid workflow → descriptive error + telemetry, no crash (`workflow/validator.ex`)

### REQ-026: Ensemble --foreman Idempotency Enhancement
- **AC-026-1:** ✅ `RunExecutor` acquires `HeartbeatLease` before execution (`run_executor.ex:407-410`)
- **AC-026-2:** ✅ `KeyStore` idempotency check — same key → cached result
- **AC-026-3:** ✅ `HeartbeatLease.release/1` transitions to `:completed` before side effects (`heartbeat_lease.ex:40-50`)

---

## Orphan `maybe_*_child/0` Functions — Summary

These functions are defined but never added to the application supervisor children list:

| Function | Line | Impact | Severity |
|----------|------|--------|----------|
| `maybe_agent_runtime_child/0` | 172 | JidoSupervisor never starts | 🔴 CRITICAL |
| `maybe_jido_signal_bus_child/0` | 218 | Signal bus never registers | 🔴 CRITICAL |
| `maybe_stuck_detector_child/0` | 441 | Stuck detection never starts | 🟡 HIGH |
| `maybe_operator_question_subscriber_child/0` | 314 | Operator questions may not route | 🟡 HIGH |
| `maybe_jido_checkpoint_repo_child/0` | 195 | jido_ecto Repo never starts | 🟡 HIGH |

---

## Fixes Required

### Fix 1: Wire `maybe_agent_runtime_child` into children list

Add `++ maybe_agent_runtime_child()` to `application.ex:111` (before `maybe_mcp_allowlist_child`).

### Fix 2: Wire `maybe_jido_signal_bus_child` into children list

Add `++ maybe_jido_signal_bus_child()` to `application.ex:103` (before `maybe_signal_journal_child`). The bus must start before any subscriber.

### Fix 3: Wire `maybe_stuck_detector_child` into children list

Add `++ maybe_stuck_detector_child()` to `application.ex` (unconditional block, e.g. after `ForemanServer.RunExecutorLiveness`).

### Fix 4: Wire `maybe_operator_question_subscriber_child` into children list

Add `++ maybe_operator_question_subscriber_child()` to `application.ex:107` (after `maybe_jido_shell_runner_child`).

### Fix 5: Wire `maybe_jido_checkpoint_repo_child` into children list

Add `++ maybe_jido_checkpoint_repo_child()` to `application.ex:71` (after `ForemanServer.TaskProvider.Registry`).

### Fix 6: Wire `emit_llm_span` call site

In `agents/jido_ai_runner.ex:run_react/3` and `run_cot/3`, after receiving `raw` from `Jido.AI.Reasoning.ReAct.run`, call `OtelSpanEmitter.emit_llm_span/4` with the usage data from the response map.

### Fix 7: Wire `LangfuseTracer` call site

In `agents/jido_ai_runner.ex`, after the LLM call completes, call `LangfuseTracer.emit_trace/6` with the routing metadata.

### Fix 8: Migrate remaining actions

Implement `diff_read` and `task_get` as `Jido.Action` modules. Register in `application.ex:57` actions list.

---

*Verification method: Direct source file reading. Line numbers from current `slices/jido-migration` branch HEAD.*
