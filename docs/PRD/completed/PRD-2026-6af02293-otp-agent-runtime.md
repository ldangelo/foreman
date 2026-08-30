---
document_id: PRD-2026-6af02293
version: 1.0.0
status: Ready for Implementation
date: 2026-07-29
scale_depth: LIGHT
total_requirements: 9
readiness_score: 4.0
---

# PRD: OTP Agent Runtime — Swappable Backend Adapters

## PRD Health Summary

| Priority | Count |
|---|---|
| Must | 6 |
| Should | 2 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---|
| AC coverage | 9/9 (100%) |
| Risk flags | 3 |
| Dependencies | 4 |
| Open ambiguity markers | 0 |
| Resolved ambiguity markers | 11/11 |


---

## 1. Executive Summary

**What this PRD defines:** an OTP-supervised agent runtime with a clean separation between the **runtime contract** (prompt → text output + status) and **backend adapters** (pi, claude code, codex, goose, opencode). The runtime contract is opaque to callers — callers do not know or care which backend fulfilled a task. The `pi` adapter is required; all others are pluggable examples.

**Why it exists:** to provide supervised, recoverable agent execution where backends can be swapped at runtime without callers noticing, and to support multi-agent routing via automatic, manual, or policy-driven selection.

---

## 2. Background and Evidence

**The problem:** agent invocations are ad-hoc shell calls — no supervision, no recovery, no routing logic, and no way to compare backends without rewriting caller code.

**What this runtime must provide:**
- OTP supervision so crashed agents are restarted automatically
- A stable runtime contract so callers are decoupled from backend implementation
- Swappable adapters so `pi`, `claude code`, `codex`, `goose`, `opencode` (or new backends) can be used interchangeably
- Routing strategies: automatic (capability-based), manual (operator-selected), and policy-driven (rules file)
- Failure handling: configurable retry, fallback, and reject-all behavior per task type
- Local and remote execution depending on backend capability

---

## 3. Requirements

### 3a. Runtime Contract

The runtime contract is the interface callers use. Backends are a pure implementation detail hidden behind it.

### REQ-001: Must | High | Agent runtime contract
The runtime MUST provide a stable `AgentRuntime` behaviour — a function `execute(prompt, context, opts) -> {:ok, result} | {:error, reason}` — that callers invoke regardless of which backend is selected.

- AC-001-1: Given a caller invokes `AgentRuntime.execute/3`, when a backend is selected, then the caller's prompt and context are passed to the backend adapter and the result (or error) is returned to the caller — the caller does not know which backend was used
- AC-001-2: Given a task is submitted, when no backend is configured or all configured backends are unavailable, then the runtime returns `{:error, :no_available_backend}` immediately — the runtime does not queue or block waiting for a backend to become available; callers needing that behaviour implement it externally
- AC-001-3: Given `AgentRuntime.execute/3` is called, when the selected backend returns a result, then the result is returned to the caller with a backend-agnostic status (:ok or :error) and the backend identifier is available in telemetry metadata only

### REQ-002: Must | High | Backend adapter behaviour
The runtime MUST define a `BackendAdapter` behaviour that all backend implementations must implement.

- AC-002-1: Given a new backend adapter implements the `BackendAdapter` behaviour, when it is registered, then it is available for selection without changing caller code
- AC-002-2: Given a backend adapter implements the `BackendAdapter` behaviour, when `execute/2` is called on it, then it returns `{:ok, output :: String.t(), metadata :: map()}` or `{:error, reason :: term()}`
- AC-002-3: Given a backend adapter requires local execution (e.g., pi), when `available?/0` is called, then it returns true if the local binary is present and executable — no credentials are required for a local backend
- AC-002-4: Given a backend adapter requires remote execution (e.g., claude code API), when `available?/0` is called, then it returns true if credentials are present and parseable — no live network call is made on every availability check; a separate async health check may run independently

---

### 3b. Required and Pluggable Adapters

`pi` is required. The others are example pluggable adapters; the runtime must not assume any of them are present.

### REQ-003: Must | High | `pi` backend adapter
The runtime MUST provide a `PiAdapter` that wraps the `foreman-worker-pi` CLI or equivalent local process.

- AC-003-1: Given `foreman-worker-pi` is installed and reachable, when `PiAdapter.execute/2` is called, then it spawns the pi process, streams output, and returns the final text result
- AC-003-2: Given the pi process exits with a non-zero code, when `PiAdapter` receives the exit signal, then it returns `{:error, {:non_zero_exit, code}}`
- AC-003-3: Given the pi process times out (per-task timeout), when the timeout elapses, then `PiAdapter` terminates the process and returns `{:error, :timeout}` — default timeout is 60 seconds; configurable globally via application environment (`config :foreman_server, PiAdapter, timeout_ms: 60_000`) and overridable per-call via `opts`

### REQ-004: Should | Medium | Pluggable backend adapters
The runtime SHOULD support `ClaudeCodeAdapter`, `CodexAdapter`, `GooseAdapter`, and `OpenCodeAdapter` as registered-but-optional backends.

