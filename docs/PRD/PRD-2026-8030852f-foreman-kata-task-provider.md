---
documentId: PRD-2026-8030852f
label: prd-foreman-kata-task-provider
title: "Foreman × Kata (kenn.io/kata) — Task-Provider Integration"
version: 1.1.13
status: Draft
date: 2026-11-18
scaleDepth: STANDARD
prdReference: null
sourceTrd: TRD-2026-8030852f-foreman-kata-task-provider.md
author: Foreman ensemble-create-prd
totalRequirements: 17
totalAcceptanceCriteria: 57
readiness_gate: PASS
readinessScore: 4.5
refineRounds: 0
complexityBreakdown:
  Low: 3
  Medium: 10
  High: 4
---

# PRD: Foreman × Kata (kenn.io/kata) — Task-Provider Integration

## 1. Health Summary

| Count | Priority |
|---|---|
| 12 | Must |
| 4 | Should |
| 1 | Could |
| 0 | Won't |

| Value | Metric |
|---|---|
| 17/17 (100%) | AC coverage (every requirement carries acceptance criteria) |
| 24 | Cross-requirement dependency edges across 16 of 17 REQs (§8 Dependency Map; REQ-001 is the root) |
| 1 | External cross-requirement link (cross-reference to PRD-2026-d99cd90d, not blocking) |
| 14 | Risk flags (REQs with Risk Level Medium or High: all but REQ-002, REQ-004, REQ-016) |
| 0 | Open ambiguity markers (PRD §11, one per `[NEEDS CLARIFICATION]`) |
| 0 | TRD decisions required (OPEN-Q1, OPEN-Q2 — both resolved in §11) |

Requirement counts above are derived from the approved TRD traceability table (§4 of
`TRD-2026-8030852f`), not independently invented. AC distribution per requirement:
REQ-001: 3, REQ-002: 4, REQ-003: 4, REQ-004: 3, REQ-005: 6, REQ-006: 3, REQ-007: 4,
REQ-008: 4, REQ-009: 2, REQ-010: 3, REQ-011: 3, REQ-012: 4, REQ-013: 2, REQ-014: 3,
REQ-015: 2, REQ-016: 2, REQ-017: 5. Sum = 57 (56 traced verbatim from the TRD
plus AC-002-4, added by this PRD to make the OPEN-Q1 `id_format` resolution
verifiable; it is traced to KATA-T038 in §12).

## 2. Executive Summary

Foreman already drives work off an external task tracker through the
`ForemanServer.TaskProvider` behaviour, with Beads (`br`) as the only provider shipped
today. This PRD specifies a second provider that speaks to **Kata** (`kenn.io/kata`),
the Rust task daemon, over its **CLI only**. Operators onboarding a Kata-backed repo get
the same Foreman guarantees they get with Beads — per-project binding, capability
declaration, claim-before-dispatch, idempotent terminal transitions, typed error
envelopes, bounded subprocess concurrency, and no leakage of sensitive fields through
logs, telemetry, or error context — without Foreman growing a second task-tracking
brain.

The product rule that shapes everything: **Kata is authoritative for task and claim
state.** Foreman reads, claims, closes, and annotates through Kata's CLI, and nothing
else. It does not open Kata's database, does not run a parallel lease layer, and does
not scan Kata for orphans. Where Beads needed a reconciling janitor, Kata needs an
operator running `kata unassign`.

Scope: 17 requirements, 57 acceptance criteria, delivered as a five-PR stack that
lands the adapter foundation, hardens its boundaries, errors, concurrency and
per-project binding, closes the lifecycle, adds observability and the generic doctor,
and finishes with end-to-end verification and documentation.

## 3. Background & Context

**Current state.** The task-provider subsystem (PRD-2026-d99cd90d, shipped) defines
`ForemanServer.TaskProvider` with **13 callbacks** — three metadata (`name/0`,
`capabilities/0`, `available?/0`) and ten operational (`create/2`, `list_ready/2`,
`get/2`, `claim/3`, `complete/3`, `fail/3`, `reopen/3`, `set_priority/3`,
`add_dependency/3`, `annotate/3`). `TaskProvider.Registry` validates every module
against `TaskProvider.behaviour_info(:callbacks)` — all 13 are mandatory; a module
missing one is rejected with `:invalid_module` and never enters the routing snapshot.
`BeadsAdapter` is the reference implementation: argv-only `System.cmd` invocation, a
closed error vocabulary mapped through `BeadsAdapter.CodeMap`, an orphan janitor, and a
`foreman doctor task_provider` probe.

**Why now.** Kata is a faster, daemon-backed tracker with first-class JSON output and
atomic claim semantics that make several Beads workarounds unnecessary. It is already
the tracker of record for the ensemble repository, and Foreman's Kata-using repos
currently cannot be driven by Foreman at all. The Beads interface proved the
provider boundary holds; this PRD exercises it with a second implementation, which is
also the cheapest real test that the boundary is provider-agnostic.

**Relationship to existing PRDs.** This PRD **extends** PRD-2026-d99cd90d (Beads as
primary task interface); it does not replace, deprecate, or change any Beads
behavior. Beads remains fully supported and remains the default provider. Where this
PRD says "mirror Beads", it means reuse the Beads mechanism (runner discipline,
CodeMap error mapping, error envelope), not reimplement it.

**Relevant prior art.**
- PRD-2026-d99cd90d — Beads primary task interface: provider behaviour, registry,
  error envelope, sensitive-field policy. Directly depended on.
- PRD-2026-48f7b420 — original task-provider behaviour extraction (13-callback
  contract, registry routing).
- Ensemble PRD-2026-6995dc96 (Configurable Tasks Backend — Kata) — the consumer-side
  mirror of this integration; useful as precedent for Kata CLI surface assumptions.

## 4. Personas & Users

| Persona | Description | Goals | Frustrations Today |
|---|---|---|---|
| **Ops operator (Kata repo)** | Runs Foreman over a repo whose tracker is Kata | Onboard the repo with one command; see health in `foreman doctor` | Foreman cannot drive Kata work; must keep two trackers or hand-migrate to Beads |
| **Automation developer** | Writes/maintains provider adapters | Add a provider by implementing one behaviour, no core changes | Beads-specific assumptions (database path, JSON-schema cache) are entangled with shared plumbing |
| **Phase executor (system actor)** | `RunExecutor`/Jobsite engine claiming tasks before dispatch | Claim atomically, never double-dispatch, close exactly once | None Kata-specific yet; risk of inheriting Beads' lease-compensation complexity |
| **Security reviewer** | Audits what escapes Foreman logs/telemetry/errors | Prove assignee/body never appear outside the provider | Must re-audit the policy per adapter |

Primary persona: **Ops operator (Kata repo)**. Secondary: **Automation developer**.
When tradeoffs arise, optimize for the operator's ability to onboard and diagnose a
Kata project without Foreman ever disagreeing with Kata.

## 5. Goals & Non-Goals

### Goals
1. Foreman can dispatch, claim, complete, and annotate Kata-tracked work through the
   same pipeline it uses for Beads.
2. Kata task and claim state is never second-guessed, mirrored, or scanned by Foreman.
3. A Kata project is onboardable, diagnosable, and reversible by one operator in under
   five minutes.
4. Adding a provider stays a `task_providers/`-local change; shared plumbing stays
   provider-generic.

### Non-Goals
- Bidirectional sync or Foreman-as-source-of-truth over Kata.
- A Kata daemon/process manager (Foreman never starts, stops, or supervises the Kata
  daemon).
- A generic plugin/entry-point discovery mechanism for third-party providers.
- Changing or removing any Beads behavior, including the orphan janitor.
- A hard version gate on the accepted range (accepted-range drift is warn-only; a
  missing or unusable `kata` binary is a hard failure — see AC-002-3).
- Kata federation / hub integration — Foreman talks to one Kata instance per project.
- The Postgres (`KATA_DSN`) Kata storage backend — the CLI is the only contract.
- Kata semantic search or the Kata MCP server — neither is a task-tracking surface.
- GitHub sync and `kata import` migration paths — Foreman neither imports into nor exports from Kata.


## 6. Requirements

### Explicit Won't

- **Won't: Foreman-side orphan reconciliation for Kata.** No scanner, janitor,
  scheduled sweep, or `[:reconcile, :*]` telemetry. Stale claims are reclaimed by the
  operator with `kata unassign <ref>`.
  (Beads keeps its janitor; this asymmetry is deliberate — Kata holds claim state
  server-side.)
- **Won't: a parallel Foreman lease layer for Kata.** Foreman's run-level lease does
  not gate Kata dispatch; the atomic claim **is** `kata claim`. Two Foreman instances
  may both *read* a task; only one may claim it.
- **Won't: Kata over anything but its CLI.** No gRPC/daemon client, no reading
  `~/.kata/*.db`, no importing Kata's Rust types. The Kata daemon protocol is internal
  and unstable; the CLI is its stable surface.
- **Won't: new Foreman error codes for Kata.** Kata failures map into the existing
  Beads-vocabulary error set (including `BR_ERROR_ENVELOPE` as the unknown-code
  fallback); no `KATA_*` atoms are minted.
- **Won't: global Kata configuration.** No `KATA_HOME`-style app-level env override in
  Foreman config; binding is per project.
- **Won't: a hard Kata version gate on the accepted range.** A Kata version that
  reports successfully but sits outside `accepted_kata_versions` warns in
  `foreman doctor` and calls proceed; it is not a hard block. A version *floor*
  (the minimum supported Kata release) is a separate capability-refresh concern:
  `accepted_kata_versions` is a list of Elixir version requirement strings such as
  `">= 0.19.0"`, per §11 "Resolved Decisions".

