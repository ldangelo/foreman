# Implementation Plan: TRD-2026-48f7b420-foreman-beads-task-provider

**Mode:** Plan only — review and approve before execution.
**Strategy:** tdd
**Branch:** `slices/go-elixir-cqrs` (current branch; `--use-current-branch`)
**Topo:** Single PR (all phases on one branch; `STACKED_PRS=false`)
**Generated:** 2026-08-06T19:23:59.980Z

## Source

- TRD: `docs/TRD/TRD-2026-48f7b420-foreman-beads-task-provider.md` (v1.0.5)
- PRD: `docs/PRD/PRD-2026-48f7b420-foreman-beads-task-provider.md`
- Slug: `trd-2026-48f7b420-foreman-beads-task-provider`
- Design readiness score: 4.5 (gate ≥ 4.0)

## Bead Hierarchy

- **Root epic:** `foreman-eve` — [trd:trd-2026-48f7b420-foreman-beads-task-provider] Implement TRD: TRD: Foreman × Beads Rust — Task-Provider Integration
- **Stories (4):**
  - `foreman-cid` — PR 1a Foundation (22 tasks)
  - `foreman-r5o` — PR 1b Adapter (30 tasks)
  - `foreman-fll` — PR 2 Boot Reconciliation (5 tasks)
  - `foreman-mt4` — PR 3 Architecture Gate (6 tasks)
- **Tasks (63):** 35 impl + 28 test
  - 28 paired impl/test rows
  - 7 unpaired impl rows (no `-TEST` counterpart): TRD-027, TRD-031, TRD-032, TRD-033, TRD-034, TRD-035, TRD-036
- **Dependencies (152):** 4 story-blocks-epic + 63 task-blocks-story + 82 task-depends + 3 inter-phase-gate

### PR 1a: Foundation — `foreman-cid`

Shippable: Operators can register providers via `Application.put_env(:foreman_server, :task_provider, providers: [...])`; each provider's `ForemanServer.TaskProvider` behaviour, `BrRunner` boundary, `ProviderError`, `JsonSchemaCache`, and `ConcurrencyLimiter` are unit-tested in isolation.

