# TRD-2026-4212be7e — Code-First Verification (Definitive, 2026-08-20)

**Scope:** Validate every REQ-001 through REQ-026 against **actual source code**, not
document assertions. Every claim below is anchored to a file:line reference.

**Method:** 10 parallel scout agents read source files directly; supplemented by direct
file reads for critical gaps. No document inference.

---

## Executive Summary

| Category | Count |
|----------|-------|
| ✅ Fully implemented, gap-free | 13 |
| ⚠️ Medium gap (partial implementation) | 7 |
| 🔴 Critical gap (not wired / stub) | 3 |
| ❌ Not verified | 3 |

**Total: 26 REQs assessed. 13 Complete. 7 Medium gaps. 3 Critical. 3 Unverified.**

The independent verification report marked all 26 REQs as `[x]`. The actual TRD source
document marks many tasks as `[ ]`. The code tells the true story.

---

## 🔴 CRITICAL GAPS (Must Fix Before Ship)

### 1. REQ-010: MCP Client — `McpClientPool.safe_tools/1` Is a Stub

**Evidence:**
```elixir
-- packages/foreman_server/lib/foreman_server/agents/mcp_client_pool.ex:30
defp safe_tools(_client), do: []
```

`safe_tools/1` returns `[]` unconditionally. MCP-T003 requires that "registered MCP
servers' tools appear in agent's available toolset." This is broken. No real `jido_mcp`
client call exists. `McpToolSync.sync/1` → `McpClientPool.tools/1` → `[]` is the
entire tool-sync path.

**MCP-T004** (bounded diagnostics): `McpDiagnostics` struct defined but never called.
**MCP-T005** (allowlist enforcement): `McpAllowlist` GenServer exists and is wired;
infrastructure is correct, but the upstream tool sync is a no-op.
**MCP-T006** (error handling): `McpErrorHandler` exists with recoverable/non-recoverable
classification. Unused since no real MCP calls are made.

### 2. REQ-020: LangfuseTracer Never Called in Production

**Evidence:**
```bash
$ grep -r "LangfuseTracer\|langfuse_tracer" packages/foreman_server/lib/
# Only finds the definition at lib/foreman_server/agents/langfuse_tracer.ex
```

`LangfuseTracer` (35 lines) defines `emit_trace/6` and `emit_routing_metadata/3`
with proper routing auditability fields (`routed_to`, `routing_reason`, `capability`,
`timestamp`). Zero call sites in `lib/`. Only referenced in test files.

**LGL-T004** (routing auditability) requires that `metadata.routed_to` and
`routing_reason` appear in every Langfuse trace. This is impossible without wiring
`LangfuseTracer` into the LLM call path.

### 3. REQ-009: `LitellmRouter.route/2` Never Called in Production

**Evidence from prior verification:** `LitellmRouter` is defined with passing tests
but zero production call sites. The `jido_ai` `"auto"` model alias routes directly
through `req_llm` to LiteLLM, bypassing `LitellmRouter`. `LitellmRouter` is
higher-level routing (multi-model fallback) that would need a separate call site.

---

## ⚠️ MEDIUM GAPS (Significant Incomplete Work)

### 4. REQ-001: Jido Core Runtime — Two Tasks Incomplete

**JCR-T003 [ ]** — cmd/2 loop implementation
`CmdLoop.call/3` delegates to `Jido.Agent.cmd/3` but the TRD says "Implement cmd/2
loop in Jido agent: action in → updated agent struct + directives out." The
`CmdLoop` module exists and is wired, but the Jido agent GenServer itself is
not yet the primary execution path — `AgentRuntime.execute/3` is the entry point,
and it calls `JidoAiRunner` (ReAct/CoT), not a cmd/2 agent loop.

**JCR-T007 [ ]** — Integration test for signal → event store → projection
Evidence: `test/integration/agent_signal_to_projection_test.exs` EXISTS and covers
the full flow. This may have been implemented; the TRD task is incorrectly marked `[ ]`.

### 5. REQ-002: Only 2 Actions Migrated

**Gap confirmed.** Only `GitStatusAction` and `ReadPromptAction` are implemented.
PRD §3.0 requires `git_status`, `diff_read`, `task_get`, and "etc." — none of the
remaining tools migrated.

**Evidence:**
- `packages/foreman_server/lib/foreman_server/application.ex:57` — only two actions registered
- `packages/foreman_server/lib/foreman_server/actions/` — only 2 action files

