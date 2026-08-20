# TRD-2026-4212be7e Code Verification — Independent Verification 2026-08-20

**Scope:** Validate every REQ-001 through REQ-026 against actual source code on `slices/jido-migration`.
**Method:** 10 parallel scout agents read source files directly; no document inference.

---

| Category | Count | Verdict |
|----------|-------|---------|
| ✅ Fully implemented, gap-free | 16 | Complete |
| 🔴 **Critical gap** — missing dep or supervision | 2 | BLOCKED |
| 🟡 **High-priority gap** — defined but unwired | 4 | Unblocked |
| 🟠 **Medium gap** — partial completion | 1 | Deferred |
| ⚠️ **Previously flagged, now corrected** | 2 | False positive |

**Total: 26 REQs assessed. Prior report had 14 Complete — corrected to 16.**

---

## Critical Gaps (Must Fix Before Ship)

### REQ-010: jido_mcp Missing from mix.exs — 🔴 VERIFIED

**Gap:** `jido_mcp` is documented in `JIDO_FORKS.md` (SHA `8986c4cb...`) but NOT declared in `packages/foreman_server/mix.exs`.

**Evidence:**
- `packages/foreman_server/mix.exs:20-50`: Only 10 Jido packages declared. `jido_mcp` is absent.
- `packages/foreman_server/lib/foreman_server/agents/mcp_client_pool.ex:3`: Moduledoc references jido_mcp but dep unavailable.
- `JIDO_FORKS.md:40-41`: Fork URL and SHA correctly documented.

**Impact:** `McpClientPool.safe_tools/1` returns hardcoded `[]`. MCP-T001–T007 (REQ-010) cannot function.

**Fix:** Add to `mix.exs` deps:
```elixir
{:jido_mcp, git: "https://github.com/Sunstone-Partners/jido_mcp", ref: "8986c4cbf4f5e89d9f9a7a4c096d45e45a514863", override: true}
```

---

### REQ-011: DirectiveQueue + SignalJournal Not in Supervision Tree — 🔴 VERIFIED

**Gap:** Both GenServers are fully implemented and referenced by production code, but never started as children in `ForemanServer.Application`.

**Evidence:**
- `packages/foreman_server/lib/foreman_server/application.ex:13-161`: No `DirectiveQueue` or `SignalJournal` in children list or `maybe_*_child` functions.
- `packages/foreman_server/lib/foreman_server/agents/signal_directive_publisher.ex:33,40,96,108`: Calls `DirectiveQueue.enqueue/2` and `mark_dispatched/1`.
- `packages/foreman_server_web/live_dashboard.ex:32,149,156,160,163`: Calls `DirectiveQueue.queued/0` and `SignalJournal.replay/2`.

**Impact:** Dashboard crashes on data query; directives cannot be enqueued. `SignalJournal` provides no replay on restart.

**Fix:** Add to `ForemanServer.Application.start/2` children (gated on `agent_runtime :enabled` config):
```elixir
{ForemanServer.Agents.DirectiveQueue, []},
{ForemanServer.Agents.SignalJournal, []},
```

---

## High-Priority Gaps (Infrastructure Exists, Not Wired)

### REQ-007: Jido Shell Integration — ✅ PREVIOUS FLAG WAS FALSE POSITIVE

**Correction:** `JidoShellRunner` is NOT a stub. The previous verification report was incorrect.

**Evidence from code read:**
- `packages/foreman_server/lib/foreman_server/agents/jido_shell_runner.ex:105`: `Jido.Shell.Agent.new(workspace_id)` — creates real shell sessions.
- `jido_shell_runner.ex:81`: `Jido.Shell.Agent.run(session_id, command, opts)` — executes commands.
- `jido_shell_runner.ex:119,133`: `Jido.Shell.Agent.stop(session_id)` — proper lifecycle teardown.
- `jido_shell_runner.ex:156`: `Jido.Shell.run(cmd, args, cwd: cwd, vfs_root: vfs_root)` — ad-hoc execution.

**Verdict:** Full implementation. GenServer session registry with owner-process monitoring and automatic cleanup. ✅

---

### REQ-008: jido_ai_runner Not Wired to Agent Startup — 🟡 VERIFIED GAP

**Gap:** `JidoAiRunner` exists with unit tests, but `RunExecutor` never calls it. Strategy is hardcoded to `:manual`.

