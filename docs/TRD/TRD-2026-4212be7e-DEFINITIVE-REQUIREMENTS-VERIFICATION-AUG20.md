# TRD-2026-4212be7e — Definitive Requirements Verification (Code-First)
**Date:** 2026-08-20
**Verified by:** Independent code-first verification (no document claims accepted as evidence)
**HEAD:** `eb8f81c4`

---

## Verdict Summary

| Verdict | Count | REQs |
|---------|-------|------|
| ✅ Verified complete | 23 | 001, 003–008, 010–019, 021–026 |
| 🟡 Partial — 2/4 actions migrated | 1 | 002 |
| 🟡 Partial — routing works via config, prescriptive API unused | 1 | 009 |
| ❌ Incomplete — defined but never called in production | 1 | 020 |

**Total: 26 REQs. 23 Complete. 2 Partial. 1 Incomplete.**

---

## 🔴 REQ-020: Langfuse Tracing — INCOMPLETE

**TRD claim:** Langfuse tracing for all LLM calls, routing metadata in traces.

### Evidence

| What | Where | Status |
|------|-------|--------|
| `LangfuseTracer` module | `lib/foreman_server/agents/langfuse_tracer.ex` | Defined, returns stub structs |
| `emit_trace/6` | `langfuse_tracer.ex:6` | Never called in `lib/` |
| `emit_routing_metadata/3` | `langfuse_tracer.ex:25` | Never called in `lib/` |
| Test calls | `test/.../langfuse_tracer_test.exs:7,23,33` | ✅ Only in tests |
| `OtelSpanEmitter.emit_llm_span/4` | `agent_runtime.ex:677,692,752,767` | ✅ In production |

### Root Cause

`LangfuseTracer` is a stub module — it returns `{:ok, trace}` structs but makes zero Langfuse API calls. The actual LLM span emission uses `OtelSpanEmitter`, which writes OTEL-compatible spans (satisfying REQ-012) but does NOT write to Langfuse.

### Fix Required

Wire `LangfuseTracer.emit_trace/6` into `AgentRuntime.execute_react/6` and `execute_cot/6` alongside the existing `OtelSpanEmitter.emit_llm_span` calls. Both functions are already at the correct call sites — only the Langfuse integration is missing.

---

## 🟡 REQ-002: Jido Action Framework — PARTIAL

**TRD claim:** Migrate existing TypeScript tool factories to Jido.Action modules (git_status, diff_read, task_get, etc.)

### Evidence

| Action | File | Status |
|--------|------|--------|
| `git_status` | `lib/foreman_server/actions/git_status_action.ex` | ✅ Implemented + registered |
| `read_prompt` | `lib/foreman_server/actions/read_prompt_action.ex` | ✅ Implemented + registered |
| `diff_read` | **MISSING** | ❌ No such file anywhere in `lib/` |
| `task_get` | **MISSING** | ❌ No such file anywhere in `lib/` |

### Evidence Details

- Registry (`application.ex:~57`): only `GitStatusAction` and `ReadPromptAction` registered
- `git_status_action.ex:7` moduledoc: explicitly acknowledges `diff_read` and `task_get` are future work
- grep `diff_read` and `task_get` in `lib/` → **0 matches** outside that moduledoc comment

### Root Cause

TRD-012 (JAF-T002) was marked `[x]` (complete) but only 2 of 4 named actions are implemented. The TRD task table checkbox does not match the actual code.

### Fix Required

Either:
1. Implement `diff_read_action.ex` and `task_get_action.ex` per JAF-T002 specification, OR
2. Update TRD §3 acceptance table: REQ-002 → `[~] Partial (2/4 actions)` with a note

---

## 🟡 REQ-009: LiteLLM Integration — PARTIAL

**TRD claim:** LiteLLM gateway with model="auto" routing, Langfuse tracing, zero-candidates error, unavailable fallback.

### Evidence

| Component | File | Production Call Sites |
|-----------|------|----------------------|
| Auto-routing (config) | `config.exs:97-104` | ✅ `jido_ai` model_aliases maps `"auto"` → LiteLLM |
| `JidoAiRunner.run/3` | `jido_ai_runner.ex:53-79` | ✅ Called from `agent_runtime.ex` |
| `LitellmRouter.route/2` | `litellm_router.ex:38` | **0** — dead code |
| `LangfuseTracer.emit_trace/6` | `langfuse_tracer.ex:6` | **0** — dead code |
| `ZeroCandidatesHandler.format_error/1` | `zero_candidates_handler.ex` | **0** — dead code |
| `LitellmUnavailableHandler.handle/1` | `litellm_unavailable_handler.ex` | **0** — dead code |

