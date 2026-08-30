---
document_id: PRD-2026-48f7b420
label: prd-foreman-beads-task-provider
version: 1.0.1
status: Ready for Implementation
date: 2026-08-06
scale_depth: STANDARD
total_requirements: 19
readiness_score: 4.0
---

# PRD: Foreman × Beads Rust — Task-Provider Integration

## PRD Health Summary

| Priority | Count |
|---|---|
| Must | 15 |
| Should | 3 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---|
| AC coverage | 19/19 (100%) — 64 ACs total |
| Risk flags | 4 |
| Dependencies | 7 |
| Open ambiguity markers | 0 |
| Resolved ambiguity markers | 13/13 |

---

## 1. Executive Summary

**What this PRD defines:** a **task-provider boundary** in Foreman that lets Beads Rust (`br`) act as the authoritative task tracker while Foreman executes the work. Beads owns the lifecycle of every tracked issue; Foreman owns the run/event lifecycle and never writes to Beads storage directly. All Beads interaction flows through a single, swappable **TaskProvider** behaviour with one production adapter (`BeadsAdapter`) that shells out to the `br` CLI. The design admits additional providers (Azure DevOps, Jira, GitHub Issues, Linear) without changing caller code.

**Why it exists:** today, Foreman tasks live inside the Phoenix `Task` aggregate as projections of Foreman-emitted events. Operators who already track work in Beads have to mirror every issue by hand, miss Beads dependency ordering, and lose audit trail when runs diverge from the source-of-truth issue list. This PRD introduces the boundary that lets Foreman *read* and *reconcile against* Beads (and any future provider) while continuing to be the execution engine.

---

## 2. Background and Evidence

### 2.1 What we observed in the Foreman codebase

- **Single HTTP ingress.** `ForemanServerWeb.CommandController.create/2` is the only public mutation surface; it forwards envelopes to `ForemanServer.CommandGateway.dispatch_operator/2`, which gates on `@allowed_operator_types ~w(project.register task.create task.approve)` and the canonical `prefix:id` aggregate-id contract (`task:<task_id>`, `project:<project_id>`). All other commands route through `dispatch_system/2`.
- **Task aggregate state is authoritative in-memory.** `ForemanServer.Aggregates.Task` exposes `initial_state/0`, `handle_command/2`, `apply_event/2` over a `%State{}` struct. Valid statuses are `["open","ready","in_progress","blocked","closed","failed"]`. Commands handled: `task.create`, `task.approve`, `task.annotate`, `task.dispatch`, `task.execution_complete`, `task.execution_fail`.
- **Read model is a projection.** `ForemanServer.ProjectionStore` materialises task state from `TaskCreated`, `TaskUpdated`, `TaskApproved`, `TaskDispatched`, `TaskExecutionCompleted`, `TaskExecutionFailed` events into a per-task map. `GET /api/tasks/:id` reads that projection; there is no aggregate-side query path.
- **Existing adapter pattern exists for agents, not for tasks.** `ForemanServer.AgentRuntime.BackendAdapter` (a `@callback`-based behaviour with `name/0`, `capabilities/0`, `available?/0`, `execute/2`) plus `ForemanServer.AgentRuntime.AdapterCatalog` (a `GenServer` that validates capabilities, registers adapters, and exposes a single atomic `routing_snapshot/0`) is the closest analogue. `ForemanServer.AgentRuntime.Adapters.PiAdapter` is the canonical process-spawning implementation: it shells out via `/bin/sh -c "exec <bin> <args>"`, captures the OS PID from `Port.info/2`, enforces timeouts with SIGTERM-then-SIGKILL escalation, scrubs terminal control sequences from output, and cleans up temp files in a `try/after` block. The Beads adapter MUST follow the same shape.
- **No Beads integration exists today.** A workspace-wide scan for `beads`, `\bbr\b`, and `.beads` against `packages;docs;README.md;CLAUDE.md` returns zero hits in code. There is no TaskProvider behaviour, no Beads CLI invocation, no `.beads` directory referenced from any module or controller.

### 2.2 What we observed in Beads Rust (`br`)

All facts below were obtained by running the `br` CLI against the local `.beads/beads.db` (issue prefix `foreman`, 24 closed + 4 tombstoned issues at the time of writing).

- **Versioned, machine-readable contract.** `br capabilities --json` returns `{version: "0.2.19", contract_version: "br.capabilities.v1", features: [...]}`. The contract name MUST be matched at provider registration; mismatches are treated as a configuration error, not a runtime fallback.
- **Per-project database path resolution.** `br where --db /abs/path/to/beads.db --json` and `br info --db /abs/path/to/beads.db --json` both honor an explicit `--db <PATH>` flag and return absolute `database_path` and `jsonl_path` in the response. Foreman MUST pass `--db` per project; it MUST NOT rely on `br`'s ambient CWD discovery.
- **Read-side commands expose structured output.** `br ready --json`, `br list --json`, `br show <id> --json`, `br status --json`, `br coordination status --json` all emit JSON. `br ready` filters include `--limit`, `--assignee`, `--unassigned`, `--label`, `--label-any`, `--type`, `--priority`, `--sort` (`hybrid|priority|oldest`), `--include-deferred`. `br list` extends with `--status`, `--id`, `--priority-min/--priority-max`, `--title-contains`, `--desc-contains`.
- **Schema export.** `br schema ready-issue --json`, `br schema issue-details --json`, `br schema error --json`, `br schema commands --json` return JSON Schema definitions. The adapter MUST validate every payload against the cached schemas at startup and on every `--contract-version` bump.
- **Error envelope and translation.** All failures are emitted as `{error: {code, message, hint, retryable, context}}` with SCREAMING_SNAKE_CASE codes (e.g. `ISSUE_NOT_FOUND`). The adapter MUST translate `br` codes into a **closed Foreman enum** via an allowlisted mapping (see REQ-008): known `br` codes map to a fixed Foreman code with a fixed `retryable?`; unknown `br` codes map to `BR_ERROR_ENVELOPE` with `retryable?` propagated from `br.retryable`. `message` and `hint` are fixed templates that never contain raw `br` text. `context` is an allowlisted key set; **stderr is unconditionally discarded on every error path** — only `stderr_byte_count` (the byte length of the raw discarded stderr), `sanitized?: true`, and `redacted_fields: []` are recorded (per REQ-008 rule 6).
- **Terminal-state write protection.** `br update --status closed|tombstone` is refused — these require `br close` and `br delete` respectively. The adapter MUST route close/delete through the dedicated commands so close-policy and dependency-rewiring are honored.
- **Atomic claim.** `br update --claim` performs `assignee=actor` + `status=in_progress` in one operation. This is the only safe way to start work; the adapter MUST use it instead of two-step `update --assignee ... && update --status in_progress`.
- **Transition comments.** `br update --transition-comment <text>` is required when the active policy lists `transition_comment` for that transition. The adapter MUST pass through any operator-supplied comment verbatim.

### 2.3 Consequence for the design

The TaskProvider boundary is a small, canonical surface (issue identity, lifecycle, dependencies, capabilities) that maps cleanly onto the agent-adapter pattern already in the codebase. The `br` CLI gives us everything we need to implement it without direct database access. Subsequent providers (ADO, Jira, Git, Linear) plug in as new modules implementing the same behaviour; Foreman's caller-facing Task/Run machinery never learns which provider is behind it.

---

## 3. Personas

This PRD targets a **small team (2–5 engineers)** — the standard depth has been confirmed. The persona profile is intentionally minimal.

### 3.1 Engineer (primary)
- Operates a single repo per project, manages 10–200 active issues at a time in Beads.
- Wants `br ready` results to flow into a Foreman run without copy-pasting IDs.
- Tolerates provider-version pinning; expects clear errors when `br` is missing or the contract version drifts.

### 3.2 Platform engineer (secondary)
- Owns the deployment topology. Wants to swap the TaskProvider for ADO/Jira in one project without redeploying Foreman.
- Wants per-project provider configuration so two projects in the same Foreman instance can use different backends.

---

## 4. Requirements

### 4a. Provider Configuration & Boundary

### REQ-001: Must | High | TaskProvider behaviour
Foreman MUST define a `ForemanServer.TaskProvider` behaviour that all provider modules implement. The behaviour is the **only** surface Foreman's Task/Run machinery is allowed to call; direct calls into a provider's adapter module are forbidden (enforced by an architecture test, see REQ-013).

- AC-001-1: Given a provider module implements the `TaskProvider` behaviour, when it is registered via the registry, then it is available to the runner without any change to caller code in the Task or Run aggregates.
- AC-001-2: Given a caller invokes `TaskProvider.list_ready/2`, when the provider succeeds, then it returns `{:ok, [%TaskProvider.Issue{}]}` where every issue is normalised to the canonical record. The first-class fields are `id`, `title`, `status`, `priority`, `dependencies`, `assignee`, `description`, `notes`, `design`, `labels`, and `metadata`. Provider-specific fields that have no first-class slot (e.g. a hypothetical `due_date`) are stored under `metadata` and are not rejected. The four sensitive fields `description`, `notes`, `design`, and `assignee` are explicit struct fields — never aliased into `metadata` — so REQ-019 capture tests can assert their round-trip without depending on map-key convention.
- AC-001-3: Given the provider returns an error, when any callback fails, then it returns `{:error, %ProviderError{code, message, retryable?, context}}` — the `retryable?` flag is propagated faithfully from the underlying transport.