### Concerns Raised During Elicitation

- **CONCERN 1 — CLI only.** *Raised by: Automation developer.* Kata's daemon transport
  is internal and version-unstable. **Impact on requirements:** REQ-001 pins the CLI as
  the sole transport; REQ-004 makes the single invocation site architecturally
  enforceable.
- **CONCERN 4 — No parallel Foreman lease layer.** *Raised by: Phase executor (system
  actor).* A Foreman-side lease on top of `kata claim` would create two sources of
  truth for one mutex and re-introduce Beads' compensation logic. **Impact:** REQ-011
  makes `kata claim` the pre-dispatch gate and the only claim; REQ-013 defines the
  idempotent guards that replace compensation.
- **CONCERN 8 — Foreman does NOT scan Kata for orphans.** *Raised by: Ops operator.*
  Scanning requires enumerating claimed/in-progress state Foreman doesn't own, and a
  wrong sweep frees another operator's live claim. **Impact:** REQ-014 forbids scanner
  invocations and `[:reconcile, :*]` telemetry; the operator triages manually with
  `kata list --status all`, `kata status <ref>` and `kata unassign`; Explicit Won't records it.
- **CONCERN 12 — No new error atoms; operator visibility via the command.** *Raised by:
  Security reviewer / Ops operator.* A Kata-specific error vocabulary fragments
  downstream handling and multiplies redaction surface. **Impact:** REQ-007 reuses
  `BeadsAdapter.CodeMap`; the `command` context key carries `binary: "kata"` so
  operators can still tell which CLI failed.
- **CONCERN 15 — Sensitive side-channels.** *Raised by: Security reviewer.* Task bodies
  and assignees reach Foreman verbatim via stdout; any log, telemetry, or error-context
  path becomes an exfiltration route. **Impact:** REQ-015 classifies the fields;
  REQ-017 makes the adapter silent-by-default with a closed context allowlist.

### Constitution Gate

Checked against `docs/standards/constitution.md`; no requirement in this PRD violates a
binding rule.

