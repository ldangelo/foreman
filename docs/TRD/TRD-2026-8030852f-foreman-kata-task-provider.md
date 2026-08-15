---
document_id: TRD-2026-8030852f
label: trd-foreman-kata-task-provider
version: 1.0.0
status: Draft
date: 2026-08-14
prd_reference: PRD-2026-8030852f
prd_label: prd-foreman-kata-task-provider
scale_depth: STANDARD
total_requirements: 17
total_acceptance_criteria: 56
design_readiness_score: 4.0
readiness_score: 4.0
kind: trd
---

# TRD: Foreman × Kata (kenn.io/kata) — Task-Provider Integration

## 1. Executive Summary

This TRD turns PRD `PRD-2026-8030852f-foreman-kata-task-provider` (v1.0.0, readiness 4.0, 17 REQs, 56 ACs) into a concrete implementation plan for the `KataAdapter` — the second `TaskProvider` adapter that lets Kata (kenn.io/kata) act as the authoritative task tracker alongside the existing Beads adapter. The PRD micro UUID `8030852f` is preserved unchanged so PRD/TRD artifacts correlate 1:1. The label prefix changes from `prd-` to `trd-` (`trd-foreman-kata-task-provider`); the label is display-only and all cross-references use the micro UUID.

The implementation lives under `packages/foreman_server/` (the Foreman repo's Phoenix package — paths in this TRD are package-relative). The slice is supervised by the existing `ForemanServer.Application` supervisor tree; new supervisor children are added, not a parallel OTP application.

The Kata adapter is materially shorter than the Beads adapter in three ways: (i) no `--db` per-call flag (Kata resolves the project from `.kata.toml` repo binding + `KATA_HOME` env); (ii) no `br schema --json` schema-fetching ceremony (Kata's `--json` output is validated by simple field-mapping rather than JSON Schema); (iii) no Foreman-side orphan scanner — Kata's claim lifecycle is encapsulated by Kata, and the operator uses Kata's native commands to triage. The architectural template is identical to BeadsAdapter; the surface area is smaller, and the multi-tracker parity pattern is demonstrated end-to-end.

The TRD delivers in four vertical slices:

1. **PR 1a** — Foundation: `KataRunner` behaviour (`cmd/3` interface), `SystemKataRunner` (sole `System.cmd("kata", ...)` site), `KataRunnerMock` at `test/support/`, `KataAdapter` implementing all 11 TaskProvider callbacks, surgical `mix.exs` + `config/test.exs` updates. KataAdapter dispatches every callback through `@runner.cmd/3` (compile-time-bound via `Application.compile_env/3`). No schema cache — Kata validates by simple field-mapping. No orphan scanner — Kata is authoritative for claim state.

2. **PR 1b** — Quality: Architecture test (`kata_architecture_test.exs`) enforcing sole-allowed `System.cmd("kata", ...)` site and no out-of-`task_providers/` adapter alias; `ProviderError` factory reusing `BeadsAdapter.CodeMap` (single allowed construction site via `KataAdapter.build_provider_error/3`); concurrency limiter (`max_in_flight: 4`); generic registry tightening + any Beads cleanup required by REQ-010.

3. **PR 2** — Lifecycle: Pre-execution atomic claim via `kata claim <ref>`; post-execution close via `kata close <ref> --done --message --commit [--evidence]`; failure-path release via `kata reopen` + `kata comment` (Kata has no failure close reason); idempotency guards for already-closed and already-claimed states.

4. **PR 3** — Observability: Sensitive fields (`assignee` + `description`/`body`) side-channel silence (Logger/IO/telemetry/ProviderError.context); `foreman doctor` integration with Kata section smoke tests.

**Reused Capabilities:** This TRD reuses the following capabilities from foundational work established by `TRD-2026-48f7b420`:
- `ForemanServer.TaskProvider` behaviour (already production-grade) — reuse via existing behaviour
- `ProviderError` envelope and `BeadsAdapter.CodeMap` — reuse for error code selection in `KataAdapter.build_provider_error/3`
- `ForemanServer.TaskProviders.ConcurrencyLimiter` — reuse unchanged
- `ForemanServer.TaskProvider.Registry` — reuse unchanged
- `ForemanServer.TaskProvider.Issue` struct — reuse unchanged

---

## 2. Architecture Decision

### 2.1 Alternatives Considered

#### Option A — Simplest (REJECTED)

Single `ForemanServer.TaskProviders.Kata` module that shells out to `kata` directly from the runner integration point. No behaviour, no adapter pattern, no mock, no registry, no closed-vocab error envelope.

- **Pros:** Fewest files (~150 LOC).
- **Cons:** Violates REQ-001 (no behaviour), REQ-002 (no capability declaration), REQ-003 (no per-project binding), REQ-004 (no architecture test), REQ-007 (no closed-vocab error envelope), REQ-009 (no concurrency limit), REQ-011 (no claim-before-dispatch), REQ-017 (no side-channel discipline).
- **Risk:** HIGH.

#### Option B — Most scalable (REJECTED)

`TaskProvider.Registry` GenServer with per-adapter Process supervisor children, ETS-backed hot-swap registry, liveness heartbeats, runtime add/remove without restart.

- **Pros:** True multi-provider hot-swap.
- **Cons:** Adds machinery the v1 PRD does not require. The dynamism is unused at v1.
- **Risk:** MEDIUM-HIGH.

#### Option C — PRD-as-specified (CHOSEN)

Single `ForemanServer.TaskProvider` behaviour (already production-grade from Beads); one production adapter (`KataAdapter`) that dispatches every callback through a compile-time-bound `@runner` module attribute. `SystemKataRunner` is the sole `System.cmd("kata", ...)` site. `ProviderError` reuses `BeadsAdapter.CodeMap` verbatim. No schema cache. No orphan scanner.

- **Pros:** 1:1 aligned with PRD. Follows the existing `BeadsAdapter` template exactly. Kata adapter is ~30% shorter than BeadsAdapter.
- **Cons:** Shares `BR_ERROR_ENVELOPE` naming — `command.binary` carries `"kata"` so the operator sees the source.
- **Risk:** LOW.

### 2.2 Chosen Architecture (Option C)

#### 2.2.1 Component Boundaries

| Path | Module | Responsibility |
|---|---|---|
| `task_providers/kata_runner.ex` | `ForemanServer.TaskProviders.KataRunner` | Behaviour contract defining `cmd/3` — shared by `SystemKataRunner` and `KataRunnerMock`. Mirrors `BrRunner`. |
| `task_providers/system_kata_runner.ex` | `ForemanServer.TaskProviders.SystemKataRunner` | Production implementation. **Sole** direct `System.cmd("kata", ...)` call-site in entire `lib/foreman_server/` tree. POSIX shell-quote; SIGTERM → 5s grace → SIGKILL; temp-file cleanup. |
| `task_providers/kata_adapter.ex` | `ForemanServer.TaskProviders.KataAdapter` | Production adapter. `@runner Application.compile_env(:foreman_server, :kata_runner, ForemanServer.TaskProviders.SystemKataRunner)`. All 11 TaskProvider callbacks via `@runner.cmd/3`. Routes through `KataAdapter.BuildProviderError` which delegates to `BeadsAdapter.CodeMap`. Field-mapping validation (no JSON Schema). |
| `task_providers/kata_adapter/build_provider_error.ex` | `ForemanServer.TaskProviders.KataAdapter.BuildProviderError` | **Single** `%ProviderError{}` construction site in `KataAdapter`. Delegates to `BeadsAdapter.CodeMap`. `command.binary: "kata"`. `redacted_fields: ["assignee", "description"]`. |

**Test-support:** `test/support/kata_runner_mock.ex` — `Mox.defmock(KataRunnerMock, for: KataRunner)`.

**Test files:** `kata_runner_test.exs`, `system_kata_runner_test.exs`, `kata_adapter_test.exs`, `kata_architecture_test.exs` (sole `System.cmd` scan + orphan-scanner-absence scan + adapter-alias scan), `kata_side_channel_test.exs` (sentinel capture), `kata_registry_tightening_test.exs`, `kata_concurrency_test.exs`, `kata_lifecycle_test.exs`, `kata_doctor_controller_test.exs`.

**Inherited (unchanged):** `ForemanServer.TaskProvider`, `ForemanServer.TaskProvider.Issue`, `ForemanServer.TaskProvider.Registry`, `ForemanServer.TaskProviders.ConcurrencyLimiter`, `ForemanServer.TaskProviders.ProviderError`, `ForemanServer.TaskProviders.BeadsAdapter.CodeMap`.

#### 2.2.2 Data Flow

**Read path (`list_ready/2`):**

```
caller → TaskProvider.Registry.route/2 → KataAdapter.list_ready/2
  → @runner.cmd(["list", "--json"], cwd: project_root)
  → field-mapping validation → {:ok, [%TaskProvider.Issue{}]}
```

**Claim path (`kata claim <ref>`):** single atomic op; on `NOT_CLAIMABLE` error → re-call `list_ready/2` once; if no longer ready → drop from dispatch set + telemetry.

**Close path:** `kata close <ref> --done --message "<msg>" --commit <sha>` [+ `--evidence`]; on `ALREADY_CLOSED` → `{:ok, :already_terminal}`.

**Failure path:** `kata reopen <ref>` + `kata comment <ref> --body "<reason>"` (Kata has no failure close reason).

#### 2.2.3 Technology Choices

| Choice | Decision | Rationale |
|---|---|---|
| Transport | CLI (`kata` binary) | CONCERN 1 "CLI only" — Kata's daemon is Kata's internal concern |
| Schema validation | Simple field-mapping | No `kata schema` equivalent — check required fields `id`, `title`, `status`, `priority` |
| Error envelope | `BeadsAdapter.CodeMap` | CONCERN 12 — no new error atoms; `command.binary: "kata"` for operator visibility |
| Claim serialization | `kata claim <ref>` atomic | CONCERN 4 — no parallel Foreman lease layer for Kata |
| Orphan handling | Operator triage only | CONCERN 8 — Foreman does NOT scan Kata; no `[:reconcile, :*]` telemetry |
| Concurrency | `ConcurrencyLimiter` | Shared with Beads; `max_in_flight: 4`, `BR_TIMEOUT_QUEUE` on queue timeout |

---

## 3. Master Task List

### 3.1 Sprint 1 — Foundation: Adapter Skeleton + Test Infrastructure

#### Story 1.1

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T001 | Create `lib/foreman_server/task_providers/kata_runner.ex` — behaviour defining `cmd/3` callback with spec `(argv :: [String.t()], cwd :: Path.t(), opts :: keyword()) :: {:ok, String.t()} \| {:error, ProviderError.t()}` | 1h | | [ ] |
| KATA-T002 | Create `lib/foreman_server/task_providers/system_kata_runner.ex` — sole `System.cmd("kata", ...)` site; POSIX shell-quote each argv element; capture OS PID via `Port.info/2`; SIGTERM → 5s grace → SIGKILL on timeout; temp-file cleanup in `try/after` block | 4h | KATA-T001 | [ ] |
| KATA-T003 | Create `test/support/kata_runner_mock.ex` — `Mox.defmock(ForemanServer.TaskProviders.KataRunnerMock, for: ForemanServer.TaskProviders.KataRunner)`; compiles only in `:test` env via `elixirc_paths(:test)` | 1h | KATA-T001 | [ ] |
| KATA-T004 | Update `mix.exs` — add `defp elixirc_paths(:test), do: ["lib", "test/support"]` if absent | 15m | | [ ] |
| KATA-T005 | Update `config/test.exs` — add `config :foreman_server, :kata_runner, ForemanServer.TaskProviders.KataRunnerMock` | 15m | KATA-T003 | [ ] |
| KATA-T006 | Write `test/foreman_server/task_providers/kata_runner_test.exs` — verify behaviour exports and callback arities | 1h | KATA-T001 | [ ] |
| KATA-T007 | Write `test/foreman_server/task_providers/system_kata_runner_test.exs` — test shell_quote edge cases; test SIGTERM/SIGKILL escalation; test temp-file cleanup telemetry | 2h | KATA-T002 | [ ] |

#### Story 1.2

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T008 | Create `lib/foreman_server/task_providers/kata_adapter.ex` — implement all 11 TaskProvider callbacks; each routes through `@runner.cmd/3`; declare `@runner Application.compile_env(:foreman_server, :kata_runner, ForemanServer.TaskProviders.SystemKataRunner)`; `id_format` regex defaults to `"^[a-z]+[0-9]+$"` until OPEN-Q1 resolves | 6h | KATA-T002, KATA-T005 | [ ] |
| KATA-T009 | Implement `available?/0` — `System.find_executable("kata")` nil → `false`; `kata --version` non-zero → `false`; both pass → `true` | 1h | KATA-T008 | [ ] |
| KATA-T010 | Implement `capabilities/0` — return `provider_id: :kata`, `contract_version: "kata.capabilities.v1"`, `supports: [:create, :claim, :close, :reopen, :annotate, :set_priority, :set_assignee, :list_dependencies, :add_dependency, :remove_dependency]`, `storage_scheme: :cli_process`, `id_format` from OPEN-Q1 | 1h | KATA-T008 | [ ] |
| KATA-T011 | Implement `list_ready/2` — invoke `kata list --json`; client-side filter to `status: "open"`; map to `%TaskProvider.Issue{}`; Kata-specific fields under `metadata` | 2h | KATA-T008 | [ ] |
| KATA-T012 | Implement `get/2` — invoke `kata show <ref> --json`; field-mapping validation rejects missing `id`/`title`/`status`/`priority` with `SCHEMA_VALIDATION_FAILED` | 1h | KATA-T008 | [ ] |
| KATA-T013 | Implement `claim/3` — invoke `kata claim <ref>` (single atomic op); on success return `{:ok, %TaskProvider.Issue{}}`; on `NOT_CLAIMABLE`/`CLAIMED_BY_OTHER` return `{:error, %ProviderError{}}` via CodeMap | 1h | KATA-T008 | [ ] |
| KATA-T014 | Implement `complete/3` — invoke `kata close <ref> --done --message "<msg>" --commit <sha>` with optional `--evidence`; fabricate deterministic default `"foreman-run:<run_id>:<artifact_path>"` when no message; on success return `{:ok, :terminal}` | 2h | KATA-T008 | [ ] |
| KATA-T015 | Implement `fail/3` — invoke `kata reopen <ref>` then `kata comment <ref> --body "<reason>"`; return `{:ok, :reopened}`; MUST NOT fabricate `kata close --reason=fail` | 1h | KATA-T008 | [ ] |
| KATA-T016 | Implement `reopen/3`, `set_priority/3`, `set_assignee/3`, `list_dependencies/2`, `add_dependency/3`, `remove_dependency/3`, `create/3`, `annotate/3` — each shells out to corresponding `kata` subcommand; field-mapping validation; error handling via CodeMap | 4h | KATA-T008 | [ ] |
| KATA-T017 | Write `test/foreman_server/task_providers/kata_adapter_test.exs` — all 11 callbacks against `KataRunnerMock` via Mox; every happy path and error path; assert `available?/0` false when `kata` not installed | 6h | KATA-T008, KATA-T009, KATA-T010 | [ ] |

#### Story 1.3

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T018 | Create `lib/foreman_server/task_providers/kata_adapter/build_provider_error.ex` — `KataAdapter.BuildProviderError` factory; **single** `%ProviderError{}` construction site in `KataAdapter`; delegates to `BeadsAdapter.CodeMap`; `command.binary: "kata"`; `redacted_fields: ["assignee", "description"]`; AC-007-3 | 1h | KATA-T008 | [ ] |
| KATA-T019 | Verify all `ProviderError` construction in `KataAdapter` routes through `KataAdapter.BuildProviderError` (no direct `%ProviderError{}` literals in callback implementations) | 1h | KATA-T018 | [ ] |
| KATA-T020 | Write `test/foreman_server/task_providers/kata_architecture_test.exs` — scan for sole `System.cmd("kata", ...)` in `system_kata_runner.ex` only; scan for direct `KataAdapter` alias outside `task_providers/`; scan for `kata list --status claimed`/`in_progress` orphan-scanner invocations (REQ-014-3) | 3h | KATA-T002, KATA-T008 | [ ] |
| KATA-T021 | Add `config :foreman_server, :task_provider, providers: [..., ForemanServer.TaskProviders.KataAdapter]` to `config/config.exs` | 15m | KATA-T008 | [ ] |
| KATA-T022 | Update `config/config.exs` — add `accepted_kata_versions` to `task_provider` config block (format TBD — OPEN-Q2) | 1h | KATA-T021 | [ ] |

### 3.2 Sprint 2 — Quality: Error Handling, Concurrency, Registry Tightening

#### Story 2.1

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T023 | Integrate `ForemanServer.TaskProviders.ConcurrencyLimiter` into `KataAdapter` — wrap every `@runner.cmd/3` call; `max_in_flight: 4`, `timeout_ms: 30_000`; on queue timeout return `{:error, %ProviderError{code: "BR_TIMEOUT_QUEUE", retryable?: true}}` | 2h | KATA-T008 | [ ] |
| KATA-T024 | Write `test/foreman_server/task_providers/kata_concurrency_test.exs` — verify 4 in-flight slots; verify 5th caller blocks; verify `BR_TIMEOUT_QUEUE` on per-call timeout; verify slot released on normal return | 2h | KATA-T023 | [ ] |
| KATA-T025 | Verify `ConcurrencyLimiter` is shared between Beads and Kata adapters (same GenServer instance); configure separately in `Application` supervision tree if separate instances are required | 1h | KATA-T023 | [ ] |

#### Story 2.2

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T026 | Implement `KataAdapter.build_provider_error/3` routing through `BeadsAdapter.CodeMap` — structured Kata envelope → `BR_ERROR_ENVELOPE`; signal → `BR_SIGNAL`; timeout → `BR_TIMEOUT`; invalid JSON → `BR_INVALID_JSON` | 2h | KATA-T018 | [ ] |
| KATA-T027 | Implement `already_terminal` guard (REQ-013-1) — when `kata close` returns `already_terminal?: true` hint, return `{:ok, :already_terminal}`; unknown codes without hint → `BR_ERROR_ENVELOPE` | 1h | KATA-T026 | [ ] |
| KATA-T028 | Implement `CLAIMED_BY_OTHER` guard (REQ-013-2) — return `{:error, %ProviderError{code: "CLAIMED_BY_OTHER", retryable?: false, context: %{current_assignee_present?: true}}}`; context carries only boolean presence flag | 1h | KATA-T026 | [ ] |
| KATA-T029 | Write tests for all error envelope paths — structured reject codes, signal, timeout, invalid JSON, `already_terminal` guard, `claimed_by_other` guard | 2h | KATA-T026, KATA-T027, KATA-T028 | [ ] |

#### Story 2.3

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T030 | Extend `TaskProvider.Registry` capability validation (REQ-010-1) — validate `capabilities/0` maps: required keys `provider_id`, `contract_version`, `supports`, `storage_scheme`; value-type checking; invalid maps logged with `[:foreman_server, :task_provider, :registry, :invalid_capabilities]` and excluded from snapshot | 3h | KATA-T021 | [ ] |
| KATA-T031 | Audit `BeadsAdapter.capabilities/0` for ordering/optional-field issues the tightened validation would reject; fix any issues found; run full Beads adapter test suite to confirm no regressions | 2h | KATA-T030 | [ ] |
| KATA-T032 | Write `test/foreman_server/task_providers/kata_registry_tightening_test.exs` — verify both adapters pass through shared capability validation; verify overlapping `supports` sets both in snapshot; verify routing prefers providers with required transition | 2h | KATA-T030, KATA-T031 | [ ] |

### 3.3 Sprint 3 — Lifecycle: Claim, Close, Idempotency

#### Story 3.1

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T033 | Wire `KataAdapter.claim/3` into `RunExecutor` — before dispatch, call `KataAdapter.claim(issue.id, actor, opts)`; on `NOT_CLAIMABLE` error, re-call `list_ready/2` once; if issue no longer ready, drop from dispatch set + emit `[:foreman_server, :task_provider, :claim, :lost]` telemetry | 3h | KATA-T013, KATA-T011 | [ ] |
| KATA-T034 | Wire `KataAdapter.complete/3` into `RunExecutor` — on `TaskExecutionCompleted`, invoke `kata close <ref> --done --message "<msg>" --commit <sha>` with optional `--evidence`; on `ALREADY_CLOSED` → `{:ok, :already_terminal}`; on Kata-side reject → surface `BR_ERROR_ENVELOPE` and stop | 2h | KATA-T014, KATA-T033 | [ ] |
| KATA-T035 | Wire `KataAdapter.fail/3` into `RunExecutor` — on `TaskExecutionFailed`, invoke `kata reopen <ref>` then `kata comment <ref> --body "<reason>"`; return `{:ok, :reopened}`; this is the Foreman-side failure-path release only (Kata owns crash reconciliation) | 2h | KATA-T015, KATA-T033 | [ ] |
| KATA-T036 | Write `test/foreman_server/task_providers/kata_lifecycle_test.exs` — exercise claim → complete; exercise claim → fail (reopen + comment); exercise already-closed idempotency; exercise already-claimed conflict; exercise claim-lost re-list-and-drop | 3h | KATA-T033, KATA-T034, KATA-T035 | [ ] |

#### Story 3.2

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T037 | Document and verify REQ-014 enforcement — no code path under `lib/foreman_server/task_providers/` invokes `kata list --status claimed`/`in_progress`; architecture test (KATA-T020) covers this; add code-comment on `list_ready/2`: "Kata is authoritative for claim state — Foreman does NOT scan for orphans" | 1h | KATA-T011, KATA-T020 | [ ] |
| KATA-T038 | Verify OPEN-Q1 — `id_format` regex for Kata short_ids — consult `docs/reference/cli.md` in Kata repository; update `capabilities/0` if a different regex is documented; retain conservative default `"^[a-z]+[0-9]+$"` if unverifiable | 1h | KATA-T010 | [ ] |
| KATA-T039 | Verify OPEN-Q2 — Kata version-floor format for capability-refresh gate — consult Kata repository for structured version metadata format; update config if a format is documented; defer to a future REQ if unresolvable | 1h | KATA-T022 | [ ] |

### 3.4 Sprint 4 — Observability: Sensitive Fields, Doctor, Side-Channels

#### Story 4.1

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T040 | Implement sensitive field side-channel silence (REQ-017) — `assignee` and `description`/`body` MUST NOT appear in `Logger.*`, `IO.*`, `:telemetry` metadata, or `ProviderError.context` keys other than `redacted_fields`; `ProviderError` context allowlist: `id`, `command`, `exit_code`, `stderr_byte_count`, `sanitized?`, `redacted_fields`; `sanitized?` always `true`; `redacted_fields` always `["assignee", "description"]`; stderr unconditionally discarded (only `stderr_byte_count` retained) | 3h | KATA-T018 | [ ] |
| KATA-T041 | Write `test/foreman_server/task_providers/kata_side_channel_test.exs` — AC-017-1: sentinel payload via `CaptureLog.capture_log/1`; AC-017-2: via `CaptureIO.capture_io/2`; AC-017-3: telemetry handlers via `:telemetry_test.attach_event_handlers/2`; AC-017-4: `ProviderError.context` only allowlisted keys + `sanitized?` always `true`; AC-017-5: domain return struct DOES contain sentinel values | 4h | KATA-T040 | [ ] |
| KATA-T042 | Implement `foreman doctor` Kata section (REQ-016) — report: (a) configured `provider_id` and `contract_version`; (b) `kata --version` exit code and stdout; (c) sample `kata list --limit 1 --json` against each registered Kata project's working directory; (d) non-zero exit or missing-binary failures; when `available?/0` is false, report project as `unhealthy` with `stderr_byte_count` (informative, non-sensitive) | 3h | KATA-T009, KATA-T011 | [ ] |
| KATA-T043 | Write `test/foreman_server_web/kata_doctor_controller_test.exs` — verify doctor reports Kata section when adapter registered; verify `unhealthy` when `kata` missing or wrong version; verify `stderr_byte_count` reported, not raw stderr | 2h | KATA-T042 | [ ] |

### 3.5 Sprint 5 — Integration: End-to-End, Documentation, Cleanup

#### Story 5.1

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T044 | End-to-end integration test — create real `.kata.toml`-bound workspace via `kata init`; run `kata create "test issue"`; wire full `RunExecutor` lifecycle against real `KataAdapter` (not mock) in sandboxed temp directory; assert issue transitions `open` → claimed → closed; assert failure path reopens and comments; use `SystemKataRunner` with timeout | 4h | KATA-T033, KATA-T034, KATA-T035 | [ ] |
| KATA-T045 | Verify `KataAdapter` registered correctly in `TaskProvider.Registry` — integration test asserting `KataAdapter` in `routing_snapshot/0`; assert both `BeadsAdapter` and `KataAdapter` appear with overlapping `supports`; assert per-project provider config (REQ-003) routes correctly | 2h | KATA-T021, KATA-T032 | [ ] |
| KATA-T046 | Run full Foreman test suite (`mix test`) — all existing tests pass; new Kata adapter tests pass; no regressions in Beads adapter | 2h | KATA-T044, KATA-T045 | [ ] |

#### Story 5.2

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T047 | Update `docs/user-guide.md` — Kata adapter setup: `brew install kata` (macOS) or install script (Linux); `kata init` to bind workspace; `foreman doctor` to verify; operator triage commands (`kata list --status claimed`, `kata audit closes`, `kata reopen`, `kata claim`); note Foreman does NOT scan Kata for orphans | 2h | KATA-T042 | [ ] |
| KATA-T048 | Update `docs/cli-reference.md` — `foreman doctor` Kata section output format; note `task_provider` config accepts `provider: KataAdapter` only (no `KATA_HOME`, no `kata_home` fields) | 1h | KATA-T047 | [ ] |
| KATA-T049 | Write `packages/foreman_server/CHANGELOG.md` entry — adapter, provider id, contract version, supported operations, one-line per major change | 30m | KATA-T046 | [ ] |

#### Story 5.3

| id | task | Est. | Deps | Status |
|---|---|---|---|---|
| KATA-T050 | Code review pass — consistency with BeadsAdapter patterns; `@runner` compile-time binding; no `System.cmd` outside `SystemKataRunner`; no direct `KataAdapter` imports outside `task_providers/`; all `ProviderError` constructions route through factory | 1h | KATA-T020 | [ ] |
| KATA-T051 | Final architecture test run — run `mix test test/foreman_server/task_providers/kata_architecture_test.exs` alone to verify all three assertion classes pass | 30m | KATA-T050 | [ ] |

---

## 4. Acceptance Criteria Traceability

| REQ | Requirement | Priority | Tasks | ACs |
|---|---|---|---|---|
| REQ-001 | KataAdapter implements TaskProvider via `kata` CLI | Must | KATA-T008–T017 | AC-001-1 (T008), AC-001-2 (T009), AC-001-3 (T009) |
| REQ-002 | KataAdapter capability declaration | Must | KATA-T010, T021, T032, T038 | AC-002-1 (T010, T038), AC-002-2 (T032), AC-002-3 (T021) |
| REQ-003 | Per-project Kata configuration | Must | KATA-T021, T045 | AC-003-1 (T021), AC-003-2 (T021), AC-003-3 (T021), AC-003-4 (T045) |
| REQ-004 | Architecture test enforces KataAdapter boundaries | Must | KATA-T020, T037, T050 | AC-004-1 (T020), AC-004-2 (T020), AC-004-3 (T020) |
| REQ-005 | KataAdapter callback implementations | Must | KATA-T008, T011–T017 | AC-005-1 (T011), AC-005-2 (T013), AC-005-3 (T014), AC-005-4 (T015), AC-005-5 (T011), AC-005-6 (T016) |
| REQ-006 | Structured output parsing with field-mapping validation | Must | KATA-T011, T012, T016, T039 | AC-006-1 (T011, T012), AC-006-2 (T011, T012), AC-006-3 (T039) |
| REQ-007 | Provider error envelope (reuse Beads CodeMap) | Must | KATA-T018, T019, T026–T029 | AC-007-1 (T026), AC-007-2 (T026), AC-007-3 (T018, T019), AC-007-4 (T026) |
| REQ-008 | CLI process safety (mirror BeadsAdapter) | Must | KATA-T002, T007, T018 | AC-008-1 (T002), AC-008-2 (T002), AC-008-3 (T002), AC-008-4 (T002) |
| REQ-009 | CLI invocation concurrency limit | Should | KATA-T023–T025 | AC-009-1 (T023), AC-009-2 (T024) |
| REQ-010 | Generic registry tightening + Beads cleanup | Should | KATA-T030–T032 | AC-010-1 (T030), AC-010-2 (T032), AC-010-3 (T031) |
| REQ-011 | Pre-execution atomic claim via `kata claim` | Must | KATA-T013, T033 | AC-011-1 (T033), AC-011-2 (T033), AC-011-3 (T033) |
| REQ-012 | Post-execution close via `kata close` | Must | KATA-T014, T034, T035 | AC-012-1 (T034), AC-012-2 (T035), AC-012-3 (T034), AC-012-4 (T034) |
| REQ-013 | Idempotent transition guards | Must | KATA-T027, T028, T036 | AC-013-1 (T027), AC-013-2 (T028) |
| REQ-014 | Kata is authoritative for claims — operator triage only | Must | KATA-T020, T037 | AC-014-1 (T035), AC-014-2 (T037), AC-014-3 (T020) |
| REQ-015 | Sensitive fields = `assignee` + `body` | Should | KATA-T040 | AC-015-1 (T040), AC-015-2 (T040) |
| REQ-016 | `foreman doctor` integration for Kata | Could | KATA-T042, T043 | AC-016-1 (T042), AC-016-2 (T043) |
| REQ-017 | Adapter silent-by-default on Kata sensitive side-channels | Should | KATA-T040, T041 | AC-017-1 (T041), AC-017-2 (T041), AC-017-3 (T041), AC-017-4 (T041), AC-017-5 (T041) |

**Totals: 17 requirements, 56 ACs, 51 tasks.**

---

## 5. Foreman Compatibility Check

| Check | Result |
|---|---|
| Parser-safe | yes |
| Dependency-orphans | 0 |
| Uncovered REQs | 0 |
| Status cell violations (`[x]` / `done`) | 0 — all 51 tasks have `[ ]` |
| Task ID format | `KATA-T001` through `KATA-T051` |
| Dependency ordering | All dependencies satisfied — no circular deps |
| Required table columns | `id`, `task`, `Est.`, `Deps`, `Status` present in all story tables |

---

## 6. Reused Capabilities

| Capability | Source | Reuse Mechanism |
|---|---|---|
| `ForemanServer.TaskProvider` behaviour | `TRD-2026-48f7b420` | Unchanged import |
| `ForemanServer.TaskProvider.Issue` struct | `TRD-2026-48f7b420` | Unchanged import |
| `ForemanServer.TaskProvider.Registry` GenServer | `TRD-2026-48f7b420` | Unchanged import |
| `ForemanServer.TaskProviders.ConcurrencyLimiter` | `TRD-2026-48f7b420` | Shared GenServer under Application supervisor |
| `ForemanServer.TaskProviders.ProviderError` struct | `TRD-2026-48f7b420` | Unchanged import |
| `ForemanServer.TaskProviders.BeadsAdapter.CodeMap` | `TRD-2026-48f7b420` | `KataAdapter.BuildProviderError` delegates for error code selection |

---

## 7. Files Touched

**New library files:**
- `packages/foreman_server/lib/foreman_server/task_providers/kata_runner.ex`
- `packages/foreman_server/lib/foreman_server/task_providers/system_kata_runner.ex`
- `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
- `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter/build_provider_error.ex`

**New test-support file:**
- `packages/foreman_server/test/support/kata_runner_mock.ex`

**New test files:**
- `packages/foreman_server/test/foreman_server/task_providers/kata_runner_test.exs`
- `packages/foreman_server/test/foreman_server/task_providers/system_kata_runner_test.exs`
- `packages/foreman_server/test/foreman_server/task_providers/kata_adapter_test.exs`
- `packages/foreman_server/test/foreman_server/task_providers/kata_architecture_test.exs`
- `packages/foreman_server/test/foreman_server/task_providers/kata_side_channel_test.exs`
- `packages/foreman_server/test/foreman_server/task_providers/kata_registry_tightening_test.exs`
- `packages/foreman_server/test/foreman_server/task_providers/kata_concurrency_test.exs`
- `packages/foreman_server/test/foreman_server/task_providers/kata_lifecycle_test.exs`
- `packages/foreman_server/test/foreman_server_web/kata_doctor_controller_test.exs`

**Modified files:**
- `packages/foreman_server/mix.exs` — add `elixirc_paths(:test)` if absent
- `packages/foreman_server/config/test.exs` — add `kata_runner` config
- `packages/foreman_server/config/config.exs` — add `KataAdapter` to providers, add `accepted_kata_versions`
- `packages/foreman_server/lib/foreman_server/application.ex` — add `ConcurrencyLimiter` child if needed
- `docs/user-guide.md` — add Kata adapter setup section
- `docs/cli-reference.md` — add `foreman doctor` Kata output format

---

## 8. Open Questions (Verification Tasks)

These are NOT design decisions — they are verification tasks against Kata's published docs that MUST resolve before implementation lands:

| ID | Item | Verification Source | Blocks |
|---|---|---|---|
| OPEN-Q1 | Exact `id_format` regex for Kata short_ids | `docs/reference/cli.md` in Kata repository | KATA-T038 |
| OPEN-Q2 | Kata version-floor format for capability-refresh gate | Kata repository version metadata | KATA-T039 |

---

## 9. Non-Goals (from PRD §7)

- Kata federation/hub integration
- Postgres `KATA_DSN` backend
- Kata semantic search / MCP server
- GitHub sync / `kata import` migration paths
- Foreman-owned crash reconciliation (Foreman does NOT scan Kata for orphans)