Tasks (22):
- foreman-37n — `TRD-001` (impl) — Define `ForemanServer.TaskProvider` behaviour with 11 callbacks (`name/0`, `capa
- foreman-up8 — `TRD-002` (impl) — Define `ForemanServer.TaskProvider.Issue` struct with 11 first-class fields (`id
- foreman-cps — `TRD-003` (impl) — Define `ForemanServer.TaskProviders.BrRunner` behaviour with a single `@callback
- foreman-ri0 — `TRD-004` (impl) — Implement `ForemanServer.TaskProviders.SystemBrRunner` (sole `System.cmd("br", .
- foreman-b1v — `TRD-005` (impl) — Implement `ForemanServer.TaskProviders.ProviderError` typed struct with `@enforc
- foreman-5ra — `TRD-006` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.CodeMap` data-only 12-row `b
- foreman-t9b — `TRD-007` (impl) — Implement `ForemanServer.TaskProviders.JsonSchemaCache` GenServer: fetches `br s
- foreman-67i — `TRD-008` (impl) — Implement `ForemanServer.TaskProviders.ConcurrencyLimiter` GenServer: `acquire(p
- foreman-d86 — `TRD-028` (impl) — Add `{:mox, "~> 1.0", only: :test}` (and `{:ex_unit, "~> 1.0", only: :test}` if 
- foreman-yo5 — `TRD-029` (impl) — Add `config :foreman_server, :br_runner, ForemanServer.TaskProviders.SystemBrRun
- foreman-ku3 — `TRD-030` (impl) — Add `config :foreman_server, :br_runner, ForemanServer.TaskProviders.BrRunnerMoc
- foreman-7i7 — `TRD-001-TEST` (TEST) — Behaviour tests: call `ForemanServer.TaskProvider.behaviour_info(:callbacks)` an
- foreman-di4 — `TRD-002-TEST` (TEST) — Issue struct tests: construct a fully-populated Issue with all 11 fields; assert
- foreman-9gg — `TRD-003-TEST` (TEST) — BrRunner behaviour tests: assert `cmd/3` is the only callback; assert `@callback
- foreman-e26 — `TRD-004-TEST` (TEST) — SystemBrRunner tests: shell_quote with whitespace, single-quote, double-quote, `
- foreman-ml9 — `TRD-005-TEST` (TEST) — ProviderError struct tests: constructor accepts the 7 allowlisted keys; construc
- foreman-rky — `TRD-006-TEST` (TEST) — CodeMap tests: 12-row mapping asserts deterministic Foreman.code and retryable?;
- foreman-zfa — `TRD-007-TEST` (TEST) — JsonSchemaCache tests: fetch at boot; cache hit on second call; 24h refresh adva
- foreman-mnr — `TRD-008-TEST` (TEST) — ConcurrencyLimiter tests: 4 concurrent acquires succeed; 5th acquires with timeo
- foreman-gca — `TRD-028-TEST` (TEST) — mix.exs tests: `Mox` is in `:test` deps; `elixirc_paths(:test)` returns `["lib",
- foreman-043 — `TRD-029-TEST` (TEST) — config/config.exs tests: `Application.get_env(:foreman_server, :br_runner)` retu
- foreman-pr7 — `TRD-030-TEST` (TEST) — config/test.exs tests: `Application.get_env(:foreman_server, :br_runner)` resolv

### PR 1b: Adapter — `foreman-r5o`

Shippable: `ForemanServer.TaskProviders.BeadsAdapter` declared via `@runner Application.compile_env(...)`; skeleton with 8 operational callbacks, preflight, Registry, Project aggregate, RunExecutor hooks.

Tasks (30):
- foreman-hqp — `TRD-010` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter` skeleton: declares `@runner
- foreman-krc — `TRD-007a` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.preflight_database/2`: invok
- foreman-y42 — `TRD-011` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.list_ready/2`: calls `JsonSc
- foreman-wll — `TRD-012` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.get/2`: calls `JsonSchemaCac
- foreman-v55 — `TRD-013` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.claim/3`: invokes `br update
- foreman-nbj — `TRD-014` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.complete/3`: invokes `br clo
- foreman-etk — `TRD-015` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.fail/3`: invokes `br update 
- foreman-sg8 — `TRD-016` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.reopen/3`: invokes `br updat
- foreman-6pz — `TRD-017` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.set_priority/3`: invokes `br
- foreman-yt1 — `TRD-018` (impl) — Implement `ForemanServer.TaskProviders.BeadsAdapter.add_dependency/3`: invokes `
- foreman-1uh — `TRD-020` (impl) — Implement `ForemanServer.TaskProvider.Registry` GenServer: registers providers f
- foreman-o7d — `TRD-021` (impl) — Implement Registry capability routing + contract-version check: `route/2` (trans
- foreman-zlc — `TRD-022` (impl) — Implement telemetry taxonomy: every `[:foreman_server, :task_provider, :*]` even
- foreman-fal — `TRD-023` (impl) — Extend `ForemanServer.Aggregates.Project` to carry `task_provider` config block:
- foreman-drp — `TRD-024` (impl) — Extend `ForemanServer.Workflow.RunExecutor` to drive the **post-execution** task
- foreman-z0v — `TRD-010-TEST` (TEST) — BeadsAdapter skeleton tests: `Application.compile_env` resolves to `ForemanServe
- foreman-1v4 — `TRD-007a-TEST` (TEST) — `BeadsAdapter.preflight_database/2` tests: Mox `BrRunnerMock` expect-exactly-1 c
- foreman-8j5 — `TRD-011-TEST` (TEST) — `list_ready` tests: empty project returns `{:ok, []}`; population with 3 issues 
- foreman-l8m — `TRD-012-TEST` (TEST) — `get` tests: single issue populates all 11 fields; `dependencies` and `dependent
- foreman-8qv — `TRD-013-TEST` (TEST) — claim tests: `NOT_CLAIMABLE` is non-retryable; `CLAIMED_BY_OTHER` returns Provid
- foreman-1b4 — `TRD-014-TEST` (TEST) — complete tests: `ALREADY_CLOSED` returns `{:ok, :already_terminal}`; success ret
- foreman-d7h — `TRD-015-TEST` (TEST) — fail tests: `br update --status open --transition-comment <reason>`; determinist
- foreman-irb — `TRD-016-TEST` (TEST) — reopen tests: success returns `{:ok, %Issue{status: "open"}}`; uses the transiti
- foreman-hzd — `TRD-017-TEST` (TEST) — set_priority tests: `br update --priority <level>`; rejects out-of-range priorit
- foreman-syi — `TRD-018-TEST` (TEST) — add_dependency tests: `br dep add <issue_id> <depends_on_id>`; rejects `depends_
- foreman-90y — `TRD-020-TEST` (TEST) — Registry tests: concurrent registration reflects both registrations in `routing_
- foreman-4nl — `TRD-021-TEST` (TEST) — Registry capability routing + contract-version rejection tests: `route/2` return
- foreman-70e — `TRD-022-TEST` (TEST) — Telemetry emit-site tests: each `[:foreman_server, :task_provider, :*]` event is
- foreman-vli — `TRD-023-TEST` (TEST) — Project aggregate tests: `task_provider` config block accepted on `project.regis
- foreman-kwk — `TRD-024-TEST` (TEST) — RunExecutor drive tests: `claim` invoked before dispatch; `complete` invoked on 

### PR 2: Boot Reconciliation — `foreman-fll`

Shippable: On Foreman server boot, `ForemanServer.Workflow.BootReconciliation` calls `BeadsAdapter.reopen/3`; doctor integration + docs updated.

Tasks (5):
- foreman-2oz — `TRD-025` (impl) — Implement `ForemanServer.Workflow.BootReconciliation` GenServer: invoked once at
- foreman-mkv — `TRD-026` (impl) — Implement `foreman doctor task_provider` CLI subcommand: enumerates registered p
- foreman-4d4 — `TRD-027` (impl) — Update `docs/user-guide.md` (per-project `task_provider` config block + `foreman
- foreman-u2q — `TRD-025-TEST` (TEST) — BootReconciliation tests: 4 paths (orphan-reopen, matching-in_progress-no-op, al
- foreman-m73 — `TRD-026-TEST` (TEST) — doctor tests: healthy project reports clean snapshot; unhealthy project reports 

### PR 3: Architecture Gate + Side-Channel + Isolation — `foreman-mt4`

Shippable: CI gates enforce 4 architecture guardrails; side-channel capture test verifies no module reads br state outside the runner while capturing errors; isolation property test verifies BrRunner is invokable from exactly one site.

Tasks (6):
- foreman-foi — `TRD-031` (impl) — Architecture test (REQ-013-1): AST scan of `lib/foreman_server/` for `System.cmd
- foreman-afk — `TRD-032` (impl) — Architecture test (REQ-013-2): AST scan of `lib/foreman_server/` for `alias Fore
- foreman-yd5 — `TRD-033` (impl) — Architecture test (REQ-008-5a): AST scan for `%ProviderError{...}` constructions
- foreman-exi — `TRD-034` (impl) — Side-channel capture tests (REQ-019-1, -2, -3, -4, -5 AND AC-008-5(b) behavioral
- foreman-eu2 — `TRD-035` (impl) — AC-005-4 property-based isolation test: pre-assigns `caller_pid => expected_data
- foreman-mt1 — `TRD-036` (impl) — Architecture test (REQ-017-2 structural enforcement): AST scan of `lib/foreman_s

## PR Topology

Single-PR mode (no per-phase PRs):
- All work committed to `slices/go-elixir-cqrs` (no new branches created; `--use-current-branch`).
- Per-phase `phase-gate` actions run pre-commit checks; `createPr: false` on each gate.
- Single completion PR created at end with title: `feat(trd-2026-48f7b420-foreman-beads-task-provider): TRD: Foreman × Beads Rust — Task-Provider Integration`.

## Dependency Graph Health

Verified via `bv --robot-insights --no-cache` (cycle analysis mode; `--robot-plan` skips cycles by design):

- Cycles: 0 (bv state=computed, count=0)
- `br stats --json` aggregate counts (full repo `.beads/`):
  - total_issues: 92
  - open_issues: 68
  - ready_issues: 6
  - blocked_issues: 62
  - closed_issues: 24
  - tombstone_issues: 4
- Story → Epic edges: 4 (story-blocks-epic)
- Task → Story edges: 63 (task-blocks-story)
- Task → Task edges: 82 (task-depends, intra-phase + inter-phase)
- Inter-phase gates: 3 (TRD-030-TEST → TRD-010; TRD-024-TEST → TRD-025; TRD-026-TEST → TRD-031)

## Branch Map

| Phase | Branch | Create PR? | Notes |
|-------|--------|-----------|-------|
| PR 1a | slices/go-elixir-cqrs | no | foundation |
| PR 1b | slices/go-elixir-cqrs | no | adapter |
| PR 2 | slices/go-elixir-cqrs | no | boot reconciliation |
| PR 3 | slices/go-elixir-cqrs | no | architecture gate |
| Final | slices/go-elixir-cqrs | YES | single completion PR |

## Execution Plan

When executed via `/ensemble:implement-trd-beads --execute`, the runtime will:

1. Iterate `bv --robot-plan` to derive a parallel-ready DAG of bead IDs.
2. For each bead: Explorer → Developer → QA → Reviewer → Finalize (TDD).
3. After PR 1a tasks close: run phase-gate (CI smoke tests on the foundation slice).
4. After PR 1b tasks close: run phase-gate (smoke + adapter integration).
5. After PR 2 tasks close: run phase-gate (boot reconciliation + doctor integration).
6. After PR 3 tasks close: run phase-gate (architecture gate + side-channel + isolation).
7. Final completion PR to main with title `feat(trd-2026-48f7b420-foreman-beads-task-provider): TRD: Foreman × Beads Rust — Task-Provider Integration`.

## Stats

- Total tasks: 63
- Impl tasks: 35
- Test tasks: 28
- Paired impl/test rows: 28
- Unpaired impl rows: 7 (TRD-027, TRD-031, TRD-032, TRD-033, TRD-034, TRD-035, TRD-036)
- Total hours: 164.0h
- Unique REQs covered: 19
- Unique ACs captured: 63
- Dependency edges: 152
- Cycles: 0
- Warnings: 1 (no `## Master Task List` heading — non-blocking)

## Next Step

Run `/ensemble:implement-trd-beads --execute --use-current-branch` to begin implementation.