|Constitution rule|Effect on this PRD|
|---|---|
|TDD: no feature starts without a failing test; none completes until tests pass|Every REQ carries ExUnit acceptance criteria, and the TRD sequences RED tests ahead of implementation in each story.|
|Event-sourced orchestration invariant: events are the source of truth; projections, the run loop, and recovery logic reconcile only from events|REQ-014 keeps Kata out of the event stream: no orphan sweep, no `[:reconcile, :*]` telemetry, so nothing reconciles Kata state from a projection or a read model.|
|New event, command, aggregate, and projection names (`*Event`, `*Command`, `*Aggregate`, `*Projection`)|Not triggered — this PRD adds a `TaskProvider` implementation and no new aggregates, commands, events, or projections (REQ-014, Explicit Won't).|
|Input validation at every external boundary|REQ-006 validates the CLI's stdout shape before use; REQ-008 validates argv against a fixed schema; REQ-015 classifies returned fields.|
|No secrets in code; secrets never rendered|REQ-015 and REQ-017 keep task bodies and assignees off logs, telemetry metadata, and error context; the account token is read from configuration, never embedded in a command string (AC-008-4).|
|Go CLI boundary: CLI sends commands and queries only, never touching the event or projection store|Not triggered — Kata integration is server-side Elixir calling an external binary; `packages/foreman_cli` is unchanged.|
|Quality gate: documentation updated before finalization|REQ-016 requires the `foreman doctor` line and its operator-facing documentation; the repo documentation gate in `AGENTS.md` applies to every PR in the TRD's PR stack.|
|UI rules (LiveView dashboard)|Not triggered — this feature ships no dashboard surface; operators see it only through `foreman doctor` and structured logs.|


### Must Have

---

#### REQ-001: KataAdapter implements the TaskProvider behaviour via the kata CLI

**Priority:** Must | **ASSPIRE:** Achievable, Specific, Integrated, Resilient, Extensible | **Conflict:** None | **Complexity:** Medium
**Citable:** Yes (CLI, provider id, contract version are operator-visible) | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** Kata CLI flag surface may drift between releases (TRD §8 verification tasks)

`ForemanServer.TaskProviders.KataAdapter` implements all 13 `ForemanServer.TaskProvider`
callbacks and reaches Kata exclusively by invoking the `kata` binary. It is registered
in the provider registry under provider id `:kata` with contract version
`"kata.capabilities.v1"`, which is added to the `:foreman_server, :task_provider`
config's `accepted_contract_versions` list.

**Acceptance Criteria:**

- AC-001-1: A module `ForemanServer.TaskProviders.KataAdapter` exists, exports all 13 `TaskProvider` callbacks, and passes the registry's `behaviour_info(:callbacks)` validation without any registry exemption.
- AC-001-2: `name/0` returns a human-readable provider name; `capabilities/0[:provider_id]` returns `:kata`; `contract_version` is `"kata.capabilities.v1"`; that version string is present in the `:foreman_server, :task_provider` config's `accepted_contract_versions` list so startup registration succeeds.
- AC-001-3: Every Kata read in the adapter goes through the runner; no code path in the adapter opens a Kata database file, speaks a daemon protocol, or shells out to any binary other than `kata`.

**Dependencies:** None (builds on shipped behaviour contract PRD-2026-48f7b420)
**Feature Stories:** As an automation developer, I want Kata behind the existing behaviour so the dispatch pipeline treats it like any other provider.
**Test Strategy:** Unit (callback presence via `behaviour_info` reflection; `name/0`/`capabilities/0` shape); static architecture check (REQ-004).

---

#### REQ-002: Kata capability declaration

**Priority:** Must | **ASSPIRE:** Accurate, Specific, Resilient, Transparent | **Conflict:** None | **Complexity:** Low
**Citable:** Yes | **Status:** Draft | **Risk Level:** Low | **Risk Factors:** None

`KataAdapter.capabilities/0` declares what Kata genuinely supports, using the same
capability vocabulary as Beads so the registry and consumers stay provider-generic.
The declaration carries `provider_id`, `contract_version`, `id_format`,
`storage_scheme`, and a `supports` list naming every Kata-supported operation:
`create`, `claim`, `close`, `reopen`, `annotate`, `set_priority`, `set_assignee`,
`list_dependencies`, `add_dependency`, `remove_dependency`.

`storage_scheme` is a closed set: `:sqlite` (providers backed by a database file —
Beads — routed and preflighted by `config.database_path`) or `:cli_process` (providers
that shell out to a CLI resolving its own storage — Kata — routed and preflighted by
`config.cwd`). The registry's capability validation rejects any other value, so
routing, preflight and `foreman doctor` key on this field instead of on a provider.
`id_format` is `"^[a-z0-9]+$"`. Kata's published reference states a `short_id` is
"the lowercased suffix of the ULID, extended if needed to avoid collisions", so it is
lowercase alphanumeric of **variable** length; the reference's only short-id examples
are `abc4` and the qualified form `kata#abc4`, and a full ref is the 26-character
ULID. A collision-extended suffix such as `4abc` or `a1b2` is therefore legal, and the
TRD's provisional default `^[a-z]+[0-9]+$` (letters then digits only) would reject it,
so this PRD fixes the broader pattern; KATA-T038 confirms it against the published
format and updates the capability map, Foreman's parser, and tests together if Kata
documents anything narrower.

**Acceptance Criteria:**

- AC-002-1: `capabilities/0` returns a map with `provider_id: :kata`, `contract_version: "kata.capabilities.v1"`, a non-empty `supports` list covering all supported operations, and `storage_scheme: :cli_process`.
- AC-002-2: The map satisfies the same registry capability validation that Beads' map satisfies, with no Kata-specific exception in the registry.
- AC-002-3: `available?/0` returns `false` — without raising — when `kata` is not findable on `PATH` **or** when `kata --version` exits non-zero (a broken or unusable binary); it returns `true` only when the binary is found and the version probe succeeds. A version that reports successfully but sits outside the accepted range does NOT make `available?/0` false: range drift is a `foreman doctor` warning (REQ-016) and calls still proceed.
- AC-002-4: `capabilities/0`'s `id_format` is `"^[a-z0-9]+$"`, and the adapter's ref parser accepts `abc4`, `4abc`, `a1b2`, and a 26-character full ULID, while rejecting an empty string, uppercase input, and any string containing a character outside `[a-z0-9]`.

**Dependencies:** REQ-001
**Constraints (not ordering edges):** REQ-010's capability validation tightening must not reject a valid Kata map.
**Feature Stories:** As an automation developer, I want one capability shape for all
providers so consumers never special-case Kata.
**Test Strategy:** Unit (exact map contents); registry integration (accepted at startup).

---

#### REQ-003: Per-project Kata binding

**Priority:** Must | **ASSPIRE:** Achievable, Specific, Integrated, Maintainable | **Conflict:** None | **Complexity:** Medium
**Citable:** Yes (project config keys are operator-visible) | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** Kata has no database-path analogue, so project config and CLI preflight paths must be kept coherent deliberately, not by copy-pasting Beads plumbing

A Kata project binds to its tracker by **working directory** only:
`task_provider.config.cwd` (absolute path). Kata resolves the project itself from that
directory (`.kata.toml`, then any user-level Kata config the operator manages outside
Foreman). There is **no** `database_path` for Kata, no global Kata home override in
Foreman config, and Kata does **not** participate in the JSON-schema-cache path
(Kata exposes no schema-fetch analogue, so the Kata adapter declares no schema
dependency and the cache is never consulted for a Kata project).

**Acceptance Criteria:**

- AC-003-1: A project whose `task_provider` is `kata` with a valid absolute `cwd` routes to `KataAdapter`; every CLI invocation it produces runs with that `cwd` as the working directory.
- AC-003-2: A Kata project's config is validated without any `database_path` requirement: no code path demands or invents one, and registry routing does not fail a Kata project for its absence.
- AC-003-3: Two projects bound to different `cwd` values never share adapter state: listing/getting for project A never observes tasks from project B's Kata project.
- AC-003-4: A project may switch between `beads` and `kata` (and back) without losing Foreman run history; the provider choice is data, not a fork in the dispatch path.

**Dependencies:** REQ-001, REQ-002
**Constraints (not ordering edges):** REQ-010 makes the registry's database-path coupling provider-generic; Kata routing consumes that change (TRD KATA-T053).
**Feature Stories:** As an ops operator, I want `foreman project create <path>
--task-provider kata` to just work, because Kata already knows what `<path>` is.
**Test Strategy:** Integration (two-project fixture with fake runner asserting `cd`
on every call); unit (config validation).

---

#### REQ-004: Architecture test enforces adapter boundaries

**Priority:** Must | **ASSPIRE:** Integrated, Resilient, Extensible, Transparent | **Conflict:** None | **Complexity:** Low
**Citable:** No (developer-facing guard) | **Status:** Draft | **Risk Level:** Low | **Risk Factors:** None

A test in the repository's static-analysis test family scans source text and fails the
build when the Kata adapter's invariants are violated, so the boundary survives
future contributors.

**Acceptance Criteria:**

- AC-004-1: The test fails if any `System.cmd` invocation of `kata` exists outside the single runner module; exactly one allowed invocation site is declared, mirroring the Beads runner rule.
- AC-004-2: The test fails if any module outside `task_providers/` aliases or calls `KataAdapter` directly; consumers go through the registry only.
- AC-004-3: The test fails if any code path invokes Kata as an orphan scanner (e.g. listing by claimed/in-progress status for reconciliation purposes), enforcing REQ-014 mechanically.

**Dependencies:** REQ-001 (adapter exists to be scanned)
**Feature Stories:** As an automation developer, I want CI to reject boundary
violations at review time, not in production.
**Test Strategy:** The architecture test is itself the deliverable; validate it fails
on injected violations.


---

#### REQ-005: KataAdapter implements the full operational callback set

**Priority:** Must | **ASSPIRE:** Achievable, Specific, Integrated, Resilient | **Conflict:** None | **Complexity:** High
**Citable:** No (internal behaviour) | **Status:** Draft | **Risk Level:** High | **Risk Factors:** Ten operational callbacks each need a Kata CLI equivalent; a partial implementation blocks registry validation (REQ-001-1)

`KataAdapter` implements every operational callback of the `TaskProvider` behaviour
with a real Kata CLI invocation: `create/2`, `list_ready/2`, `get/2`, `claim/3`,
`complete/3`, `fail/3`, `reopen/3`, `set_priority/3`, `add_dependency/3`, and
`annotate/3`. No callback is stubbed, and no callback returns a canned value.

> **Callback-count note.** The behaviour declares 13 callbacks in total; ten are
> operational (the list above) and three are metadata/lifecycle
> (`name/0`, `capabilities/0`, `available?/0`), covered by REQ-001 and REQ-002. An
> earlier TRD draft said "all 11 callbacks"; the TRD now says 13 and the
> discrepancy is closed. The normative contract is
> `ForemanServer.TaskProvider` as it exists on the branch under test — REQ-001-1
> checks it by reflection, so a stale count cannot slip through.

**Acceptance Criteria:**

- AC-005-1: `list_ready/2` returns the ready (unclaimed, dependency-satisfied) Kata tasks as `TaskProvider.Issue` structs; `get/2` returns one task by Kata reference; both accept a project config and honor it as the working directory.
- AC-005-2: `claim/3` issues exactly one atomic Kata claim operation for the given reference and returns the claimed task.
- AC-005-3: `complete/3` closes the task in Kata with the run's completion message, the produced commit SHA, and evidence when available.
- AC-005-4: `fail/3` reopens the task in Kata, records the failure reason as a comment, and then releases Foreman's own claim so the task is claimable again; when a different actor owns the task it writes nothing and returns a typed error; it never fabricates a close-with-reason to simulate failure.
- AC-005-5: `reopen/3`, `set_priority/3`, `add_dependency/3`, and `annotate/3` each perform the corresponding Kata operation and return success only when Kata reports success.
- AC-005-6: `create/2` creates a Kata task from the supplied attributes and returns the created task.

**Dependencies:** REQ-001, REQ-003, REQ-004
**Constraints (not ordering edges):** REQ-002's capability declaration is built in the same slice and must agree with these callbacks.
**Feature Stories:** As a phase executor, I want every lifecycle operation backed by a
real Kata call so dispatch, completion, and failure behave identically to Beads.
**Test Strategy:** Unit with a mocked runner per callback (argv asserted, result
mapped); integration for the lifecycle trio.

---

#### REQ-006: Structured output parsing with field-mapping validation

**Priority:** Must | **ASSPIRE:** Specific, Accurate, Resilient, Transparent | **Conflict:** None | **Complexity:** Medium
**Citable:** No | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** Kata's JSON shape is not Foreman's; a silent mapping gap produces wrong state rather than an error

The adapter parses Kata's JSON output into the normalized `TaskProvider.Issue`
record, mapping Kata fields onto the Foreman contract's first-class fields and
placing Kata-specific fields under `metadata`. Missing or malformed required fields
are rejected with a typed validation error, never defaulted.

**Acceptance Criteria:**

- AC-006-1: `get/2` rejects a Kata payload missing `short_id`, `title`, or `status` with a typed schema-validation error naming the missing fields; it does not substitute placeholder values. `priority` is optional: Kata leaves it unset until an operator sets it, and an absent `priority` maps to no priority rather than an error.
- AC-006-2: The same field-mapping validation applies to every list-producing path, so a partially-malformed list yields validated records or a typed error — never a partially-populated record.
- AC-006-3: Kata-specific fields that have no first-class Foreman equivalent (for example `uid`, `author`, `revision`, `qualified_id`, `web_url` and the timestamps) are preserved under the issue's `metadata`, and the Foreman fields are filled from Kata's real keys: `id` from `short_id`, `description` from `body`, `assignee` from `owner` (present only while the issue is claimed), `labels` and `dependencies` from `show`'s `labels` and `links`; a Foreman field Kata does not emit (`notes`, `design`) stays empty rather than being invented.

**Dependencies:** REQ-005
**Constraints (not ordering edges):** validation failures are reported through REQ-007's error envelope.
**Feature Stories:** As an automation developer, I want one mapping discipline so a
Kata payload change fails loudly at the boundary instead of producing wrong task
state.
**Test Strategy:** Unit with fixture payloads (complete, missing-field, extra-field,
wrong-type).

---

#### REQ-007: Provider error envelope reusing the Beads code map

**Priority:** Must | **ASSPIRE:** Consistent, Specific, Resilient, Transparent | **Conflict:** None | **Complexity:** High
**Citable:** Yes (error codes are consumed downstream) | **Status:** Draft | **Risk Level:** High | **Risk Factors:** Kata's error surface differs from Beads'; an unmapped code must degrade to the generic envelope, not crash

Kata failures are surfaced as `ForemanServer.TaskProviders.ProviderError` with the
**existing** error vocabulary. The adapter reuses `BeadsAdapter.CodeMap` as the single
mapping source and introduces **no new error codes** for Kata. The `command` context
key carries `binary: "kata"` so an operator reading the error can tell which CLI
failed.

**Acceptance Criteria:**

- AC-007-1: A Kata failure that matches a known code maps to that code with its existing retryable flag (AC-013-2 overrides it for the claimed-by-other code); the mapping is read from `BeadsAdapter.CodeMap`, not duplicated, while `redacted_fields` is always the Kata-sensitive list of AC-015-1.
- AC-007-2: A Kata failure with an unrecognized code maps to the generic envelope code; the adapter never raises, never returns a raw string, and never mints a provider-specific code.
- AC-007-3: Every `ProviderError` produced by the adapter carries `command.binary: "kata"` in its context, together with the run's identifier, exit code, and stderr byte count — never the stderr text.
- AC-007-4: A single construction site builds provider errors for the Kata adapter, and that site is the only place a `ProviderError` struct is created for Kata.

**Dependencies:** REQ-006
**Constraints (not ordering edges):** REQ-017's redaction rules govern the error context this envelope carries.
**Feature Stories:** As an operator, I want Kata errors to read like every other
Foreman provider error, so my runbooks do not fork by provider.
**Test Strategy:** Unit per mapped code, per unknown code, and for the context shape.

---

#### REQ-008: CLI process safety

**Priority:** Must | **ASSPIRE:** Resilient, Specific, Transparent | **Conflict:** None | **Complexity:** Medium
**Citable:** No | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** A hung `kata` process would block the dispatch pipeline indefinitely

Kata CLI invocations run under the same process discipline as Beads invocations:
arguments are passed as an argv (never interpolated into a shell string), the child
process is bounded by a timeout, and a timed-out child is terminated and its temporary
artifacts removed.

**Acceptance Criteria:**

- AC-008-1: Arguments reach the CLI as discrete argv elements with no shell interpolation, so a task title containing shell metacharacters cannot alter the command.
- AC-008-2: A CLI call that exceeds the configured timeout is terminated (grace period first, then forced kill), and the caller receives a typed retryable timeout error.
- AC-008-3: Temporary files created to capture CLI output are removed on both the success and the failure path.
- AC-008-4: The adapter surfaces the OS process id of the child it spawned for diagnosis, without exposing the child's output text beyond the redaction policy.

**Dependencies:** REQ-005
**Constraints (not ordering edges):** timeout and signal failures surface as REQ-007 envelopes.
**Feature Stories:** As an operator, I want a wedged Kata call to fail fast and
cleanly instead of stalling a Foreman run.
**Test Strategy:** Unit (argv shape, timeout escalation, temp cleanup); the runner
test exercises the signal path.

---

### Should Have

---

#### REQ-009: Bounded concurrency for CLI invocations

**Priority:** Should | **ASSPIRE:** Resilient, Specific, Maintainable | **Conflict:** None | **Complexity:** Medium
**Citable:** No | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** A shared limiter across providers couples Kata throughput to Beads load if misconfigured

Every Kata CLI invocation passes through the provider concurrency limiter, with a
bounded number of in-flight Kata calls and a bounded wait for a slot.

**Acceptance Criteria:**

- AC-009-1: At most four Kata CLI calls per project are in flight at once; a fifth caller for the same project waits for a slot rather than starting a fifth child process.
- AC-009-2: A caller that cannot obtain a slot within the queue timeout receives a typed, retryable queue-timeout error instead of blocking indefinitely; slots are released on both success and failure.

**Dependencies:** REQ-008
**Feature Stories:** As an ops operator, I want Foreman to put a ceiling on Kata
subprocess churn so a large ready-set cannot stampede the daemon.
**Test Strategy:** Unit (slot accounting, queue timeout, slot release on error).

---

#### REQ-010: Generic registry capability validation, with Beads cleanup

**Priority:** Should | **ASSPIRE:** Consistent, Transparent, Extensible, Specific | **Conflict:** None | **Complexity:** Medium
**Citable:** No (internal) | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** Tightening validation can reject the existing Beads adapter; the audit must land in the same change

The provider registry validates every registered provider's capability declaration
against one provider-generic contract — required keys, value types, and a
well-formedness check — so a malformed declaration is rejected and logged instead of
entering the routing snapshot. Any Beads-side fix required to pass the tightened
validation ships in the same change; no Beads behavior changes beyond what the
tightening demands.

**Acceptance Criteria:**

- AC-010-1: The registry validates a provider's capability map against required keys and value types; an invalid map is excluded from the routing snapshot and logged with a distinguishable provider-scoped telemetry event.
- AC-010-2: Both the Beads adapter and the Kata adapter pass the tightened validation unchanged in observable behavior — no Kata-specific branch, exemption, or special case exists in the registry.
- AC-010-3: The Beads adapter's declaration is audited against the tightened rules and corrected where needed, with the existing Beads test suite still green.

**Dependencies:** REQ-001, REQ-002 (Kata declaration must satisfy the contract)
**Feature Stories:** As an automation developer, I want one capability contract so a
future third provider is validated by the same rules.
**Test Strategy:** Unit (invalid map rejected and logged); regression (full Beads
adapter suite green).


---

### Must Have (continued — lifecycle)

---

#### REQ-011: Pre-dispatch atomic claim

**Priority:** Must | **ASSPIRE:** Specific, Integrated, Resilient, Transparent | **Conflict:** None | **Complexity:** High
**Citable:** No | **Status:** Draft | **Risk Level:** High | **Risk Factors:** Claim-loss handling must not silently re-dispatch work another actor holds

Before dispatching work, Foreman claims the task through Kata's atomic claim
operation. A task that can no longer be claimed is **not** dispatched; the dispatch set
is refreshed once, and if the task is still not claimable it is dropped from the
dispatch set with a distinguishable telemetry event. Foreman maintains no additional
lease over Kata tasks — the Kata claim is the gate.

**Acceptance Criteria:**

- AC-011-1: No task is dispatched to an agent unless Foreman first received a successful claim response from Kata for that task.
- AC-011-2: When the claim is refused because another actor holds the task, Foreman refreshes its ready set once and retries the claim; it does not loop.
- AC-011-3: When the task is still not claimable after that refresh, it is dropped from the dispatch set and a distinguishable provider-scoped telemetry event records the claim loss.

**Dependencies:** REQ-005, REQ-009
**Constraints (not ordering edges):** claim-refusal errors are mapped through REQ-007's envelope.
**Feature Stories:** As a phase executor, I want to dispatch only work Kata has
handed me, so two Foreman instances never run the same task.
**Test Strategy:** Unit (claim-before-dispatch ordering, one-shot refresh, drop with
telemetry); integration (concurrent claimers, one winner).

---

#### REQ-012: Post-execution close

**Priority:** Must | **ASSPIRE:** Specific, Accurate, Resilient, Transparent | **Conflict:** None | **Complexity:** Medium
**Citable:** No | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** Closing on the failure path would report work as done

When a task's execution completes, Foreman closes it in Kata with the completion
message, the commit SHA produced by the run, and the run's evidence when available. When
the task's execution fails, Foreman **reopens** it in Kata, records the failure
reason as a comment, and releases its own claim so the task is open, unowned and claimable again — a failed task is never reported as closed.

**Acceptance Criteria:**

- AC-012-1: On successful execution, the task is closed in Kata carrying the run's completion message and typed evidence: the commit SHA when the run produced one, otherwise the run's artifact path as reviewed-paths evidence when that file exists (Kata refuses a `--done` close that carries none, and a path to a report the run never wrote would be a false completion claim).
- AC-012-2: On failed execution, the task is reopened in Kata, the failure reason is recorded as a comment on that task, and Foreman's own claim is released so the task is open, unowned and claimable again; the task is not closed, and a task owned by a different actor is left untouched.
- AC-012-3: The completion message identifies the Foreman run that produced it (run identifier and artifact path) when the caller supplies no message of its own, and is at least 40 characters — Kata's minimum for `kata close --done` — so the generated default is never rejected for length.
- AC-012-4: When Kata refuses the close, the refusal is surfaced as a typed provider error and the run does not report the task as successfully closed.

**Dependencies:** REQ-011, REQ-007
**Feature Stories:** As an ops operator, I want Kata to reflect exactly what happened
in the Foreman run, so my tracker is trustworthy without reading run logs.
**Test Strategy:** Unit (close argv on success; reopen + comment + unassign argv on failure;
refusal mapping).

---

#### REQ-013: Idempotent transition guards

**Priority:** Must | **ASSPIRE:** Resilient, Specific, Consistent | **Conflict:** None | **Complexity:** Medium
**Citable:** No | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** Distinguishing "already done" from "genuinely failed" depends on Kata's error surface

Repeating a terminal transition is not an error. Closing a task that Kata already
reports as terminal returns an explicit "already terminal" success; claiming a task
held by another actor returns the existing claimed-by-other error with a
retryable=false flag, and the error context carries only whether an assignee is
present — never the assignee's identity.

**Acceptance Criteria:**

- AC-013-1: When Kata reports a task as already terminal, closing it returns an explicit already-terminal success rather than a failure.
- AC-013-2: When Kata reports a task as claimed by another actor, the returned error carries the existing claimed-by-other code with `retryable?: false`, and its context carries no owner identity — no name, no id and no presence flag — only the allowlisted keys of AC-017-4.

**Dependencies:** REQ-012
**Constraints (not ordering edges):** the already-terminal and claimed-by-other results use REQ-007's error envelope.
**Feature Stories:** As a phase executor, I want a retried close to be a no-op
success so a network hiccup does not fail an otherwise complete run.
**Test Strategy:** Unit (already-terminal path; claimed-by-other path with context
assertion).

---

#### REQ-014: Kata is authoritative for claims — operator triage only

**Priority:** Must | **ASSPIRE:** Specific, Consistent, Transparent, Integrated | **Conflict:** None | **Complexity:** Medium
**Citable:** Yes (operator-facing triage workflow) | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** A future contributor could add a scanner believing it is a robustness fix

Foreman never enumerates Kata's claimed or in-progress tasks to reconcile them, never
runs a Kata-side janitor or sweep, and emits no reconciliation telemetry for Kata. A
task stranded in a claimed state is reclaimed by the operator using Kata's own
commands (`kata list --status all` plus `kata status <ref>`, `kata unassign <ref>`). The asymmetry
with Beads (which keeps its janitor) is deliberate: Kata holds claim state
server-side, so a Foreman-side sweep could free another operator's live claim.

**Acceptance Criteria:**

- AC-014-1: On `TaskExecutionFailed`, `KataAdapter.fail/3` first reads the task's effective actor and current owner with `kata status <ref> --json`; if a different actor owns the task it writes nothing to it and returns a typed `CLAIMED_BY_OTHER` provider error. Otherwise it invokes `kata reopen <ref>`, then `kata comment <ref> --body "<reason>"` under an idempotency key derived from the run id and the comment text (a retried notification never duplicates the comment, and a differently worded comment is never refused), then, unless the task is already unowned, `kata unassign <ref> --expect-owner <actor>`; returns `{:ok, :reopened}`. A release refused because ownership changed in the meantime surfaces the same typed error. This is the Foreman-side failure-path release only (Kata owns crash reconciliation; a run that dies mid-flight is reclaimed by the operator).
- AC-014-2: No code path under `lib/foreman_server/task_providers/` scans Kata for claimed, in-progress or orphaned work (any `kata list`/`kata status`/`kata audit`-based sweep); the single-reference `kata status <ref> --json` lookup of the effective actor inside `fail/3` is not a sweep; `list_ready/2` carries an explicit comment: "Kata is authoritative for claim state — Foreman does NOT scan for orphans."
- AC-014-3: The architecture test fails the build if it finds such a claim-state sweep under `lib/foreman_server/task_providers/`; the Kata provider emits no `[:reconcile, :*]` telemetry events.

**Dependencies:** REQ-004 (architecture test)
**Feature Stories:** As an ops operator, I want Foreman to respect Kata's ownership of
claim state, so it can never free a claim another operator is still working.
**Test Strategy:** Architecture test (no scanner invocation); integration test
(`kata reopen`, `kata comment` and `kata unassign` on failure path; the issue ends open and unowned).

---

### Should Have (continued)

---

#### REQ-015: Sensitive field classification

**Priority:** Should | **ASSPIRE:** Specific, Secure, Consistent, Transparent | **Conflict:** None | **Complexity:** Low
**Citable:** No | **Status:** Draft | **Risk Level:** Medium | **Risk Factors:** Kata may add fields later; the classification must be stated as a rule, not a fixed list

Foreman classifies Kata's `assignee` and task body/description as sensitive. The
classification is stated as a rule that extends to newly added Kata fields by default,
so a future Kata field is sensitive unless explicitly declared otherwise.

**Acceptance Criteria:**

- AC-015-1: `assignee` and the task body/description are classified as sensitive fields for the Kata provider, and the provider-error context carries them as the literal list `redacted_fields: ["assignee", "description"]`.
- AC-015-2: A Kata field not present in the Foreman issue contract is treated as sensitive by default: it appears in no log line, telemetry metadata or error context, because only allowlisted keys may be emitted there (REQ-017); `redacted_fields` declares the known-sensitive set and is not the enforcement mechanism.

**Dependencies:** REQ-006 (classification applies to parsed fields)
**Constraints (not ordering edges):** enforced by REQ-017, which depends on this requirement.
**Feature Stories:** As a security reviewer, I want a default-sensitive rule so new
Kata fields cannot leak by omission.
**Test Strategy:** Unit (classification table).

---

#### REQ-017: Silent by default on Kata sensitive side-channels

**Priority:** Should | **ASSPIRE:** Secure, Specific, Consistent, Transparent | **Conflict:** None | **Complexity:** High
**Citable:** Yes (the error-context allowlist is consumer-visible) | **Status:** Draft | **Risk Level:** High | **Risk Factors:** Any logging call in the adapter path is an exfiltration route; stderr text is the easiest leak

The Kata adapter is silent about sensitive content in every outward channel. Sensitive
values may appear only in the domain records Foreman returns to its caller. Logs,
standard output, telemetry metadata, and provider-error context never contain a
sensitive field's value. The provider-error context allowlist is closed and explicit,
and CLI stderr is discarded except for its byte count.

**Acceptance Criteria:**

- AC-017-1: A sentinel sensitive value passed through the adapter never appears in the application log.
- AC-017-2: A sentinel sensitive value passed through the adapter never appears in standard output or standard error.
- AC-017-3: A sentinel sensitive value passed through the adapter never appears in telemetry event metadata.
- AC-017-4: The provider-error context contains only the allowlisted keys (`id`, `command`, `exit_code`, `stderr_byte_count`, `sanitized?`, `redacted_fields` and `missing_fields`); `sanitized?` is always `true`, `redacted_fields` always names the redacted fields, and `missing_fields` is an empty list except on schema-validation errors, where it names the absent required fields and never their values.
- AC-017-5: The domain record Foreman returns to its caller **does** contain the sensitive values, so the redaction does not silently destroy task content the caller needs.

**Dependencies:** REQ-007 (error envelope), REQ-015 (classification)
**Feature Stories:** As a security reviewer, I want a redaction proof with sentinel
values across every channel, so the claim is verified rather than asserted.
**Test Strategy:** Sentinel-value tests over log capture, IO capture, telemetry
handler capture, and error-context assertions.

---

### Could Have

---

#### REQ-016: `foreman doctor` Kata section

**Priority:** Could | **ASSPIRE:** Transparent, Diagnostic, Specific, Maintainable | **Conflict:** None | **Complexity:** Medium
**Citable:** Yes (operator-visible output) | **Status:** Draft | **Risk Level:** Low | **Risk Factors:** None

`foreman doctor` reports Kata project health the same way it reports Beads project
health: the configured provider and contract version, the Kata CLI version, and a
sample live read of the project's tasks. A missing binary, a non-zero exit, or an
out-of-range version is reported; a version outside the accepted range is a **warning**
and does not block task calls.

> **Surface note.** `foreman doctor` (the Go CLI, which calls the HTTP
> `DoctorController`) and `foreman doctor task_provider` (the Elixir
> `CLI.DoctorTaskProvider` probe) are **distinct** surfaces that both report on
> provider health. If both are kept, the Kata health verdict must be computed
> once in a shared provider-generic module and both surfaces render that verdict;
> duplicating the probe logic per surface is a defect. The TRD's KATA-T042 covers
> the CLI probe and KATA-T043 the controller side — both must reach the same
> shared verdict.

**Acceptance Criteria:**

- AC-016-1: The doctor report for a Kata project states the configured provider id and contract version, the `kata --version` result, and the outcome of a sample task listing against the project's working directory.
- AC-016-2: A missing Kata binary, a non-zero `kata --version` exit, or a failing sample read marks the project unhealthy with a non-sensitive diagnostic; a version that reports successfully but sits outside the accepted range is reported as a warning while the project remains healthy and calls proceed.

> **TRD divergence (recorded, not a marker).** KATA-T043 says to verify `unhealthy`
> "when `kata` is missing **or wrong version**". This PRD reads "wrong version" as
> the version probe failing (non-zero exit, per REQ-002 / AC-002-3), which is the
> `unhealthy` case above. Accepted-range drift stays a warning, because a hard
> range gate is an Explicit Won't in this PRD. If the TRD intended range drift to
> be unhealthy, REQ-016, AC-016-2, and the Explicit Won't entry must all change
> together — confirm at refine time, not in implementation.

**Dependencies:** REQ-001, REQ-002
**Constraints (not ordering edges):** consumes REQ-010's registry validation.
**Feature Stories:** As an ops operator, I want one doctor command to tell me whether
my Kata binding works and whether the installed CLI version is supported.
**Test Strategy:** Integration (doctor output for healthy, missing-binary, and
out-of-range-version cases).


---

## 7. Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---|
| REQ-001 | KataAdapter implements TaskProvider behaviour via kata CLI | Must | Medium | 3 |
| REQ-002 | Kata capability declaration | Must | Low | 4 |
| REQ-003 | Per-project Kata binding (cwd only) | Must | Medium | 4 |
| REQ-004 | Architecture test enforces adapter boundaries | Must | Low | 3 |
| REQ-005 | KataAdapter implements full operational callback set | Must | High | 6 |
| REQ-006 | Structured output parsing with field-mapping validation | Must | Medium | 3 |
| REQ-007 | Provider error envelope reusing Beads code map | Must | High | 4 |
| REQ-008 | CLI process safety | Must | Medium | 4 |
| REQ-009 | Bounded concurrency for CLI invocations | Should | Medium | 2 |
| REQ-010 | Generic registry capability validation, with Beads cleanup | Should | Medium | 3 |
| REQ-011 | Pre-dispatch atomic claim | Must | High | 3 |
| REQ-012 | Post-execution close | Must | Medium | 4 |
| REQ-013 | Idempotent transition guards | Must | Medium | 2 |
| REQ-014 | Kata is authoritative for claims — operator triage only | Must | Medium | 3 |
| REQ-015 | Sensitive field classification | Should | Low | 2 |
| REQ-016 | `foreman doctor` Kata section | Could | Medium | 2 |
| REQ-017 | Silent by default on Kata sensitive side-channels | Should | High | 5 |

---

## 8. Dependency Map

| REQ | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | – | – | Core adapter existence required for all downstream. |
| REQ-002 | REQ-001 | – | Capability map must reflect adapter. |
| REQ-003 | REQ-001, REQ-002 | – | Per-project binding relies on adapter registration. |
| REQ-004 | REQ-001 | – | Architecture test validates adapter boundaries. |
| REQ-005 | REQ-001, REQ-003, REQ-004 | – | Operational callbacks depend on behaviour contract and binding. |
| REQ-006 | REQ-005 | – | Parsing validates callback output. |
| REQ-007 | REQ-006 | – | Error envelope built on parsed payload. |
| REQ-008 | REQ-005 | – | CLI safety guards every callback. |
| REQ-009 | REQ-008 | – | Concurrency limit wraps CLI safety. |
| REQ-010 | REQ-001, REQ-002 | – | Registry validation of capabilities. |
| REQ-011 | REQ-005, REQ-009 | – | Claim must precede execution. |
| REQ-012 | REQ-011, REQ-007 | – | Close uses error envelope if failure. |
| REQ-013 | REQ-012 | – | Idempotent guard applied to close/fail paths. |
| REQ-014 | REQ-004 | – | No orphan scanner enforced by architecture test. |
| REQ-015 | REQ-006 | – | Classification works on parsed fields. |
| REQ-016 | REQ-001, REQ-002 | – | Doctor uses registry and version check. |
| REQ-017 | REQ-015, REQ-007 | – | Silent-by-default uses classification and error envelope. |

---

## 9. Success Metrics (Readiness Scorecard)

| Metric | Target | Measurement |
|---|---|---|
| Requirement coverage | 100 % (57 ACs) | All AC tests must pass. |
| Health summary risk flags | 0 % (no high-risk failures) | All flagged REQs must have passing tests. |
| Concurrency limit adherence | ≤4 concurrent kata CLI processes | `kata_concurrency_test.exs` asserts limit. |
| Doctor health status | Healthy for a valid kata binary; warnings only for version drift | `doctor_task_provider_test.exs` (Kata cases). |
| Sensitive-field exfiltration | None detected | `kata_side_channel_test.exs` sentinel capture. |
| Idempotent close success | 100 % of retry scenarios succeed as no-ops | `kata_lifecycle_test.exs`. |
| Registry validation | 100 % of providers pass capability schema | `kata_registry_tightening_test.exs`. |

---

## 10. Risks & Mitigations

| REQ | Risk Description | Mitigation |
|---|---|---|
| REQ-001 | CLI flag drift may break `System.cmd("kata", …)` calls. | Pin kata version via `accepted_kata_versions` config; version-drift reported as a warning. |
| REQ-003 | Copy-paste of per-project config could introduce a stray `database_path` reference on the Kata path. | No Kata code path references `database_path` (the Beads path keeps it, selected by `storage_scheme: :sqlite`); a unit test asserts Kata config validation neither requires nor invents it. |
| REQ-005 | Missing callback implementation would break registry validation. | Architecture test (`kata_architecture_test.exs`) fails on any missing callback. |
| REQ-007 | Incorrect mapping to Beads `CodeMap` could expose unknown error codes. | Unit test checks every mapped code appears in `BeadsAdapter.CodeMap` and unknown codes default to envelope. |
| REQ-008 | CLI timeout may be too short for long-running kata commands. | Timeout set to 30 s (configurable); test verifies long-running command aborts cleanly. |
| REQ-009 | Unlimited concurrency could overload the host. | Concurrency limiter enforces max 4; test verifies 5th caller blocks and receives `BR_TIMEOUT_QUEUE`. |
| REQ-011 | Claim loss race could cause duplicate work. | Pre-dispatch claim check and one-shot refresh; test with two parallel claimers. |
| REQ-013 | Idempotent close may mask genuine failure. | Guard that non-terminal state returns explicit `already_terminal` success; test both paths. |
| REQ-015 | Mis-classification of a new Kata field as non-sensitive could leak data. | Default-sensitive rule applies to any unmapped field; unit test with synthetic field. |
| REQ-017 | Logging accidental sensitive data. | Adapter logs only sanitized messages; test captures log output with sentinel. |
| REQ-006 | Kata payload drift (renamed or removed keys) could yield partially-populated issues. | Field-mapping validation against the real keys (`short_id`, `title`, `status`); fixture tests cover complete, missing-field and extra-field payloads. |
| REQ-012 | `kata close` rejects a message under 40 characters, so a short fallback message would fail every close. | The generated default is padded to Kata's minimum; a unit test asserts its length. |
| REQ-014 | A future change could add a claim-state sweep that frees another operator's live claim. | The architecture test forbids claim-state enumeration outside the permitted call sites. |

---
## 11. Open Questions & Clarifications

No `[NEEDS CLARIFICATION]` marker is open. Four questions — three raised during
elicitation and one raised by the TRD refinement pass — were resolved from primary
sources or from a probe of the pinned `kata` binary; each resolution is recorded here
with the evidence that fixed it.

### Open Questions

None.

### Resolved Decisions
- **RESOLVED (failure-path claim release — raised by the TRD refinement pass, blocked KATA-T015, KATA-T035 and KATA-T036).**
  `fail/3` also releases Foreman's own claim, so a failed task returns to the ready
  list. Evidence, from `kata` v0.23.0 in an isolated scratch workspace: after
  `kata claim <ref> --if-unowned`, `kata reopen <ref>` returns `changed: false` (the
  issue is already open) and leaves `owner` set, so `kata ready --unowned` omits the
  issue and `kata claim --if-unowned` is refused with `already_claimed` (exit 5) — a
  failed run would strand its own task. `kata unassign <ref> --expect-owner <actor>`
  clears the owner (event `issue.unassigned`); the issue then appears in
  `kata ready --unowned` and can be claimed again. With a non-matching expected owner
  Kata changes nothing and refuses with `owner_mismatch` (kind `conflict`, exit 5).
  `kata status <ref> --json` reports the effective `actor` and the current `owner` at
  the top level (the `owner` key is absent when the issue is unowned; `hold` is then
  `unassigned`), and
  `kata comment --idempotency-key` replays an identical comment as `changed: false`
  with no new comment, but refuses the same key with a different body
  (`idempotency_mismatch`, exit 5). The resulting contract:
  (1) `fail/3` reads `kata status <ref> --json` first.
  (2) If a different actor owns the task it writes nothing — no reopen, comment or
  unassign — and returns a typed `CLAIMED_BY_OTHER` error that carries no owner name.
  As AC-013-2 requires of every Kata claimed-by-other error, the code is non-retryable
  (`retryable?: false`, overriding the `CodeMap` default), so the run executor classifies
  it as permanent and does not repeat the notification: another operator's issue never
  collects a failure comment from Foreman.
  (3) Otherwise the order is reopen, then comment, then unassign, so the failure reason
  is on record before the task becomes ready.
  (4) The comment carries an idempotency key derived from the run id and a hash of the
  comment text, so a retried notification — for example after a transient unassign
  failure while Foreman still holds the claim — never duplicates it, while a differently
  worded comment under the same run gets its own key instead of being refused with
  `idempotency_mismatch`. An already-unowned task still gets the reopen and the comment
  (there is nothing to release), so the failure is always recorded.
  (5) The unassign passes the effective `actor` as `--expect-owner`, and is skipped
  when the task is already unowned, which counts as released; a release refused because
  ownership changed in the meantime (`owner_mismatch`) surfaces as the same typed error.
  (6) `<actor>` is the `actor` field of the status envelope, the effective actor: Kata's
  `claim` help says the daemon's authenticated actor takes precedence over the
  client-selected one and that `kata whoami` shows only the client-selected actor, so
  `whoami` is not used. The scratch probe ran with `auth: none`, where actor and owner
  agree, so that divergence is documented upstream behavior, not probed here. The
  lookup is one call on the single reference being failed, not a sweep, and AC-014-2
  says so.
  (7) `kata reopen` is a no-op (`changed: false`, exit 0) on an issue that is already
  open, so on the normal failure path the unassign is the only state change; that result
  is not an error.
  A run that dies mid-flight never reaches `fail/3`; its claim is reclaimed by the
  operator with `kata unassign <ref>`, consistent with REQ-014 (no Foreman-side
  sweep). Applied to AC-005-4, AC-012-2 and AC-014-1.
- **RESOLVED (TRD OPEN-Q1 — Kata `id_format` regex, was blocking KATA-T038).**
  `id_format` is `^[a-z0-9]+$` with `example: "abc4"`. Kata's published concepts
  reference states the rule directly: *"kata derives visible `short_id` as the
  lowercased suffix of the ULID, extended if needed to avoid collisions inside the
  project."* A ULID suffix is lowercased Crockford Base32 — digits and letters — and
  the collision extension makes the length variable, so a short id may begin with a
  digit and may interleave digits and letters. The TRD's candidate `^[a-z]+[0-9]+$`
  (letters then digits only) would reject legal ids such as `4abc` and `a1b2`.
  Evidence: Kata's concepts reference, "Issue identity" section, and the CLI
  reference's issue-identity section, which show the bare form `abc4`, the qualified
  form `kata#abc4`, and the full 26-character ULID as the three accepted ref shapes.
  KATA-T038 still runs the upstream check and files an upstream issue if Kata ships
  an explicit regex that contradicts this, in which case the declaration follows
  upstream.
  *Resolution note (KATA-T038):* the upstream check could not be done as written —
  no pinned upstream revision exists and the upstream source is not reachable
  (`kenn.io/kata` returns 404). The published CLI reference (katatracker.com) and
  the installed `kata` v0.23.0 binary were used instead, and neither contradicts
  `^[a-z0-9]+$`; filing an upstream issue was not authorised.
- **RESOLVED (TRD OPEN-Q2 — `accepted_kata_versions` format, was blocking KATA-T039).**
  `accepted_kata_versions` is a **list of version requirement strings** evaluated
  with Elixir's `Version.match?/2` — the range syntax is exactly the one already
  used in `mix.exs` (`">= 0.19.0"`, `"~> 0.19.0"`), so no new dependency and no
  bespoke range grammar. A single exact version string is rejected as the format:
  Kata's own documentation gates features by floor (*"These commands require Kata
  0.19.0 or later"*, stated for `kata agent-hook`, `kata teams` and the
  account-token bridges), not by pinned release, and an allowlist of exact versions
  would mark every patch upgrade unhealthy. Kata states no floor for `kata claim`
  or `kata close`, so the adapter's own floor stays an operator policy — the shipped
  default is `">= 0.19.0"`, and KATA-T039/T041 re-confirm it against the pinned
  upstream revision. The probe value comes from
  `kata version --json`, whose `version` field carries a `v` prefix (`v0.6.0`)
  that `Version.parse/1` rejects — the adapter MUST strip a leading `v` before
  matching. Kata also emits `kata_api_version` (an integer, `1` today); the CLI
  probe keeps using the human-readable `version` because the daemon handshake is
  out of scope. Development builds report a non-semver identifier
  (`Version.parse/1` → `:error`): that is an *unparseable* version, handled as a
  warning with the raw value quoted, never a hard failure and never a silent pass.
  *Resolution note (KATA-T039):* re-confirming the floor and the version format
  against a pinned upstream revision could not be done — no pinned upstream
  revision exists and the upstream source is not reachable (`kenn.io/kata` returns
  404). The published CLI reference (katatracker.com) and the installed `kata`
  v0.23.0 binary were used instead and confirm the declared values; filing an
  upstream issue was not authorised.