### REQ-002: Must | High | Provider capability declaration
Each provider MUST declare a static capability map at registration time describing which lifecycle transitions it can perform, its data-store location scheme, and its contract identifier.

- AC-002-1: Given a provider module registers, when `capabilities/0` is called, then the returned map includes `provider_id` (atom), `contract_version` (string), `supports` (subset of `[:claim, :close, :reopen, :annotate, :set_priority, :set_assignee, :list_dependencies, :add_dependency, :remove_dependency]`), `storage_scheme` (`:cli_process | :http | :sdk`), and `id_format` (regex) — the registry validates the map and rejects the module if any required key is missing or mistyped.
- AC-002-2: Given two providers are registered, when a task needs to be routed, then the selector prefers providers that declare the required transition in `supports` over providers that do not.
- AC-002-3: Given a provider's `contract_version` does not match the registry's accepted version range (configured via `:foreman_server, :task_provider, :accepted_contract_versions`), when registration is attempted, then the registry returns `{:error, :contract_version_mismatch}` and does NOT register the provider — the mismatch is a configuration error.

### REQ-003: Must | High | Per-project provider configuration
Each Foreman project MUST carry a `task_provider` config block that selects the provider module and binds it to a provider-specific data-store location (e.g. a Beads database path).

- AC-003-1: Given a project is registered with `project.register`, when the operator supplies a `task_provider` field, then the registration succeeds and the config is persisted as part of the project's `config` projection map.
- AC-003-2: Given a project's `task_provider` config is `{provider: BeadsAdapter, config: %{database_path: "/abs/path/to/beads.db"}}`, when the runner resolves the project, then it routes all task-provider calls through `BeadsAdapter` with `database_path` propagated to every `br` invocation as `--db /abs/path/to/beads.db`.
- AC-003-3: Given a project's `task_provider` config is missing or `provider` is `nil`, when the runner resolves the project, then it returns `{:error, :provider_not_configured}` and does NOT fall back to a default — providers are an explicit, per-project choice.
- AC-003-4: Given a project is updated via `project.update`, when the operator supplies a new `task_provider` block, then the config is replaced atomically; existing in-flight task-provider calls for the project complete against the OLD provider, subsequent calls use the NEW provider.

### REQ-004: Must | High | Provider registry
A supervised `GenServer` (`ForemanServer.TaskProvider.Registry`) MUST own the registered providers and expose a single atomic routing snapshot, mirroring the existing `AdapterCatalog` pattern.

- AC-004-1: Given two concurrent registrations are issued, when `routing_snapshot/0` is called, then the snapshot reflects both registrations in registration order — no partial snapshot is observed.
- AC-004-2: Given a provider's `available?/0` returns `false`, when a task is routed by capability, then the provider is filtered out from the snapshot for that selection — re-registration is required to re-enter the snapshot.
- AC-004-3: Given the registry process crashes, when it is restarted by its supervisor, then it re-registers every provider from the application configuration (`Application.get_env(:foreman_server, :task_provider, [])[:providers] || []`) and emits a `[:foreman_server, :task_provider, :registry, :restarted]` telemetry event.

### REQ-005: Should | Medium | Project-scoped provider isolation
The provider registry MUST scope calls to the project that originated them; no cross-project data leakage is permitted even when providers are shared.

- AC-005-1: Given two projects share the same provider module but have different `database_path` values, when both projects call `list_ready/2`, then every `br` invocation issued for project A carries A's `database_path` and every invocation for project B carries B's `database_path` — the routing key is `{project_id, database_path}` and the provider is a single module instance per provider, not a process per project.
- AC-005-2: Given project A is configured with `BeadsAdapter` and project B with a future `JiraAdapter`, when both projects are active, then a task originating in A is never sent to B's adapter and vice versa — the `project_id` is part of the routing key.
- AC-005-3: Given the adapter holds no per-project mutable state in ETS or process dictionaries, when two projects invoke the adapter concurrently, then the calls do not block each other on any shared state — the only state shared between calls is the cached schemas (REQ-007) and the in-flight semaphore (REQ-010), both keyed by provider module, not by project.
- AC-005-4: Given the adapter is a stateless module (consistent with AC-005-1's single-instance guarantee — no per-project state, no per-project process — and AC-005-3's concurrent-calls-do-not-block requirement, which forbids a singleton GenServer that would serialize calls; the adapter is stateless but NOT pure — it dispatches via `@runner.cmd/3` and touches the shared semaphore (REQ-010) and cached schemas (REQ-007)), the adapter declares `@runner Application.compile_env(:foreman_server, :br_runner, ForemanServer.TaskProviders.SystemBrRunner)` and dispatches every callback through `@runner.cmd/3` (Mox does not replace modules at runtime, so the call site MUST be compile-time-bound to either the production implementation or the test mock — there is no per-test swap mechanism, and runtime `Application.put_env` is rejected because `compile_env/3` ignores runtime values; per-test `Application.put_env` is also forbidden because application env is node-global and would leak across concurrent tests), when a property-based test exercises two projects concurrently with different `database_path` values by: (a) pre-assigning each spawned caller task to a known project upfront via a `caller_pid => expected_database_path` map (each caller uses its assigned path when invoking the adapter, NOT picked from argv — keeping the expected-path source independent from the captured argv); (b) spawning N caller tasks via `Task.async/1` (each task returns a `%Task{pid: pid, ref: ref}` so the test pid can both authorise via `Mox.allow` and surface crashes via `Task.await_many`) in a BLOCKED state — each task's first action is `receive do {:start, ^test_pid} -> :ok end`, so the task cannot dispatch any adapter call until the test explicitly releases the barrier; (c) AFTER every pid is spawned, calling `Mox.allow(ForemanServer.TaskProviders.BrRunnerMock, test_pid, caller_pid)` for each pid, THEN broadcasting `send(pid, {:start, test_pid})` to release every caller simultaneously — the start barrier guarantees no caller can hit the private mock before authorisation; (d) calling `Task.await_many(tasks, :infinity)` which RAISES on any non-`:normal` exit (an unlinked task crash would otherwise vanish, leaving a partial / empty capture set that still satisfies `Enum.all?` trivially); (e) asserting `length(captured_argvs) == N * 50` EXACTLY before checking paths — `Mox.stub/3` does NOT contribute to `:verify_on_exit!`'s expectations (the stub only fills unknown calls with a return value, so it neither proves the stub was called nor proves N * 50 invocations occurred), therefore the explicit length assertion is the sole mechanism that catches an empty or partial capture set; (f) iterating the captured `{caller_pid, argv}` tuples (each captured by the Mox stub sending `{self(), argv}` to the test pid) and independently asserting that `argv`'s `--database-path` flag equals `Map.fetch!(assignments, captured_caller_pid)` for every entry — the expected path comes from the pre-built assignment map, an INDEPENDENT source (never derived from argv itself, so leakage is detected even if the adapter always writes one fixed path); no cross-project path leakage ever appears in any of the N * 50 captured argvs, regardless of which call interleaves first. The test module declares `setup :set_mox_private` (puts Mox in private mode owned by the test pid) and `setup :verify_on_exit!` (asserts Mox `expect` expectations on exit — explicitly NOT a stub-coverage check). The adapter does NOT invoke `System.cmd/3` directly — Mox intercepts the test-build dispatch at the single behaviour call-site because `compile_env/3` resolved `@runner` to `ForemanServer.TaskProviders.BrRunnerMock` at compile time (production builds resolve to `ForemanServer.TaskProviders.SystemBrRunner`).

### 4b. Beads Rust Adapter

### REQ-006: Must | High | BeadsAdapter implements TaskProvider via `br` CLI
A `BeadsAdapter` module MUST implement the `TaskProvider` behaviour. The adapter declares `@runner Application.compile_env(:foreman_server, :br_runner, ForemanServer.TaskProviders.SystemBrRunner)` and dispatches every callback through `@runner.cmd/3` — `config/test.exs` sets `config :foreman_server, :br_runner, ForemanServer.TaskProviders.BrRunnerMock` (a `Mox.defmock(ForemanServer.TaskProviders.BrRunnerMock, for: ForemanServer.TaskProviders.BrRunner)`); `ForemanServer.TaskProviders.BrRunnerMock` MUST be defined in `test/support/br_runner_mock.ex` (NOT under `lib/foreman_server/`) so production compilation does NOT include or fail on the mock, and `mix.exs` MUST register `defp elixirc_paths(:test), do: ["lib", "test/support"]` and `defp elixirc_paths(_), do: ["lib"]` so the support directory compiles ONLY in the `:test` env. `Mox` MUST be declared `only: :test` in `mix.exs` `:deps` so the production release artifact NEVER carries the mock module, Mox runtime, or any mock-bytecode in the production `lib/` or `_build/` outputs — the mock module is test-only infrastructure and any production-build reference to it indicates a compile-time pipeline leak. The adapter does NOT alias or import `ForemanServer.TaskProviders.BrRunnerMock` — dispatch is exclusively through `@runner.cmd/3`; production builds compile with `@runner = ForemanServer.TaskProviders.SystemBrRunner`. The production `ForemanServer.TaskProviders.SystemBrRunner` is the ONLY module allowed to invoke `System.cmd("br", ...)` directly (enforced by an architecture test, see REQ-013). Runtime `Application.put_env(:foreman_server, :br_runner, ...)` is rejected by `compile_env/3` (compile-time-only) and per-test `Application.put_env` is also forbidden because application env is node-global and would leak across concurrent tests.