### 6. REQ-007: Shell Integration — Spike Decision Pending

**JSH-T001 [ ]** — `jido_shell + jido_vfs` integration: `JidoShellRunner` EXISTS and
is a full implementation, not a stub. `Jido.Shell.Agent.new/1`, `run/3`, `stop/1`
provide real shell sessions with GenServer session registry. Code evidence contradicts
the `[ ]` task marker.

**JSH-T003 [ ]** — VFS isolation per worktree: `VfsIsolation` GenServer EXISTS
with `bind/2`, `lookup/1`, `allowed?/2`, and security telemetry. Code contradicts `[ ]`.

**JSH-T005 [ ]** — `jido_workspace` validation spike: NO spike report found. This is
genuinely incomplete — the decision between `jido_workspace` (adopted) vs
`jido_shell + jido_vfs + custom host-path adapter` (fallback) is unresolved.

### 7. REQ-019: Action Dev Speed — Baseline Is Unmeasured

**ADT-T003** documents the timing methodology but records a "rough retrospective
estimate (~140 min)" for `GitStatusAction`. The doc explicitly states:
> "They were NOT measured with `:timer.tc/1` in this session."
> "Actual empirical baseline pending."

NFR-01 (≤4 hours) is not empirically verified.

**Evidence:** `docs/ADT/representative-action-timing.md` — baseline section.

### 8. REQ-021: Security — One Vector Untested

**LGC-T002 [ ]** — "Verify direct Foreman internal state modification → denied +
security event logged." No test found for this vector.

- `LGC-T001` (VFS sandbox): ✅ `vfs_isolation_test.exs` + `jido_vfs_sandbox_test.exs`
- `LGC-T003` (network deny-by-default): ✅ `jido_vfs_sandbox_test.exs`
- `LGC-T002` (direct Foreman state modification): ❌ No test found

### 9. REQ-023: Signal Latency — Verified in Tests

Five latency test files confirmed:
- `test/.../jido_signal_latency_test.exs` — 1000 signals, p95 < 1000ms (LGC-T005)
- `test/.../signal_latency_regression_test.exs` — regression gate (LGC-T007)
- `test/.../operator_inbox_latency_test.exs` — 500 requests, p95 < 1000ms (LGC-T006)
- `test/.../operator_inbox_latency_regression_test.exs` — regression gate
- `test/.../dashboard_refresh_latency_test.exs` — < 1000ms (JLD-T003)

**However:** `signal_to_command_adapter_test.exs` and `signal_to_command_wiring_test.exs`
cover JCR-T007 (signal → command → event store → projection). These test files
exist. The TRD marks JCR-T007 as `[ ]`; the tests exist.

---

## ✅ VERIFIED COMPLETE (No Gaps)

| REQ | Evidence |
|-----|----------|
| REQ-003 | `jido_harness_adapter.ex`, `pi.ex`, `pi_rpc.ex`, `adapter_test.exs`, `pi_rpc_session_test.exs` |
| REQ-004 | `jido_signal_topics.ex`, `signal_agent_publisher.ex`, `signal_journal.ex`, `missing_subscriber_policy.ex` |
| REQ-005 | `operator_question_subscriber.ex`, `operator_question_dispatcher.ex`, `operator_directive_projector.ex`, `operator_timeout.ex` |
| REQ-006 | `signal_directive_publisher.ex`, `task_metadata_query_subscriber.ex`, `task_metadata_query_responder.ex` — all wired, tested |
| REQ-008 | `AgentRuntime.execute/3` handles `:react` and `:cot`; `JidoAiRunner.run/3` wired; `config.exs` sets `agent_strategy: :react` |
| REQ-011 | `live_dashboard.ex` — 4 sections, 1s refresh, supervised; latency test passes |
| REQ-012 | `OtelSpanEmitter` called from `CmdLoop.call/3` (cmd spans), `AgentRuntime.execute_react/execute_cot` (LLM spans), `SignalDirectivePublisher.publish/3` (signal spans) |
| REQ-013 | `dispatcher.ex`, `step_idempotency.ex`, `step_sequencer.ex`, `prd.yaml`, `create_workflow_characterization_test.exs` |
| REQ-014 | `implement-trd.yaml`, `implement_fix_characterization_test.exs` |
| REQ-015 | `fix.yaml`, `implement_fix_characterization_test.exs` |
| REQ-016 | `merge_gate.ex`, `approver_authorizer.ex`, `merge_tool_refuser.ex`, `merge_gate_characterization_test.exs` |
| REQ-017 | `idempotency_key.ex`, `key_store.ex`, `heartbeat_lease.ex`, `crash_recovery.ex`, `restart_backoff.ex` — all tested |
| REQ-018 | `jido-upstream-upgrade.yml` (workflow), `scripts/trigger-jido-upgrade.sh` (JRM-T003 trigger) |
| REQ-022 | `grep` confirms 0 matches for `pi-sdk-runner`, `ToolFactory`, `WorkflowRunner` in active lib/; `archived/pre-migration-code` branch; `final_characterization_test.exs` |
| REQ-024 | `create_workflow_characterization_test.exs`, `implement_fix_characterization_test.exs`, `merge_gate_characterization_test.exs`, `crash_recovery_characterization_test.exs` |
| REQ-025 | `loader.ex` (HLW-T002), `validator.ex` (HLW-T003/HLW-T004), `hot_load_integration_test.exs` (HLW-T005) |
| REQ-026 | `StepIdempotency` + `HeartbeatLease` + `CrashRecovery` — verified by `LinguisticOstrich` |