- **RESOLVED (queue timeout configuration).** No new config key. The Kata adapter
  reuses the existing `ConcurrencyLimiter` defaults — `max_in_flight: 4`,
  `timeout_ms: 30_000`. The limiter exposes `acquire/1,2` (the second argument is a
  per-call timeout override, and `{:error, :timeout}` is its queue-timeout result) and
  `release/1`; its cap is per `project_id`. The Beads adapter does not call it today
  (see the limiter-supervision divergence below), so there is no existing
  provider-specific key to mirror, and adding one would fork provider behavior for no
  operator-visible gain. This matches TRD KATA-T023, which specifies the values
  inline rather than by key.
- **RESOLVED (Kata CLI contract, verified against `kata` v0.23.0 on 2026-11-19).**
  (1) `kata list --status` accepts only `open`, `closed` or `all`. (2) `kata close
  --done -m|--message <msg>` requires a message of at least 40 characters; evidence
  is `--commit <sha>` or `--evidence`. (3) `kata ready --unowned` returns open issues
  that nothing open blocks, that are not scheduled for a future date and not marked
  someday, and that have no owner — a stricter set than `kata list`, intentionally
  used for AC-005-1's "unclaimed, dependency-satisfied". (4) `--json` payloads
  (observed in an isolated scratch workspace): `ready` returns `{issues: [...]}`,
  `show` returns `{issue, comments, links, labels}`, `claim` returns `{issue, event}`;
  an issue carries `id` (numeric), `uid`, `short_id`, `qualified_id` (list only),
  `title`, `body`, `status` (`open`/`closed`), `owner` (only once claimed), `author`,
  `metadata`, `revision` and timestamps, and carries no `priority`, `assignee`,
  `description`, `notes` or `design` key. AC-006-1/AC-006-3 map accordingly. (5) The
  `storage_scheme` value set is `:sqlite` or `:cli_process` (REQ-002).

