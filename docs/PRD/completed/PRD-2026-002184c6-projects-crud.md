---
document_id: PRD-2026-002184c6
version: 0.1.4
status: Draft
date: 2026-08-07
scale_depth: STANDARD
total_requirements: 17
readiness_score: 3.5
---

# PRD: Project CRUD — HTTP Resource Read + Command-Gateway Mutations

## PRD Health Summary

| Priority | Count |
|---|---|
| Must | 12 |
| Should | 4 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---|
| AC coverage | 17/17 (100%) |
| Total ACs | 78 |
| Dependency rows | 10 |
| Ambiguity markers | 5 (1 resolved since v0.1.0; 4 deferred to TRD: AMB-001, AMB-003, AMB-004, AMB-005) |
| Open ambiguity | 4 |
| Readiness score | 3.5 — TENTATIVE (4 open ambiguities, none blocking PRD-to-TRD progression) |
| Version | 0.1.4 |

### Changelog
| Version | Date | Changes |
| 0.1.0 | 2026-08-07 | Initial draft. Corrected architecture: only `GET /api/projects/:id` is a resource route; all mutations continue through `POST /api/commands` (architectural invariant from `AGENTS.md`). |
| 0.1.1 | 2026-08-07 | Recounted REQs (14, not 18) and ACs (51 across 14 REQs); fixed REQ-007 cross-reference (REQ-017 → REQ-013); corrected idempotency contract in REQ-005/REQ-006 and AMB-002 — dedup is enforced by the event-store unique constraint on `command_id`, not by a TTL-bounded in-memory cache; a failed dispatch appends nothing, so the "replay the same 409" claim was wrong; §4 and §8 updated to reflect 3 open ambiguities. |
| 0.1.2 | 2026-08-07 | Restructured §2b recon table to add controller-layer gate row (`@allowed_types`, `aggregate_prefix/1`, `id_field_for/1` in `command_controller.ex:20,60-64,107-115`); corrected envelope-validation status from `403` to `400` (controller's current behavior at lines 49-52, 95-102). |
| 0.1.3 | 2026-08-07 | Re-attributed dedup mechanism in REQ-005/REQ-006/AMB-002 — `event_id = event_id_for(aggregate_id, command_id)` is computed by the actor (`foreman_server/aggregates/actor.ex:122-134`), the event-store primary key on `event_id` rejects the duplicate insert, and the actor handles `:duplicate_event` (lines 173-178) by retrieving the previously-stored event. `CommandGateway.dispatch_operator/2` normalizes/validates/enriches the envelope and calls `CommandRouter` (command_gateway.ex:54-60) — it does not compute `event_id`. v0.1.2 attributed computation to the gateway/router; that was wrong. Added REQ-015 (gateway identity-binding validator as defense in depth, 5 ACs) covering both the direct-gateway tuple (`{:error, {:invalid_envelope, :aggregate_id_mismatch}}`) and HTTP path (`400 Bad Request` with `reason: ":aggregate_id_mismatch"`). Fixed AC-002-5 to `:invalid_envelope` (controller's `build_envelope/1:62` generic path), corrected S-3 (aggregate supports `project.reactivate` but gateway allowlist does NOT admit it), and resolved editing-pattern bugs that left duplicate headers/rows. |
| 0.1.4 | 2026-08-07 | Reversed v0.1.0 SCAMPER-Eliminate decision on list endpoints at user request. Added REQ-016 (HTTP `GET /api/projects` list route, 8 ACs — Should) and REQ-017 (Go CLI `foreman project list` subcommand, 7 ACs — Should). Added AC-012-6 (telemetry `[:foreman_server, :project, :list]`) and AC-009-5 (CLI subcommand grouping now includes `list`). Restored missing AC-012-4 (`[:foreman_server, :project, :archive]` telemetry for `project.archive` dispatches) that was inadvertently skipped in earlier drafts. §2a problem statement and §2b recon updated to note `project_store.list/0` becomes a real surface. §7 Out of Scope updated: list is now in scope (REQ-016/REQ-017); cross-project search, full-text search, and bulk mutation remain out of scope. AC-014-1 updated to "all five subcommands" and S-3 updated to "the five operations" to match the new `list` subcommand. §6 dependency map restored the `foreman_server_web/controllers/command_controller.ex` modify row (REQ-002's `@allowed_types`, `aggregate_prefix/1`, `id_field_for/1`) and merged the `list` subcommand detail into the existing `foreman_cli/cmd/foreman/project.go` row so all 10 rows remain distinct. |

---

## 1. Executive Summary

Operators currently mutate the `foreman_events` event log directly via `psql` to register, update, and archive projects. This bypasses the event store's audit trail, breaks the projection store's invariants, and leaves no path for CI pipelines to script project lifecycle. This PRD defines a first-class, end-to-end HTTP and CLI surface for project lifecycle: **create, read, update, delete, list**.

**Architectural alignment:** all mutations route through the existing `POST /api/commands` command gateway — the sole mutation surface defined by `AGENTS.md`. The two read operations (`GET /api/projects/:id` and `GET /api/projects`) are new resource routes, parallel to the existing `GET /api/tasks/:id` and `GET /api/runs/:id`. The Go CLI is a thin ergonomic layer on top of these endpoints. List reads directly from the projection store via `project_store.list/0` — no new event is appended and no command is dispatched.

**Out of scope:** cross-project search, full-text search, hard delete, project access control / RBAC, multi-tenant project namespaces, project-level secrets management, automated reactivation workflows, project-import from external systems, bulk mutation endpoints (distinct from the read-only list endpoint now in scope).

---

## 2. Background and Evidence

### 2a. Problem Statement

| Pain | Evidence |
|---|---|
| No scriptable project lifecycle | Operators run `psql` to write `project.register` events directly into `foreman_events`, bypassing the actor's `expected_stream_version` conflict path |
| No CI integration path | The `foreman` CLI exposes `task`, `run`, `workflow` subcommands but no `project` subcommand; CI pipelines cannot self-service project registration |
| Inconsistent read access | The projection store has a `projects` table populated by the projection handler, but there is no HTTP endpoint to read it — read paths today require direct Postgres access |
| Delete semantics undefined | `ProjectArchived` exists as an event and a projection column (`archived?`), but no HTTP route surfaces the soft-delete, and there is no operator-gated archive flow |
| No list endpoint | `project_store.list/0` exists and is exercised in test code, but there is no HTTP route and no CLI subcommand to surface it — operators must query Postgres directly to enumerate projects, and CI pipelines cannot audit "which projects are registered" without a database credential |

### 2b. Codebase Recon (existing capability vs. gap)

| Capability | Status | Notes |
|---|---|---|
| `Project` aggregate (CQRS) | Exists | `foreman_server/aggregates/project.ex` handles `project.register`, `project.update`, `project.archive`, `project.reactivate` |
| Typed events | Exists | `project_registered.ex`, `project_updated.ex`, `project_archived.ex` |
| Command gateway allowlist | **Partial** | `foreman_server/command_gateway.ex` lists `@allowed_operator_types ~w(project.register task.create task.approve)` — **`project.update` and `project.archive` are NOT in the gateway allowlist**. The gateway has per-type `validate_aggregate_id/1` clauses (lines 114-188); only the fallback clause `validate_aggregate_id(_)` is a no-op (`-> :ok`), so adding `project.update` / `project.archive` to the allowlist would not by itself bind the envelope's `aggregate_id` to the payload's `project_id` — see REQ-015 for the defense-in-depth identity-binding validator. Public entry point is `CommandGateway.dispatch_operator/2` (lines 54-60), which normalizes/validates/enriches the envelope and calls `CommandRouter`. |
| HTTP controller gate | **Partial** | `foreman_server_web/controllers/command_controller.ex` has its own `@allowed_types`, `aggregate_prefix/1`, and `id_field_for/1` (lines 20, 60-64, 107-115). `project.update` and `project.archive` are rejected at the controller layer before reaching the gateway. Envelope-validation failures currently return `400 Bad Request` with body `{error: "invalid_envelope", reason: inspect(reason)}` (lines 49-52; 95-102 is the symmetric path). Note: the existing `error: "..."` / `reason: "..."` shape predates REQ-007's structured envelope (`{status, code, message, retryable, current_version?}`); aligning the existing `POST /api/commands` controller to REQ-007's envelope is a stated future cross-cutting change and is **not** in scope for this PRD. See REQ-002 for the controller-layer allowlist update; REQ-007 governs only the new `GET /api/projects/:id` route. |
| Projection store | Exists | `foreman_server/project_store.ex` (`save/1`, `get/1`, `list/0`, `archive/1`, `reactivate/1`). `list/0` is currently exercised only by test code; v0.1.4 surfaces it via `GET /api/projects` (REQ-016) and `foreman project list` (REQ-017). |
| `POST /api/commands` | Exists | `foreman_server_web/controllers/command_controller.ex` accepts the envelope and returns `{status: "accepted", result: ...}` |
| `GET /api/tasks/:id`, `GET /api/runs/:id` | Exists | Resource-route pattern; v0.1.0 added `GET /api/projects/:id`; v0.1.4 adds `GET /api/projects` (list) |
| `foreman` CLI | **Gap** | `packages/foreman_cli/cmd/foreman/` has `task`, `run`, `workflow`; no `project` subcommand |
| Bearer auth | Exists | `foreman_server_web/plugs/bearer_auth.ex`; applies to all router plugs |
| Architecture test (CQRS enforcement) | Exists | `event_store_enforcement_test.exs` scans `lib/foreman_server/`; needs a parallel test for `lib/foreman_server_web/` |

### 2c. Elicitation Decisions (confirmed)

- **SCAMPER — Eliminate (v0.1.0):** no list/search/bulk endpoints. CRUD only. *Reversed in v0.1.4 at user request — list is now in scope per REQ-016/REQ-017.* |
|- **SCAMPER — Combine:** project registration includes project-level config (`task_provider`, `database_path`). |
|- **SCAMPER — Adapt:** REST-shaped CLI ergonomics mapped onto the existing command-gateway POST; gh-style CLI surface. |
|- **Failure scenario — concurrent create:** deterministic `command_id` derived from a client-supplied idempotency key; `CommandRouter` dedup prevents double-write. |
|- **Failure scenario — delete during use:** soft-delete (`project.archive`); blocked if the project has an active run. |
|- **Failure scenario — CI retry storm:** the same `command_id` is reused on retry; the server returns the original outcome, not a new event. |
|- **Naming convention:** CLI subcommand is `project {create|get|update|delete|list}` (operator-friendly); the wire-level `type` is `project.register | project.update | project.archive` (existing internal names). List is read-only and goes through `GET /api/projects` — it does NOT add a new command type to the gateway allowlist. |

### 2d. Architectural Constraints (preserved)

- `POST /api/commands` is the **sole mutation surface**. No new mutation routes.
- `CommandRouter` is the sole append point to the event log.
- `CommandGateway.dispatch_operator/2` is the only path a controller may use to enqueue a command (public entry point at `command_gateway.ex:54-60`; normalizes/validates/enriches the envelope and calls `CommandRouter`).
- Aggregate actors are supervised, rehydrated via `Aggregate.load/2`; the existing retry path handles `wrong_expected_version` conflicts.
- All projections are read models; reads do not write.

### 2e. Tech Dependencies (existing, no new infrastructure)

- Elixir 1.16+ / OTP 26+
- Phoenix 1.7+
- Commanded 1.4+ (EventStore adapter)
- PostgreSQL 15+ (existing `foreman_events` table; no new tables)
- Go 1.22+ / `foreman_cli` package
- `Application.compile_env(:foreman_server, :bearer_token, ...)` (existing config)
- No new external services

---

## 3. Requirements

### 3a. HTTP Resource Read

### REQ-001: Must | High | ⚠️ Risk: read route accidentally writing
The system MUST expose a `GET /api/projects/:id` endpoint that returns the project projection.

- AC-001-1: Given a project exists in the projection store with id `proj-1`, when `GET /api/projects/proj-1` is called, then the response is `200 OK` with a JSON body `{project: {id, path, task_provider, archived?, registered_at, updated_at, version}}`
- AC-001-2: Given no project exists with the given id, when `GET /api/projects/:id` is called, then the response is `404 Not Found` with a structured error envelope
- AC-001-3: Given a project exists but is soft-deleted (`archived? = true`), when `GET /api/projects/:id` is called, then the response is `404 Not Found` with `code: "project_archived"` (soft-deletes are hidden from read)
- AC-001-4: Given an unauthenticated request, when `GET /api/projects/:id` is called, then the response is `401 Unauthorized` (Bearer auth plug enforces)
- AC-001-5: Given the request reaches the controller, when the controller runs, then no event is appended and no command is dispatched, and the architecture test in REQ-008 (web-layer CQRS enforcement) does not flag the read handler as a writer

### 3b. Command-Gateway Mutations

### REQ-002: Must | High | ⚠️ Risk: any of four allowlist tables omitted rejects new types
Both layers of the mutation gate MUST accept `project.update` and `project.archive` as operator-gated command types. This requires updating four tables: `CommandController.@allowed_types`, `CommandController.aggregate_prefix/1`, `CommandController.id_field_for/1`, AND `CommandGateway.@allowed_operator_types`. REQ-015 provides defense-in-depth identity validation at the gateway, but runs only AFTER the gateway allowlist check — so an entry must be present in `@allowed_operator_types` for the new types to flow end-to-end.

- AC-002-1: Given `project.update` is added to `CommandController.@allowed_types`, when an HTTP `POST /api/commands` envelope with `type: "project.update"` is received, then the controller does not reject the type and proceeds to envelope construction
- AC-002-2: Given `project.archive` is added to `CommandController.@allowed_types`, when an HTTP `POST /api/commands` envelope with `type: "project.archive"` is received, then the controller does not reject the type and proceeds to envelope construction
- AC-002-3: Given `aggregate_prefix/1` returns `"project"` for both `project.update` and `project.archive`, when the controller constructs the `aggregate_id`, then it is `"project:<project_id>"` (the same shape as `project.register`)
- AC-002-4: Given `id_field_for/1` returns `:project_id` for both `project.update` and `project.archive`, when the controller reads the id from the payload, then it correctly extracts `project_id` and constructs `"project:#{project_id}"`
- AC-002-5: Given an operator type is not in `CommandController.@allowed_types`, when an HTTP request arrives, then the response is `400 Bad Request` with body `{error: "invalid_envelope", reason: ":invalid_envelope"}` (current controller behavior: `build_envelope/1` at `command_controller.ex:62` returns `{:error, :invalid_envelope}` and `create/2` at lines 49-52 renders it via `inspect/1`; envelope shape predates REQ-007's structured envelope — see §2b HTTP controller gate row)
- AC-002-6: Given the existing `project.register` flow, when an HTTP `POST /api/commands` envelope with `type: "project.register"` is received, then the behavior is unchanged (regression-safe)
- AC-002-7: Given `project.update` is added to `CommandGateway.@allowed_operator_types`, when an envelope reaches the gateway, then the type is not rejected at the gateway's allowlist gate (`command_gateway.ex` ~line 98) and proceeds to `validate_aggregate_id/1` (REQ-015)
- AC-002-8: Given `project.archive` is added to `CommandGateway.@allowed_operator_types`, when an envelope reaches the gateway, then the type is not rejected at the gateway's allowlist gate and proceeds to `validate_aggregate_id/1`

### REQ-003: Must | High
`POST /api/commands` MUST continue to return the existing `201 Created` envelope `{status: "accepted", result: serialize(result)}` for all three project command types (`project.register`, `project.update`, `project.archive`).

- AC-003-1: Given a valid `project.register` envelope, when the controller dispatches, then the response is `201 Created` with `{status: "accepted", result: {project_id, ...}}`
- AC-003-2: Given a valid `project.update` envelope, when the controller dispatches, then the response is `201 Created` with the same envelope shape
- AC-003-3: Given a valid `project.archive` envelope, when the controller dispatches, then the response is `201 Created` with the same envelope shape
- AC-003-4: Given the actor's retry path exhausts on `wrong_expected_version`, when the response is generated, then the controller returns `409 Conflict` with `code: "version_conflict"` and `current_version` in the body

### 3c. Soft-Delete Semantics

### REQ-004: Must | High | ⚠️ Risk: orphaning in-flight runs
`project.archive` MUST be rejected with `409 Conflict` if the project has any run in a non-terminal state.

- AC-004-1: Given a project has zero runs, when `project.archive` is dispatched, then the command succeeds and `ProjectArchived` is appended
- AC-004-2: Given a project has one or more runs in a non-terminal state, when `project.archive` is dispatched, then the response is `409 Conflict` with `code: "project_has_active_runs"` and the list of active run ids
- AC-004-3: Given all of a project's runs reach a terminal state after a previous `409`, when `project.archive` is retried, then it succeeds
- AC-004-4: Given a project has at least one run in a non-terminal state (per the active-run definition resolved from AMB-004 at the TRD stage), when `project.archive` is dispatched, then the response is `409 Conflict` with `code: "project_has_active_runs"` and the list of active run ids (this AC is bound to the AMB-004 enumerated terminal-state set; the implementation test must enumerate the set first)

### REQ-005: Must | High | ⚠️ Risk: failed dispatch leaves no record to dedup against
A `project.archive` request that fails because of `409 project_has_active_runs` MUST NOT append a `ProjectArchived` event; a successful `project.archive` retried with the same `command_id` MUST return the original outcome and MUST NOT append a second event.
- AC-005-1: Given a `project.archive` request that returns `409 project_has_active_runs`, when the response is generated, then no `ProjectArchived` event exists in the event log for that stream (the aggregate's `handle_command/2` rejected the dispatch before any append — there is no event to dedup)
- AC-005-2: Given a `project.archive` request that returned `201 Created` with `command_id = X` and `aggregate_id = "project:proj-1"`, when the operator retries the request with the same `command_id = X` and `aggregate_id`, then the actor (`foreman_server/aggregates/actor.ex`) computes `event_id = event_id_for(aggregate_id, command_id)` (lines 122-134), attempts to append, the event store's primary key on `event_id` rejects the duplicate insert as a unique violation, the actor handles the `:duplicate_event` case (lines 173-178) by retrieving the previously-stored event, and the actor returns the original `201` outcome; no second `ProjectArchived` event is appended

### 3d. Idempotency for CI

### REQ-006: Must | High | ⚠️ Risk: CI retry storm doubles events
The CLI MUST generate a deterministic `command_id` per logical operation so that CI retries against the same logical operation do not produce a second event. Dedup is enforced by the actor (`foreman_server/aggregates/actor.ex`), which computes `event_id = event_id_for(aggregate_id, command_id)` (lines 122-134) before each append. The event store's primary key on `event_id` rejects the duplicate insert as a unique violation, and the actor handles the `:duplicate_event` case (lines 173-178) by retrieving the previously-stored event and returning its outcome to the caller. `CommandGateway.dispatch_operator/2` normalizes/validates/enriches the envelope and calls `CommandRouter` (command_gateway.ex:54-60) — it does not compute `event_id`.

- AC-006-1: Given a CLI invocation with `--idempotency-key=<key>`, when the request is constructed, then the `command_id` in the envelope equals `sha256("project.<op>.<key>")` (or an equivalent deterministic transformation)
- AC-006-2: Given no `--idempotency-key` is supplied, when the request is constructed, then the `command_id` is generated from the operation inputs (e.g. `sha256("project.create." + path + "." + task_provider)`) so a re-run with the same inputs is also idempotent
- AC-006-3: Given a CI pipeline runs the same `foreman project create` command twice with the same `--idempotency-key`, when the second run reaches the actor, then the actor (`foreman_server/aggregates/actor.ex`) computes `event_id = event_id_for(aggregate_id, command_id)` (lines 122-134) — the same value for both runs — attempts to append, the event store's primary key on `event_id` rejects the second insert as a unique violation, the actor handles the `:duplicate_event` case (lines 173-178) by retrieving the previously-stored event, and the response is the original `201` outcome with no second `ProjectRegistered` event
- AC-006-4: Given an event with `event_id = event_id_for(aggregate_id, command_id)` is retained in the event store, when the same envelope (same `command_id` and `aggregate_id`) is re-submitted, then the event-store primary key on `event_id` rejects the duplicate insert, the actor handles `:duplicate_event` (lines 173-178) by retrieving the previously-stored event, and the response is the original outcome — idempotency holds for the retained-event lifetime of the event store (event-retention policy is an operational concern outside this PRD)

### 3e. Error Envelope Consistency

### REQ-007: Must | Medium
All errors from the new `GET /api/projects/:id` route and the CLI MUST conform to a single structured error envelope.
- AC-007-1: Given a `GET /api/projects/:id` returns an error, when the response is generated, then the body is `{status: "error", code: "<snake_case>", message: "<human>", retryable: <bool>, current_version?: <int>}` and the appropriate HTTP status
- AC-007-2: Given the CLI receives an error response, when it formats the failure, then it prints the envelope to stderr as JSON and exits with the documented exit code (see REQ-013)
- AC-007-3: Given the response includes `current_version` (e.g. on `409 version_conflict`), when the CLI reads it, then it surfaces the version in a structured `--show=version` output mode (or the equivalent `--format=json`)

### 3f. Web-Layer CQRS Enforcement

### REQ-008: Must | High | ⚠️ Risk: a future controller bypasses the gateway
The web layer (`foreman_server_web/`) MUST be subject to a CQRS enforcement test that mirrors the existing `event_store_enforcement_test.exs`.

- AC-008-1: Given a controller file under `lib/foreman_server_web/`, when the architecture test scans it, then any call to `EventStore.append_to_stream`, `CommandRouter.append_*`, or direct `EventStore.Adapter` dispatch causes the test to fail
- AC-008-2: Given a controller file under `lib/foreman_server_web/`, when the architecture test scans it, then calls to `CommandGateway.dispatch_operator/2` are allowed (sole permitted write path)
- AC-008-3: Given `ProjectController` is added, when the test runs, then the new controller is included in the scan set

### 3g. Go CLI — Project Subcommand

### REQ-009: Must | Medium
The Go CLI MUST expose a `foreman project` subcommand grouping with `create`, `get`, `update`, `delete`, and `list` subcommands. The `list` subcommand is specified in REQ-017.

- AC-009-1: Given `foreman project create --id <id> --path <path> --task-provider <name>` is invoked, when the CLI runs, then it POSTs `/api/commands` with `type: "project.register"` and the required payload, and prints the envelope on success
- AC-009-2: Given `foreman project get <id>` is invoked, when the CLI runs, then it calls `GET /api/projects/<id>` and prints the projection
- AC-009-3: Given `foreman project update <id> --task-provider <name>` is invoked, when the CLI runs, then it POSTs `/api/commands` with `type: "project.update"`
- AC-009-4: Given `foreman project delete <id>` is invoked, when the CLI runs, then it POSTs `/api/commands` with `type: "project.archive"` (the soft-delete)
- AC-009-5: Given `foreman project list` is invoked, when the CLI runs, then it calls `GET /api/projects` (REQ-016) and prints the response; requirements for the table layout, `--include-archived`, and `--format` are specified in REQ-017

### REQ-010: Must | Medium
The CLI subcommands MUST follow the existing CLI conventions (long flags, JSON output mode, Bearer auth via env).

- AC-010-1: Given `FOREMAN_API_URL` and `FOREMAN_API_TOKEN` are set, when the CLI runs, then the client reads them via the existing `internal/client` (no new client code path)
- AC-010-2: Given `--format=json` is passed, when the CLI runs, then the response envelope is printed to stdout as JSON
- AC-010-3: Given no `--format` is passed, when the CLI runs, then the output is human-readable (id and short summary)

### 3h. Non-Functional — Auth, Telemetry, Observability

### REQ-011: Must | High
The `GET /api/projects/:id` endpoint MUST be subject to the existing Bearer auth plug.

- AC-011-1: Given no `Authorization: Bearer <token>` header and no `?token=` query, when the request reaches the router, then the response is `401 Unauthorized` with `code: "missing_token"`
- AC-011-2: Given an invalid token, when the request reaches the router, then the response is `401 Unauthorized` with `code: "invalid_token"`
- AC-011-3: Given a valid token, when the request reaches the controller, then the controller runs (existing auth plug behavior preserved)

### REQ-012: Should | Medium
The system MUST emit telemetry events for each project lifecycle operation.

- AC-012-1: Given a `GET /api/projects/:id` is called, when the response is generated, then `[:foreman_server, :project, :read]` is emitted with `duration_ms` and `outcome: :ok | :error`
- AC-012-2: Given a `project.register` envelope is dispatched, when the response is generated, then `[:foreman_server, :project, :register]` is emitted
- AC-012-3: Given a `project.update` envelope is dispatched, when the gateway completes the dispatch, then `[:foreman_server, :project, :update]` is emitted
- AC-012-4: Given a `project.archive` envelope is dispatched, when the gateway completes the dispatch, then `[:foreman_server, :project, :archive]` is emitted
- AC-012-5: Given an outcome is `:error`, when the telemetry event is emitted, then it includes `code` and `retryable` from the response envelope
- AC-012-6: Given a `GET /api/projects` (list) is called, when the response is generated, then `[:foreman_server, :project, :list]` is emitted with `duration_ms`, `count: <n>`, and `outcome: :ok | :error` (added in v0.1.4 for REQ-016)

### REQ-013: Should | Medium
The CLI MUST use a documented exit-code map for errors so that CI pipelines can branch on outcome.

- AC-013-1: Given a successful CLI run, when the command exits, then the exit code is `0`
- AC-013-2: Given a usage error (missing required flag), when the CLI parses the arguments, then the exit code is `1` and a usage message is printed to stderr
- AC-013-3: Given the server returns `404 not_found` or `404 project_archived`, when the CLI receives the response, then the exit code is `2`
- AC-013-4: Given the server returns `409 conflict` (version conflict or active-runs), when the CLI receives the response, then the exit code is `3`
- AC-013-5: Given the server returns `401 unauthorized`, when the CLI receives the response, then the exit code is `4`
- AC-013-6: Given the server returns any other server error (5xx), when the CLI receives the response, then the exit code is `5`

### REQ-014: Could | Low
The user guide (`docs/user-guide.md`) and CLI reference (`docs/cli-reference.md`) MUST document the new `project` subcommand grouping, including the `project archive` ↔ `project delete` mapping.

- AC-014-1: Given the user-guide is updated, when an operator reads the project section, then they see all five subcommands (`create`, `get`, `update`, `delete`, `list`) with examples and a note that `delete` is a soft-delete (archive); the list subcommand documents the default table columns, `--include-archived`, and `--format` flags
- AC-014-2: Given the CLI reference is updated, when an operator runs `foreman project delete --help`, then the help text states the operation is a soft-delete and that an active run blocks it

### 3i. Identity-Binding Validation (Defense in Depth)

### REQ-015: Must | High | ⚠️ Risk: cross-project command injection
`CommandGateway.dispatch_operator/2` MUST reject any operator command whose `aggregate_id` does not match `"<aggregate_prefix>:<id_field_value>"` for the `project.update` and `project.archive` operator types. The controller constructs the `aggregate_id` correctly via `aggregate_prefix/1` and `id_field_for/1` (REQ-002), but the gateway must independently verify the identity binding before dispatching to the actor. Two contract surfaces are covered:
- **Direct gateway path** (any non-HTTP caller): the gateway's `validate_aggregate_id/1` returns `{:error, {:invalid_envelope, :aggregate_id_mismatch}}` per `command_gateway.ex:128-129`.
- **HTTP controller path** (`POST /api/commands`): the controller intercepts the mismatch before reaching the gateway and returns `400 Bad Request` with body `{error: "invalid_envelope", reason: ":aggregate_id_mismatch"}` per `command_controller.ex:49-52` (the existing envelope shape predates REQ-007's structured envelope — see §2b HTTP controller gate row).

- AC-015-1: Given a `project.update` envelope arrives at `CommandGateway.dispatch_operator/2` with `aggregate_id: "project:victim"` and `payload.project_id: "other"`, when the gateway runs `validate_aggregate_id/1`, then it returns `{:error, {:invalid_envelope, :aggregate_id_mismatch}}` and no event is appended (direct-gateway tuple path)
- AC-015-2: Given a `project.archive` envelope arrives at `CommandGateway.dispatch_operator/2` with `aggregate_id: "project:victim"` and `payload.project_id: "other"`, when the gateway runs `validate_aggregate_id/1`, then it returns `{:error, {:invalid_envelope, :aggregate_id_mismatch}}` and no event is appended (direct-gateway tuple path)
- AC-015-3: Given a `project.update` or `project.archive` envelope arrives at the HTTP controller with mismatched `aggregate_id` and `payload.project_id`, when the controller runs `resolve_aggregate_id/3` (`command_controller.ex:101`), then it returns `{:error, :aggregate_id_mismatch}`, `build_envelope/1` passes it through unchanged (lines 74-75), and `create/2` renders the response as `400 Bad Request` with body `{error: "invalid_envelope", reason: ":aggregate_id_mismatch"}` and no event is appended (HTTP path; current controller behavior — distinct from AC-002-5's generic `:invalid_envelope` from line 62)
- AC-015-4: Given a `project.update` envelope with `aggregate_id: "project:proj-1"` and `payload.project_id: "proj-1"`, when the controller dispatches, then validation passes at both layers and the command proceeds to the actor (positive case)
- AC-015-5: Given the gateway's allowlist gate accepts the operator type, when the gateway runs `validate_aggregate_id/1` for `project.update` or `project.archive`, then the validator returns `:ok` for a matching `"<aggregate_prefix>:<id_field_value>"` pair and `{:error, {:invalid_envelope, :aggregate_id_mismatch}}` for any mismatched pair, before any call to the actor


### 3j. List Projects (added v0.1.4)

### REQ-016: Should | Medium | ⚠️ Risk: list endpoint accidentally writing
The system MUST expose a `GET /api/projects` endpoint that returns the projection-store list of projects. The list is served by reading `project_store.list/0` directly — no event is appended and no command is dispatched. `?include_archived=<bool>` controls whether archived projects are included; the default excludes them. This is a read-only resource route that does NOT add a new command type to the gateway allowlist.

- AC-016-1: Given one or more projects exist in the projection store, when `GET /api/projects` is called, then the response is `200 OK` with body `{projects: [{id, path, task_provider, archived?, registered_at, updated_at, version}, ...]}`
- AC-016-2: Given no projects exist in the projection store, when `GET /api/projects` is called, then the response is `200 OK` with body `{projects: []}` (an empty list is NOT an error)
- AC-016-3: Given `?include_archived=true` is supplied, when `GET /api/projects` is called, then projects with `archived? = true` are included in the response
- AC-016-4: Given no `include_archived` query parameter is supplied (defaults to `false`), when `GET /api/projects` is called, then projects with `archived? = true` are excluded from the response
- AC-016-5: Given the request reaches the controller, when the controller runs, then no event is appended and no command is dispatched, and the architecture test in REQ-008 does not flag the list handler as a writer
- AC-016-6: Given an unauthenticated request (no `Authorization: Bearer <token>` header and no `?token=` query), when `GET /api/projects` is called, then the response is `401 Unauthorized` with `code: "missing_token"` (existing Bearer auth plug behavior — same as REQ-011)
- AC-016-7: Given the dataset exceeds the hard cap (per AMB-005, default 1000), when `GET /api/projects` is called, then the response is `200 OK` with at most the hard cap entries and the response header `X-Total-Count` reflects the actual returned count
- AC-016-8: Given the server returns a 5xx error (e.g. projection store unavailable), when the response is generated, then the body conforms to REQ-007's structured error envelope `{status: "error", code: "<snake_case>", message: "<human>", retryable: <bool>}`

### REQ-017: Should | Medium
The Go CLI MUST expose a `foreman project list` subcommand that calls the `GET /api/projects` endpoint from REQ-016. Default output is a human-readable table; `--format=json|ndjson` produces machine-readable output. The CLI mirrors the API's `?include_archived` flag via a `--include-archived` long flag. An empty list is not an error — exit code 0.

- AC-017-1: Given `foreman project list` is invoked, when the CLI runs, then it calls `GET /api/projects?include_archived=false` and prints the default table with columns `ID, PATH, ARCHIVED, REGISTERED, VERSION`
- AC-017-2: Given `foreman project list --include-archived` is invoked, when the CLI runs, then it calls `GET /api/projects?include_archived=true` and the table includes archived projects
- AC-017-3: Given `foreman project list --format=json` is invoked, when the CLI runs, then the response array is printed to stdout as a single JSON array
- AC-017-4: Given `foreman project list --format=ndjson` is invoked, when the CLI runs, then each project is printed on its own line as a JSON object (suitable for `jq -c` or streaming)
- AC-017-5: Given the server returns `200 OK` with an empty list, when the CLI runs, then it exits with code `0` (empty list is not an error — see AC-016-2)
- AC-017-6: Given the server returns `401` (unauthenticated), when the CLI runs, then it exits with code `4` (per AC-013-5)
- AC-017-7: Given the server returns any `5xx` error, when the CLI runs, then it exits with code `5` (per AC-013-6)

---

## 4. Ambiguity Markers
| Marker | Question | Default if unresolved | Impact |
| AMB-001 | Numeric adoption target (% of new projects via API/CLI by EOY) | TBD — placeholder in §5 | Success metric measurement |
| ~~AMB-002~~ | ~~Idempotency-key retention window in `CommandRouter` (how long is `command_id` dedup remembered?)~~ | **RESOLVED in v0.1.3.** Dedup is enforced by the actor (`foreman_server/aggregates/actor.ex`), which computes `event_id = event_id_for(aggregate_id, command_id)` (lines 122-134) before each append. The event store's primary key on `event_id` rejects the duplicate insert as a unique violation, and the actor handles the `:duplicate_event` case (lines 173-178) by retrieving the previously-stored event and returning its outcome to the caller. `CommandGateway.dispatch_operator/2` normalizes/validates/enriches the envelope and calls `CommandRouter` (command_gateway.ex:54-60) — it does not compute `event_id`. There is no separate 'command_id unique constraint' and no TTL-bounded cache. Originally marked resolved in v0.1.1 against an incorrect TTL-bounded mechanism; v0.1.2 partially corrected to event-id + PK but mis-attributed computation to the gateway/router; v0.1.3 names the actor. | n/a (no longer ambiguous) |
| AMB-003 | p99 latency target for `GET /api/projects/:id` | TBD — no SLO at v0.1; revisit at TRD | Future NFR promotion |
| AMB-004 | Active-run definition (which run-aggregate states count as non-terminal for the archive block in REQ-004) | TBD — implementer reads `foreman_server/aggregates/run.ex` to enumerate terminal states and locks the test contract | AC-004-4 |
| AMB-005 | Hard-cap value for `GET /api/projects` list response (default 1000 in AC-016-7) | TBD — confirm at TRD whether 1000 is acceptable; `X-Total-Count` header behavior bounds the visible surface | AC-016-7 |

AMB-001, AMB-003, AMB-004, and AMB-005 are flagged for resolution at the TRD stage before the Implementation Readiness Gate is moved from 3.5 to 4.0. (AMB-005 is added in v0.1.4 alongside the new list endpoint.)



## 5. Success Metrics (placeholder)

| Metric | Target | Source |
|---|---|---|
| % of new projects created via API/CLI vs. direct `psql` event writes | AMB-001 — TBD | Foreman MCP / event log audit |
| Time-to-onboard for a new project (CI pipeline → registered → runnable) | TBD | Operational metric |
| Number of `409 project_has_active_runs` per 100 archive attempts | TBD | Telemetry `[:foreman_server, :project, :archive]` with `outcome: :error` |

---

## 6. Dependency Map

| # | Dependency | Type | Status | Required for |
|---|---|---|---|---|
| 1 | `foreman_server/aggregates/project.ex` | Existing module | Stable | REQ-002..REQ-005 |
| 2 | `foreman_server/command_gateway.ex` allowlist | Modify | Ready | REQ-002, REQ-015 |
| 3 | `foreman_server_web/controllers/command_controller.ex` (`@allowed_types`, `aggregate_prefix/1`, `id_field_for/1`) | Modify | Ready | REQ-002 (three of the four gate tables live here; the fourth, `@allowed_operator_types`, lives in `command_gateway.ex` at row 2) |
| 4 | `foreman_server_web/router.ex` (add `GET /api/projects/:id` and `GET /api/projects` index routes) | Modify (add 2 GET routes) | Ready | REQ-001, REQ-011, REQ-016 |
| 5 | `foreman_server_web/controllers/project_controller.ex` | New | Greenfield | REQ-001, REQ-016 |
| 6 | `foreman_server/project_store.ex` (read) | Existing | Stable | REQ-001, REQ-016 |
| 7 | Architecture test (web layer) | New or extend existing | Greenfield | REQ-008, REQ-016 (list handler must be covered) |
| 8 | `foreman_cli/cmd/foreman/project.go` (`create`, `get`, `update`, `delete`, `list` subcommands; `list` includes default table rendering) | New | Greenfield | REQ-009, REQ-010, REQ-017 |
| 9 | `foreman_cli/internal/client/client.go` | Existing | Stable | REQ-010, REQ-017 |
| 10 | Telemetry handlers | Modify (extend event set) | Greenfield (small) | REQ-012 |

---

## 7. Out of Scope (explicit)

- **Cross-project search / full-text search** — list is a flat enumeration of the `projects` table; substring/glob search across names, paths, or descriptions is not in v0.1.4 and would require a separate query layer
- **Bulk mutation endpoints** — `POST /api/commands` accepts one envelope per request; bulk-mutate-many-projects is a separate operational concern
- **Hard delete** — soft-delete (archive) only; reactivation is a separate operation not in v1
- **Project access control / RBAC** — bearer token gates the whole API today; per-project ACL is future
- **Multi-tenant project namespaces** — single namespace today
- **Project-level secrets management** — out of scope; deferred to the secrets-management TRD
- **Automated reactivation workflows** — `project.reactivate` exists as a command but is not surfaced in the CLI for v1
- **Migration importer / external integrations** — out of scope


## 8. Self-Critique & Issue Resolution

Fifteen issues surfaced during self-review across v0.1.0, v0.1.1, v0.1.2, v0.1.3, and v0.1.4. Eleven are resolved (S-1..S-11); the remaining four are open ambiguities (AMB-001, AMB-003, AMB-004, AMB-005) deferred to the TRD stage (see §4).

### 8a. Resolved in v0.1.0

| # | Issue | Resolution |
|---|---|---|
| S-1 | Initial draft proposed `POST/PATCH/DELETE /api/projects` mutation routes, contradicting AGENTS.md's "POST /api/commands is the sole mutation surface" invariant | Corrected: only `GET /api/projects/:id` is a new resource route. `project.register`, `project.update`, `project.archive` flow through the existing `POST /api/commands`. The original draft was scrapped and REQ-001/REQ-002/REQ-003 rewritten. |
| S-2 | HTTP status code `201 Created` is semantically wrong for `update` and `archive` responses | Kept `201 Created` for all three to match the existing `command_controller.ex` convention. Noted as a known cross-cutting inconsistency; changing it is a separate refactor and out of scope for this PRD. |
| S-3 | `project.reactivate` is supported by the `Project` aggregate but is intentionally neither admitted at the gateway allowlist nor exposed in the CLI for v1 | The current gateway allowlist (`command_gateway.ex` §2b) admits `project.register`, `task.create`, and `task.approve` only — `project.reactivate` is not admitted. The CLI surface for v1 is the five operations (`create`, `get`, `update`, `delete`, `list`); `list` was added in v0.1.4 alongside REQ-016/REQ-017. Reactivation is documented as out of scope in §7. Adding reactivation later is a separate PRD scope (it would also need a gateway allowlist addition and a CLI subcommand). |
| S-4 | Telemetry emission point (controller vs. `CommandGateway`) | Documented as an implementation choice; both points are valid since `CommandGateway` is the boundary. No PRD change. |
| S-5 | Architecture test scope — does the existing `event_store_enforcement_test.exs` cover `lib/foreman_server_web/`? | No. The existing test scans `lib/foreman_server/`, which does not include the web layer. REQ-008 specifies a parallel test for `lib/foreman_server_web/`. |
| S-6 | v0.1.0 claimed REQ-005/REQ-006/AMB-002 a TTL-bounded `command_id` dedup with a "replay the same 409" guarantee on failed commands — both wrong; the event store enforces persistent uniqueness and a failed dispatch appends nothing | Corrected in v0.1.1 (mechanism); corrected in v0.1.2 (event-id + PK attribution); corrected in v0.1.3 (attribution moved to actor). REQ-005/REQ-006 ACs rewritten to attribute `event_id_for/2` to `foreman_server/aggregates/actor.ex` (lines 122-134) with `:duplicate_event` handling at lines 173-178; AMB-002 retired. |
| S-7 | v0.1.0 metadata claimed 18 requirements and 18/18 AC coverage; the body only contained REQ-001..REQ-014 (14 REQs) | Recounted in v0.1.1: `total_requirements: 14`. Recounted again in v0.1.3 after adding REQ-015: `total_requirements: 15`, ACs 59 → 61 after REQ-002 restructure (6 → 8). |
| S-8 | REQ-002 covered only the controller-layer allowlist tables; the gateway-layer `@allowed_operator_types` allowlist (which gates before REQ-015's identity validator) was not in any requirement | v0.1.3: REQ-002 description rewritten to cover all four tables (`@allowed_types`, `aggregate_prefix/1`, `id_field_for/1`, AND `@allowed_operator_types`); AC-002-7 and AC-002-8 added for the gateway allowlist of `project.update`/`project.archive`. |
| S-9 | REQ-005 AC-005-2 and REQ-006 AC-006-3 still attributed dedup to `CommandRouter` / `CommandGateway` after v0.1.1; v0.1.2 partially corrected (event_id + PK) but kept wrong attribution | v0.1.3: ACs rewritten to attribute `event_id = event_id_for(aggregate_id, command_id)` to the actor (`foreman_server/aggregates/actor.ex:122-134`), with the event-store PK rejecting the duplicate insert and the actor handling `:duplicate_event` (lines 173-178) by retrieving the previously-stored event. |
| S-10 | v0.1.2 described `validate_aggregate_id/1` as a no-op; in fact the function has real per-type validators at lines 114-188 and only the fallback clause is a no-op | v0.1.3: §2b recon row refined; the function's real per-type structure is now stated accurately. |
| S-11 | v0.1.3 §2c marked SCAMPER-Eliminate as removing "list / search / bulk endpoints" from v1; the user reversed this decision in v0.1.4 refine-prd interview and asked to add list functionality to both the HTTP API and CLI | v0.1.4: §2c decision row reversed; §7 out-of-scope bullet removed and replaced with the precise note that list is in scope (REQ-016/REQ-017) but cross-project search and bulk mutation are not. REQ-016 and REQ-017 added with 8 + 7 = 15 new ACs; AC-009-5 (CLI subcommand dispatch) and AC-012-6 (`[:foreman_server, :project, :list]` telemetry) added; AC-012-4 (`[:foreman_server, :project, :archive]` telemetry for `project.archive` dispatches) restored — it had been inadvertently skipped since v0.1.0 leaving REQ-012 with only 5 of the 6 expected ACs. AMB-005 (hard cap value) added to §4. No regression to existing REQs. Final AC count: 78. |

### 8b. Deferred to TRD stage (open ambiguity)

These match the four remaining AMB-NNN entries in §4 (AMB-002 was initially retired in v0.1.1, then re-corrected in v0.1.3 to attribute dedup to the actor rather than the gateway/router; AMB-005 is the new v0.1.4 entry for the list endpoint hard cap). They do not block the PRD's progression to TRD creation; they block the Implementation Readiness Gate from advancing to 4.0 (currently 3.5 TENTATIVE).

| AMB | Topic | TRD-stage action |
|---|---|---|
| AMB-001 | Numeric adoption target | Set in TRD §5 Success Metrics with rationale |
| AMB-003 | p99 latency target | Optional NFR; revisit at TRD with observed baseline |
| AMB-004 | Active-run definition (terminal states of the run aggregate) | Read `foreman_server/aggregates/run.ex`; enumerate terminal states and bind AC-004-4 to the enumerated set |
| AMB-005 | Hard-cap value for `GET /api/projects` (default 1000) | Confirm at TRD whether 1000 is the right bound; AC-016-7 makes the cap observable via `X-Total-Count` |

### 8c. Implementation Readiness Gate

| Gate criterion | Status | Notes |
|---|---|---|
| All Must/Should/Could requirements have ≥1 AC | PASS | 17/17 (78 total ACs) |
| ACs use Given/When/Then wording | PASS | all ACs conform |
| REQs trace to Must/Should from elicitation | PASS | SCAMPER elimination/combine/adapt + failure scenarios mapped |
| No direct DB writes from new modules | PASS | REQ-008 architecture test enforces |
| Bearer auth applied to new routes | PASS | REQ-011 |
| Bearer auth on `POST /api/commands` for new types | PASS | existing plug covers all router plugs |
| Architecture test exists for web layer | PASS (REQ-008) | greenfield test |
| Ambiguity markers all closed or explicitly deferred | OPEN | 4 deferred to TRD (AMB-001, AMB-003, AMB-004, AMB-005) |
| Numeric thresholds have rationale | OPEN | AMB-001, AMB-003, AMB-005 |
| No new infrastructure introduced | PASS | uses existing EventStore, CommandRouter, Bearer auth, Go client |
| **Score** | **3.5 — TENTATIVE** | advance to 4.0 after AMB-001, AMB-003, AMB-004, AMB-005 are resolved at TRD stage |

---

*Generated: 2026-08-07 | Document ID: PRD-2026-002184c6 | Scale: STANDARD | Draft v0.1.4*