- AC-006-1: Given the BeadsAdapter is registered, when it is selected for a project, then every callback (`list_ready/2`, `get/2`, `claim/3`, `complete/3`, `fail/3`, `reopen/3`, `set_priority/3`, `add_dependency/3`) shells out to the `br` CLI via `@runner.cmd/3` where `@runner` is compile-time-bound via `Application.compile_env(:foreman_server, :br_runner, ForemanServer.TaskProviders.SystemBrRunner)`. `config/test.exs` sets `config :foreman_server, :br_runner, ForemanServer.TaskProviders.BrRunnerMock` so test builds compile with `@runner = ForemanServer.TaskProviders.BrRunnerMock` (a `Mox.defmock(ForemanServer.TaskProviders.BrRunnerMock, for: ForemanServer.TaskProviders.BrRunner)`); production builds compile with `@runner = ForemanServer.TaskProviders.SystemBrRunner` (the sole direct `System.cmd("br", ...)` call-site per REQ-006 / REQ-013). Runtime `Application.put_env(:foreman_server, :br_runner, ...)` is rejected by `compile_env/3` (compile-time-only) and per-test `Application.put_env` is also forbidden because application env is node-global and would leak across concurrent tests. The adapter parses the JSON output against the cached schemas.
- AC-006-2: Given `br` is not installed (i.e. `System.find_executable("br")` returns `nil`), when `available?/0` is called, then it returns `false` and the registry excludes the provider from the routing snapshot — there is no fallback to direct SQLite access.
- AC-006-3: Given `br` is installed but the configured `database_path` does not exist or is not a file, when the adapter calls `br where --db <path>`, then the adapter returns `{:error, %ProviderError{code: "DATABASE_NOT_FOUND", retryable?: false, ...}}` and does NOT attempt to create the database.

### REQ-007: Must | High | Structured output parsing with cached schema validation
The adapter MUST validate every JSON payload against the cached schemas exported by `br schema`, parsed at startup.

- AC-007-1: Given the adapter starts, when `br schema ready-issue --json` and `br schema issue-details --json` are executed, then the response schemas are cached in memory and used to validate every subsequent `br ready` / `br show` payload.
- AC-007-2: Given a payload fails schema validation (e.g. a missing required field), when the adapter processes the response, then it returns `{:error, %ProviderError{code: "SCHEMA_VALIDATION_FAILED", retryable?: false, context: %{missing_fields: [...]}}}` and includes the offending payload path in `context` for diagnosis.
- AC-007-3: Given the adapter has been running for >24h, when the next `br` invocation completes, then the adapter re-fetches `br capabilities --json` and emits a telemetry event `[:foreman_server, :task_provider, :beads, :capabilities, :refreshed]`; a contract-version change triggers REQ-002-3 (the provider is unregistered and re-registration is required).

### REQ-008: Must | High | Provider error envelope mapping
The adapter MUST translate `br`'s error surface into Foreman's `ProviderError` struct using **closed-vocabulary discipline** and an **explicit allowlisted code mapping**. The guarantee is **no untrusted `br` content reaches a `ProviderError` field in plaintext, on any error path**. The mapping is the single source of truth for `ProviderError` construction and is inherited by REQ-019 (side-channel scrub) and REQ-018 (doctor display).

**Allowlisted mapping.** Each `br` error envelope is reduced to a closed Foreman code via this table. The mapping is the **primary defence** — it removes `br`'s raw `code`/`message`/`hint` strings from the result. The rules below the table are the **secondary defences** that bound everything else.

| `br` envelope `code` | Foreman `code` | `retryable?` | Reason |
|---|---|---|---|
| `ISSUE_NOT_FOUND` | `ISSUE_NOT_FOUND` | `false` | `br show` returned no such issue (AC-012-2) |
| `DATABASE_NOT_FOUND` | `DATABASE_NOT_FOUND` | `false` | `br where` cannot locate the project's DB (AC-006-3) |
| `SCHEMA_VALIDATION_FAILED` | `SCHEMA_VALIDATION_FAILED` | `false` | Cached-schema check rejected a payload (AC-007-2) |
| `NOT_CLAIMABLE` | `NOT_CLAIMABLE` | `false` | `br update --claim` race lost (AC-014-3) |
| `CLAIMED_BY_OTHER` | `CLAIMED_BY_OTHER` | `false` | `br update --claim` rejected — assignee already set (AC-016-2) |
| `UNSUPPORTED_VERSION` | `BR_CONTRACT_DRIFT` | `false` | `br` reported a contract version we don't support (REQ-002-3) |
| `VALIDATION` | `BR_VALIDATION` | `false` | Generic `br` validation failure on a known shape |
| `IO_ERROR` | `BR_DB_UNREACHABLE` | `true` | `br` cannot read/write the DB file |
| `INTERNAL` | `BR_ERROR_ENVELOPE` | `true` | `br` self-classified as internal — preserve retryable default |
| `BR_TIMEOUT` | `BR_TIMEOUT` | `true` | `br` subprocess exceeded the per-call timeout (AC-009-2) |
| `BR_SIGNAL` | `BR_SIGNAL` | `true` | `br` exited on a signal (AC-008-3) |
| `BR_INVALID_JSON` | `BR_INVALID_JSON` | `false` | `br` returned non-JSON output (AC-008-4) |
| *anything else* | `BR_ERROR_ENVELOPE` | from `br.retryable` | Unknown `br` code — preserve `br.retryable` per §2.2 / AC-001-3 |

**Mapping rules (apply to every row of the table above).**
1. For KNOWN rows, the mapping determines BOTH the Foreman code and `retryable?` — `br.retryable` is intentionally ignored because the mapping encodes the design's policy decision (e.g. `NOT_CLAIMABLE` is non-retryable even if `br` says otherwise).
2. For the unknown row, `retryable?` is propagated from `br.retryable` (this is the only place `br.retryable` is consulted, and it preserves the AC-001-3 / §2.2 contract).
3. `message` and `hint` are open-coded templates parameterised only on the closed Foreman `code`, the structured `command.subcommand`, and (when applicable) the issue ID — never on raw `br` text. The template for `BR_ERROR_ENVELOPE` is e.g. `"br command :<subcommand> failed for issue <id> (uncategorised error envelope — see context.exit_code and context.stderr_byte_count)"`.
4. `command` is a **structured argv shape** `%{binary: "br", subcommand: <atom_or_string>, flags: [<flag_atom_or_string>]}` — no positional values, no flag values, no raw argv strings.
5. `context` is built from a fixed allowlist with the keys `id`, `command`, `exit_code`, `stderr_byte_count`, `sanitized?`, and `redacted_fields`. **Any other keys `br` may carry in its envelope are dropped.**
6. **stderr is always discarded. No `sanitized_stderr_excerpt` is retained.** `stderr_byte_count` is the byte count of the discarded stderr (informative for operators; non-sensitive). `sanitized?` is `true` on every construction path. `redacted_fields` is `[]` on every construction path (the scrubber literally has nothing to operate on because nothing is retained). The scrubber is still implemented and unit-tested, but it is invoked only for explicit opt-in redaction of structured `ProviderError` extras (none defined in v1) — NOT for the stderr byte stream. The reason is that the only stderr-scrubbing guarantee the design can give is "no stderr bytes leave the subprocess layer," and the strongest reliable way to satisfy that is to keep the byte stream in the subprocess layer.
7. The mapping table is data — a single `%ForemanServer.TaskProviders.BeadsAdapter.CodeMap{}` module — and the architecture test (REQ-008-5) verifies that every `ProviderError` construction site in the adapter routes through this module (not through ad-hoc string keys).