### Root Cause

The functional requirement (LiteLLM auto-routing) works via `config.exs` model_aliases — this is production-quality. However, the prescriptive architectural API (`LitellmRouter`, error handlers) was defined and tested but never wired into the runtime.

### Fix Required

Either:
1. Wire `LitellmRouter.route/2` into `AgentRuntime` and connect error handlers to LLM failure paths, OR
2. Remove dead code (LitellmRouter, error handlers) and update §3 to `[~] Partial`

---

## ✅ Verified Complete REQs (23)

| REQ | Component | Evidence |
|-----|-----------|----------|
| 001 | Jido Core Runtime | `mix.exs` packages, `AgentRuntime.Supervisor`, `SignalToCommandAdapter`, `JidoCheckpointStore.Repo` — all wired |
| 003 | Jido Harness Adapter | `JidoHarnessAdapter` + `Driver` + `Session` + `Process` + `Run` — all implemented, `BackendAdapter` behaviour satisfied |
| 004 | Inter-Agent Communication | `JidoSignalTopics`, `SignalAgentPublisher`, `SignalDirectivePublisher` — topics registered |
| 005 | Agent↔Operator | `OperatorQuestionSubscriber`, `OperatorTimeout`, workflow-configurable timeouts |
| 006 | Agent↔Foreman | `DirectivePublisher`, `TaskMetadataQuerySubscriber` |
| 007 | Jido Shell | `JidoShellRunner` (session lifecycle via `Process.monitor`), `VfsIsolation` (allowed?/2) |
| 008 | Jido AI Strategy | `JidoAiRunner.run_react/2` → `Jido.AI.Reasoning.ReAct.run/3` |
| 010 | MCP Client | `mcp.ex` (Anubis.Server), `McpClientPool`, `McpAllowlist`, `McpToolSync`, `McpDiagnostics` |
| 011 | Live Dashboard | `LiveDashboard` at `/dashboard`, 4 sections, <1000ms refresh |
| 012 | OpenTelemetry | `OtelSpanEmitter` — `jido.cmd`, `jido.llm`, `jido.signal` spans in production call paths |
| 013 | Workflow Dispatch — create | `Dispatcher`, `StepSequencer`, `StepIdempotency`, 5-phase ensemble chain |
| 014 | Workflow Dispatch — implement | `--foreman` dispatch, `implement-{taskId}-1` key |
| 015 | Workflow Dispatch — fix | `--foreman` dispatch, `fix-{taskId}-1` key |
| 016 | Merge Gate | `MergeGate` (GenServer+ETS), `ApproverAuthorizer`, `MergeToolRefuser` |
| 017 | Resumable Execution | `KeyStore` (started/completed/ambiguous), `HeartbeatLease`, `CrashRecovery`, `RestartBackoff` (5 retries) |
| 018 | Jido Repo Mirroring | 12 Jido packages in `mix.exs`, fork URLs + pinned SHAs, `trigger-jido-upgrade.sh` |
| 019 | Action Dev Speed Target | Timing test + upgrade compatibility test |
| 021 | Security — Agent Isolation | `VfsIsolation.allowed?/2`, `McpPolicy.deny-default`, security integration test |
| 022 | Legacy Backend Removal | `pi-sdk-runner.ts` absent, replaced by `JidoHarnessAdapter` + `Driver` |
| 023 | Signal Delivery Latency | `signal_latency_regression_test.exs` (p95 <1000ms gate), 4 latency test files |
| 024 | Characterization Harness | 3 characterization test files (805 lines for implement+fix) |
| 025 | Hot-Loadable Workflows | `Workflow.Loader`, `Workflow.Validator`, `Workflow.Catalog` (GenServer, poll, auto-install) |
| 026 | Ensemble --foreman Idempotency | `StepIdempotency.make_key/3`, `HeartbeatLease`, `CrashRecovery` reconciliation |

---

## Gap Summary

| Priority | REQ | Gap | Fix |
|----------|-----|-----|-----|
| 🔴 High | 020 | `LangfuseTracer` defined but never called; Langfuse NOT written in production | Wire `emit_trace/6` into `AgentRuntime.execute_react/6` and `execute_cot/6` |
| 🟡 Medium | 002 | `diff_read_action.ex` and `task_get_action.ex` absent; TRD checkbox misaligned | Implement missing actions OR update TRD §3 to `[~] Partial` |
| 🟡 Low | 009 | `LitellmRouter.route/2` + error handlers defined but never called; config-based routing works | Wire prescriptive API into `AgentRuntime` OR remove dead code |