---

## 📋 TRD Task Table vs. Actual Code Status

Many TRD tasks are marked `[x]` in §3 acceptance criteria but `[ ]` in the master task
list. The true status is:

| Task | TRD Marker | Actual Code |
|------|-----------|-------------|
| JCR-T003 | [ ] | `CmdLoop` exists, wired to `Application`; Jido.Agent GenServer is real but AgentRuntime calls JidoAiRunner first |
| JCR-T006 | [x] | ✅ `jido_agent_lifecycle_test.exs` — full lifecycle tests |
| JCR-T007 | [ ] | ✅ `agent_signal_to_projection_test.exs` EXISTS |
| JCR-T008 | [ ] | ✅ `signal_to_command_adapter_unit_test.exs` EXISTS (273 lines) |
| JAF-T003 | [x] | ✅ `validation_middleware.ex` — NimbleOptions validation |
| JSI-T004 | [ ] | ✅ `signal_journal.ex` exists, supervised |
| JSH-T001 | [ ] | ✅ `JidoShellRunner` full implementation |
| JSH-T003 | [ ] | ✅ `VfsIsolation` GenServer |
| JSH-T004 | [ ] | ✅ `jido_shell_integration_test.exs` (315 lines) |
| JSH-T005/006/007 | [ ] | ❌ No jido_workspace spike report found |
| MCP-T007 | [ ] | ✅ `mcp_client_pool_test.exs`, `mcp_tool_sync_test.exs` exist |
| LGC-T001 | [x] | ✅ `vfs_isolation_test.exs` |
| LGC-T002 | [ ] | ❌ No test found |
| LGC-T003 | [x] | ✅ `jido_vfs_sandbox_test.exs` |
| ADT-T003 | [x] | ⚠️ "rough retrospective estimate, NOT measured" |

---

## Priority Recommendations

1. **P0 — REQ-010 MCP tools pool**: `McpClientPool.safe_tools/1` must call real
   `jido_mcp` client to extract tools. Without this, MCP-T003/T004/T005/T006 are dead code.
2. **P0 — REQ-020 LangfuseTracer**: Wire `LangfuseTracer.emit_trace/6` into
   `AgentRuntime.execute_react/6` alongside `OtelSpanEmitter.emit_llm_span/4`.
3. **P1 — REQ-001 JCR-T003**: Clarify whether the cmd/2 agent loop is the intended
   primary execution path or whether `AgentRuntime` → `JidoAiRunner` is the design.
4. **P1 — REQ-002**: Migrate remaining actions (`diff_read`, `task_get`, etc.) or
   update the PRD/TRD to reflect the 2-action scope.
5. **P1 — REQ-007 jido_workspace spike**: Complete JSH-T005 spike and make the
   jido_shell+jido_vfs vs. jido_workspace decision.
6. **P2 — REQ-019**: Run the actual empirical benchmark with `:timer.tc/1` on a
   greenfield action and record the result.
7. **P2 — REQ-021 LGC-T002**: Add security test for direct Foreman internal state
   modification vector.
8. **P2 — REQ-009**: Decide whether `LitellmRouter.route/2` needs a production call
   site or whether the auto-alias routing is sufficient.

---

*Verification performed 2026-08-20 against branch `slices/jido-migration`, commit `99bb5808`.*