**Closed-vocabulary Foreman codes (emitted directly, not via the mapping).** `BR_TIMEOUT_QUEUE` (per-call queue timeout from AC-010-2) is emitted by the queue layer without going through `br`.
**Success path that does not produce an error.** `ALREADY_CLOSED` from `br close` returns `{:ok, :already_terminal}` directly (AC-016-1) — it is not an error and does not produce a `ProviderError`.
**Sensitive information rule.** No field on the resulting `ProviderError` may carry untrusted `br` content in plaintext. The mapping table is the primary defence — it bounds `code`, `message`, `hint`. The structured `command` shape is the secondary defence — it bounds the argv. The unconditional stderr discard is the third defence — it bounds the byte stream. The `current_assignee` value mentioned in AC-016-2 is replaced by `current_assignee_present?: true` in the context map (the runner needs to know there's a conflict but NOT to see the assignee value).

- AC-008-1: Given `br` returns an envelope `{code: "NOT_CLAIMABLE", message: "foreman-3 already claimed by alice", hint: "issue is in_progress", retryable: false, context: br_raw_context}` on stderr with a non-zero exit code, and the adapter is processing a `claim/3` call, when the adapter processes it, then it returns `{:error, %ProviderError{code: "NOT_CLAIMABLE", message: "br command :update failed for issue foreman-3 (claim lost)", hint: "refer to context.exit_code and context.stderr_byte_count for diagnostics", retryable?: false, context: %{id: "foreman-3", command: %{binary: "br", subcommand: "update", flags: ["--claim", "--json"]}, exit_code: 2, stderr_byte_count: 47, sanitized?: true, redacted_fields: []}}}` — the closed `code` comes from the REQ-008 mapping table for `NOT_CLAIMABLE`, `retryable?` is the fixed `false` from the mapping (NOT propagated from `br.retryable`), `message` and `hint` are templates that contain no raw `br` text (note that the raw `br` message "foreman-3 already claimed by alice" was discarded entirely — not retained, not scrubbed — because the stderr byte stream is unconditional-discard per REQ-008 rule 6), `command` is structured (no positional values, no flag values, no raw argv), `stderr_byte_count` records the discarded stderr length only, and `br_raw_context` is dropped wholesale. The runner receives `NOT_CLAIMABLE` and re-issues `list_ready/2` once per AC-014-3.
- AC-008-2: Given `br` returns an envelope whose `code` is `BR_INVALID_CUSTOM_FIELD` (not in the mapping table — unknown code), when the adapter processes it, then it returns `{:error, %ProviderError{code: "BR_ERROR_ENVELOPE", message: "br command :update failed for issue foreman-3 (uncategorised error envelope — see context.exit_code and context.stderr_byte_count)", hint: "the br error code was not in the adapter mapping; the raw envelope was discarded", retryable?: <propagated from br.retryable>, context: %{id: "foreman-3", command: %{binary: "br", subcommand: "update", flags: ["--claim", "--json"]}, exit_code: 2, stderr_byte_count: 124, sanitized?: true, redacted_fields: []}}}` — the closed `code` is `BR_ERROR_ENVELOPE` (the unknown-row fallback), `retryable?` is propagated from `br.retryable` (the only place `br.retryable` is consulted), the `message` and `hint` templates contain no raw `br` text, the structured `command` shape is preserved, and `stderr_byte_count` is the byte length of the discarded stderr. The case exercises the mapping's unknown-row fallback.
- AC-008-3: Given `br` exits with a signal (e.g. SIGKILL on timeout) rather than a structured envelope, when the adapter processes the exit, then the adapter routes through the `%CodeMap{}` module's `BR_SIGNAL` row and returns `{:error, %ProviderError{code: "BR_SIGNAL", message: "br command :<subcommand> exited on signal", hint: "the br process was terminated by a signal; refer to context.exit_code", retryable?: true, context: %{command: %{binary: "br", subcommand: <subcommand>, flags: [<flag>, ...]}, exit_code: -<signal>, stderr_byte_count: 0, sanitized?: true, redacted_fields: []}}}` — the structured argv shape is used even when the envelope is missing, `exit_code` is `-<signal>` (negative of the OS signal number), and `stderr_byte_count` is `0` because no stderr was captured before the signal.
- AC-008-4: Given `br` exits 0 but emits invalid JSON, when the adapter parses the response, then the adapter routes through the `%CodeMap{}` module's `BR_INVALID_JSON` row and returns `{:error, %ProviderError{code: "BR_INVALID_JSON", message: "br command :<subcommand> returned non-JSON output", hint: "the br response did not parse as JSON; refer to context.exit_code and context.stderr_byte_count", retryable?: false, context: %{command: %{binary: "br", subcommand: <subcommand>, flags: [<flag>, ...]}, exit_code: 0, stderr_byte_count: <N>, sanitized?: true, redacted_fields: []}}}` — the byte count of the discarded stderr is recorded, but no excerpt is retained.
- AC-008-5: Given the adapter source tree AND a runtime test fixture, when the architecture test plus the behavioral sentinel test run as part of the canonical verification pipeline, then: **(a) Single factory function.** An AST scan confirms `%ProviderError{}` is constructed in exactly one place in the adapter — the `BeadsAdapter.build_provider_error/3` factory function — and no other construction site exists; the test fails with the offending file/line if any direct `%ProviderError{...}` match is found outside the factory. The factory is also the only place the `code` value is selected (from the mapping table's known/unknown rows), the `command` map is constructed, and the `stderr_byte_count` is recorded. **(b) Behavioral sentinel runtime test.** The test stubs `br` to return, for every error path the adapter exposes (per AC-008-1, AC-008-2, AC-008-3, AC-008-4, plus the `database_path` resolution failure path from AC-006-3 and the queue timeout path from AC-010-2), a malicious envelope AND a malicious stderr containing all four sentinels (`SENTINEL_ASSIGNEE_@@@`, `SENTINEL_DESC_@@@`, `SENTINEL_NOTES_@@@`, `SENTINEL_DESIGN_@@@`) with sentinel values embedded in EVERY free-text field (`code`, `message`, `hint`, `context.assignee`, `context.description`, `context.notes`, `context.design`, AND the raw stderr byte stream). The test then invokes the adapter, captures the returned `:error` tuple, and uses deep struct/map tooling (`Macro.to_string/1` over the walked AST of the returned struct, plus `Enum.each/2` over every string field and every key/value of every nested map) to assert that NONE of the four sentinels occur anywhere in the returned `%ProviderError{}` — `code`, `message`, `hint`, `retryable?`, and every `context` key/value (including the `command` map, `stderr_byte_count`, `sanitized?`, `redacted_fields`). The test asserts the sentinel absence AT RUNTIME against the constructed struct, not against the source text. A failure prints the offending struct field and the offending sentinel. The factory function and the sentinel test together are the safety gate; the AST scan alone is insufficient because it cannot prove template behaviour, and the runtime test alone is insufficient because an attacker could add a new direct construction site that bypasses the factory — both are required.
- AC-008-6: Given the adapter runtime, when the verification pipeline runs, then the BEHAVIORAL sentinel test from AC-008-5(b) is re-executed as a separate, named test case per error path (one assertion per path) so that a regression localises to the specific path that failed — the assertion is `assert no_sentinel_in_struct?(returned_error, [sentinels])` against the exact returned `%ProviderError{}` for that path, and the test name is `test "no sentinel leaks in <path-name> error"` where `<path-name>` is


### REQ-009: Must | High | CLI process safety
The adapter MUST follow the process-spawning pattern established by `ForemanServer.AgentRuntime.Adapters.PiAdapter`: shell-quoted argv, bounded timeout with SIGTERM-then-SIGKILL escalation, captured OS PID, and explicit cleanup.

- AC-009-1: Given the adapter constructs an argv list for `br`, when the list contains any element with whitespace or shell metacharacters (e.g. a path with spaces), then the element is POSIX single-quoted with `'\''` escaping — the same `shell_quote/1` rule as `PiAdapter`.
- AC-009-2: Given a `br` invocation exceeds the configured timeout, when the timeout elapses, then the adapter sends SIGTERM, waits up to 5 seconds, then sends SIGKILL — the OS PID used for the signal is the captured `br` process, not the shell wrapper.
- AC-009-3: Given the adapter is configured with `database_path: "/abs/path/with spaces/beads.db"`, when it invokes `br ready --db <path>`, then the spawned command succeeds and the path is forwarded to `br` unchanged — no double-quoting, no shell expansion.
- AC-009-4: Given a `br` invocation completes, when the port closes, then any temp files created for the invocation (e.g. for `--description-file` content) are removed in a `try/after` block; leftover temp files are surfaced as a `[:foreman_server, :task_provider, :beads, :temp_file, :leaked]` telemetry event.
- AC-009-5: Given a project is registered with a `database_path` that is relative (i.e. `Path.type/1` does not return `:absolute`) or contains `..` segments, when the provider starts (or when the runner resolves the project for the first time), then the provider resolves the path via `Path.expand/1`, caches the expanded absolute path for the lifetime of the project registration so per-invocation expansion is not repeated, and rejects relative or unexpanded paths with `{:error, :database_path_must_be_absolute}` BEFORE any `br` invocation is issued — silently forwarding a relative path to `br` (which would then resolve via ambient CWD) is forbidden.

### REQ-010: Should | Medium | CLI invocation concurrency limit
The adapter MUST enforce a per-process concurrency limit on `br` invocations to prevent `foreman ready` storms from saturating the SQLite write lock.

- AC-010-1: Given the adapter is configured with `max_in_flight: 4` (default), when 10 concurrent `list_ready/2` calls arrive, then the adapter processes 4 immediately and queues 6 — the 5th–10th callers block in `receive` until a slot frees, with a per-call timeout configurable via `:timeout_ms` (default 30_000).
- AC-010-2: Given a queued caller waits longer than the per-call timeout, when the timeout fires, then the caller receives `{:error, %ProviderError{code: "BR_TIMEOUT_QUEUE", retryable?: true}}` and the slot is NOT consumed.

### 4c. Task Discovery and Execution Eligibility

### REQ-011: Must | High | `list_ready` issues
The provider MUST expose a `list_ready/2` callback that returns the set of issues eligible to be executed next.

- AC-011-1: Given the runner calls `list_ready/2` for a project, when the underlying provider is `BeadsAdapter`, then the adapter invokes `br ready --json` with the project's `database_path` propagated via `--db` and returns the parsed array mapped to `[%TaskProvider.Issue{id, title, status, priority, dependencies, assignee, description, notes, design, labels, metadata}]` (the canonical shape per REQ-001-2).
- AC-011-2: Given a returned issue has `status: "blocked"` in the Beads response, when the adapter maps it, then `TaskProvider.Issue.status` is `"blocked"` (not `"ready"`) — `br ready` already filters these out, but the adapter re-asserts the field defensively.
- AC-011-3: Given an issue references dependencies by Beads ID (e.g. `depends_on: ["foreman-3"]`), when the adapter builds the `Issue.dependencies` list, then it preserves the Beads IDs as opaque strings — the runner does not need to know the project's issue prefix.

### REQ-012: Must | High | `get` a single issue
The provider MUST expose a `get/2` callback that returns a single issue by ID, including its full dependency graph.

- AC-012-1: Given the runner calls `get/2` with a Beads ID, when the adapter invokes `br show <id> --json`, then the returned payload includes `dependencies` (issues this one is blocked by) and `dependents` (issues that block on this one) — both are mapped to `[%TaskProvider.Issue{...}]` with the same field normalisation as `list_ready/2`.
- AC-012-2: Given the issue does not exist, when `br show` returns `ISSUE_NOT_FOUND`, then the adapter returns `{:error, %ProviderError{code: "ISSUE_NOT_FOUND", retryable?: false}}` and does NOT retry.

### REQ-013: Must | High | Architecture test enforces provider boundaries
An ExUnit architecture test MUST scan `lib/foreman_server/` for direct `System.cmd("br", ...)` calls and direct imports of provider adapter modules. The single production implementation of `ForemanServer.TaskProviders.SystemBrRunner.cmd/3` is the ONLY allowed `System.cmd("br", ...)` call-site — the scan exempts that single module and fails on every other match in `lib/foreman_server/`.

- AC-013-1: Given the architecture test scans `lib/foreman_server/` for direct `System.cmd("br"` / `System.cmd("br ",` / `~c"br "` calls (as the first argv), when a match is found OUTSIDE the production implementation of `ForemanServer.TaskProviders.SystemBrRunner.cmd/3` (which is the sole allowed `System.cmd("br", ...)` call-site per AC-006-1 / REQ-006), then the test fails with a message naming the offending file and line. The scan allows exactly one such match in the entire `lib/foreman_server/` tree — the `ForemanServer.TaskProviders.SystemBrRunner.cmd/3` body — and any additional match fails.
- AC-013-2: Given any module under `lib/foreman_server/` outside of `lib/foreman_server/task_providers/` aliases a provider adapter module directly (e.g. `alias ForemanServer.TaskProviders.BeadsAdapter`), then the test fails — callers MUST go through `TaskProvider.behaviour_info()` or the registry.
- AC-013-3: Given the test suite is run as part of the canonical verification pipeline, when a developer adds a direct `br` call or alias, then CI fails on the architecture test before any other test is executed — the gate is structural, not behavioural.

### 4d. Execution Lifecycle Synchronization

### REQ-014: Must | High | Pre-execution atomic claim
The runner MUST atomically claim an issue in Beads before dispatching a Foreman run for it. The runner's identity is the configured actor (`Application.get_env(:foreman_server, :task_provider, [])[:actor]`); if the actor is unset at boot, the registry MUST return `{:error, :task_provider_actor_not_configured}` and the runner MUST NOT issue any `br update --claim` invocation until the actor is configured — silent defaulting to a placeholder actor (e.g. `"anonymous"`, `""`, the OS user) is forbidden because the Beads-side `assignee` is the audit anchor for REQ-014 and REQ-017.

- AC-014-1: Given the runner has selected an issue from `list_ready/2`, when it prepares to dispatch, then the adapter invokes `br update --claim <id>` against the issue — this atomically sets `assignee=<actor>` and `status=in_progress` in a single `br` invocation, not two sequential `update --assignee` and `update --status` calls.
- AC-014-2: Given the claim succeeds, when the runner dispatches the run, then the run's `task_id` projection carries the Beads issue ID verbatim and the `assignee` is the configured runner actor (`Application.get_env(:foreman_server, :task_provider, [])[:actor]`).
- AC-014-3: Given the claim returns `NOT_CLAIMABLE` (e.g. the issue was claimed by another actor between `list_ready` and `claim`), when the adapter processes the error, then the runner re-issues `list_ready/2` once and, if the issue is no longer ready, drops it from the dispatch set with a `[:foreman_server, :task_provider, :claim, :lost]` telemetry event.

### REQ-015: Must | High | Post-execution state transition
On run completion or failure, the runner MUST transition the Beads issue to the corresponding terminal state.

- AC-015-1: Given a Foreman run for a claimed issue completes successfully, when the runner records `TaskExecutionCompleted`, then the adapter invokes `br close <id>` (NOT `br update --status closed` — see REQ-006 evidence) with an optional `--reason` derived from the run's final artifact path.
- AC-015-2: Given a Foreman run for a claimed issue fails terminally, when the runner records `TaskExecutionFailed`, then the adapter invokes `br update --status open --transition-comment <reason>` to return the issue to the ready pool with the failure reason attached as a comment.
- AC-015-3: Given the close invocation is preceded by a `br update --transition-comment` policy requirement, when the runner has no operator-supplied comment, then the adapter fabricates a deterministic default comment `"foreman-run:<run_id>:<artifact_path>"` — the issue is never blocked by a missing-comment policy because the runner always supplies a comment.
- AC-015-4: Given a `br` envelope returned from `br close` or `br update --status open --transition-comment` carries a `code` that is NOT in REQ-008's 12-row allowlist (i.e. the envelope routes through the unknown-code fallback path), when the runner processes the error, then the unknown-code fallback MUST additionally surface the unmapped `br` code to the operator by emitting BOTH a `[:foreman_server, :task_provider, :transition_comment, :rejected]` telemetry event AND a log entry at `:warning` level — the log line contains only the closed-vocab `BR_ERROR_ENVELOPE` Foreman code (already produced by the fallback) and the raw unmapped `br` code as a string, NEVER the raw `br` `message`/`hint` text (per REQ-008 rule 3 closed templates and REQ-019 side-channel restrictions) — silent routing through the fallback without operator-side surfacing would leave operators blind to upstream `br` additions.

### REQ-016: Must | High | Idempotent transition guards
The runner MUST be safe against duplicate transition attempts (e.g. a re-delivered run-completion event after a crash).

- AC-016-1: Given a Beads issue is already closed, when the runner attempts `br close <id>` again (e.g. due to event re-delivery), then `br close` returns `ALREADY_CLOSED` and the adapter returns `{:ok, :already_terminal}` — the runner treats this as success and does not emit a second `TaskExecutionCompleted` event.
- AC-016-2: Given a Beads issue is already `in_progress` with a DIFFERENT assignee, when the runner attempts `br update --claim <id>`, then the adapter returns `{:error, %ProviderError{code: "CLAIMED_BY_OTHER", retryable?: false, context: %{current_assignee_present?: true}}}` and the runner does NOT overwrite the assignee — it surfaces the conflict and stops. The context carries only a boolean presence flag (`current_assignee_present?: true`), never the assignee value itself, so the runner knows there is a conflict without seeing the conflicting assignee's identity (per REQ-008 rule 5 — the allowlisted `context` keys are `id`, `command`, `exit_code`, `stderr_byte_count`, `sanitized?`, `redacted_fields`; the `current_assignee` value is non-allowlisted and is dropped).

### REQ-017: Must | High | Crash reconciliation
On startup, the runner MUST reconcile Beads claims against Foreman's run state and resolve any drift.

- AC-017-1: Given the Foreman server restarts, when the reconciliation scanner runs once at boot, then it calls `br coordination status --json` (or the equivalent `list_ready` + per-project coordination query) to enumerate issues currently in `in_progress` with the runner actor as assignee.
- AC-017-2: Given the scanner finds an issue claimed by the runner actor with no matching Foreman run in `RunStarted` state, when reconciliation completes, then the issue is reopened via `br update --status open --transition-comment "foreman-run-reconciled"` and a telemetry event `[:foreman_server, :task_provider, :reconcile, :reopened]` is emitted.
- AC-017-3: Given the scanner finds an issue claimed by the runner actor with a matching Foreman run still in `in_progress`, when reconciliation completes, then no action is taken — the run continues to drive the issue lifecycle.
- AC-017-4: Given the scanner finds a Foreman run in `in_progress` state whose corresponding Beads issue is already `closed` (e.g. operator manually closed the issue via `br close` while the run was in flight, or a parallel Beads session closed it independently of the runner), when reconciliation completes, then the scanner takes `:no_action` (does NOT reopen the issue via `br update --status open`, does NOT emit a `TaskExecutionFailed` event — the operator's closure is authoritative per §7 Risk #1 mitigation), and emits a `[:foreman_server, :task_provider, :reconcile, :already_closed]` telemetry event carrying the `run_id` and `issue_id` so the operator can see the drift — the run is left to its own lifecycle and will reconcile on next restart or via REQ-016 idempotency when the eventual `TaskExecutionCompleted` arrives.

### 4e. Operator Experience & Observability

### REQ-018: Could | Low | `foreman doctor` integration
The existing `foreman doctor` command SHOULD add a `task_provider` section that verifies the provider chain end-to-end.

- AC-018-1: Given an operator runs `foreman doctor`, when the task-provider section executes, then it reports: (a) the configured `provider_id` and `contract_version`, (b) `br --version` and `br capabilities --json` results, (c) a sample `br ready --limit 1 --json` invocation against each registered project's `database_path`, (d) any schema-validation failures encountered at boot.
- AC-018-2: Given the configured `database_path` is missing or unreadable, when `foreman doctor` runs, then the project is reported as `unhealthy` with the `br` exit code (numeric) and the `stderr_byte_count` from the `ProviderError.context` — i.e. the doctor prints the allowlisted byte count (informative, non-sensitive), never raw stderr (REQ-008-1, REQ-019-4). The doctor report MUST also surface `redacted_fields` (the list of atoms that the scrubber would have redacted had there been anything to redact — expected to be `[]` for stderr-derived content per REQ-008 rule 6) so the operator can see that the discard rule applied; if `redacted_fields` is empty, the doctor states "no sensitive fields detected in stderr (stderr discarded by REQ-008 rule 6)". The doctor MUST NOT panic or crash on a malformed `ProviderError` — it logs the `code`, `message`, and `retryable?` and exits the section cleanly.


### REQ-019: Should | Medium | Adapter silent-by-default on sensitive side-channels
Sensitive Beads fields (`assignee`, `description`, `notes`, `design`) are legitimate domain data — they are explicit first-class fields on `%TaskProvider.Issue{}` (REQ-001-2) and MUST remain present in adapter returns (REQ-011, REQ-014, REQ-015 all require them) and in any state the runner needs to act on. The restriction is narrower: those four fields MUST NOT appear in **side-channels** outside the adapter — `Logger.*` calls, `IO.*` writes, `:telemetry` event metadata, or `ProviderError.context` keys other than the explicit `redacted_fields` audit list. When the underlying `br` invocation returns stderr that contains those field values (e.g. `br` echoing back an assignee name in an error message), the adapter MUST scrub the values from `stderr_excerpt` before recording it. Enforcement is by **behavioral capture tests** with sentinel payloads and asserted round-trip on the domain return.

- AC-019-1: Given an issue payload containing `assignee="SENTINEL_ASSIGNEE_12345"`, `description="SENTINEL_DESC_67890"`, `notes="SENTINEL_NOTES_11111"`, `design="SENTINEL_DESIGN_22222"` is fed to every adapter callback (`list_ready/2`, `get/2`, `claim/3`, `complete/3`, `fail/3`, `reopen/3`, `set_priority/3`, `add_dependency/3`) wrapped in `ExUnit.CaptureLog.capture_log/1`, when the callbacks return, then the captured log string does not contain any of the four sentinel values — failure includes the offending captured log lines and the callback that produced them.
- AC-019-2: Given the same sentinel payload, when the same callbacks are wrapped in `ExUnit.CaptureIO.capture_io/2` (to capture both `IO.puts`/`IO.inspect` and any stray `IO.write`), then the captured output string does not contain any of the four sentinel values.
- AC-019-3: Given the same sentinel payload, when telemetry handlers are attached via `:telemetry_test.attach_event_handlers/2` to every `[:foreman_server, :task_provider, :beads_adapter, :*]` event, then no event metadata map contains any of the four sentinel values — `attach_event_handlers/2`'s returned captures are asserted negative for each sentinel.
- AC-019-4: Given the adapter handles an error from `br` whose `stderr` (if it had been retained) would have contained the issue's `description`, `notes`, `design`, or `assignee` field values (because `br` echoes them back in error messages), when it constructs a `ProviderError` (REQ-008), then (a) the adapter does NOT record `sanitized_stderr_excerpt` at all — stderr is unconditionally discarded on every error path (REQ-008 rule 6: the only stderr-scrubbing guarantee the design can give is "no stderr bytes leave the subprocess layer," and the strongest reliable way to satisfy that is to keep the byte stream in the subprocess and never copy it into the `ProviderError` struct); (b) `ProviderError.context` records only the allowlisted keys `id`, `command`, `exit_code`, `stderr_byte_count` (the byte length of the raw discarded stderr — informative for operators, non-sensitive), `sanitized?` (set to `true`), and `redacted_fields` (set to `[]` for stderr-derived content because nothing is retained to scrub); the scrubber is still implemented and unit-tested in isolation, but is invoked only for explicit opt-in redaction of structured `ProviderError` extras (none defined in v1) — NOT for the stderr byte stream; (c) the four sentinel values are absent from any string the adapter returns to the caller on the error path (the only string fields are `code`, `message`, `hint`, and the `command`/`id` from the structured context — all built from closed templates per REQ-008 rules 3–4), and from any string emitted via `Logger.*` / `IO.*` / `:telemetry`; (d) the test asserts BOTH the absence of sentinels in the constructed `%ProviderError{}` AND that `stderr_byte_count` is recorded as the byte length of the raw stderr (proving the byte stream was discarded, not retained as plaintext), so a regression that re-introduces `sanitized_stderr_excerpt` is caught by the structural assertion on `context.keys` (`Map.keys/1` MUST NOT include `:sanitized_stderr_excerpt`).
- AC-019-5: Given the same sentinel payload is fed to `list_ready/2` and `get/2`, when the adapter returns the parsed `[%TaskProvider.Issue{}]` or single `%TaskProvider.Issue{}`, then the returned struct DOES contain `assignee`, `description`, `notes`, and `design` populated with the sentinel values — the side-channel rule is not violated by the domain return, and the test asserts the field round-trip (positive assertion on the sentinel in the returned struct, negative assertion on the same sentinel in the captured side-channels).

---

## 5. Ambiguity Resolution Status

All 13 ambiguity markers are resolved:

| # | Item | Resolution |
|---|------|------------|
| 1 | Where does the provider config live — env var, project registry, or per-project config map? | Per-project `task_provider` block in the project's `config` projection (REQ-003). No env-var fallback for production; dev may use `Application.put_env`. |
| 2 | How are providers selected when multiple are registered? | Capability-declared `supports` set matched against the required transition (REQ-002-2); providers whose `available?/0` is `false` are filtered out (REQ-004-2). |
| 3 | What happens when `br` is missing? | `BeadsAdapter.available?/0` returns `false`; the provider is excluded from the routing snapshot (REQ-006-2). There is no fallback to direct SQLite access. |
| 4 | How is the per-project `database_path` validated? | `br where --db <path> --json` is invoked once at provider startup for each project; failure returns `DATABASE_NOT_FOUND` and the project is reported as `unhealthy` by `foreman doctor` (REQ-018). |
| 5 | Atomic claim vs two-step update | `br update --claim` only (REQ-014-1); two-step `update --assignee` + `update --status` is forbidden. |
| 6 | Close vs update-status | `br close` only for terminal `closed`; `br update --status open --transition-comment` for reopen on failure (REQ-015). `br delete` for tombstone. |
| 7 | Schema validation timing | Once at startup (cached), then refreshed every 24h on the next invocation (REQ-007-3); contract-version mismatch triggers a re-registration gate (REQ-002-3). |
| 8 | Provider process model | One supervisor-tree process per provider module, not per project; projects are a routing key, not a process key (REQ-005). |
| 9 | Concurrency limit on `br` | Per-adapter `max_in_flight` semaphore (default 4); queued callers have an independent per-call timeout (REQ-010). |
| 10 | Crash reconciliation strategy | Read Beads coordination status at boot, compare against `RunStarted` projections, reopen orphaned claims (REQ-017). |
| 11 | Transition-comment policy handling | Adapter fabricates a deterministic default `foreman-run:<run_id>:<artifact_path>` when no operator comment is supplied (REQ-015-3). |
| 12 | Sensitive data handling | The adapter MUST NOT log `description`, `notes`, `design`, or `assignee` fields in plaintext; an architecture test enforces the rule and the requirement is captured as REQ-019 (see §7 Risk #4 for the compliance framing). |
| 13 | What does `list_ready` return for an empty project? | `{:ok, []}` — never an error, never a 404. |

**Resolved: 13 · Open: 0 · Total: 13.**

---

## 6. Dependency Map

```
REQ-001 (TaskProvider behaviour)
  ├── REQ-002 (capability declaration) ──► REQ-004 (registry)
  ├── REQ-003 (per-project configuration)
  ├── REQ-006 (BeadsAdapter)
  │     ├── REQ-007 (schema validation)
  │     ├── REQ-008 (error envelope mapping)
  │     ├── REQ-009 (process safety)
  │     └── REQ-010 (concurrency limit)
  ├── REQ-011 (list_ready)  ──► REQ-014 (claim)
  ├── REQ-012 (get)         ──► REQ-013 (architecture test)
  ├── REQ-014 (claim)       ──► REQ-015 (transition) ──► REQ-016 (idempotency)
  ├── REQ-015 (transition)  ──► REQ-017 (reconciliation)
  └── REQ-018 (doctor)
```

- REQ-001 → REQ-002 → REQ-004 (provider spine)
- REQ-001 → REQ-003 (per-project binding)
- REQ-006 → REQ-007, REQ-008, REQ-009, REQ-010 (adapter spine)
- REQ-011, REQ-012 → REQ-014, REQ-015 (lifecycle drive)
- REQ-013 is a structural gate that depends only on REQ-001 and REQ-006 being defined (so it can reject violations)
- REQ-017 depends on REQ-014 and REQ-015 having been exercised at least once (so a restart has reconciliation work to do)

---

## 7. Risks and Open Questions

### Risks
1. **Dual source of truth.** Beads owns issue lifecycle; Foreman owns run/event lifecycle. If the two diverge (e.g. operator closes an issue in Beads while a Foreman run is in flight), reconciliation may overwrite operator intent. **Mitigation:** REQ-016-2 refuses to overwrite a claim owned by a different assignee; REQ-017 only reopens claims owned by the runner actor (i.e. not operator-driven closures).
2. **`br` contract drift.** Beads Rust is at 0.2.19 with `contract_version: br.capabilities.v1`. A future 0.3.x may change the JSON schema or rename commands. **Mitigation:** REQ-002-3 treats `contract_version` drift as a configuration error; REQ-007-3 re-checks the version every 24h. The adapter pins `contract_version` at registration time.
3. **SQLite write contention.** `br` writes to a SQLite database; concurrent `update --claim` calls from multiple Foreman runners (or a single runner with high concurrency) can hit `SQLITE_BUSY`. **Mitigation:** REQ-010 enforces a per-adapter concurrency limit (default 4) and the runner serializes dispatch per project.
4. **Sensitive data leakage.** Beads issues may carry sensitive content in `description`, `design`, `notes`, or `assignee`. Forwarding this into Foreman logs or telemetry is a compliance hazard. **Mitigation:** Three layered defences — (i) REQ-008 unconditionally discards stderr on every error path (only `stderr_byte_count` is recorded), so no plaintext from `br` stderr can leak through `ProviderError`; (ii) REQ-008's allowlisted 12-row mapping + closed-vocabulary templates mean `code`, `message`, `hint`, and `command` never carry untrusted `br` content; (iii) REQ-019 explicitly forbids the four sensitive fields in Logger, IO, telemetry, and `ProviderError.context` keys other than `redacted_fields`. AC-019-1 through AC-019-4 use behavioral sentinel-payload capture tests (`ExUnit.CaptureLog`, `ExUnit.CaptureIO`, `:telemetry_test.attach_event_handlers/2`, and ProviderError struct inspection) that exercise every adapter callback and assert the sentinel strings never leak. AC-019-5 asserts the domain return preserves the sentinel fields, so the side-channel rule does not silently strip required data. Compliance with structured-redaction policy (e.g. field-level scrubbing of telemetry payloads) is a follow-up PRD if regulators require it.

### Open Questions
None — all 13 ambiguity markers are resolved (see §5). The remaining items below are intentional v1 out-of-scope gaps identified in self-critique.

### Known out-of-scope gaps (not blocking v1)
1. No streaming issue updates — `list_ready/2` returns a point-in-time snapshot; webhook-driven live updates are a future enhancement.
2. No `br` JSONL export support — Foreman reads via the CLI only, never reads `.beads/issues.jsonl` directly (REQ-006 architectural boundary).
3. No provider-side rate limiting beyond the per-adapter semaphore — global back-pressure across providers is a future concern.
4. No explicit redaction rule for sensitive fields — the adapter is silent-by-default about payload contents; a follow-up REQ will introduce structured redaction if compliance requires it.
5. No cross-provider correlation — if a project is migrated from Beads to a future provider (ADO, Jira, Git, Linear), issue IDs change and existing Foreman runs referencing the old IDs become orphaned. Provider swap requires explicit operator reconciliation; no automated cross-reference preservation is provided in v1 (see §8 self-critique item #1).

---

## 8. Self-Critique

1. **No requirement for cross-provider correlation.** If a project uses Beads and a future migration moves it to Jira, the issue IDs change. REQ-003-4 covers per-project provider swaps, but cross-references during a swap are out-of-scope in v1; provider migration requires explicit operator reconciliation and no automated cross-reference preservation is provided (also noted in §7 out-of-scope gap #5). [No REQ added — out-of-scope in v1.]
2. **`br update --transition-comment` policy requirement is partially handled.** REQ-015-3 fabricates a deterministic default comment, but this assumes the comment policy is non-empty for the affected transition. If a future Beads release adds a policy that REJECTS the default shape, the runner will silently fail. [Suggested resolution: surface policy failures from `br` as a first-class error class in REQ-008, and have the runner re-prompt the operator for a comment on first failure.]
3. **Crash reconciliation (REQ-017) does not handle mid-flight `br close`.** If a Foreman run crashes AFTER `br close` succeeded but BEFORE `TaskExecutionCompleted` was persisted, the next restart will not see the issue in Beads' ready set, but will see the run still in `in_progress` — the reconciliation scanner needs to handle the "run in progress, issue already closed" case explicitly. [Suggested resolution: add AC-017-4 covering the closed-during-run case with a `:no_action` outcome and a `[:foreman_server, :task_provider, :reconcile, :already_closed]` telemetry event.]
4. **`br --db` resolution is not tested for relative paths.** REQ-009-3 covers absolute paths with spaces; the SDK does not specify whether `--db` accepts relative paths. [Suggested resolution: at provider startup, resolve the project's `database_path` to an absolute path and reject relative paths with `:database_path_must_be_absolute`.]
5. **Provider isolation (REQ-005) is logical, not process-level.** The adapter is a single module per provider; per-project config is passed in each call. If the adapter holds any per-project state in ETS or Process dict, a misstep could leak across projects. [Suggested resolution: add a property-based test that exercises two projects with different `database_path` values and asserts that no `br` invocation ever receives the wrong path.]

---

## 9. Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---|
| REQ-001 | TaskProvider behaviour | Must | High | 3 |
| REQ-002 | Provider capability declaration | Must | High | 3 |
| REQ-003 | Per-project provider configuration | Must | High | 4 |
| REQ-004 | Provider registry | Must | High | 3 |
| REQ-005 | Project-scoped provider isolation | Should | Medium | 4 |
| REQ-006 | BeadsAdapter implements TaskProvider via `br` CLI | Must | High | 3 |
| REQ-007 | Structured output parsing with cached schema validation | Must | High | 3 |
| REQ-008 | Provider error envelope mapping | Must | High | 6 |
| REQ-009 | CLI process safety | Must | High | 5 |
| REQ-010 | CLI invocation concurrency limit | Should | Medium | 2 |
| REQ-011 | `list_ready` issues | Must | High | 3 |
| REQ-012 | `get` a single issue | Must | High | 2 |
| REQ-013 | Architecture test enforces provider boundaries | Must | High | 3 |
| REQ-014 | Pre-execution atomic claim | Must | High | 3 |
| REQ-015 | Post-execution state transition | Must | High | 4 |
| REQ-016 | Idempotent transition guards | Must | High | 2 |
| REQ-017 | Crash reconciliation | Must | High | 4 |
| REQ-018 | `foreman doctor` integration | Could | Low | 2 |
| REQ-019 | Adapter silent-by-default on sensitive side-channels | Should | Medium | 5 |

---

## 10. Implementation Readiness Gate

| Dimension | Score (1–5) | Notes |
|---|---|---|
| Completeness | 4 | All 19 requirements have explicit ACs (64 ACs total); 13/13 ambiguity markers resolved; three architecture tests (REQ-013 structural, REQ-008-5(a) single-factory AST scan + REQ-008-5(b) sentinel runtime, REQ-019 behavioral sentinel) close structural, error-mapping, and side-channel gates; refinement pass added AC-005-4 (property-based isolation), AC-009-5 (absolute path enforcement), AC-015-4 (unmapped-code operator-surfacing guard), and AC-017-4 (closed-during-run reconciliation:no_action). |
| Testability | 4 | REQ-008-5(a) single-factory AST scan asserts every `%ProviderError{}` construction site routes through `BeadsAdapter.build_provider_error/3`; REQ-008-5(b) and AC-008-6 per-path runtime tests verify closed-vocabulary mapping + unconditional stderr discard (no `sanitized_stderr_excerpt`) on every error path; REQ-019 sentinel capture tests verify Logger/IO/telemetry/ProviderError side-channels; AC-019-4 asserts both sentinel absence and that `stderr_byte_count` is recorded (proving the byte stream was discarded); BeadsAdapter can be exercised against an empty SQLite DB created via `br init`. |
| Clarity | 4 | Behaviour surface is minimal (REQ-001); existing agent-adapter pattern (PiAdapter, AdapterCatalog) provides a clear template; AC-001-2 names the canonical `%TaskProvider.Issue{}` fields including the four sensitive ones; REQ-019 explicitly carves out domain returns from side-channels; REQ-008 rule 6 explicitly carves stderr out of `ProviderError` entirely (unconditional discard, only `stderr_byte_count` retained) so the cleanliness of the side-channel contract is observable from the constructed struct alone. |
| Feasibility | 4 | All `br` commands cited were observed at version 0.2.19; the integration is bounded by what `br` exposes today and the contract version check (REQ-002-3) makes drift safe; sentinel capture tests use only ExUnit + `:telemetry_test` (both already in the dependency graph). |

**Overall: 4.0 — READY FOR IMPLEMENTATION.**

**Gate decision: READY FOR IMPLEMENTATION.** All 13 ambiguity markers are resolved (see §5). The dependency map is acyclic and bounded (see §6). The architectural boundary is enforced by REQ-013. The integration is ready to enter the TRD design phase via `/ensemble:create-trd`.

---

## Appendix A: Observed `br` Commands Used by This PRD

| PRD requirement | `br` invocation | Notes |
|---|---|---|
| REQ-006 | `br --version`, `br where --db <path> --json`, `br info --db <path> --json` | Startup preconditions |
| REQ-007 | `br schema ready-issue --json`, `br schema issue-details --json`, `br schema error --json`, `br capabilities --json` | Cached schema + contract version |
| REQ-008 | All `br` invocations route stderr through this contract | `ErrorEnvelope` shape |
| REQ-011 | `br ready [--limit N] [--assignee X] [--label Y] [--priority P] [--sort hybrid\|priority\|oldest] --json` | `--db <path>` is always present |
| REQ-012 | `br show <id> --json` | `--db <path>` always present |
| REQ-014 | `br update --claim <id> --json` | Atomic claim |
| REQ-015 | `br close <id> [--reason ...] --json` (success), `br update <id> --status open --transition-comment <reason> --json` (failure) | Terminal transitions |
| REQ-017 | `br coordination status --json`, `br list --status in_progress --assignee <actor> --json` | Reconciliation scan |
| REQ-018 | All of the above as smoke tests | `foreman doctor` |

## Appendix B: Files Touched (when implemented)

This PRD is the **design contract only**. Implementation will add:

- `lib/foreman_server/task_provider.ex` — behaviour
- `lib/foreman_server/task_providers/beads_adapter.ex` — adapter that dispatches every callback through `@runner.cmd/3` (compile-time-bound via `Application.compile_env/3`); does NOT invoke `System.cmd/3` directly
- `lib/foreman_server/task_providers/br_runner.ex` — behaviour contract defining `cmd/3` (interface shared by `ForemanServer.TaskProviders.BrRunner` / `ForemanServer.TaskProviders.SystemBrRunner` / `ForemanServer.TaskProviders.BrRunnerMock`)
- `lib/foreman_server/task_providers/system_br_runner.ex` — production implementation containing the sole direct `System.cmd("br", ...)` call-site in the entire `lib/foreman_server/` tree (exempted by REQ-013's scan)
- `test/support/br_runner_mock.ex` — `Mox.defmock(ForemanServer.TaskProviders.BrRunnerMock, for: ForemanServer.TaskProviders.BrRunner)`; compiles only in the `:test` env via `mix.exs` `defp elixirc_paths(:test), do: ["lib", "test/support"]` (NOT under `lib/`)
- `lib/foreman_server/task_providers/registry.ex` — GenServer
- `lib/foreman_server/task_providers/provider_error.ex` — error struct
- `lib/foreman_server/task_providers/issue.ex` — normalised record with explicit `id`, `title`, `status`, `priority`, `dependencies`, `assignee`, `description`, `notes`, `design`, `labels`, `metadata` fields (description/notes/design/assignee are first-class per AC-001-2 / REQ-019)
- `test/foreman_server/task_providers/architecture_test.exs` — REQ-013 (structural scan for `System.cmd("br", ...)` and direct adapter aliases)
- `test/foreman_server/task_providers/side_channel_test.exs` — REQ-019 (sentinel-payload capture tests for Logger, IO, telemetry, ProviderError)
- Updates to `ForemanServer.Aggregates.Project` to carry `task_provider` config
- Updates to `lib/foreman_server/workflow/run_executor.ex` to drive the lifecycle (REQ-014, REQ-015, REQ-016, REQ-017)
- Documentation updates per `foreman-doc-gate`: `docs/user-guide.md` (per-project provider config), `docs/cli-reference.md` (`foreman doctor` section), `README.md` (overview), and `CLAUDE.md` (boundary reminder)

No existing test, projection, or aggregate code is modified without a documented reason tied to a REQ above.

---

## Changelog

### 1.0.1 — 2026-08-06 — Refinement pass

Applied `ensemble:refine-prd` review findings; Document ID `PRD-2026-48f7b420` and Label `prd-foreman-beads-task-provider` preserved unchanged (downstream artifacts correlate by micro UUID).

**Added 4 acceptance criteria:**

- **AC-005-4** (REQ-005, Project-scoped provider isolation): Property-based isolation test — two concurrent projects with different `database_path` values must never cross-leak paths in any captured `br` argv, across an interleaved schedule of `list_ready/2` / `get/2` / `claim/3` calls. Each spawned caller task is pre-assigned to a project via an independent `caller_pid => expected_database_path` map (the assignment is the expected-path source — never derived from argv itself, which avoids circular verification). Callers are spawned via `Task.async/1` in a BLOCKED state on `receive do {:start, ^test_pid} -> :ok end`; after every pid is spawned the test calls `Mox.allow(ForemanServer.TaskProviders.BrRunnerMock, test_pid, caller_pid)` for each pid, THEN broadcasts `send(pid, {:start, test_pid})` to release all callers simultaneously (the start barrier prevents the race where a spawned task hits the private mock before `Mox.allow/3` returns). The test calls `Task.await_many(tasks, :infinity)` which RAISES on any non-`:normal` caller exit (otherwise an unlinked crash vanishes into a partial / empty capture set that still satisfies `Enum.all?` trivially) and asserts `length(captured_argvs) == N * 50` EXACTLY before checking paths — `Mox.stub/3` does NOT contribute to `:verify_on_exit!`'s expectations (the stub fills unknown calls with a return value, neither proving it was called nor proving N * 50 invocations occurred), so the explicit length assertion is the sole mechanism catching an empty / partial capture set. The Mox stub captures `{self(), argv}` per `cmd/3` invocation; the test reads `self()` from the captured tuple and asserts argv's `--database-path` equals `Map.fetch!(assignments, captured_caller_pid)`. The adapter declares `@runner Application.compile_env(:foreman_server, :br_runner, ForemanServer.TaskProviders.SystemBrRunner)` and dispatches every callback through `@runner.cmd/3`; `config/test.exs` fixes `config :foreman_server, :br_runner, ForemanServer.TaskProviders.BrRunnerMock` so test builds compile with `@runner = ForemanServer.TaskProviders.BrRunnerMock` (a `Mox.defmock(ForemanServer.TaskProviders.BrRunnerMock, for: ForemanServer.TaskProviders.BrRunner)`); production builds compile with `@runner = ForemanServer.TaskProviders.SystemBrRunner` (the sole direct `System.cmd("br", ...)` call-site per REQ-006 / REQ-013). Runtime `Application.put_env(:foreman_server, :br_runner, ...)` is rejected by `compile_env/3` (compile-time-only) and is also forbidden because application env is node-global and would leak across concurrent tests. The test declares `setup :set_mox_private` (private mode owned by the test pid) and `setup :verify_on_exit!` (asserts Mox `expect` expectations on exit — unrelated to stub coverage). The adapter is stateless (no `start_link/1`, no singleton GenServer) but NOT pure — it dispatches via `@runner.cmd/3` and touches the shared semaphore (REQ-010) and cached schemas (REQ-007). `Application.put_env` is explicitly NOT used (rejected by `compile_env/3`, and forbidden because application env is node-global and would leak across concurrent tests).
- **AC-009-5** (REQ-009, CLI process safety): Absolute path enforcement — provider MUST resolve `database_path` via `Path.expand/1` at startup and reject relative or unexpanded paths with `{:error, :database_path_must_be_absolute}` before any `br` invocation; the expanded absolute path is cached for the lifetime of the project registration.
- **AC-015-4** (REQ-015, Post-execution state transition): Operator-surfacing guard on the unknown-code fallback path — when a `br` envelope `code` is not in REQ-008's 12-row allowlist (i.e. the envelope routes through the unknown-code fallback), the fallback MUST additionally emit `[:foreman_server, :task_provider, :transition_comment, :rejected]` telemetry + `:warning` log; the log carries only the closed-vocab `BR_ERROR_ENVELOPE` Foreman code (already produced by the fallback) and the raw unmapped `br` code as a string — never raw `message`/`hint` text. No speculative `br` code vocabulary added to REQ-008's allowlist.
- **AC-017-4** (REQ-017, Crash reconciliation): Closed-during-run case — when a Foreman run is `in_progress` but the corresponding Beads issue is already `closed` (operator-authoritative closure), the scanner takes `:no_action` and emits `[:foreman_server, :task_provider, :reconcile, :already_closed]`.

**Surfaced existing requirements:**

- **REQ-014 prose**: Made the runner actor config requirement explicit — the actor is read via `Application.get_env(:foreman_server, :task_provider, [])[:actor]` and is mandatory at boot; an unset value returns `{:error, :task_provider_actor_not_configured}` from the registry; silent defaulting is forbidden because the Beads-side `assignee` is the audit anchor for REQ-014 and REQ-017.

**Tightened prose:**

- **§7 out-of-scope gaps #5** (new): "No cross-provider correlation — provider migration requires operator reconciliation; no automated cross-reference preservation in v1."
- **§8 self-critique #1**: Tightened wording to match §7 #5 — "cross-references during a swap are out-of-scope in v1; provider migration requires explicit operator reconciliation."

**Structural updates:**

- **§9 AC count summary**: REQ-005 3→4, REQ-009 4→5, REQ-015 3→4, REQ-017 3→4; total 60→64 ACs.
- **§10 Readiness Gate**: Completeness note updated to reference the four new ACs; Testability / Clarity / Feasibility notes unchanged. Overall score remains **4.0 — READY FOR IMPLEMENTATION**.
- **Frontmatter**: `version: 1.0.0` → `1.0.1`; `total_requirements: 19` unchanged; `readiness_score: 4.0` unchanged.
- **Health Summary**: `60 ACs total` → `64 ACs total`.
- **Namespace qualification fix (Advisory #9)**: Every reference to `TaskProviders.BrRunner` / `TaskProviders.SystemBrRunner` / `TaskProviders.BrRunnerMock` is now fully-qualified as `ForemanServer.TaskProviders.<X>` at every binding/default site (`Application.compile_env/3` default, `config/test.exs` value, `@runner = ...` compile-time assignments) and at every `Mox.defmock/2` / `Mox.allow/3` call — `config/test.exs` has no implicit `ForemanServer.` alias, so unqualified `TaskProviders.BrRunnerMock` would raise `UndefinedFunctionError` when the adapter is first invoked (the config atom is not validated at boot — BEAM defers module resolution to the first `cmd/3` call site). No double-qualification (`ForemanServer.ForemanServer.+`) remains. All other prose references to the three modules are also fully-qualified for consistency (the bare-name tokens in backticks in this bullet are illustrative examples of the unqualified forms, not literal code references).
**Verified externally:**

- `br 0.2.19` with `contract_version: br.capabilities.v1` confirmed at `/Users/ldangelo/.local/bin/br` — matches PRD §2.2 and §10 Feasibility.