- AC-004-1: Given a named adapter (e.g., `ClaudeCodeAdapter`) is not registered, when a caller requests it, then the runtime returns `{:error, :backend_not_found}` — not a crash
- AC-004-2: Given a named adapter is registered and its `available?/0` returns false, when a non-manual routing strategy (automatic or policy-driven) selects it, then the runtime treats it identically to a backend that returned an error — it skips to the next available backend (fallback chain) or returns `{:error, :no_available_backend}` if no backends remain; note: manual routing (AC-005-2) is exempt and returns `{:error, :backend_unavailable}` directly

---

### 3c. Routing Strategies

### REQ-005: Must | High | Routing strategy behaviour
The runtime MUST support three routing strategies selectable at runtime: automatic (capability-based), manual (operator-selected), and policy-driven (rules-based).


- AC-005-1: Given `strategy: :automatic`, when a task is submitted, then the runtime selects the backend by matching the caller's `task_type` hint (e.g., `:code`, `:planning`, `:review` from `opts[:task_type]`) against each backend's declared `supported_contexts` in its capability map, filtering to available backends, then applying the tiebreak rule
- AC-005-2: Given `strategy: :manual`, when a task is submitted with a named backend, then the runtime uses that backend if available, otherwise returns `{:error, :backend_unavailable}`
- AC-005-3: Given `strategy: :policy`, when a task is submitted, then the runtime evaluates a policy module (behaviour: `route(task_type, capabilities) → backend_name`) configured under `:foreman_server, :agent_runtime, :policy_module` and selects the backend the policy returns — no direct backend name in the caller request

### REQ-006: Must | Medium | Capability declaration
Each backend adapter MUST declare its capabilities at registration time.

- AC-006-1: Given a backend adapter registers, when it calls `AgentRuntime.register_adapter/2`, then it declares a capability map — `type` (e.g., `:code`, `:planning`, `:review`), `strengths` (list of atoms, e.g., `[:fast, :low_cost]`), `weaknesses` (list of atoms, e.g., `[:high_latency]`), and `supported_contexts` (list of task types the backend handles, e.g., `[:code, :review]`) are required; `cost_per_call` (float, arbitrary units) and `typical_latency_ms` (integer) are optional
- AC-006-2: Given two backends have equal declared capabilities for the requested task type, when automatic routing selects between them, then the tiebreak is: prefer available (online) backends first, then lower `cost_per_call` if declared, then lower `typical_latency_ms` if declared, then by earliest registration time — deterministic and stable; no randomness at any step

---

### 3d. Failure Handling

### REQ-007: Must | High | Automatic fallback on backend failure
When a selected backend fails, the runtime MUST attempt fallback to the next available backend if and only if the task's failure policy enables fallback for that task type — the fallback mechanism is always available; whether it fires is policy-controlled per task type.

- AC-007-1: Given a task is submitted and the selected backend returns an error, when fallback is enabled for that task type's failure policy, then the runtime selects the next highest-ranked available backend and retries — if the policy enables fallback but omits the attempt count, `max_attempts: 2` is used (initial + one fallback); an explicit `max_attempts` in the policy overrides this default
- AC-007-2: Given all registered backends return errors, when the final backend fails, then the runtime returns `{:error, :all_backends_failed, %{attempts: [backend_results]}}`
- AC-007-3: Given a task is submitted with `fail_on_unavailable: true`, when no backend is available, then the runtime returns `{:error, :no_available_backend}` immediately without queuing

### REQ-008: Should | Medium | Per-task-type failure policy
The runtime SHOULD allow failure policy to be configured per task type (e.g., code tasks retry 3x; planning tasks fail fast).

- AC-008-1: Given a task has an associated task type (e.g., :planning, :code, :review), when the task is submitted, then the runtime resolves the applicable failure policy for that type — retry count, fallback enabled, timeout
- AC-008-2: Given a task type has no configured policy, when the task fails, then the default policy applies: `fail_fast: true`, `max_attempts: 1` (no fallback retries), and `timeout_ms` from the global default — callers wanting different behaviour for a task type must register an explicit policy for that type

---

### 3e. Observability

### REQ-009: Could | Low | Telemetry and audit log
The runtime COULD expose telemetry for task execution — which backend, latency, success/failure, retry count.

- AC-009-1: Given a task executes, when it completes (success or error), then a Telemetry event is emitted with fields: backend, duration_ms, status, task_type
- AC-009-2: Given a task falls back to a second backend, when it completes, then the telemetry event records both backends attempted and which succeeded

---

## 4. Ambiguity Resolution Status

All 11 ambiguity markers are resolved:

| # | Item | Resolution |
|---|------|------------|
| 1 | AC-001-2 — no backend available: block or reject? | Immediate rejection; callers needing queuing implement it externally |
| 2 | AC-002-3 — pi available? check binary, credentials, or both? | Binary presence only (no credentials for local pi) |
| 3 | AC-002-4 — remote available? check network, credentials, or both? | Credentials present + parseable; no live network call on availability check |
| 4 | AC-003-3 — per-task timeout value and configurability | Default 60s; global app env or per-call opts override |
| 5 | AC-004-2 — unavailable adapter: skip to fallback or reject? | Skip to fallback for non-manual routing; manual returns backend_unavailable |
| 6 | AC-005-1 — automatic routing capability signals | `task_type` hint in opts matched against backend `supported_contexts` |
| 7 | AC-005-3 — policy rules file format | Elixir behaviour module: `route(task_type, capabilities) → backend_name` |
| 8 | AC-006-1 — capability map fields | `type`, `strengths`, `weaknesses`, `supported_contexts` required; `cost_per_call`, `typical_latency_ms` optional |
| 9 | AC-006-2 — automatic routing tiebreak rule | Available > lower cost_per_call > lower typical_latency_ms > earliest registration |
| 10 | AC-007-1 — max retry count: per task type, per backend, or global? | Per task type via failure policy; when fallback is enabled but count is omitted, default max_attempts: 2 (initial + one fallback) |
| 11 | AC-008-2 — default failure policy when no per-type policy exists | `fail_fast: true`, `max_attempts: 1`, global default timeout |

**Resolved: 11 · Open: 0 · Total: 11**

---

## 5. Dependency Map

- REQ-001 (runtime contract) → REQ-002 (adapter behaviour) → REQ-003 (pi adapter)
- REQ-004 (pluggable adapters) → REQ-002
- REQ-005 (routing strategies) → REQ-002, REQ-006
- REQ-006 (capability declaration) → REQ-002
- REQ-007 (fallback) → REQ-001, REQ-002
- REQ-008 (per-task policy) → REQ-007
- REQ-009 (telemetry) → REQ-001, REQ-007

---

## 6. Risks and Open Questions

### Risks
1. Without a defined capability schema, automatic routing degenerates to a simple registry with no real selection logic. **Mitigated:** REQ-006 requires explicit capability declaration; automatic routing uses declared capabilities.
2. A misbehaving adapter (crashes, hangs, returns corrupt output) can poison the runtime. **Mitigated:** OTP supervision isolates each execution; adapter process is linked and terminated on timeout.
3. Policy routing is implemented as an Elixir behaviour — operators who write policy modules need Elixir knowledge; if non-Elixir policy formats (JSON/YAML rules) are needed in future, the behaviour interface provides a natural extension point

### Open Questions

All 11 open questions have been resolved — see §4 for the authoritative resolution of each. The remaining items below are known gaps identified in self-critique that are intentionally left out of scope for v1.

**Known out-of-scope gaps (not blocking v1):**
1. No dynamic adapter hot-swap — adapters are registered at startup; runtime un/register is out of scope for v1
2. No streaming output — the runtime contract returns a single `{:ok, string}`; streaming is a future enhancement
3. No cost tracking — `cost_per_call` is declared in the capability map but no spend limit or reporting is implemented
4. Policy routing rules format is Elixir behaviour (not JSON/YAML) — operators need Elixir knowledge to write policies

---

## 7. Self-Critique

1. **No explicit requirement for adapter lifecycle management** — adapters are registered at startup but there is no requirement for dynamic adapter registration/unregistration at runtime. This may be a gap if hot-swapping backends is desired. [Suggested resolution: add REQ-010 for dynamic adapter registration if hot-swap is needed; otherwise note it as out of scope.]
2. **No requirement for streaming output** — agents like `pi` stream tokens. The current contract returns a single `{:ok, string}` — callers needing streaming won't get it. [Suggested resolution: add AC variant for streaming callback or add streaming as a separate REQ if needed.]
3. **No requirement for cost tracking** — if backends have different costs (e.g., OpenAI API vs local pi), there is no way to track or limit spend. [Suggested resolution: add cost field to capability map and telemetry event if cost tracking is needed.]
4. **Per-task-type failure policy (REQ-008) is marked Should** — if reliability is the primary success metric, configurable per-type policies may need to be Must.
5. **Policy routing rules format is completely unspecified** — this is a major gap that will drive implementation coupling. It should be resolved before implementation begins.

---

## 8. Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---|
| REQ-001 | Agent runtime contract (opaque to callers) | Must | High | 3 |
| REQ-002 | Backend adapter behaviour | Must | High | 4 |
| REQ-003 | `pi` backend adapter (required) | Must | High | 3 |
| REQ-004 | Pluggable backend adapters (examples) | Should | Medium | 2 |
| REQ-005 | Routing strategies (auto/manual/policy) | Must | High | 3 |
| REQ-006 | Capability declaration | Must | Medium | 2 |
| REQ-007 | Automatic fallback on backend failure | Must | High | 3 |
| REQ-008 | Per-task-type failure policy | Should | Medium | 2 |
| REQ-009 | Telemetry and audit log | Could | Low | 2 |

---

## 9. Implementation Readiness Gate

| Dimension | Score (1–5) | Prior |
|---|---|---|
| Completeness | 4 | — |
| Testability | 4 | — |
| Clarity | 4 | — |
| Feasibility | 4 | — |

**Overall: 4.0 — READY FOR IMPLEMENTATION**

**Gate decision: READY FOR IMPLEMENTATION.** All 11 ambiguity markers are resolved (see §4). The document is ready for implementation pending stakeholder review and acceptance.

---