### Divergences recorded as decisions (never counted as markers)

- **Version drift semantics** — KATA-T043's "unhealthy when `kata` is missing or
  wrong version" is read as "the version probe failed" (non-zero exit), matching
  AC-002-3. Accepted-range drift is a warning, not an unhealthy verdict. See the
  TRD divergence note under REQ-016 (§6) and the Explicit Won't entry "a hard Kata
  version gate on the accepted range".
- **Callback count** — an earlier TRD draft said "all 11 TaskProvider callbacks";
  the behaviour in `packages/foreman_server/lib/foreman_server/task_provider.ex`
  declares **13** (3 metadata + 10 operational). The PRD requires all 13, REQ-005
  carries a note recording the discrepancy, and the TRD now says 13 — closed.
- **Limiter supervision** — TRD KATA-T025 says to verify the limiter is "shared
  between Beads and Kata adapters (same GenServer instance)". Today
  `ConcurrencyLimiter` is referenced only by its own module and tests; it is not
  started in `ForemanServer.Application`, and the Beads adapter does not call it.
  Wiring it into the supervision tree is therefore new work in this PRD's scope,
  and "shared instance" is a decision to make there rather than a property to
  preserve.
---
## 12. Traceability to TRD

All 17 requirements and 57 acceptance criteria trace to the TRD
`TRD-2026-8030852f-foreman-kata-task-provider.md` — 56 of the 57 ACs are the
TRD's own set, and AC-002-4 is added by this PRD to make the OPEN-Q1 `id_format`
resolution verifiable (it is traced to KATA-T038). The requirement IDs match the
TRD IDs one-for-one; the table below is the TRD's traceability matrix as of PRD
v1.1.3: the original rows plus AC-002-4, the five tasks KATA-T052–T056 that the
TRD added so the `cwd`/`storage_scheme` routing, limiter supervision and generic
doctor behavior the ACs already require have an owner, and four re-mapped ACs
(AC-001-2, AC-001-3, AC-002-3, AC-005-5 — see the §14 v1.1.3 row). The TRD task
list now holds 56 tasks (`KATA-T001`–`KATA-T056`).