**Evidence:**
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:421-427`:
  ```elixir
  AgentRuntime.execute(
    prompt,
    request.context,
    backend: execution_backend(),
    strategy: :manual,  # ← HARDCODED
    ...
  )
  ```
- `packages/foreman_server/lib/foreman_server/agent_runtime/jido_supervisor.ex:75-90`: `start_agent/1` never passes `:strategy` to `Jido.AgentServer`.
- `packages/foreman_server/lib/foreman_server/agent_runtime.ex:48-161`: `execute/3` recognizes `:manual`, `:automatic`, `:policy` — not `:react` or `:cot`.

**Impact:** ReAct and ChainOfThought reasoning strategies are untested in production. `Jido.AI.Reasoning.ReAct` and `Jido.AI.Reasoning.ChainOfThought` are never invoked from the workflow path.

---

### REQ-009: litellm_router Not Called in LLM Path — 🟡 VERIFIED GAP

**Gap:** `LitellmRouter.route/2` is defined with passing tests, but zero production call sites. LLM calls bypass the router entirely.

**Evidence:**
- `packages/foreman_server/lib/foreman_server/agents/jido_ai_runner.ex:29-39,52,67-69`: `run/3` calls `Jido.AI.Reasoning.ReAct` directly — no `LitellmRouter.route/2` call.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:911-928`: `base_context/4` never invokes router.
- `packages/foreman_server/config/config.exs:77-83`: `litellm` config exists (`endpoint: "http://localhost:4000"`, `model: "auto"`) but never used.

**Actual LLM flow:** `RunExecutor → AgentRuntime.execute → JidoAiRunner.run → Jido.AI.Reasoning.ReAct → req_llm` (endpoint source unknown; bypasses `LitellmRouter`).

---

### REQ-012: otel_span_emitter Not Called from Production Paths — 🟡 VERIFIED GAP

**Gap:** `OtelSpanEmitter.emit_cmd_span/3`, `emit_llm_span/4`, `emit_signal_span/3` are defined but never invoked.

**Evidence from codebase scan:**
- No calls to `OtelSpanEmitter` or `emit_*_span` anywhere in `lib/foreman_server/`.
- `packages/foreman_server/lib/foreman_server/agents/otel_span_emitter.ex`: Functions defined with correct signatures.
- `packages/foreman_server/mix.exs:64`: `jido_otel` dependency declared.
- `packages/foreman_server/config/config.exs:73-75`: OTLP endpoint configured.

**Impact:** Zero OTEL spans emitted for cmd/2, LLM calls, or signal dispatch. NFR-09 (signal trace 100% in Langfuse) unsatisfied.

---

### REQ-018: Repo Mirroring CI Trigger Mechanism Missing — 🟡 PARTIAL GAP

**Gap:** Workflow infrastructure exists but automated trigger is missing.

**Evidence:**
- `.github/workflows/jido-upstream-upgrade.yml`: GitHub Actions workflow present. Runs `scripts/ci/jido-upgrade-evaluation.sh`.
- `scripts/ci/jido-upgrade-evaluation.sh`: Full evaluation script (exit 0=adopt, 1=reject, 2=error).
- `JIDO_FORKS.md`: Documents 13 forked packages with SHAs.

**Gap:** No code watches upstream Jido repos and sends `repository_dispatch` event with `type=jido_release`. Workflow is manual-only (`workflow_dispatch` trigger). `TRD-081` (JRM-T003) remains `[ ]` in the source TRD.

**Verdict:** Script and CI infra present; automation trigger not built.

---

### REQ-020: langfuse_tracer Not Called in Production Path — 🟡 VERIFIED GAP

**Gap:** `LangfuseTracer` and `emit_routing_metadata/3` are defined but never invoked.

**Evidence:** `LangfuseTracer` defined with correct fields (`routed_to`, `routing_reason`). No production call sites found. Blocked on REQ-009 wiring.

---

## Medium Gaps

### REQ-002: Only 2/10+ Actions Migrated — 🟠 VERIFIED GAP

**Gap:** TRD-012 (JAF-T002) marked `[x]` complete. Actual implementation: 2 of N actions.

**Evidence:**
- `packages/foreman_server/lib/foreman_server/actions/git_status_action.ex`: ✅ `GitStatusAction` — git porcelain.
- `packages/foreman_server/lib/foreman_server/actions/read_prompt_action.ex`: ✅ `ReadPromptAction` — workflow prompt loader.
- `packages/foreman_server/lib/foreman_server/application.ex:57`: Only these two registered.
- PRD-4212be7e §3.0 requires: `git_status`, `diff_read`, `task_get`, and "etc." — none of the remaining tools migrated.

**Verdict:** Gap confirmed. `diff_read`, `task_get`, and remaining TypeScript tool factories are MISSING.

---

## Corrected: Previously Flagged, Now Verified

### REQ-023: Latency Regression Tests — ✅ TESTS PRESENT

**Correction:** Previous report flagged this as missing. Tests DO exist.

