---
document_id: TRD-2026-8030852f
label: trd-foreman-kata-task-provider
version: 2.0.4
status: Draft
date: 2026-11-18
prd_reference: PRD-2026-8030852f
prd_label: prd-foreman-kata-task-provider
scale_depth: STANDARD
total_requirements: 17
total_acceptance_criteria: 57
design_readiness_score: 4.3
readiness_score: 4.3
kind: trd
---

# TRD: Foreman × Kata (kenn.io/kata) — Task-Provider Integration

## 1. Executive Summary

This TRD turns PRD `PRD-2026-8030852f-foreman-kata-task-provider` (v1.1.7, readiness 4.5 PASS, 17 REQs, 57 ACs; source file `docs/PRD/PRD-2026-8030852f-foreman-kata-task-provider.md`) into a concrete implementation plan for the `KataAdapter` — the second `TaskProvider` adapter that lets Kata (kenn.io/kata) act as the authoritative task tracker alongside the existing Beads adapter. The PRD micro UUID `8030852f` is preserved unchanged so PRD/TRD artifacts correlate 1:1. The label prefix changes from `prd-` to `trd-` (`trd-foreman-kata-task-provider`); the label is display-only and all cross-references use the micro UUID.

The implementation lives under `packages/foreman_server/` (the Foreman repo's Phoenix package) plus one change in `packages/foreman_cli/` (the Go CLI) — paths in this TRD are repo-relative. The slice is supervised by the existing `ForemanServer.Application` supervisor tree; new supervisor children are added, not a parallel OTP application.

The Kata adapter is materially shorter than the Beads adapter in three ways: (i) no `--db` per-call flag and no `database_path` (Kata resolves the project from the `.kata.toml` binding at or above the working directory each call runs in; `KATA_HOME` is Kata's own daemon state and is never Foreman config); (ii) no `br schema --json` schema-fetching ceremony (Kata's `--json` output is validated by simple field-mapping rather than JSON Schema); (iii) no Foreman-side orphan scanner — Kata's claim lifecycle is encapsulated by Kata, and the operator uses Kata's native commands to triage. The architectural template is identical to BeadsAdapter; the surface area is smaller, and the multi-tracker parity pattern is demonstrated end-to-end.

The TRD delivers in five vertical slices, one `### PR N:` section each in the Master Task List:

1. **PR 1** — Foundation: `KataRunner` behaviour (`cmd/3` interface), `SystemKataRunner` (sole `System.cmd("kata", ...)` site), `KataRunnerMock` at `test/support/`, `KataAdapter` implementing all 13 TaskProvider callbacks (`name/0`, `create/2`, `capabilities/0`, `available?/0`, `list_ready/2`, `get/2`, `claim/3`, `complete/3`, `fail/3`, `reopen/3`, `set_priority/3`, `add_dependency/3`, `annotate/3`), surgical `mix.exs` + `config/test.exs` + `config/config.exs` updates (provider registration and `"kata.capabilities.v1"` in `accepted_contract_versions`). KataAdapter dispatches every callback through `@runner.cmd/3` (compile-time-bound via `Application.compile_env/3`). No schema cache — Kata validates by simple field-mapping. No orphan scanner — Kata is authoritative for claim state.

2. **PR 2** — Quality: Architecture test (`kata_architecture_test.exs`) enforcing sole-allowed `System.cmd("kata", ...)` site and no out-of-`task_providers/` adapter alias; `ProviderError` factory reusing `BeadsAdapter.CodeMap` (single allowed construction site via `KataAdapter.build_provider_error/3`); concurrency limiter (`max_in_flight: 4`) now supervised by `ForemanServer.Application`; generic registry tightening + any Beads cleanup required by REQ-010; per-project `cwd` binding without `database_path` (Go CLI emits `config.cwd`, server routing and preflight key on `capabilities[:storage_scheme]`, `KataAdapter` runs every call in that directory).

3. **PR 3** — Lifecycle: Pre-execution atomic claim via `kata claim <ref> --if-unowned`; post-execution close via `kata close <ref> --done --message --commit [--evidence]`; failure path via `kata reopen`, `kata comment` and `kata unassign --expect-owner` (Kata has no failure close reason, and `reopen` leaves the claim owner set, so the unassign is what returns the task to the ready list); idempotency guards for already-closed and already-claimed states.

4. **PR 4** — Observability: Sensitive fields (`assignee` + `description`/`body`) side-channel silence (Logger/IO/telemetry/ProviderError.context); provider-generic `foreman doctor` with a Kata section and smoke tests.

5. **PR 5** — Integration: end-to-end test against a real `kata` binary, full-suite run, user-guide / CLI-reference / CHANGELOG updates, final architecture gate.

**Reused Capabilities:** This TRD reuses the following capabilities from foundational work established by `TRD-2026-48f7b420`:
- `ForemanServer.TaskProvider` behaviour (already production-grade) — reuse via existing behaviour
- `ProviderError` envelope and `BeadsAdapter.CodeMap` — reuse for error code selection in `KataAdapter.build_provider_error/3`
- `ForemanServer.TaskProviders.ConcurrencyLimiter` — reuse the module unchanged; supervision under `ForemanServer.Application` is added by KATA-T055 because nothing starts it today
- `ForemanServer.TaskProvider.Registry` — reuse; extended generically by KATA-T030 (capability validation) and KATA-T053 (storage-scheme routing), with no Kata-specific branch
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
- **Per-project binding:** follows from rejecting Option D below — the Go CLI emits `task_provider.config.cwd` for Kata (KATA-T052), server routing, preflight and `foreman doctor` key on `capabilities[:storage_scheme]` instead of a hardcoded `database_path` (KATA-T053, KATA-T056), and `KataAdapter` passes that `cwd` to every `kata` call (KATA-T054).
- **Risk:** LOW.


#### Option D — Server-side default for `database_path` (REJECTED)

Let `validateTaskProviderConfig` in `packages/foreman_cli/cmd/foreman/project.go:751` keep ignoring `--task-provider-database-path` for non-`beads` providers, and have the server synthesize a Kata project config so the projector's non-nil `database_path` gate (`project_provider_projector.ex:233`) passes.

- **Pros:** No Go-side change.
- **Cons:** Invents a path Foreman never reads for Kata, so `foreman doctor` (`doctor_task_provider.ex:77-85`) would either report a phantom path or a false `DATABASE_PATH_MISSING`. A synthesized value that no code path consumes is exactly the plausible-looking success the repo rules forbid.
- **Risk:** MEDIUM.

### 2.2 Chosen Architecture (Option C)

#### 2.2.1 Component Boundaries

| Path | Module | Responsibility |
|---|---|---|
| `task_providers/kata_runner.ex` | `ForemanServer.TaskProviders.KataRunner` | Behaviour contract defining `cmd/3` — shared by `SystemKataRunner` and `KataRunnerMock`. Mirrors `BrRunner`. |
| `task_providers/system_kata_runner.ex` | `ForemanServer.TaskProviders.SystemKataRunner` | Production implementation. **Sole** direct `System.cmd("kata", ...)` call-site in entire `lib/foreman_server/` tree. POSIX shell-quote; SIGTERM → 5s grace → SIGKILL; temp-file cleanup. |
| `task_providers/kata_adapter.ex` | `ForemanServer.TaskProviders.KataAdapter` | Production adapter. `@runner Application.compile_env(:foreman_server, :kata_runner, ForemanServer.TaskProviders.SystemKataRunner)`. All 13 TaskProvider callbacks (`name/0`, `create/2`, `capabilities/0`, `available?/0`, `list_ready/2`, `get/2`, `claim/3`, `complete/3`, `fail/3`, `reopen/3`, `set_priority/3`, `add_dependency/3`, `annotate/3`) via `@runner.cmd/3`. Routes through `KataAdapter.BuildProviderError` which delegates to `BeadsAdapter.CodeMap`. Field-mapping validation (no JSON Schema). |
| `task_providers/kata_adapter/build_provider_error.ex` | `ForemanServer.TaskProviders.KataAdapter.BuildProviderError` | **Single** `%ProviderError{}` construction site in `KataAdapter`. Delegates to `BeadsAdapter.CodeMap`. `command.binary: "kata"`. `redacted_fields: ["assignee", "description"]`. |

**Test-support:** `test/support/kata_runner_mock.ex` — `Mox.defmock(KataRunnerMock, for: KataRunner)`.

**Test files:** `kata_runner_test.exs`, `system_kata_runner_test.exs`, `kata_adapter_test.exs`, `kata_architecture_test.exs` (sole `System.cmd` scan + orphan-scanner-absence scan + adapter-alias scan), `kata_side_channel_test.exs` (sentinel capture), `kata_registry_tightening_test.exs`, `kata_concurrency_test.exs`, `kata_lifecycle_test.exs`, `kata_e2e_test.exs`, `registry_routing_test.exs`; Kata cases are added to the existing `cli/doctor_task_provider_test.exs`, `task_provider/project_provider_projector_test.exs`, `task_provider/registry_route_test.exs`, `application_children_test.exs` and the Go `project_test.go`.

**Inherited (reused as-is):** `ForemanServer.TaskProvider`, `ForemanServer.TaskProvider.Issue`, `ForemanServer.TaskProviders.ProviderError`, `ForemanServer.TaskProviders.BeadsAdapter.CodeMap`. **Inherited and extended generically (no Kata-specific branch):** `ForemanServer.TaskProvider.Registry` (KATA-T030, T053), `ProjectProviderProjector` and `run_executor.ex` routing (KATA-T053), `BeadsAdapter.capabilities/0` (KATA-T031), `ForemanServer.Cli.DoctorTaskProvider` (KATA-T056), the Go `project.go` provider payload (KATA-T052). **Inherited and newly wired:** `ForemanServer.TaskProviders.ConcurrencyLimiter` — the module is unchanged but nothing starts it today; KATA-T055 supervises it.

#### 2.2.2 Data Flow

**Read path (`list_ready/2`):**

```
caller → TaskProvider.Registry.route/2 → KataAdapter.list_ready/2
  → @runner.cmd(["ready", "--unowned", "--json"], project_config[:cwd], opts)
  → field-mapping validation → {:ok, [%TaskProvider.Issue{}]}
```

**Claim path (`kata claim <ref> --if-unowned`):** single atomic op; on a `CLAIMED_BY_OTHER` refusal (stderr `already_claimed`, exit 5) → re-call `list_ready/2` once; if no longer ready → drop from dispatch set + telemetry.

**Close path:** `kata close <ref> --done --message "<msg>" --commit <sha>` [+ `--evidence`], message at least 40 characters (padded when defaulted); an already-closed issue is not an error — the close envelope carries `changed: false`, which maps to `{:ok, :already_terminal}`.

**Failure path:** `kata status <ref> --json` first (`$.actor`, `$.owner`); when a different actor owns the task, write nothing and return `CLAIMED_BY_OTHER`; otherwise `kata reopen <ref>` + `kata comment <ref> --body "<reason>" --idempotency-key foreman-fail:<run_id>:<body_hash>` + `kata unassign <ref> --expect-owner <actor>` unless the task is already unowned (Kata has no failure close reason; `reopen` leaves the claim owner set, so the unassign is what returns the task to `kata ready --unowned`; `<actor>` is `$.actor`, never `$.owner` and never `kata whoami`).

#### 2.2.3 Technology Choices

| Choice | Decision | Rationale |
|---|---|---|
| Transport | CLI (`kata` binary) | CONCERN 1 "CLI only" — Kata's daemon is Kata's internal concern |
| Schema validation | Simple field-mapping | No `kata schema` equivalent — required keys `short_id`, `title`, `status`; `priority` is optional (Kata leaves it unset). Keys observed on `kata` v0.23.0 (PRD §11) |
| Error envelope | `BeadsAdapter.CodeMap` | CONCERN 12 — no new error atoms; `command.binary: "kata"` for operator visibility |
| Claim serialization | `kata claim <ref> --if-unowned` atomic | CONCERN 4 — no parallel Foreman lease layer for Kata |
| Orphan handling | Operator triage only | CONCERN 8 — Foreman does NOT scan Kata; no `[:reconcile, :*]` telemetry |
| Concurrency | One supervised `ConcurrencyLimiter` (KATA-T055) used by Kata | `max_in_flight: 4`, `BR_TIMEOUT_QUEUE` on queue timeout; the limiter is a single globally named GenServer and the Beads adapter does not call it (KATA-T025) |

---

## Master Task List

Task IDs are `TRD-KATA-T###`, with an optional `-TEST` suffix marking a test task (`TRD-KATA-T017-TEST`). The PRD §12 task identity is the `KATA-T###` stem, and §4 and PRD §12 keep using the stem. The `TRD-` prefix exists only because the Ensemble TRD parser recognises task lines of the form `- [ ] **TRD-…**`. Every status checkbox is `[ ]`. Paths are repo-relative. Story headings are for navigation; the parser groups tasks by the `### PR N:` boundaries.

### PR 1: Foundation — Adapter Skeleton + Test Infrastructure

**Shippable State:** A developer can run the Kata adapter's 13 `TaskProvider` callbacks end to end through the mock runner and see Kata accepted by the registry (`routing_snapshot/0` lists provider `:kata` with contract `kata.capabilities.v1`); the unit and architecture tests pass. No Foreman project is bound to Kata yet.

#### Story 1.1 — Runner behaviour, system runner and test support

- [ ] **TRD-KATA-T001**: Create `lib/foreman_server/task_providers/kata_runner.ex` (1h)
  - PRD task ID: KATA-T001
  - Description: Create `lib/foreman_server/task_providers/kata_runner.ex` — behaviour defining `cmd/3` callback with spec `(argv :: [String.t()], cwd :: Path.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, ProviderError.t()}`
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_runner.ex`
  - Implementation AC:
    - [ ] `KataRunner` declares exactly one callback, `cmd/3`, with the spec `(argv :: [String.t()], cwd :: Path.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, ProviderError.t()}`
- [ ] **TRD-KATA-T002**: Create `lib/foreman_server/task_providers/system_kata_runner.ex` (4h) [satisfies REQ-008]
  - PRD task ID: KATA-T002
  - Description: Create `lib/foreman_server/task_providers/system_kata_runner.ex` — sole `System.cmd("kata", ...)` site; POSIX shell-quote each argv element; capture OS PID via `Port.info/2`; SIGTERM → 5s grace → SIGKILL on timeout; temp-file cleanup in `try/after` block; default per-call timeout 30 s (PRD §10), overridable per call through `opts`; a timeout kills the child and returns the retryable timeout error (`BR_TIMEOUT_SUBPROCESS`, KATA-T026)
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/system_kata_runner.ex`
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-008-3, AC-008-4
  - Implementation AC:
    - [ ] AC-008-1 — Arguments reach the CLI as discrete argv elements with no shell interpolation, so a task title containing shell metacharacters cannot alter the command.
    - [ ] AC-008-2 — A CLI call that exceeds the configured timeout is terminated (grace period first, then forced kill), and the caller receives a typed retryable timeout error.
    - [ ] AC-008-3 — Temporary files created to capture CLI output are removed on both the success and the failure path.
    - [ ] AC-008-4 — The adapter surfaces the OS process id of the child it spawned for diagnosis, without exposing the child's output text beyond the redaction policy.
  - Dependencies: TRD-KATA-T001
- [ ] **TRD-KATA-T003**: Create `test/support/kata_runner_mock.ex` (1h)
  - PRD task ID: KATA-T003
  - Description: Create `test/support/kata_runner_mock.ex` — `Mox.defmock(ForemanServer.TaskProviders.KataRunnerMock, for: ForemanServer.TaskProviders.KataRunner)`; compiles only in `:test` env via `elixirc_paths(:test)`
  - Target Files: `packages/foreman_server/test/support/kata_runner_mock.ex`
  - Implementation AC:
    - [ ] `ForemanServer.TaskProviders.KataRunnerMock` is defined by `Mox.defmock` against `KataRunner` and exists only where `test/support` is compiled (the `:test` env)
  - Dependencies: TRD-KATA-T001
- [ ] **TRD-KATA-T004**: Update `mix.exs` (0.25h)
  - PRD task ID: KATA-T004
  - Description: Update `mix.exs` — add `defp elixirc_paths(:test), do: ["lib", "test/support"]` if absent
  - Target Files: `packages/foreman_server/mix.exs`
  - Implementation AC:
    - [ ] `mix compile` under `MIX_ENV=test` compiles `test/support`; under `dev` and `prod` it does not
- [ ] **TRD-KATA-T005**: Update `config/test.exs` (0.25h)
  - PRD task ID: KATA-T005
  - Description: Update `config/test.exs` — add `config :foreman_server, :kata_runner, ForemanServer.TaskProviders.KataRunnerMock`
  - Target Files: `packages/foreman_server/config/test.exs`
  - Implementation AC:
    - [ ] Under `MIX_ENV=test`, `Application.fetch_env!(:foreman_server, :kata_runner)` is `ForemanServer.TaskProviders.KataRunnerMock`
  - Dependencies: TRD-KATA-T003
- [ ] **TRD-KATA-T006-TEST**: Write `test/foreman_server/task_providers/kata_runner_test.exs` (1h) [satisfies REQ-001]
  - PRD task ID: KATA-T006
  - Description: Write `test/foreman_server/task_providers/kata_runner_test.exs` — verify behaviour exports and callback arities
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_runner_test.exs`
  - Test AC:
    - [ ] The test fails if `KataRunner.behaviour_info(:callbacks)` is anything other than `[cmd: 3]`
  - Dependencies: TRD-KATA-T001
- [ ] **TRD-KATA-T007-TEST**: Write `test/foreman_server/task_providers/system_kata_runner_test.exs` (2h) [satisfies REQ-008]
  - PRD task ID: KATA-T007
  - Description: Write `test/foreman_server/task_providers/system_kata_runner_test.exs` — test shell_quote edge cases; test SIGTERM/SIGKILL escalation; test temp-file cleanup telemetry
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/system_kata_runner_test.exs`
  - Test AC:
    - [ ] Shell-quote cases (space, single and double quote, `$`, backtick, newline, empty string) reach the child as one unchanged argv element
    - [ ] A child that ignores SIGTERM is killed with SIGKILL after the 5 s grace period and the caller receives the timeout error
    - [ ] The temp file is removed after both a successful and a failing call
  - Dependencies: TRD-KATA-T002

#### Story 1.2 — KataAdapter callbacks

- [ ] **TRD-KATA-T008**: Create `lib/foreman_server/task_providers/kata_adapter.ex` (6h) [satisfies REQ-001, REQ-005]
  - PRD task ID: KATA-T008
  - Description: Create `lib/foreman_server/task_providers/kata_adapter.ex` — implement all 13 TaskProvider callbacks (`name/0`, `create/2`, `capabilities/0`, `available?/0`, `list_ready/2`, `get/2`, `claim/3`, `complete/3`, `fail/3`, `reopen/3`, `set_priority/3`, `add_dependency/3`, `annotate/3`); each routes through `@runner.cmd/3`; declare `@runner Application.compile_env(:foreman_server, :kata_runner, ForemanServer.TaskProviders.SystemKataRunner)`; `id_format` = `"^[a-z0-9]+$"` per PRD §11 OPEN-Q1 resolution
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-001-1, AC-001-3
  - Implementation AC:
    - [ ] AC-001-1 — A module `ForemanServer.TaskProviders.KataAdapter` exists, exports all 13 `TaskProvider` callbacks, and passes the registry's `behaviour_info(:callbacks)` validation without any registry exemption.
    - [ ] AC-001-3 — Every Kata read in the adapter goes through the runner; no code path in the adapter opens a Kata database file, speaks a daemon protocol, or shells out to any binary other than `kata`.
  - Dependencies: TRD-KATA-T002
- [ ] **TRD-KATA-T009**: Implement `available?/0` (1h)
  - PRD task ID: KATA-T009
  - Description: Implement `available?/0` — `System.find_executable("kata")` nil → `false`; `kata --version` (prints `kata v<semver> commit: … built: …`) non-zero exit → `false`; both pass → `true`. No version gate here: an installed version outside `accepted_kata_versions` is a doctor warning (KATA-T042), never `available?/0 == false`
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-002-3
  - Implementation AC:
    - [ ] AC-002-3 — `available?/0` returns `false` — without raising — when `kata` is not findable on `PATH` **or** when `kata --version` exits non-zero (a broken or unusable binary); it returns `true` only when the binary is found and the version probe succeeds. A version that reports successfully but sits outside the accepted range does NOT make `available?/0` false: range drift is a `foreman doctor` warning (REQ-016) and calls still proceed.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T010**: Implement `capabilities/0` (1h) [satisfies REQ-002]
  - PRD task ID: KATA-T010
  - Description: Implement `capabilities/0` — return `provider_id: :kata`, `contract_version: "kata.capabilities.v1"`, `supports: [:create, :claim, :close, :reopen, :annotate, :set_priority, :set_assignee, :list_dependencies, :add_dependency, :remove_dependency]` (the PRD AC-002-1 transition vocabulary, same shape as `BeadsAdapter`; it is not a callback list — `TaskProvider` declares no `set_assignee`, `list_dependencies` or `remove_dependency` callbacks), `storage_scheme: :cli_process` (no database file, so no `database_path`; routing and preflight key off this value), `id_format: "^[a-z0-9]+$"` (PRD §11 OPEN-Q1 resolution)
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-001-2, AC-002-1
  - Implementation AC:
    - [ ] AC-001-2 — `name/0` returns a human-readable provider name; `capabilities/0[:provider_id]` returns `:kata`; `contract_version` is `"kata.capabilities.v1"`; that version string is present in the `:foreman_server, :task_provider` config's `accepted_contract_versions` list so startup registration succeeds.
    - [ ] AC-002-1 — `capabilities/0` returns a map with `provider_id: :kata`, `contract_version: "kata.capabilities.v1"`, a non-empty `supports` list covering all supported operations, and `storage_scheme: :cli_process`.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T011**: Implement `list_ready/2` (2h) [satisfies REQ-006]
  - PRD task ID: KATA-T011
  - Description: Implement `list_ready/2` — invoke `kata ready --unowned --json` in `project_config[:cwd]` (open, unblocked, unscheduled, unowned issues; `kata list` is not used because it also returns claimed and blocked issues; never `--all`, which spans projects); the payload is `{"issues": [...]}`; validate every record through field-mapping (required `short_id`, `title`, `status`; optional `priority`); map to `%TaskProvider.Issue{}` — `id` from `short_id`, `description` from `body`, `assignee` from `owner`; other Kata fields under `metadata`; return `{:ok, [Issue.t()]}` per the `list_ready_result` type
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-005-1, AC-006-1, AC-006-2, AC-006-3
  - Implementation AC:
    - [ ] AC-005-1 — `list_ready/2` returns the ready (unclaimed, dependency-satisfied) Kata tasks as `TaskProvider.Issue` structs; `get/2` returns one task by Kata reference; both accept a project config and honor it as the working directory.
    - [ ] AC-006-1 — `get/2` rejects a Kata payload missing `short_id`, `title`, or `status` with a typed schema-validation error naming the missing fields; it does not substitute placeholder values. `priority` is optional: Kata leaves it unset until an operator sets it, and an absent `priority` maps to no priority rather than an error.
    - [ ] AC-006-2 — The same field-mapping validation applies to every list-producing path, so a partially-malformed list yields validated records or a typed error — never a partially-populated record.
    - [ ] AC-006-3 — Kata-specific fields that have no first-class Foreman equivalent (for example `uid`, `author`, `revision`, `qualified_id`, `web_url` and the timestamps) are preserved under the issue's `metadata`, and the Foreman fields are filled from Kata's real keys: `id` from `short_id`, `description` from `body`, `assignee` from `owner` (present only while the issue is claimed), `labels` and `dependencies` from `show`'s `labels` and `links`; a Foreman field Kata does not emit (`notes`, `design`) stays empty rather than being invented.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T012**: Implement `get/2` (1h)
  - PRD task ID: KATA-T012
  - Description: Implement `get/2` — invoke `kata show <ref> --json` (payload `{issue, comments, links, labels}`); field-mapping validation rejects a missing `short_id`/`title`/`status` with `SCHEMA_VALIDATION_FAILED` (`priority` optional); `labels` and `dependencies` come from `show`'s `labels` and `links`
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-006-1, AC-006-2, AC-006-3
  - Implementation AC:
    - [ ] AC-006-1 — `get/2` rejects a Kata payload missing `short_id`, `title`, or `status` with a typed schema-validation error naming the missing fields; it does not substitute placeholder values. `priority` is optional: Kata leaves it unset until an operator sets it, and an absent `priority` maps to no priority rather than an error.
    - [ ] AC-006-2 — The same field-mapping validation applies to every list-producing path, so a partially-malformed list yields validated records or a typed error — never a partially-populated record.
    - [ ] AC-006-3 — Kata-specific fields that have no first-class Foreman equivalent (for example `uid`, `author`, `revision`, `qualified_id`, `web_url` and the timestamps) are preserved under the issue's `metadata`, and the Foreman fields are filled from Kata's real keys: `id` from `short_id`, `description` from `body`, `assignee` from `owner` (present only while the issue is claimed), `labels` and `dependencies` from `show`'s `labels` and `links`; a Foreman field Kata does not emit (`notes`, `design`) stays empty rather than being invented.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T013**: Implement `claim/3` (1h) [satisfies REQ-011]
  - PRD task ID: KATA-T013
  - Description: Implement `claim/3` — invoke `kata claim <ref> --if-unowned` (single atomic claim; Kata refuses a claim on an owned issue unless `--force`, which Foreman never passes); on success return `{:ok, %TaskProvider.Issue{}}` built from the claim's `--json` envelope (`{issue, event}`, observed on `kata` v0.23.0) — never a second claim; on stderr `error.code: "already_claimed"` (exit 5) return `{:error, %ProviderError{code: "CLAIMED_BY_OTHER"}}` via CodeMap; any other refusal goes through the KATA-T026 mapping
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-005-2
  - Implementation AC:
    - [ ] AC-005-2 — `claim/3` issues exactly one atomic Kata claim operation for the given reference and returns the claimed task.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T014**: Implement `complete/3` (2h) [satisfies REQ-012]
  - PRD task ID: KATA-T014
  - Description: Implement `complete/3` — invoke `kata close <ref> --done --message "<msg>" --commit <sha>` with optional `--evidence`; when no message is supplied fabricate the deterministic default `"foreman-run:<run_id>:<artifact_path>"` padded to satisfy Kata's 40-character minimum for `--done`; on success return `{:ok, :terminal}` (`run_executor.ex` matches `{:ok, term()}`, not bare `:ok`)
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-005-3
  - Implementation AC:
    - [ ] AC-005-3 — `complete/3` closes the task in Kata with the run's completion message, the produced commit SHA, and evidence when available.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T015**: Implement `fail/3` (1h)
  - PRD task ID: KATA-T015
  - Description: Implement `fail/3` — four Kata calls, each with `--json` so the output is the full envelope (top-level `kata_api_version`), in this order. (1) `kata status <ref> --json`: read `$.actor` (the effective, daemon-aware actor) and `$.owner` (a string; the key is absent when the task is unowned, where `$.hold` is `"unassigned"`); this is one call on the single reference being failed, not a sweep (AC-014-2). If `$.owner` is a string different from `$.actor`, write nothing — no reopen, comment or unassign — and return a `CLAIMED_BY_OTHER` `ProviderError` built through `KataAdapter.BuildProviderError`, with no owner name in its context. That code is retryable in `BeadsAdapter.CodeMap`, so `RunExecutor.fail_retry_loop` repeats the notification on its 1 s / 5 s / 15 s schedule; every repeat re-reads the status and writes nothing, so another operator's issue never collects a failure comment. (2) `kata reopen <ref> --json`: `$.changed == false` on an already-open issue is success, not an error (observed on `kata` v0.23.0: after a claim, reopen is a no-op and leaves `owner` set, so the unassign is what returns the task to `kata ready --unowned`). (3) `kata comment <ref> --body "<reason>" --idempotency-key foreman-fail:<run_id>:<body_hash> --json`: `<run_id>` is `failure_token.run_id` (set by `build_failure_token/2`), `<reason>` is the token's rendered reason text, and `<body_hash>` is the first 16 hex characters of the SHA-256 of that exact body, so the key and the body always move together. `fail_retry_loop` rebuilds an identical token for each retry, and Kata replays an identical comment as `$.changed == false` with no event and no second comment, so a retry after a transient unassign failure never duplicates the comment; a differently worded comment under the same run gets a different key instead of being refused (a reused key with a different body is `idempotency_mismatch`, exit 5, which KATA-T026 maps to `BR_ERROR_ENVELOPE`). Read only `$.changed`; `changed: false` is success. An already-unowned task still gets steps 2 and 3, so the failure is always recorded. (4) Unless step 1 found the task unowned (`$.owner` absent, already released), `kata unassign <ref> --expect-owner <actor> --json`: success is `$.changed == true` with `$.event.type == "issue.unassigned"` (the issue object then has no `owner` key); an `owner_mismatch` refusal (kind `conflict`, exit 5, meaning ownership changed after step 1) maps to `CLAIMED_BY_OTHER` through KATA-T026. No `error.data` field is read anywhere in `fail/3`, so KATA-T026's rule that `data` never reaches the error context holds. `<actor>` comes from `$.actor` only — never from `kata whoami` (client-selected actor) and never from `$.owner`. Return `{:ok, :reopened}`, the `{:ok, _}` shape `RunExecutor` matches (the `@callback fail/3` spec in `task_provider.ex` still reads `:ok | {:error, term()}`; reconciling that spec is a separate change); MUST NOT fabricate `kata close --reason=fail` (Kata has no failure close reason)
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-005-4
  - Implementation AC:
    - [ ] AC-005-4 — `fail/3` reopens the task in Kata, records the failure reason as a comment, and then releases Foreman's own claim so the task is claimable again; when a different actor owns the task it writes nothing and returns a typed error; it never fabricates a close-with-reason to simulate failure.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T016**: Implement `create/2`, `reopen/3`, `set_priority/3`, `add_dependency/3` and `annotate/3` (4h)
  - PRD task ID: KATA-T016
  - Description: Implement `create/2`, `reopen/3`, `set_priority/3`, `add_dependency/3` and `annotate/3` — each shells out to the corresponding `kata` subcommand (`kata create "<title>" --body … --json`, `kata reopen`, `kata edit`, `kata comment`); field-mapping validation; error handling via CodeMap. These are the five remaining of the behaviour's 13 callbacks (with T008–T015: `name/0`, `capabilities/0`, `available?/0`, `list_ready/2`, `get/2`, `claim/3`, `complete/3`, `fail/3`)
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-005-5, AC-005-6
  - Implementation AC:
    - [ ] AC-005-5 — `reopen/3`, `set_priority/3`, `add_dependency/3`, and `annotate/3` each perform the corresponding Kata operation and return success only when Kata reports success.
    - [ ] AC-005-6 — `create/2` creates a Kata task from the supplied attributes and returns the created task.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T017-TEST**: Write `test/foreman_server/task_providers/kata_adapter_test.exs` (6h) [satisfies REQ-001, REQ-005, REQ-006]
  - PRD task ID: KATA-T017
  - Description: Write `test/foreman_server/task_providers/kata_adapter_test.exs` — all 13 callbacks against `KataRunnerMock` via Mox; every happy path and error path; assert `available?/0` false when `kata` not installed
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_adapter_test.exs`
  - Test AC:
    - [ ] Each of the 13 callbacks has a happy-path and an error-path test against `KataRunnerMock`
    - [ ] `available?/0` returns `false` when `System.find_executable("kata")` is `nil` and when `kata --version` exits non-zero
  - Dependencies: TRD-KATA-T008, TRD-KATA-T009, TRD-KATA-T010, TRD-KATA-T003, TRD-KATA-T005

#### Story 1.3 — Error factory, architecture test and registration

- [ ] **TRD-KATA-T018**: Create `lib/foreman_server/task_providers/kata_adapter/build_provider_error.ex` (1h) [satisfies REQ-007]
  - PRD task ID: KATA-T018
  - Description: Create `lib/foreman_server/task_providers/kata_adapter/build_provider_error.ex` — `KataAdapter.BuildProviderError` factory; **single** `%ProviderError{}` construction site in `KataAdapter`; delegates to `BeadsAdapter.CodeMap`; `command.binary: "kata"`; `redacted_fields: ["assignee", "description"]`; AC-007-3
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter/build_provider_error.ex`
  - Validates PRD ACs: AC-007-3
  - Implementation AC:
    - [ ] AC-007-3 — Every `ProviderError` produced by the adapter carries `command.binary: "kata"` in its context, together with the run's identifier, exit code, and stderr byte count — never the stderr text.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T019**: Verify `ProviderError` construction routes through `KataAdapter.BuildProviderError` (1h)
  - PRD task ID: KATA-T019
  - Description: Verify all `ProviderError` construction in `KataAdapter` routes through `KataAdapter.BuildProviderError` (no direct `%ProviderError{}` literals in callback implementations)
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-007-3
  - Implementation AC:
    - [ ] AC-007-3 — Every `ProviderError` produced by the adapter carries `command.binary: "kata"` in its context, together with the run's identifier, exit code, and stderr byte count — never the stderr text.
  - Dependencies: TRD-KATA-T018
- [ ] **TRD-KATA-T020-TEST**: Write `test/foreman_server/task_providers/kata_architecture_test.exs` (3h) [satisfies REQ-004, REQ-014]
  - PRD task ID: KATA-T020
  - Description: Write `test/foreman_server/task_providers/kata_architecture_test.exs` — scan for sole `System.cmd("kata", ...)` in `system_kata_runner.ex` only; scan for direct `KataAdapter` alias outside `task_providers/`; scan `lib/foreman_server/task_providers/` and `workflow/run_executor.ex` for claim-state enumeration (REQ-014-3): forbidden are `kata list --owner`, `kata ready --owner`, any `--all`, and `kata status`/`kata audit` calls, except the single-reference `kata status <ref> --json` lookup of the effective actor inside `fail/3`; the one permitted enumeration is `kata ready --unowned --json` inside `list_ready/2` (the doctor's `kata list --limit 1 --json` sample read lives outside the scanned tree in `cli/doctor_task_provider.ex`). The verb allow-list is per provider (verified on v0.23.0: `ready`, `show`, `claim`, `close`, `reopen`, `comment`, `unassign`, `create`, `edit`, plus `status` only as that single-reference lookup) and must be extended in the same PR when a callback needs a new verb
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_architecture_test.exs`
  - Validates PRD ACs: AC-001-3, AC-004-1, AC-004-2, AC-004-3, AC-014-3
  - Test AC:
    - [ ] AC-001-3 — Every Kata read in the adapter goes through the runner; no code path in the adapter opens a Kata database file, speaks a daemon protocol, or shells out to any binary other than `kata`.
    - [ ] AC-004-1 — The test fails if any `System.cmd` invocation of `kata` exists outside the single runner module; exactly one allowed invocation site is declared, mirroring the Beads runner rule.
    - [ ] AC-004-2 — The test fails if any module outside `task_providers/` aliases or calls `KataAdapter` directly; consumers go through the registry only.
    - [ ] AC-004-3 — The test fails if any code path invokes Kata as an orphan scanner (e.g. listing by claimed/in-progress status for reconciliation purposes), enforcing REQ-014 mechanically.
    - [ ] AC-014-3 — The architecture test fails the build if it finds such a claim-state sweep under `lib/foreman_server/task_providers/`; the Kata provider emits no `[:reconcile, :*]` telemetry events.
  - Dependencies: TRD-KATA-T002, TRD-KATA-T008
- [ ] **TRD-KATA-T021**: Update `config/config.exs` (0.25h)
  - PRD task ID: KATA-T021
  - Description: Update `config/config.exs` — add `ForemanServer.TaskProviders.KataAdapter` to `config :foreman_server, :task_provider, providers: [...]` and add `"kata.capabilities.v1"` to that block's `accepted_contract_versions` (currently `["br.capabilities.v1"]`; the registry's contract-version gate rejects the adapter otherwise)
  - Target Files: `packages/foreman_server/config/config.exs`
  - Validates PRD ACs: AC-001-2, AC-003-1, AC-003-2, AC-003-3
  - Implementation AC:
    - [ ] AC-001-2 — `name/0` returns a human-readable provider name; `capabilities/0[:provider_id]` returns `:kata`; `contract_version` is `"kata.capabilities.v1"`; that version string is present in the `:foreman_server, :task_provider` config's `accepted_contract_versions` list so startup registration succeeds.
    - [ ] AC-003-1 — A project whose `task_provider` is `kata` with a valid absolute `cwd` routes to `KataAdapter`; every CLI invocation it produces runs with that `cwd` as the working directory.
    - [ ] AC-003-2 — A Kata project's config is validated without any `database_path` requirement: no code path demands or invents one, and registry routing does not fail a Kata project for its absence.
    - [ ] AC-003-3 — Two projects bound to different `cwd` values never share adapter state: listing/getting for project A never observes tasks from project B's Kata project.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T022**: Update `config/config.exs` (1h)
  - PRD task ID: KATA-T022
  - Description: Update `config/config.exs` — add `accepted_kata_versions` to the `task_provider` config block: a list of Elixir `Version.match?/2` requirement strings (e.g. `">= 0.19.0"`), consumed only by `foreman doctor` (KATA-T042); distinct from `accepted_contract_versions`; the leading `v` of `kata --version` is stripped before matching and a non-semver dev build is a warning (PRD §11 OPEN-Q2 resolution)
  - Target Files: `packages/foreman_server/config/config.exs`
  - Implementation AC:
    - [ ] `accepted_kata_versions` is a list of strings that each pass `Version.parse_requirement/1`, and `accepted_contract_versions` is not changed by this task
  - Dependencies: TRD-KATA-T021

### PR 2: Quality — Error Handling, Concurrency, Registry Tightening, Per-Project Binding

**Shippable State:** A Kata project created with `--path` is routed by `cwd` without any `database_path`; every Kata call runs in that directory under the supervised `ConcurrencyLimiter`; errors use the closed-vocabulary envelope; the registry validates capability maps for both adapters.

#### Story 2.1 — Concurrency limiter

- [ ] **TRD-KATA-T023**: Integrate `ForemanServer.TaskProviders.ConcurrencyLimiter` into `KataAdapter` (2h) [satisfies REQ-009]
  - PRD task ID: KATA-T023
  - Description: Integrate `ForemanServer.TaskProviders.ConcurrencyLimiter` into `KataAdapter` — wrap every `@runner.cmd/3` call in `ConcurrencyLimiter.acquire(project_id, timeout_ms)` / `release(project_id)` (release in `after`); the limits are the limiter's configured defaults (`max_in_flight: 4`, `timeout_ms: 30_000`), no new config key; on `{:error, :timeout}` return `{:error, %ProviderError{code: "BR_TIMEOUT_QUEUE", retryable?: true}}`
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-009-1
  - Implementation AC:
    - [ ] AC-009-1 — At most four Kata CLI calls per project are in flight at once; a fifth caller for the same project waits for a slot rather than starting a fifth child process.
  - Dependencies: TRD-KATA-T008
- [ ] **TRD-KATA-T024-TEST**: Write `test/foreman_server/task_providers/kata_concurrency_test.exs` (2h) [satisfies REQ-009]
  - PRD task ID: KATA-T024
  - Description: Write `test/foreman_server/task_providers/kata_concurrency_test.exs` — verify 4 in-flight slots; verify 5th caller blocks; verify `BR_TIMEOUT_QUEUE` on per-call timeout; verify slot released on normal return
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_concurrency_test.exs`
  - Validates PRD ACs: AC-009-2
  - Test AC:
    - [ ] AC-009-2 — A caller that cannot obtain a slot within the queue timeout receives a typed, retryable queue-timeout error instead of blocking indefinitely; slots are released on both success and failure.
  - Dependencies: TRD-KATA-T023
- [ ] **TRD-KATA-T055**: Supervise `ConcurrencyLimiter` under `ForemanServer.Application` (2h)
  - PRD task ID: KATA-T055
  - Description: Supervise `ConcurrencyLimiter` — add `ForemanServer.TaskProviders.ConcurrencyLimiter` as a child of `ForemanServer.Application`; it is currently referenced only by its own module and `task_provider/telemetry.ex` and is never started, so `acquire/2` would exit with no process; add a start/restart assertion to `test/foreman_server/application_children_test.exs`
  - Target Files: `packages/foreman_server/lib/foreman_server/application.ex`, `packages/foreman_server/test/foreman_server/application_children_test.exs`
  - Validates PRD ACs: AC-009-1
  - Implementation AC:
    - [ ] AC-009-1 — At most four Kata CLI calls per project are in flight at once; a fifth caller for the same project waits for a slot rather than starting a fifth child process.
  - Dependencies: TRD-KATA-T023
- [ ] **TRD-KATA-T025**: Record the limiter-sharing decision (1h)
  - PRD task ID: KATA-T025
  - Description: Record the limiter-sharing decision — `ConcurrencyLimiter` is one globally named GenServer with per-project accounting, so a separately configured second instance is not possible and the TRD's earlier "shared with Beads" premise does not hold (the Beads adapter does not call it and stays unchanged); assert in a test that the instance supervised by KATA-T055 is the one `KataAdapter` acquires from, and state the single-instance decision in the `ConcurrencyLimiter` moduledoc
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/concurrency_limiter.ex`, `packages/foreman_server/test/foreman_server/task_providers/kata_concurrency_test.exs`
  - Implementation AC:
    - [ ] `Process.whereis(ForemanServer.TaskProviders.ConcurrencyLimiter)` is a live pid under the started application and is the process `KataAdapter` acquires from
    - [ ] The `ConcurrencyLimiter` moduledoc states the single-instance decision
  - Dependencies: TRD-KATA-T023, TRD-KATA-T055

#### Story 2.2 — Error envelope and guards

- [ ] **TRD-KATA-T026**: Implement `KataAdapter.build_provider_error/3` routing through `BeadsAdapter.CodeMap` (2h)
  - PRD task ID: KATA-T026
  - Description: Implement `KataAdapter.build_provider_error/3` routing through `BeadsAdapter.CodeMap` — Kata reports errors as JSON on stderr, `{"error": {"kind", "code", "hint", "message", "exit_code", "data"}}` (observed on `kata` v0.23.0); map `error.code` to CodeMap upstream codes: `already_claimed` (exit 5) and `owner_mismatch` (exit 5, from `kata unassign --expect-owner`) → `CLAIMED_BY_OTHER`, `issue_not_found` (exit 4) → `ISSUE_NOT_FOUND`, `validation` (exit 3) → `VALIDATION_FAILED`; exit 7 (daemon unavailable) and exit 8 (wait timeout) and a runner timeout → `BR_TIMEOUT_SUBPROCESS` (retryable; the closest existing code, since the PRD forbids new codes); unparseable stdout → `BR_PARSE_ERROR`; signal death and every other nonzero exit (1 internal, 2 usage, 6 confirmation required) and every other code, including `idempotency_mismatch` (exit 5, from `kata comment --idempotency-key` reused with a different body — a key-derivation bug, so it stays a non-retryable generic error) → `BR_ERROR_ENVELOPE`; `message`, `hint` and `data` are never copied into the error context — only `stderr_byte_count`; no caller reads `error.data`
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter/build_provider_error.ex`
  - Validates PRD ACs: AC-007-1, AC-007-2, AC-007-4
  - Implementation AC:
    - [ ] AC-007-1 — A Kata failure that matches a known code maps to that code with its existing retryable flag and redacted-field list; the mapping is read from `BeadsAdapter.CodeMap`, not duplicated.
    - [ ] AC-007-2 — A Kata failure with an unrecognized code maps to the generic envelope code; the adapter never raises, never returns a raw string, and never mints a provider-specific code.
    - [ ] AC-007-4 — A single construction site builds provider errors for the Kata adapter, and that site is the only place a `ProviderError` struct is created for Kata.
  - Dependencies: TRD-KATA-T018
- [ ] **TRD-KATA-T027**: Implement `already_terminal` guard (REQ-013-1) (1h) [satisfies REQ-013]
  - PRD task ID: KATA-T027
  - Description: Implement the already-terminal guard (REQ-013-1) — `kata close` on an already-closed issue exits 0 with `"changed": false` and no `event` (observed on `kata` v0.23.0, not an error), so a close envelope with `changed: false` returns `{:ok, :already_terminal}` and one with `changed: true` returns `{:ok, :terminal}`; no stderr code is involved
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-013-1
  - Implementation AC:
    - [ ] AC-013-1 — When Kata reports a task as already terminal, closing it returns an explicit already-terminal success rather than a failure.
  - Dependencies: TRD-KATA-T026
- [ ] **TRD-KATA-T028**: Implement `CLAIMED_BY_OTHER` guard (REQ-013-2) (1h)
  - PRD task ID: KATA-T028
  - Description: Implement the claimed-by-other guard (REQ-013-2) — a `kata claim` that fails with stderr `error.code: "already_claimed"` (exit 5) returns `{:error, %ProviderError{code: "CLAIMED_BY_OTHER", retryable?: false, context: %{current_assignee_present?: true}}}`; `data.current_owner` and `message` (which names the owner) are discarded, the context carries only the boolean presence flag
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-013-2
  - Implementation AC:
    - [ ] AC-013-2 — When Kata reports a task as claimed by another actor, the returned error carries the existing claimed-by-other code with `retryable?: false`, and its context contains only a boolean presence flag for the current assignee.
  - Dependencies: TRD-KATA-T026
- [ ] **TRD-KATA-T029-TEST**: Write tests for all error envelope paths (2h) [satisfies REQ-007]
  - PRD task ID: KATA-T029
  - Description: Write tests for all error envelope paths — `already_claimed`, `issue_not_found`, `validation`, exit 7 and 8, runner timeout, signal, unparseable stdout, a `changed: false` close, and the claimed-by-other guard
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_adapter_test.exs`
  - Test AC:
    - [ ] Each path has a test asserting the returned code, `retryable?` and the context keys: `already_claimed`, `issue_not_found`, `validation`, exit 7 and 8, runner timeout, signal, unparseable stdout, a `changed: false` close, and the claimed-by-other guard
    - [ ] No test asserts on raw stderr text, and none finds `current_owner` in any error context
  - Dependencies: TRD-KATA-T026, TRD-KATA-T027, TRD-KATA-T028

#### Story 2.3 — Registry tightening

- [ ] **TRD-KATA-T030**: Extend `TaskProvider.Registry` capability validation (REQ-010-1) (3h) [satisfies REQ-010]
  - PRD task ID: KATA-T030
  - Description: Extend `TaskProvider.Registry` capability validation (REQ-010-1) — validate `capabilities/0` maps: required keys `provider_id`, `contract_version`, `supports`, `storage_scheme`; value-type checking; invalid maps logged with `[:foreman_server, :task_provider, :registry, :invalid_capabilities]` and excluded from snapshot
  - Target Files: `packages/foreman_server/lib/foreman_server/task_provider/registry.ex`, `packages/foreman_server/test/foreman_server/task_provider/registry_test.exs`
  - Validates PRD ACs: AC-010-1
  - Implementation AC:
    - [ ] AC-010-1 — The registry validates a provider's capability map against required keys and value types; an invalid map is excluded from the routing snapshot and logged with a distinguishable provider-scoped telemetry event.
  - Dependencies: TRD-KATA-T010
- [ ] **TRD-KATA-T031**: Audit `BeadsAdapter.capabilities/0` against the tightened validation (2h)
  - PRD task ID: KATA-T031
  - Description: Audit `BeadsAdapter.capabilities/0` against the tightened validation — it declares no `storage_scheme` (a required key per KATA-T030): add `storage_scheme: :sqlite` (database-file scheme, the counterpart of Kata's `:cli_process`) and fix any ordering/optional-field issue the validation would reject; run the full Beads adapter test suite to confirm no regressions
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter.ex`, `packages/foreman_server/test/foreman_server/task_providers/beads_adapter_test.exs`
  - Validates PRD ACs: AC-010-3
  - Implementation AC:
    - [ ] AC-010-3 — The Beads adapter's declaration is audited against the tightened rules and corrected where needed, with the existing Beads test suite still green.
  - Dependencies: TRD-KATA-T030
- [ ] **TRD-KATA-T032-TEST**: Write `test/foreman_server/task_providers/kata_registry_tightening_test.exs` (2h) [satisfies REQ-002, REQ-010]
  - PRD task ID: KATA-T032
  - Description: Write `test/foreman_server/task_providers/kata_registry_tightening_test.exs` — verify both adapters pass through shared capability validation; verify overlapping `supports` sets both in snapshot; verify routing prefers providers with required transition
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_registry_tightening_test.exs`
  - Validates PRD ACs: AC-002-2, AC-010-2
  - Test AC:
    - [ ] AC-002-2 — The map satisfies the same registry capability validation that Beads' map satisfies, with no Kata-specific exception in the registry.
    - [ ] AC-010-2 — Both the Beads adapter and the Kata adapter pass the tightened validation unchanged in observable behavior — no Kata-specific branch, exemption, or special case exists in the registry.
  - Dependencies: TRD-KATA-T030, TRD-KATA-T031

#### Story 2.4 — Per-project cwd binding (REQ-003)

- [ ] **TRD-KATA-T052**: Enforce the Kata project config contract in the Go CLI (2h)
  - PRD task ID: KATA-T052
  - Description: Enforce the Kata project config contract in the Go CLI — `taskProviderPayload`/`validateTaskProviderConfig` in `project.go` (today `database_path` is the only config key ever emitted and is required for beads): for `--task-provider=kata` emit `task_provider.config.cwd` from the absolute `--path` (no new flag) and never `database_path`; reject `--task-provider-database-path` for kata with a usage error; `foreman project get` renders `cwd:` instead of `database_path:` for a Kata project (it reads `database_path` today); beads behavior unchanged; no new verb or flag is added, so `usage_drift_test.go` must stay green unchanged
  - Target Files: `packages/foreman_cli/cmd/foreman/project.go`, `packages/foreman_cli/cmd/foreman/project_test.go`
  - Validates PRD ACs: AC-003-1, AC-003-2
  - Implementation AC:
    - [ ] AC-003-1 — A project whose `task_provider` is `kata` with a valid absolute `cwd` routes to `KataAdapter`; every CLI invocation it produces runs with that `cwd` as the working directory.
    - [ ] AC-003-2 — A Kata project's config is validated without any `database_path` requirement: no code path demands or invents one, and registry routing does not fail a Kata project for its absence.
- [ ] **TRD-KATA-T053**: Make server-side routing and preflight storage-scheme-generic (4h) [satisfies REQ-003]
  - PRD task ID: KATA-T053
  - Description: Make server-side routing and preflight storage-scheme-generic — `project_provider_projector.ex` `preflight_provider/2` (returns `{:error, :preflight_failed}` when `database_path` is nil), `registry.ex` `route_provider/3` (`:database_path_mismatch`) and `run_executor.ex` `fetch_database_path/1` must key on `capabilities[:storage_scheme]`: `:sqlite` providers keep `database_path`; `:cli_process` (Kata) projects are keyed and preflighted by `config.cwd` (absolute, existing directory), with no code path demanding or inventing a `database_path`; no Kata-specific branch
  - Target Files: `packages/foreman_server/lib/foreman_server/task_provider/project_provider_projector.ex`, `packages/foreman_server/lib/foreman_server/task_provider/registry.ex`, `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, `packages/foreman_server/test/foreman_server/task_provider/project_provider_projector_test.exs`, `packages/foreman_server/test/foreman_server/task_provider/registry_route_test.exs`
  - Validates PRD ACs: AC-003-2, AC-010-2
  - Implementation AC:
    - [ ] AC-003-2 — A Kata project's config is validated without any `database_path` requirement: no code path demands or invents one, and registry routing does not fail a Kata project for its absence.
    - [ ] AC-010-2 — Both the Beads adapter and the Kata adapter pass the tightened validation unchanged in observable behavior — no Kata-specific branch, exemption, or special case exists in the registry.
  - Dependencies: TRD-KATA-T010, TRD-KATA-T031
- [ ] **TRD-KATA-T054**: Propagate the project working directory in `KataAdapter` (2h)
  - PRD task ID: KATA-T054
  - Description: Propagate the project working directory in `KataAdapter` — every callback reads `project_config[:cwd]` (normalized once at the boundary, atom keys, no atom/string fallback chains) and passes it as the `cwd` argument of `@runner.cmd/3` so each `kata` invocation runs in that directory; a missing or non-absolute `cwd` returns a typed `INVALID_PARAMS`-style `ProviderError` via the factory; two projects with different `cwd` never share adapter state
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`, `packages/foreman_server/test/foreman_server/task_providers/kata_adapter_test.exs`
  - Validates PRD ACs: AC-003-1, AC-003-3
  - Implementation AC:
    - [ ] AC-003-1 — A project whose `task_provider` is `kata` with a valid absolute `cwd` routes to `KataAdapter`; every CLI invocation it produces runs with that `cwd` as the working directory.
    - [ ] AC-003-3 — Two projects bound to different `cwd` values never share adapter state: listing/getting for project A never observes tasks from project B's Kata project.
  - Dependencies: TRD-KATA-T008, TRD-KATA-T053

### PR 3: Lifecycle — Claim, Close, Idempotency

**Shippable State:** A Foreman run against a Kata project claims its task, then closes it on success or, on failure, reopens it with a comment and releases its claim so the task returns to the ready list, idempotently; OPEN-Q1 and OPEN-Q2 are confirmed against the pinned Kata reference.

#### Story 3.1 — Claim, close and fail through RunExecutor

- [ ] **TRD-KATA-T033**: Exercise the provider-generic claim path in `RunExecutor` for Kata projects (3h)
  - PRD task ID: KATA-T033
  - Description: Exercise the provider-generic claim path in `RunExecutor` for Kata projects (`provider_module.claim(task_id, actor, project_config)`, `run_executor.ex` ~121–125; no Kata-specific branch) — before dispatch claim via `KataAdapter.claim/3`; on a `CLAIMED_BY_OTHER` refusal re-call `list_ready/2` once; if the issue is no longer ready, drop it from the dispatch set and emit `[:foreman_server, :task_provider, :claim, :lost]` telemetry; handle `{:ok, term()}`
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  - Validates PRD ACs: AC-011-1, AC-011-2, AC-011-3
  - Implementation AC:
    - [ ] AC-011-1 — No task is dispatched to an agent unless Foreman first received a successful claim response from Kata for that task.
    - [ ] AC-011-2 — When the claim is refused because another actor holds the task, Foreman refreshes its ready set once and retries the claim; it does not loop.
    - [ ] AC-011-3 — When the task is still not claimable after that refresh, it is dropped from the dispatch set and a distinguishable provider-scoped telemetry event records the claim loss.
  - Dependencies: TRD-KATA-T013, TRD-KATA-T011, TRD-KATA-T053
- [ ] **TRD-KATA-T034**: Exercise the provider-generic complete path in `RunExecutor` for Kata (2h)
  - PRD task ID: KATA-T034
  - Description: Exercise the provider-generic complete path in `RunExecutor` (`provider_module.complete/…`, `run_executor.ex` ~134–138) for Kata — on `TaskExecutionCompleted`, invoke `kata close <ref> --done --message "<msg>" --commit <sha>` with optional `--evidence`; on a close envelope with `changed: false` → `{:ok, :already_terminal}`; on Kata-side reject → surface `BR_ERROR_ENVELOPE` and stop
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  - Validates PRD ACs: AC-012-1, AC-012-3, AC-012-4
  - Implementation AC:
    - [ ] AC-012-1 — On successful execution, the task is closed in Kata carrying the run's completion message and commit SHA.
    - [ ] AC-012-3 — The completion message identifies the Foreman run that produced it (run identifier and artifact path) when the caller supplies no message of its own, and is at least 40 characters — Kata's minimum for `kata close --done` — so the generated default is never rejected for length.
    - [ ] AC-012-4 — When Kata refuses the close, the refusal is surfaced as a typed provider error and the run does not report the task as successfully closed.
  - Dependencies: TRD-KATA-T014, TRD-KATA-T033
- [ ] **TRD-KATA-T035**: Exercise the provider-generic fail path in `RunExecutor` for Kata (2h)
  - PRD task ID: KATA-T035
  - Description: Exercise the provider-generic fail path in `RunExecutor` (`provider_module.fail(task_id, failure_token, project_config)`, `run_executor.ex` ~154) for Kata — on `TaskExecutionFailed`, `KataAdapter.fail/3` (KATA-T015) reads `kata status <ref> --json`, then runs `kata reopen <ref>`, `kata comment <ref> --body "<reason>" --idempotency-key foreman-fail:<run_id>:<body_hash>` and `kata unassign <ref> --expect-owner <actor>`; return `{:ok, :reopened}`. When a different actor owns the task nothing is written and a retryable `CLAIMED_BY_OTHER` error comes back, which the existing `fail_retry_loop` repeats without ever touching the issue. This is the Foreman-side failure-path release only (Kata owns crash reconciliation; a run that dies mid-flight is reclaimed by the operator with `kata unassign <ref>`)
  - Target Files: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  - Validates PRD ACs: AC-012-2, AC-014-1
  - Implementation AC:
    - [ ] AC-012-2 — On failed execution, the task is reopened in Kata, the failure reason is recorded as a comment on that task, and Foreman's own claim is released so the task is open, unowned and claimable again; the task is not closed, and a task owned by a different actor is left untouched.
    - [ ] AC-014-1 — On `TaskExecutionFailed`, `KataAdapter.fail/3` first reads the task's effective actor and current owner with `kata status <ref> --json`; if a different actor owns the task it writes nothing to it and returns a typed `CLAIMED_BY_OTHER` provider error. Otherwise it invokes `kata reopen <ref>`, then `kata comment <ref> --body "<reason>"` under an idempotency key derived from the run id and the comment text (a retried notification never duplicates the comment, and a differently worded comment is never refused), then, unless the task is already unowned, `kata unassign <ref> --expect-owner <actor>`; returns `{:ok, :reopened}`. A release refused because ownership changed in the meantime surfaces the same typed error. This is the Foreman-side failure-path release only (Kata owns crash reconciliation; a run that dies mid-flight is reclaimed by the operator).
  - Dependencies: TRD-KATA-T015, TRD-KATA-T033
- [ ] **TRD-KATA-T036-TEST**: Write `test/foreman_server/task_providers/kata_lifecycle_test.exs` (3h) [satisfies REQ-011, REQ-012, REQ-013]
  - PRD task ID: KATA-T036
  - Description: Write `test/foreman_server/task_providers/kata_lifecycle_test.exs` — exercise claim → complete; exercise claim → fail (status, reopen, comment, unassign); exercise fail when a different actor owns the task (only the status call is issued; `CLAIMED_BY_OTHER`), when the task is already unowned (reopen and comment, no unassign), and when ownership changes between the status read and the unassign (`owner_mismatch` → `CLAIMED_BY_OTHER`); exercise a retried fail after the comment succeeded (the replay is `changed: false`, no second comment); exercise already-closed idempotency; exercise already-claimed conflict; exercise claim-lost re-list-and-drop
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_lifecycle_test.exs`
  - Test AC:
    - [ ] Claim → complete, claim → fail, already-closed, already-claimed and claim-lost each have a passing test
    - [ ] The fail test asserts `status`, `reopen`, `comment` (with `--idempotency-key foreman-fail:<run_id>:<body_hash>`) and `unassign --expect-owner <actor>` are issued in that order with `<actor>` taken from `$.actor` of `kata status <ref> --json`, and `close` is not
    - [ ] When `kata status` shows a different actor as owner, no `reopen`, `comment` or `unassign` is issued and a typed `CLAIMED_BY_OTHER` error is returned
    - [ ] When `kata status` shows the task already unowned, `reopen` and `comment` are issued, `unassign` is not, and the call succeeds
    - [ ] When ownership changes between the status read and the unassign, Kata's `owner_mismatch` refusal surfaces as a typed `CLAIMED_BY_OTHER` error
    - [ ] A retried fail after the comment succeeded replays the comment (`changed: false`) without creating a second one
  - Dependencies: TRD-KATA-T033, TRD-KATA-T034, TRD-KATA-T035

#### Story 3.2 — Kata authority and open questions

- [ ] **TRD-KATA-T037**: Document and verify REQ-014 enforcement (1h) [satisfies REQ-004, REQ-014]
  - PRD task ID: KATA-T037
  - Description: Document and verify REQ-014 enforcement — no code path under `lib/foreman_server/task_providers/` or `workflow/run_executor.ex` enumerates Kata claim state (owner-filtered listings, `--all`, `kata status`/`kata audit` sweeps); the architecture test (KATA-T020) covers this; add code-comment on `list_ready/2`: "Kata is authoritative for claim state — Foreman does NOT scan for orphans"
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`
  - Validates PRD ACs: AC-014-2
  - Implementation AC:
    - [ ] AC-014-2 — No code path under `lib/foreman_server/task_providers/` scans Kata for claimed, in-progress or orphaned work (any `kata list`/`kata status`/`kata audit`-based sweep); the single-reference `kata status <ref> --json` lookup of the effective actor inside `fail/3` is not a sweep; `list_ready/2` carries an explicit comment: "Kata is authoritative for claim state — Foreman does NOT scan for orphans."
  - Dependencies: TRD-KATA-T011, TRD-KATA-T020-TEST
- [ ] **TRD-KATA-T038**: Confirm OPEN-Q1 (1h)
  - PRD task ID: KATA-T038
  - Description: Confirm OPEN-Q1 — `id_format` regex for Kata short_ids — against `docs/reference/cli.md` in the Kata repository at the pinned upstream revision; `"^[a-z0-9]+$"` (lowercased ULID suffix, variable length, digit-initial ids legal) is already declared by KATA-T008/T010, so this task changes that declaration only if the pinned upstream contradicts it (PRD-added AC-002-4 makes the declaration verifiable)
  - Target Files: `docs/reference/cli.md` (external: Kata repository at the pinned upstream revision; read-only)
  - Validates PRD ACs: AC-002-1, AC-002-4
  - Implementation AC:
    - [ ] AC-002-1 — `capabilities/0` returns a map with `provider_id: :kata`, `contract_version: "kata.capabilities.v1"`, a non-empty `supports` list covering all supported operations, and `storage_scheme: :cli_process`.
    - [ ] AC-002-4 — `capabilities/0`'s `id_format` is `"^[a-z0-9]+$"`, and the adapter's ref parser accepts `abc4`, `4abc`, `a1b2`, and a 26-character full ULID, while rejecting an empty string, uppercase input, and any string containing a character outside `[a-z0-9]`.
  - Dependencies: TRD-KATA-T010
- [ ] **TRD-KATA-T039**: Confirm OPEN-Q2 (1h)
  - PRD task ID: KATA-T039
  - Description: Confirm OPEN-Q2 — `accepted_kata_versions` format (PRD §11: list of `Version.match?/2` requirement strings) — against Kata's published version metadata; the `>= 0.19.0` floor gates `kata agent-hook`/`kata teams`, and Kata documents no floor for `kata claim`/`kata close`, so the range stays operator policy; adjust `config/config.exs` only if upstream documents otherwise
  - Target Files: `packages/foreman_server/config/config.exs`
  - Implementation AC:
    - [ ] Every `accepted_kata_versions` entry parses with `Version.parse_requirement/1`; the PRD §11 resolution is either confirmed against Kata's version metadata or corrected in `config/config.exs`
  - Dependencies: TRD-KATA-T022

### PR 4: Observability — Sensitive Fields, Doctor, Side-Channels

**Shippable State:** `assignee` and `description`/`body` are silent across Logger, IO, telemetry and `ProviderError.context`, and `foreman doctor` reports a provider-appropriate section for Kata projects without any Beads-only check.

#### Story 4.1 — Side-channel silence and doctor

- [ ] **TRD-KATA-T040**: Implement sensitive field side-channel silence (REQ-017) (3h) [satisfies REQ-015, REQ-017]
  - PRD task ID: KATA-T040
  - Description: Implement sensitive field side-channel silence (REQ-017) — `assignee` and `description`/`body` MUST NOT appear in `Logger.*`, `IO.*`, `:telemetry` metadata, or `ProviderError.context` keys other than `redacted_fields`; `ProviderError` context allowlist: `id`, `command`, `exit_code`, `stderr_byte_count`, `sanitized?`, `redacted_fields`; `sanitized?` always `true`; `redacted_fields` always `["assignee", "description"]`; stderr unconditionally discarded (only `stderr_byte_count` retained)
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/kata_adapter.ex`, `packages/foreman_server/lib/foreman_server/task_providers/system_kata_runner.ex`
  - Validates PRD ACs: AC-015-1, AC-015-2
  - Implementation AC:
    - [ ] AC-015-1 — `assignee` and the task body/description are classified as sensitive fields for the Kata provider, and the provider-error context carries them as the literal list `redacted_fields: ["assignee", "description"]`.
    - [ ] AC-015-2 — A Kata field not present in the Foreman issue contract is treated as sensitive by default: it appears in no log line, telemetry metadata or error context, because only allowlisted keys may be emitted there (REQ-017); `redacted_fields` declares the known-sensitive set and is not the enforcement mechanism.
  - Dependencies: TRD-KATA-T018
- [ ] **TRD-KATA-T041-TEST**: Write `test/foreman_server/task_providers/kata_side_channel_test.exs` (4h) [satisfies REQ-015, REQ-017]
  - PRD task ID: KATA-T041
  - Description: Write `test/foreman_server/task_providers/kata_side_channel_test.exs` — AC-017-1: sentinel payload via `CaptureLog.capture_log/1`; AC-017-2: via `CaptureIO.capture_io/2`; AC-017-3: telemetry handlers via `:telemetry_test.attach_event_handlers/2`; AC-017-4: `ProviderError.context` only allowlisted keys + `sanitized?` always `true`; AC-017-5: domain return struct DOES contain sentinel values
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_side_channel_test.exs`
  - Validates PRD ACs: AC-017-1, AC-017-2, AC-017-3, AC-017-4, AC-017-5
  - Test AC:
    - [ ] AC-017-1 — A sentinel sensitive value passed through the adapter never appears in the application log.
    - [ ] AC-017-2 — A sentinel sensitive value passed through the adapter never appears in standard output or standard error.
    - [ ] AC-017-3 — A sentinel sensitive value passed through the adapter never appears in telemetry event metadata.
    - [ ] AC-017-4 — The provider-error context contains only the allowlisted keys (`id`, `command`, `exit_code`, `stderr_byte_count`, `sanitized?`, `redacted_fields`); `sanitized?` is always `true` and `redacted_fields` always names the redacted fields.
    - [ ] AC-017-5 — The domain record Foreman returns to its caller **does** contain the sensitive values, so the redaction does not silently destroy task content the caller needs.
  - Dependencies: TRD-KATA-T040
- [ ] **TRD-KATA-T056**: Make `foreman doctor` provider-generic (3h)
  - PRD task ID: KATA-T056
  - Description: Make `foreman doctor` provider-generic — `doctor_task_provider.ex` hardcodes the Beads probe (`DATABASE_PATH_MISSING` when `database_path` is absent, `PROVIDER_MISSING` "br not installed", `br_version`, janitor/orphan fields): gate on `capabilities[:storage_scheme]` and `available?/0` and dispatch to a provider-specific probe/message so a Kata project never reports `DATABASE_PATH_MISSING`; Beads output unchanged
  - Target Files: `packages/foreman_server/lib/foreman_server/cli/doctor_task_provider.ex`, `packages/foreman_server/test/foreman_server/cli/doctor_task_provider_test.exs`
  - Validates PRD ACs: AC-016-1
  - Implementation AC:
    - [ ] AC-016-1 — The doctor report for a Kata project states the configured provider id and contract version, the `kata --version` result, and the outcome of a sample task listing against the project's working directory.
  - Dependencies: TRD-KATA-T010
- [ ] **TRD-KATA-T042**: Implement the Kata section of `foreman doctor` (3h) [satisfies REQ-016]
  - PRD task ID: KATA-T042
  - Description: Implement the Kata section of `foreman doctor` (REQ-016) on top of the provider-generic doctor (KATA-T056) — report: (a) configured `provider_id` and `contract_version`; (b) `kata --version` exit code and stdout, with an out-of-range `accepted_kata_versions` match or a non-semver dev build reported as a warning (project stays healthy); (c) sample `kata list --limit 1 --json` against each registered Kata project's `cwd`; (d) non-zero exit or missing-binary failures; when `available?/0` is false, report the project as `unhealthy` with `stderr_byte_count` (informative, non-sensitive)
  - Target Files: `packages/foreman_server/lib/foreman_server/cli/doctor_task_provider.ex`
  - Validates PRD ACs: AC-016-1
  - Implementation AC:
    - [ ] AC-016-1 — The doctor report for a Kata project states the configured provider id and contract version, the `kata --version` result, and the outcome of a sample task listing against the project's working directory.
  - Dependencies: TRD-KATA-T009, TRD-KATA-T011, TRD-KATA-T056
- [ ] **TRD-KATA-T043-TEST**: Write the Kata cases in `test/foreman_server/cli/doctor_task_provider_test.exs` (2h) [satisfies REQ-016]
  - PRD task ID: KATA-T043
  - Description: Write the Kata cases in `test/foreman_server/cli/doctor_task_provider_test.exs` — verify doctor reports the Kata section when the adapter is registered; verify `unhealthy` when `kata` is missing; verify an out-of-range version is a warning, not unhealthy; verify `stderr_byte_count` is reported, not raw stderr
  - Target Files: `packages/foreman_server/test/foreman_server/cli/doctor_task_provider_test.exs`
  - Validates PRD ACs: AC-016-2
  - Test AC:
    - [ ] AC-016-2 — A missing Kata binary, a non-zero `kata --version` exit, or a failing sample read marks the project unhealthy with a non-sensitive diagnostic; a version that reports successfully but sits outside the accepted range is reported as a warning while the project remains healthy and calls proceed.
  - Dependencies: TRD-KATA-T042

### PR 5: Integration — End-to-End, Documentation, Cleanup

**Shippable State:** The real-`kata` end-to-end test and the full suite pass; user guide, CLI reference and CHANGELOG describe the adapter; the architecture test passes on its own.

#### Story 5.1 — End-to-end and routing verification

- [ ] **TRD-KATA-T044-TEST**: End-to-end integration test (4h)
  - PRD task ID: KATA-T044
  - Description: End-to-end integration test — in a sandboxed temp directory with its own `KATA_HOME` (set in the test process env only, never Foreman config) run `kata init --project <name>`, then `kata create "test issue" --body "…" --idempotency-key <key> --json` (id at `.issue.short_id`); wire the full `RunExecutor` lifecycle against the real `KataAdapter` (not the mock); assert the issue transitions `open` → claimed → closed; assert the failure path reopens, comments and unassigns, leaving the issue open and unowned, listed by `kata ready --unowned` and claimable again; use `SystemKataRunner` with timeout
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_e2e_test.exs`
  - Test AC:
    - [ ] Against a real `kata` in a scratch workspace the issue goes open → owned → closed on success, and on failure is reopened with a comment and released (open, unowned, listed by `kata ready --unowned`, claimable again)
    - [ ] The test is excluded (not failed) when `kata` is not on `PATH`
  - Dependencies: TRD-KATA-T033, TRD-KATA-T034, TRD-KATA-T035
- [ ] **TRD-KATA-T045-TEST**: Verify `KataAdapter` registered correctly in `TaskProvider.Registry` (2h) [satisfies REQ-003]
  - PRD task ID: KATA-T045
  - Description: Verify `KataAdapter` registered correctly in `TaskProvider.Registry` — integration test asserting `KataAdapter` in `routing_snapshot/0`; assert both `BeadsAdapter` and `KataAdapter` appear with overlapping `supports`; assert per-project provider config (REQ-003) routes correctly
  - Target Files: `packages/foreman_server/test/foreman_server/task_provider/registry_routing_test.exs`
  - Validates PRD ACs: AC-003-4
  - Test AC:
    - [ ] AC-003-4 — A project may switch between `beads` and `kata` (and back) without losing Foreman run history; the provider choice is data, not a fork in the dispatch path.
  - Dependencies: TRD-KATA-T021, TRD-KATA-T032-TEST, TRD-KATA-T053
- [ ] **TRD-KATA-T046-TEST**: Run full Foreman test suite (`mix test`) (2h)
  - PRD task ID: KATA-T046
  - Description: Run full Foreman test suite (`mix test`) — all existing tests pass; new Kata adapter tests pass; no regressions in Beads adapter
  - Target Files: `packages/foreman_server/` (full suite via `mix test`)
  - Test AC:
    - [ ] `mix test --warnings-as-errors` exits 0 for `packages/foreman_server`, including the Beads adapter suites
  - Dependencies: TRD-KATA-T044-TEST, TRD-KATA-T045-TEST

#### Story 5.2 — Documentation

- [ ] **TRD-KATA-T047**: Update `docs/user-guide.md` and `README.md` (2h)
  - PRD task ID: KATA-T047
  - Description: Update `docs/user-guide.md` and `README.md` — Kata adapter setup: `brew install kata` (macOS) or install script (Linux); `kata init` to bind the workspace; `foreman project create --path <dir> --task-provider kata` (no database path); `foreman doctor` to verify; operator triage commands (`kata list --status all` plus `kata status <ref>` to inspect ownership — `--status` accepts only `open`, `closed` or `all` — `kata audit closes`, `kata reopen`, `kata claim`); note Foreman does NOT scan Kata for orphans; make the stale database-path binding statements provider-conditional (`README.md` lines 46 and 114–115; `docs/user-guide.md` lines 561, 573, 2176, 2634)
  - Target Files: `docs/user-guide.md`, `README.md`
  - Implementation AC:
    - [ ] Every `kata` command in the new text appears in the help of the pinned `kata` version
    - [ ] `grep -n "status claimed"` finds nothing in either file, and the database-path binding is described as beads-only
  - Dependencies: TRD-KATA-T042
- [ ] **TRD-KATA-T048**: Update `docs/cli-reference.md` and `CLAUDE.md` (1h)
  - PRD task ID: KATA-T048
  - Description: Update `docs/cli-reference.md` and `CLAUDE.md` — `foreman project create/update --task-provider kata` (config is the absolute `--path` as `cwd`; `--task-provider-database-path` rejected for Kata); `foreman doctor` Kata section output format; note the Kata `task_provider` payload carries `provider: "kata"` and `config.cwd` only (no `KATA_HOME`, no `kata_home`, no `database_path`); make the stale database-path statements provider-conditional (`docs/cli-reference.md` lines 301, 316, 354, 363; `CLAUDE.md` lines 577 and 579)
  - Target Files: `docs/cli-reference.md`, `CLAUDE.md`
  - Implementation AC:
    - [ ] The two files describe the Kata binding (`--path` becomes `config.cwd`, no database path) and state the database path as required only for beads
    - [ ] `go test ./cmd/foreman/...`, including `usage_drift_test.go`, passes
  - Dependencies: TRD-KATA-T047
- [ ] **TRD-KATA-T049**: Write `packages/foreman_server/CHANGELOG.md` entry (0.5h)
  - PRD task ID: KATA-T049
  - Description: Write `packages/foreman_server/CHANGELOG.md` entry — adapter, provider id, contract version, supported operations, one-line per major change
  - Target Files: `packages/foreman_server/CHANGELOG.md`
  - Implementation AC:
    - [ ] The entry names the adapter, provider id `kata`, contract version `kata.capabilities.v1`, and the supported operations
  - Dependencies: TRD-KATA-T036-TEST

#### Story 5.3 — Review and architecture gate

- [ ] **TRD-KATA-T050**: Code review pass (1h)
  - PRD task ID: KATA-T050
  - Description: Code review pass — consistency with BeadsAdapter patterns; `@runner` compile-time binding; no `System.cmd` outside `SystemKataRunner`; no direct `KataAdapter` imports outside `task_providers/`; all `ProviderError` constructions route through factory
  - Target Files: `packages/foreman_server/lib/foreman_server/task_providers/` (review scope)
  - Implementation AC:
    - [ ] The review confirms: `@runner` bound via `Application.compile_env/3`; one `System.cmd("kata"` site; no `KataAdapter` alias outside `task_providers/`; every `%ProviderError{}` built by the factory; findings are fixed or filed
  - Dependencies: TRD-KATA-T020-TEST
- [ ] **TRD-KATA-T051-TEST**: Final architecture test run (0.5h)
  - PRD task ID: KATA-T051
  - Description: Final architecture test run — run `mix test test/foreman_server/task_providers/kata_architecture_test.exs` alone to verify all three assertion classes pass
  - Target Files: `packages/foreman_server/test/foreman_server/task_providers/kata_architecture_test.exs`
  - Test AC:
    - [ ] `mix test test/foreman_server/task_providers/kata_architecture_test.exs` exits 0 on its own, and all three assertion classes (single runner site, alias boundary, claim-state sweep) execute
  - Dependencies: TRD-KATA-T050

---

## 4. Acceptance Criteria Traceability

| REQ | Requirement | Priority | Tasks | ACs |
|---|---|---|---|---|
| REQ-001 | KataAdapter implements TaskProvider via `kata` CLI | Must | KATA-T008–T017 | AC-001-1 (T008), AC-001-2 (T010, T021), AC-001-3 (T008, T020) |
| REQ-002 | KataAdapter capability declaration | Must | KATA-T009, T010, T021, T032, T038 | AC-002-1 (T010, T038), AC-002-2 (T032), AC-002-3 (T009), AC-002-4 (T038, PRD-added) |
| REQ-003 | Per-project Kata configuration | Must | KATA-T021, T045, T052–T054 | AC-003-1 (T021, T052, T054), AC-003-2 (T021, T052, T053), AC-003-3 (T021, T054), AC-003-4 (T045) |
| REQ-004 | Architecture test enforces KataAdapter boundaries | Must | KATA-T020, T037, T050 | AC-004-1 (T020), AC-004-2 (T020), AC-004-3 (T020) |
| REQ-005 | KataAdapter callback implementations | Must | KATA-T008, T011–T017 | AC-005-1 (T011), AC-005-2 (T013), AC-005-3 (T014), AC-005-4 (T015), AC-005-5 (T016), AC-005-6 (T016) |
| REQ-006 | Structured output parsing with field-mapping validation | Must | KATA-T011, T012, T016 | AC-006-1 (T011, T012), AC-006-2 (T011, T012), AC-006-3 (T011, T012) |
| REQ-007 | Provider error envelope (reuse Beads CodeMap) | Must | KATA-T018, T019, T026–T029 | AC-007-1 (T026), AC-007-2 (T026), AC-007-3 (T018, T019), AC-007-4 (T026) |
| REQ-008 | CLI process safety (mirror BeadsAdapter) | Must | KATA-T002, T007, T018 | AC-008-1 (T002), AC-008-2 (T002), AC-008-3 (T002), AC-008-4 (T002) |
| REQ-009 | CLI invocation concurrency limit | Should | KATA-T023–T025, T055 | AC-009-1 (T023, T055), AC-009-2 (T024) |
| REQ-010 | Generic registry tightening + Beads cleanup | Should | KATA-T030–T032, T053 | AC-010-1 (T030), AC-010-2 (T032, T053), AC-010-3 (T031) |
| REQ-011 | Pre-execution atomic claim via `kata claim` | Must | KATA-T013, T033 | AC-011-1 (T033), AC-011-2 (T033), AC-011-3 (T033) |
| REQ-012 | Post-execution close via `kata close` | Must | KATA-T014, T034, T035 | AC-012-1 (T034), AC-012-2 (T035), AC-012-3 (T034), AC-012-4 (T034) |
| REQ-013 | Idempotent transition guards | Must | KATA-T027, T028, T036 | AC-013-1 (T027), AC-013-2 (T028) |
| REQ-014 | Kata is authoritative for claims — operator triage only | Must | KATA-T020, T037 | AC-014-1 (T035), AC-014-2 (T037), AC-014-3 (T020) |
| REQ-015 | Sensitive fields = `assignee` + `body` | Should | KATA-T040 | AC-015-1 (T040), AC-015-2 (T040) |
| REQ-016 | `foreman doctor` integration for Kata | Could | KATA-T042, T043, T056 | AC-016-1 (T042, T056), AC-016-2 (T043) |
| REQ-017 | Adapter silent-by-default on Kata sensitive side-channels | Should | KATA-T040, T041 | AC-017-1 (T041), AC-017-2 (T041), AC-017-3 (T041), AC-017-4 (T041), AC-017-5 (T041) |

**Totals: 17 requirements, 57 ACs, 56 tasks.** Task ids in this table are the PRD §12 identities (`KATA-T###`); the Master Task List ids are `TRD-KATA-T###`. This matrix matches PRD §12 at v1.1.3.

---

## 5. Foreman Compatibility Check

| Check | Result |
|---|---|
| Parser used | The live Ensemble parser, `packages/development/lib/trd-parser.js`, via `node packages/development/lib/trd-cli.js parse <this file>` (the byte-identical copies in `packages/full` and `packages/pi/vendor` match). The untracked `dist/orchestrator/trd-parser.js` is a stale build artifact of the retired TypeScript table parser; it has no importer and was not used as evidence. |
| Format deviation | `ensemble-create-trd-foreman` v3.0.1 prescribes a table Master Task List with lowercase `id` and `KATA-T###` ids. The live parser recognises only the narrative form (`## Master Task List`, `### PR N:` + `**Shippable State:**`, `- [ ] **TRD-…**` task lines) and returned zero tasks for the table form, so `implement-trd` could not dispatch it. The narrative form was chosen deliberately; the PRD §12 identity of each task is the `KATA-T###` stem of its `TRD-KATA-T###` id (test tasks add a `-TEST` suffix). |
| Parse result | 56 `TRD-KATA-T001`–`TRD-KATA-T056` tasks in 5 PR sections (22, 14, 7, 5, 8), no parser warnings, no synthetic AC tasks, PR format detected, PRD path resolved to `docs/PRD/PRD-2026-8030852f-foreman-kata-task-provider.md`. Every task has hours (109.75h total), target files, and a `Validates PRD ACs` line where a PRD AC maps to it. |
| Validator | `trd-cli.js validate --prd <PRD>`: `ok: true`, 0 errors, no unresolved dependencies, no cycles, 0 uncovered REQs, 0 invalid AC references. 14 `MISSING_TEST_PAIR` warnings remain and are accepted: 14 implementation tasks (one carrier per REQ group) keep `[satisfies REQ-…]` so the requirement-evidence chain (`verify-requirements-evidence`) has an implementation pointer for every REQ, while the 14 test tasks carry `-TEST` ids whose stem is their own PRD id, so no carrier has a `<carrier-id>-TEST` sibling and the chain falls back to the first test task covering the REQ. Pairing by carrier id would renumber PRD §12. `trd-cli.js analyze` also reports two PRD-level warnings: acceptance criteria are single outcome statements rather than literal Given/When/Then, and the PRD has no heading named Constraints / Assumptions / Dependencies. |
| Traceability | 17 REQs and 57/57 ACs appear in §4 and on task `Validates PRD ACs` lines; §4 and PRD §12 rows are identical (script-checked); every `KATA-T0NN` reference in §4 and PRD §12 resolves to a defined task. |
| Status cells | All 56 task checkboxes are unchecked (`- [ ]`); no task is marked checked, `done`, `todo` or `deferred`. |
| Dispatch path | `packages/foreman_server/priv/defaults/workflows/implement-trd.yaml` runs `/skill:ensemble-implement-trd <path> --foreman`, which preflights with `trd-cli.js parse`. `foreman sling trd` is not implemented (`docs/cli-reference.md`: "NOT IMPLEMENTED"). |
| Not verified here | No implementation code exists; no `mix test` or `go test` was run for this plan. `ensemble-implement-trd` itself was not executed. Kata CLI behavior cited in tasks was observed on `kata` v0.23.0 in isolated scratch workspaces (error envelope, `changed` flag, owner persistence after reopen, `unassign --expect-owner` release and `owner_mismatch` refusal, the `kata status --json` field paths, and comment replay under `--idempotency-key` including `idempotency_mismatch`). The daemon-authenticated-actor case — where `kata whoami` can differ from the effective actor, the reason KATA-T015 reads the actor from `kata status <ref> --json` — was not probed (the scratch workspace ran with `auth: none`) and rests on `kata claim --help`. The retry behavior of `CLAIMED_BY_OTHER` is read from `beads_adapter_code_map.ex` and `run_executor.ex`, not exercised. |

---

## 6. Reused Capabilities

| Capability | Source | Reuse Mechanism |
|---|---|---|
| `ForemanServer.TaskProvider` behaviour | `TRD-2026-48f7b420` | Unchanged import |
| `ForemanServer.TaskProvider.Issue` struct | `TRD-2026-48f7b420` | Unchanged import |
| `ForemanServer.TaskProvider.Registry` GenServer | `TRD-2026-48f7b420` | Reused; capability validation (KATA-T030) and storage-scheme routing (KATA-T053) added generically, no Kata branch |
| `ForemanServer.TaskProviders.ConcurrencyLimiter` | `TRD-2026-48f7b420` | Module reused unchanged; supervised under `ForemanServer.Application` by KATA-T055 (it is not started today); Kata-only caller |
| `ForemanServer.TaskProviders.ProviderError` struct | `TRD-2026-48f7b420` | Unchanged import |
| `ForemanServer.TaskProviders.BeadsAdapter.CodeMap` | `TRD-2026-48f7b420` | `KataAdapter.BuildProviderError` delegates for error code selection |
| `ForemanServer.TaskProvider.ProjectProviderProjector` preflight | `TRD-2026-48f7b420` | Extended to key on `capabilities[:storage_scheme]` (KATA-T053) |
| `ForemanServer.Cli.DoctorTaskProvider` | `TRD-2026-48f7b420` | Made provider-generic (KATA-T056); Kata section added on top (KATA-T042) |
| Go `taskProviderPayload` / `validateTaskProviderConfig` (`project.go`) | existing CLI | Emits `config.cwd` for Kata and rejects a database path for it (KATA-T052) |

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
- `packages/foreman_server/test/foreman_server/task_providers/kata_e2e_test.exs`
- `packages/foreman_server/test/foreman_server/task_provider/registry_routing_test.exs`

**Modified files:**
- `packages/foreman_server/mix.exs` — add `elixirc_paths(:test)` if absent
- `packages/foreman_server/config/test.exs` — add `kata_runner` config
- `packages/foreman_server/config/config.exs` — add `KataAdapter` to providers, add `"kata.capabilities.v1"` to `accepted_contract_versions`, add `accepted_kata_versions`
- `packages/foreman_server/lib/foreman_server/application.ex` — supervise `ConcurrencyLimiter`
- `packages/foreman_server/lib/foreman_server/task_provider/registry.ex`, `task_provider/project_provider_projector.ex`, `workflow/run_executor.ex` — generic capability validation and storage-scheme routing
- `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter.ex` — declare `storage_scheme`
- `packages/foreman_server/lib/foreman_server/task_providers/concurrency_limiter.ex` — moduledoc records the single-instance decision
- `packages/foreman_server/lib/foreman_server/cli/doctor_task_provider.ex` — provider-generic doctor, Kata section
- `packages/foreman_server/test/foreman_server/cli/doctor_task_provider_test.exs`, `task_provider/project_provider_projector_test.exs`, `task_provider/registry_route_test.exs`, `task_provider/registry_test.exs`, `task_providers/beads_adapter_test.exs`, `application_children_test.exs` — Kata and generic-routing cases
- `packages/foreman_cli/cmd/foreman/project.go` and `project_test.go` — Kata config payload and validation
- `packages/foreman_server/CHANGELOG.md` — adapter entry
- `docs/user-guide.md`, `README.md` — Kata adapter setup and the provider-conditional project binding (KATA-T047)
- `docs/cli-reference.md`, `CLAUDE.md` — `foreman project` Kata binding, `foreman doctor` Kata section (KATA-T048)

**Documentation Gate (`AGENTS.md`).** Externally visible identifiers added: provider `ForemanServer.TaskProviders.KataAdapter` and contract version `"kata.capabilities.v1"`, config keys `accepted_kata_versions` and `kata_runner`, the `foreman project create/update --task-provider kata` binding (`--path` becomes `config.cwd`; `--task-provider-database-path` rejected for Kata), and a Kata section in `foreman doctor`. Removed or renamed: none; no CLI verb or flag is added, so `usage_drift_test.go` is unaffected. Stale references found by `grep` for `task-provider-database-path` / `config.database_path`: `README.md` lines 46 and 114–115, `CLAUDE.md` lines 577 and 579, `docs/user-guide.md` lines 561, 573, 2176, 2634 and `docs/cli-reference.md` lines 301, 316, 354, 363 state the database path as the binding contract and become provider-conditional (all four files are owned by KATA-T047/T048). `AGENTS.md` is not a doc-update target.

---

## 8. Open Questions (Verification Tasks)

These are verification tasks, not design decisions — PRD §11 has already resolved both values; each task re-confirms the resolution against the pinned Kata reference and changes the declaration only if upstream contradicts it:

| ID | Item | Verification Source | Verification Task |
|---|---|---|---|
| OPEN-Q1 | Exact `id_format` regex for Kata short_ids — resolved in PRD §11 as `^[a-z0-9]+$` | `docs/reference/cli.md` in Kata repository | KATA-T038 |
| OPEN-Q2 | Format of `accepted_kata_versions` — resolved in PRD §11 as a list of `Version.match?/2` requirement strings | Kata repository version metadata | KATA-T039 |

---

## 9. Non-Goals (from PRD §5)

- Kata federation/hub integration
- Postgres `KATA_DSN` backend
- Kata semantic search / MCP server
- GitHub sync / `kata import` migration paths
- Foreman-owned crash reconciliation (Foreman does NOT scan Kata for orphans)

---

## 10. Changelog

| Version | Date | Changes |
|---|---|---|
| 2.0.4 | 2026-11-19 | Failure-comment idempotency key is now `foreman-fail:<run_id>:<body_hash>` (first 16 hex of the SHA-256 of the comment body) instead of the run id alone, because Kata refuses a reused key with a different body; PRD 1.1.7. KATA-T015 states that an already-unowned task still gets the reopen and the comment, notes that `{:ok, :reopened}` is the shape `RunExecutor` matches while the `@callback fail/3` spec reads `:ok | {:error, term()}`, and KATA-T026 names `idempotency_mismatch` → `BR_ERROR_ENVELOPE` and drops the stale `current_owner` remark. KATA-T036-TEST splits into the three real fail cases (foreign owner, already unowned, ownership race) plus the retry. No task added or removed (still 56), no dependency changed. |
| 2.0.3 | 2026-11-19 | `fail/3` tightened. KATA-T015 now reads `kata status <ref> --json` first and, when a different actor owns the task, writes nothing and returns a typed `CLAIMED_BY_OTHER` error. That code is retryable in `BeadsAdapter.CodeMap` and `RunExecutor.fail_retry_loop` repeats the notification, so the earlier unconditional reopen + comment + unassign would have appended the failure comment to another operator's issue on every attempt. The comment carries `--idempotency-key foreman-fail:<run_id>` (probed: replay is `changed: false`, a different body under the same key is `idempotency_mismatch`), so a retry after a transient unassign failure never duplicates it. KATA-T015 pins the argv and JSON path of each call (`--json` on all four; `$.actor`, `$.owner`, `$.changed`, `$.event.type`) and no longer reads `error.data`. KATA-T035 and KATA-T036-TEST and the AC-005-4, AC-012-2 and AC-014-1 checklist text follow PRD 1.1.6. No task added or removed (still 56), no dependency changed. |
| 2.0.2 | 2026-11-19 | Failure-path claim release decided (user decision), resolving the `[NEEDS CLARIFICATION]` in KATA-T015 and KATA-T035 and PRD §11; PRD 1.1.5 readiness gate PENDING → PASS, 4.0 → 4.5. `fail/3` runs `kata reopen`, `kata comment`, then `kata unassign <ref> --expect-owner <actor>`, with `<actor>` from `kata status <ref> --json` (the daemon-aware effective actor, not `whoami` and never `owner`). KATA-T015, T035 and the AC-005-4, AC-012-2, AC-014-1 and AC-014-2 checklist text updated to the PRD wording. KATA-T026 maps `owner_mismatch` to `CLAIMED_BY_OTHER`. KATA-T020-TEST allows the single-reference `kata status <ref>` lookup and the `unassign` verb. KATA-T036-TEST and KATA-T044-TEST assert the release. No task added or removed (still 56) and no dependency changed. |
| 2.0.1 | 2026-11-19 | Refinement. PR 1 Shippable State rewritten as an observable capability. The 14 test tasks renamed to `-TEST` ids and carry `[satisfies]`; 14 implementation carriers keep `[satisfies]` as well (validator warnings 46 → 14 `MISSING_TEST_PAIR`, with REQ→implementation pointers preserved). 18 tasks that had no PRD AC mapping got concrete acceptance criteria; 7 of them had carried the generic "behavior described above is implemented" phrasing. Error mapping rewritten against Kata's real stderr JSON envelope and the CodeMap upstream codes (`BR_SIGNAL`, `BR_TIMEOUT` and `BR_INVALID_JSON` do not exist in CodeMap; the already-terminal guard uses the close envelope's `changed: false`, not a nonexistent `ALREADY_CLOSED`). AC-006-3 moved from KATA-T039 to KATA-T011/T012. KATA-T002 states the 30 s default timeout. Critical path shortened from 13 to 11 tasks (KATA-T008 no longer waits on the test-mock config; KATA-T030 depends on KATA-T010; KATA-T049 on KATA-T036). One `[NEEDS CLARIFICATION]` inserted (KATA-T015, KATA-T035) and mirrored in PRD §11, which moves to readiness PENDING. Readiness 4.0 → 4.3. |
| 2.0.0 | 2026-11-18 | Master Task List converted to the narrative format the live Ensemble parser accepts; KATA-T052–T056 added; PRD v1.1.3 alignment. |