| REQ | Title | Priority | TRD Tasks | AC → TRD Task |
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

---

## 13. Self-Critique & Implementation Readiness Gate

**Self-Critique:** The PRD follows the ensemble-create-prd skill contract, respects the TRD's exact requirement count, and enumerates the required front-matter keys using camelCase as mandated. The risk-flag set matches the 14 risk-flagged REQs (Risk Level Medium or High) identified in the health summary. Version handling is split deliberately: a missing binary or failed probe is a hard `available?/0` failure, while accepted-range drift is a `foreman doctor` warning, and that split is recorded against the TRD's KATA-T043 wording rather than silently diverging. Three things were resolved from primary sources rather than guessed, and each cites its evidence in §11: the `id_format` regex (Kata's short ids are the lowercased ULID suffix, so they are variable-length lowercase alphanumeric and a digit-initial suffix is legal, which falsifies the TRD's letters-then-digits candidate), the `accepted_kata_versions` format (reuse Elixir's `Version.match?/2` range grammar, already in `mix.exs`; `kata version --json` reports a `v`-prefixed semver that `Version.parse/1` rejects, so the strip is specified), and the queue timeout (no new config key; the existing `ConcurrencyLimiter` default of `timeout_ms: 30_000` plus the per-call override the Beads adapter already uses covers it, matching KATA-T023). Two residual risks stay open by design, not by omission: the Kata CLI flag surface may drift between releases, and the accepted-version range is a policy value — Kata's docs gate individual features by floor ("These commands require Kata 0.19.0 or later" for `kata agent-hook`, `kata teams` and account-token bridges) but never state a floor for `kata claim` or `kata close`, so both risks carry a TRD verification task (KATA-T038–T041) and an upstream-issue route rather than a guess baked into config.

**Implementation Readiness Score:** 4.5. All 17 REQs and 57 ACs trace to TRD tasks (56 verbatim, plus the PRD-added AC-002-4), every risk-flagged REQ has a named mitigation and a test strategy, and four `[NEEDS CLARIFICATION]` markers are closed with cited evidence — OPEN-Q1 and OPEN-Q2 no longer block KATA-T038 and KATA-T039, because both now have a specified value and a falsification route if upstream contradicts it, and the failure-path claim release found by a `kata` v0.23.0 probe is decided in §11 (`fail/3` reopens, comments, then releases Foreman's own claim). The score is not higher: the `id_format` and version-floor values are derived from Kata's published documentation and examples rather than a normative schema Kata ships, so KATA-T038–T041 must re-confirm them against the pinned upstream revision before the adapter ships.
---

## 14. Version History

| Version | Date | Author | Summary |
|---|---|---|---|
| 1.0.0 | 2026-11-18 | Foreman ensemble-create-prd | Initial PRD for Kata task-provider integration, aligned with TRD-8030852f. |
| 1.0.1 | 2026-11-18 | Foreman ensemble-create-prd | TRD-consistency pass: §12 traceability matrix filled from TRD §4; REQ-011/REQ-015 dependency cycle removed; §7/§12 priorities reconciled; §11 marker 1 replaced with TRD OPEN-Q1 and marker 2 tightened to OPEN-Q2; §5 non-goals completed (federation, `KATA_DSN`, semantic search/MCP); REQ-014 and CONCERN 8 re-scoped to foreman-native-execution parity (no orphan surfacing); AC-002-3 aligned to KATA-T009; AC-016-2 aligned to KATA-T042/T043 with the accepted-range divergence recorded; §6 grouped Must/Should/Could ordering fixed; §8 dependency table syntax repaired; readiness set to 3.5 PENDING. |
| 1.1.0 | 2026-11-18 | Foreman ensemble-create-prd | Resolution pass: all three §11 `[NEEDS CLARIFICATION]` markers closed with cited evidence — OPEN-Q1 `id_format` fixed to `^[a-z0-9]+$` (short ids are the lowercased ULID suffix, so variable length and digit-initial suffixes are legal, which falsifies the TRD's letters-then-digits candidate); OPEN-Q2 `accepted_kata_versions` fixed to a list of Elixir `Version.match?/2` requirement strings, with the `v`-prefix strip and the non-semver dev-build warning called out; the queue-timeout question closed as "no new config key" against the existing `ConcurrencyLimiter` defaults and per-call override, matching KATA-T023. Added the limiter-supervision divergence (the limiter is not yet started in `Application` and the Beads adapter does not call it, so KATA-T025's "shared instance" is new work, not a property to preserve). Health-summary marker and TRD-decision counts set to 0; readiness raised 3.5 PENDING → 4.5 PASS. |
| 1.1.1 | 2026-11-18 | Foreman ensemble-create-prd | Count and citation reconciliation after adding AC-002-4: AC total 56 → 57 in front-matter, §1 distribution, §2 scope, §9 coverage target, §12 intro and REQ-002 row, and §13, with AC-002-4 labelled PRD-added and traced to KATA-T038 rather than presented as TRD-traced. Two evidence claims corrected against the pinned Kata reference: `abc4` is a collision-suffix example (the `^[a-z0-9]+$` case rests on short ids being the lowercased ULID suffix, not on a literal digit-initial example), and the 0.19.0 floor in §11/§13 gates `kata agent-hook`, `kata teams` and account-token bridges — Kata's docs state no floor for `kata claim`/`kata close`, so the accepted-version range stays an operator policy plus a KATA-T038–T041 verification task. |
| 1.1.2 | 2026-11-18 | Foreman ensemble-create-prd | Skill-contract compliance pass: added the two front-matter keys the active `ensemble-create-prd` skill (Phase 5, Step 1) requires and the document was missing — `status: Draft` and `date: 2026-11-18`. Contract re-read from the loaded skill (`~/.pi/agent/skills/ensemble-create-prd/SKILL.md`, v2.5.0), which mandates per-requirement `complexity` tags, the `complexityBreakdown` front-matter block, priority/AC-count health-summary tables and the §7 "Priority, Complexity, AC Count" column set; an out-of-tree copy of the skill under `ensemble.kata` forbids those same tags and asks for two sections ("Approvals and Decision Ownership", "Entry and Exit Criteria") the loaded skill does not name. The loaded skill governs, so complexity tagging stays and those sections stay out. No requirement, AC, dependency, or score changed. |
| 1.1.3 | 2026-11-19 | Foreman ensemble-create-prd | TRD-alignment pass against the live sources. (1) §12 now maps the five tasks the TRD added — KATA-T052 (Go CLI emits `config.cwd`, rejects a Kata database path), T053 (server routing and preflight keyed on `capabilities[:storage_scheme]` instead of a hardcoded `database_path`), T054 (`KataAdapter` passes `project_config[:cwd]` to every call), T055 (`ConcurrencyLimiter` supervised under `ForemanServer.Application`, the §11 limiter-supervision divergence), T056 (provider-generic `foreman doctor`) — to the existing ACs they implement; no AC was added or removed (still 57). (2) Four ACs re-mapped to the task that implements their text: AC-001-2 → T010/T021, AC-001-3 → T008/T020, AC-002-3 (`available?/0`) → T009, AC-005-5 → T016. (3) AC-014-2/AC-014-3, CONCERN 8 and REQ-014 no longer name `kata list --status claimed` / `in_progress`: Kata's `kata list --status` accepts only `open`, `closed` or `all` (verified against `kata` v0.23.0), so the forbidden behavior is stated as any claim-state sweep and the operator triage commands are `kata list --status all` plus `kata status <ref>`. (4) The 57 per-requirement AC tables were converted to the `- AC-NNN-M: …` list form that the active `ensemble-create-prd` skill (Step 3) specifies and that the Ensemble PRD parser reads (it resolved 1 of 57 ACs from the table form, so REQ→AC traceability was invisible to the tooling); AC wording is unchanged and was not re-phrased into Given/When/Then. (5) The per-REQ `**Dependencies:**` lines carried 30 edges with four cycles (REQ-002↔REQ-010, REQ-007↔REQ-017, REQ-015↔REQ-017 and the longer REQ-006→REQ-007→REQ-017→REQ-015→REQ-006) while §1 and §8 state 24 acyclic edges; they now list exactly the §8 ordering edges (script-checked: 24 edges, no cycles, no difference from §8), and the former back-references are kept as `**Constraints (not ordering edges):**` lines. |
| 1.1.4 | 2026-11-19 | Foreman ensemble-refine-trd | TRD refinement pass (TRD 2.0.1). (1) AC-006-3 re-mapped from KATA-T039 (the OPEN-Q2 version-format confirmation, which does not implement it) to the field-mapping tasks KATA-T011/T012; REQ-006 no longer lists T039. No AC added or removed (still 57); PRD §12 ids are unchanged (the TRD's 14 test tasks carry `-TEST` ids whose stem is the PRD id, e.g. `TRD-KATA-T017-TEST` is KATA-T017). (2) Probe of `kata` v0.23.0 in an isolated scratch workspace: `kata reopen` leaves `owner` set, so a failed run's task is neither listed by `kata ready --unowned` nor re-claimable. Not decided here: recorded as an open `[NEEDS CLARIFICATION]` in §11, so `readiness_gate` moves PASS → PENDING and `readinessScore` 4.5 → 4.0 until AC-005-4/AC-012-2/AC-014-1 settle whether `fail/3` also runs `kata unassign`. (3) Confirmed against the binary: `kata list --status all` is valid (exit 0); `kata close --done` on an open issue with a short message exits 3 (`need >=40 chars`). |
| 1.1.5 | 2026-11-19 | Foreman ensemble-refine-trd | Failure-path claim release decided (user decision). `fail/3` now runs `kata reopen`, `kata comment`, then `kata unassign <ref> --expect-owner <actor>` (actor from `kata status <ref> --json` `.actor`, the daemon-aware effective actor), so a failed task returns to `kata ready --unowned` and can be re-claimed. AC-005-4, AC-012-2 and AC-014-1 reworded and AC-014-2 clarified that the single-reference actor lookup is not a sweep; no AC added or removed (still 57) and no §12 mapping changed. The §11 marker is closed with the probe evidence, `readiness_gate` returns PENDING → PASS and `readinessScore` 4.0 → 4.5. Operator reclaim of a crashed run's claim now names `kata unassign` (Won't, CONCERN 8, REQ-014): `kata reopen` leaves `owner` set and is a no-op on an open issue. |
| 1.1.6 | 2026-11-19 | Foreman ensemble-refine-trd | `fail/3` failure path tightened (user decision). It now reads `kata status <ref> --json` first and, when a different actor owns the task, writes nothing and returns a typed `CLAIMED_BY_OTHER` error — that code is retryable in the existing `CodeMap`, so the run executor retries the notification, and the earlier unconditional reopen + comment would have re-appended the failure comment to another operator's issue on every attempt. The comment now carries an idempotency key derived from the run id (probed on `kata` v0.23.0: an identical replay is `changed: false` and adds no comment; the same key with a different body is refused with `idempotency_mismatch`). The unassign is skipped when the task is already unowned and no longer depends on reading `error.data`. AC-005-4, AC-012-2 and AC-014-1 reworded; no AC added or removed (still 57), no §12 mapping changed, readiness gate stays PASS at 4.5. |
| 1.1.7 | 2026-11-19 | Foreman ensemble-refine-trd | Idempotency key for the failure comment now derived from the run id and a hash of the comment text rather than the run id alone: Kata refuses a reused key with a different body (`idempotency_mismatch`, exit 5), so a run-id-only key would lose a differently worded second failure comment. AC-014-1 reworded; the §11 entry states that an already-unowned task still gets reopen and comment. No AC added or removed (still 57), no §12 mapping changed, readiness gate stays PASS at 4.5. |
| 1.1.8 | 2026-11-19 | Foreman ensemble-implement-trd | Implementation-time correction (no AC changed, still 57). The foreign-owner `CLAIMED_BY_OTHER` error from `fail/3` is non-retryable, like every Kata claimed-by-other error under AC-013-2, so `RunExecutor` does not retry it; the 1.1.6 and 1.1.7 rows' reasoning that `CodeMap` marks the code retryable no longer applies to Kata. §11 (2) updated to match. |
| 1.1.9 | 2026-11-19 | Foreman ensemble-implement-trd | Closed a conflict between two ACs found during implementation (still 57 ACs). AC-013-2 required a boolean assignee-presence flag in the claimed-by-other context while AC-017-4 closes the context key set to `id`, `command`, `exit_code`, `stderr_byte_count`, `sanitized?` and `redacted_fields`; a per-test exception would have let any key ride under that code, so AC-013-2 now says the context carries no owner identity and only the allowlisted keys. AC-007-1 said errors take the CodeMap's existing redacted-field list, which for `CLAIMED_BY_OTHER` is `["current_assignee"]` and contradicts AC-015-1's literal `["assignee", "description"]`; it now says the retryable flag comes from CodeMap (overridden by AC-013-2) and `redacted_fields` is always the Kata list. |
| 1.1.10 | 2026-11-19 | Foreman ensemble-implement-trd | AC-017-4's closed context key set gains `missing_fields`. `ProviderError.new/3` seeds `missing_fields: []` into every context (the shared struct, Beads included) and AC-006-1 requires schema-validation errors to name the absent fields, so a literal six-key set could never hold; the key is now part of the closed set, always a list of field names, empty except on schema-validation errors, never values. Naming the fields only in the error message was considered and rejected because it would not remove the seeded key. Still 57 ACs. |
| 1.1.11 | 2026-11-19 | Foreman ensemble-implement-trd | AC-012-1 no longer requires a commit SHA on every close. Probed on `kata` v0.23.0: `kata close --done` needs typed evidence (`commit:`, `pr:`, `test:`, `reviewed-paths:`, `external:` or `attachment:`) and exits 3 without it; an empty `--commit` is also refused (`evidence[0] commit requires non-empty sha`). A phase that produces no commit therefore cannot supply a SHA, so the close carries the commit SHA when the run produced one and otherwise the run's artifact path as reviewed-paths evidence, but only when that file exists; a run with neither gets a typed validation error rather than an invented value or a claim about a file that was never written. Still 57 ACs. |
| 1.1.12 | 2026-11-19 | Foreman ensemble-implement-trd | §11 OPEN-Q1 and OPEN-Q2 each gain a resolution note: the upstream-pinned check (KATA-T038, KATA-T039) could not be done because no pinned upstream revision exists and the upstream source is not reachable (`kenn.io/kata` returns 404); the published CLI reference (katatracker.com) and the installed `kata` v0.23.0 binary were used instead, and filing an upstream issue was not authorised. No AC added, removed or changed (still 57). |
| 1.1.13 | 2026-11-19 | Foreman ensemble-implement-trd | Forward pointer only; no AC text changed (still 57). AC-004-1 says "`System.cmd` invocation of `kata`"; the built runner spawns `kata` through `Port.open` on `/bin/sh`, so there is no such `System.cmd`. The architecture test enforces the stronger rule (no spawn of `kata` in any form, `System.cmd`, `System.shell`, `Port.open`, `:os.cmd`, `:erlang.open_port`, outside the single runner site), and the TRD's AC-004-1 restates it that way (TRD 2.0.12). |

---