**Evidence:**
- `packages/foreman_server/test/foreman_server/agents/jido_signal_latency_test.exs`: 1000 signals, p95 < 1000ms. LGC-T005.
- `packages/foreman_server/test/foreman_server/agents/signal_latency_regression_test.exs`: 500 signals, p95 < 1000ms regression gate. LGC-T007.
- `packages/foreman_server_web/test/foreman_server_web/operator_inbox_latency_test.exs`: 500 requests, p95 < 1000ms. LGC-T006.
- `packages/foreman_server_web/test/foreman_server_web/operator_inbox_latency_regression_test.exs`: 200 requests, p95 regression gate.
- `packages/foreman_server_web/test/foreman_server_web/dashboard_refresh_latency_test.exs`: Dashboard render < 1000ms. JLD-T003.

**Architecture:** `:timer.tc` microsecond precision, percentile computed via `Enum.at` on sorted latency list. `:latency_regression` tag for CI gating.

---

## Verified Complete (No Gaps)

| REQ | Requirement | Evidence |
|-----|-------------|----------|
| REQ-001 | Jido Core Runtime | mix.exs deps, JidoSupervisor, signal_to_command_adapter, jido_ecto |
| REQ-003 | Jido Harness Pi Adapter | pi.ex, pi_rpc.ex, adapter_test.exs, pi_rpc_session_test.exs |
| REQ-004 | Signal Bus | jido_signal_topics.ex, signal_agent_publisher.ex, operator_question_subscriber.ex |
| REQ-005 | Operator Communication | Full bidirectional flow: question → inbox event → projector → directive |
| REQ-006 | Agent↔Foreman Communication | signal_directive_publisher, task_metadata_query_subscriber |
| REQ-007 | Jido Shell Integration | ✅ CORRECTED — Full Jido.Shell.Agent integration, not a stub |
| REQ-013 | Workflow Dispatch — create | prd.yaml, step_idempotency.ex, dispatcher.ex |
| REQ-014 | Workflow Dispatch — implement | implement-trd.yaml, implement-trd-beads.yaml |
| REQ-015 | Workflow Dispatch — fix | fix.yaml |
| REQ-016 | Merge Gate | merge_gate.ex, approver_authorizer.ex, merge_tool_refuser.ex, security events |
| REQ-017 | Resumable Execution | idempotency_key.ex, heartbeat_lease.ex, crash_recovery.ex, restart_backoff.ex |
| REQ-019 | Action Development Speed | representative_action_timing_test.exs, upgrade_compatibility_test.exs |
| REQ-021 | Security Isolation | vfs_isolation.ex, mcp_allowlist.ex, policy.ex, security_isolation_test.exs |
| REQ-022 | Legacy Removal | pi-sdk-runner.ts removed, jido_harness replaces it |
| REQ-023 | Signal Latency Tests | ✅ CORRECTED — 5 latency test files with p95 < 1000ms gates |
| REQ-024 | Characterization Harness | implement_fix_characterization_test.exs, adapter_test.exs |
| REQ-025 | Hot-Loadable Workflows | catalog.ex, validator.ex, workflow_template_test.exs |
| REQ-026 | Ensemble --foreman Idempotency | StepIdempotency + HeartbeatLease + CrashRecovery infrastructure |

---

## Gap Summary (Definitive)

| Priority | REQ | Gap | Fix Required |
|----------|-----|-----|-------------|
| 🔴 Critical | REQ-010 | `jido_mcp` missing from `mix.exs` | Add dependency line |
| 🔴 Critical | REQ-011 | `DirectiveQueue` + `SignalJournal` not supervised | Add to Application children |
| 🟡 High | REQ-008 | `JidoAiRunner` not called; `:manual` hardcoded | Wire strategy selection |
| 🟡 High | REQ-009 | `LitellmRouter` not called in LLM path | Add route/2 call site |
| 🟡 High | REQ-012 | `OtelSpanEmitter` spans never emitted | Add call sites in cmd/2, LLM, signal paths |
| 🟡 High | REQ-018 | CI trigger mechanism absent | Build upstream release watcher |
| 🟡 High | REQ-020 | `LangfuseTracer` not called | Wire after REQ-009 fixed |
| 🟠 Medium | REQ-002 | Only 2/N actions migrated | Complete `diff_read`, `task_get`, etc. |

---

## Recommendations (Priority Order)

1. **Immediate:** Add `jido_mcp` to `mix.exs` deps — unblocks entire MCP client pool.
2. **Immediate:** Add `DirectiveQueue` and `SignalJournal` to `ForemanServer.Application` children — unblocks dashboard and directive queueing.
3. **High:** Wire `LitellmRouter.route/2` into LLM execution path — enables LiteLLM auto-routing.
4. **High:** Add OTEL span instrumentation call sites — satisfies NFR-09.
5. **High:** Wire `JidoAiRunner` strategy selection into `RunExecutor` — enables ReAct/CoT.
6. **High:** Build upstream release watcher for Jido repos — enables automated CI on upstream release.
7. **Medium:** Complete remaining Jido.Action migrations (`diff_read`, `task_get`, etc.).
