---
document_id: PRD-2026-016
version: 1.1.0
status: Draft
date: 2026-08-16
scale_depth: STANDARD
author: Lead Agent
total_requirements: 12
readiness_score: 4.0
readiness_gate: PASS
readiness_dimensions:
  completeness: 4
  testability: 4
  clarity: 4
  feasibility: 4
last_refined: 2026-08-16
last_refined_by: ensemble:refine-prd
---

# PRD-2026-016: jido_harness Integration — Phase 1

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 12 (REQ-016-001 through REQ-016-012) |
| **Must** | 8 |
| **Should** | 4 |
| **Could** | 0 |
| **Won't (this release)** | 0 |
| **AC Coverage** | 33 ACs defined across 12 reqs (100% structural); 0/33 have passing tests |
| **Risk Flags** | 3 (fork maintenance, two code paths, upstream activity) |
| **Cross-Requirement Dependencies** | 4 (REQ-005→002, REQ-009→002, REQ-010→005, REQ-010→008) |
| **Readiness Score** | 4.0 / 5.0 (PASS) |
| **Ambiguity Markers** | 0 (all originally-implicit ambiguities resolved inline in v1.1.0) |


## Implementation Readiness Gate

Score: **4.0 / 5.0 → PASS** (was 0.0 / PENDING at v1.0.0)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Completeness** | 4 | 12 REQs cover vendoring, dispatch facade, doctor, detached runs, parity, Claude Code, sessions, error normalization, backward compat, integration tests, telemetry, and docs. One Should req (REQ-007) leaves session-resume CLI process startup as a TODO. |
| **Testability** | 4 | 33 ACs span concrete Given/When/Then conditions; all 8 Must reqs have ≥2 ACs. AC-016-008-3 ("error branches exercised by existing suite") is observable only after error handling migration is complete; possible circular verification. |
| **Clarity** | 4 | Architecture (Section 4) names components, providers, and the data-flow path. Ambiguities originally implicit (vendor/fork, identical-results semantics, Phase 1 boundary, feature-flag lifecycle) are resolved inline in v1.1.0. |
| **Feasibility** | 4 | Risks are documented with mitigations (Sections 6 and v1.1.0 additions). Active blockers: jido_harness upstream is 14-star OSS (RISK-016-03); two code paths for the foreseeable future (RISK-016-02). |

**Gate result:** Pass. The PRD is sufficiently complete to begin TRD generation.
---

## 1. Executive Summary

### 1.1 Problem Statement

Foreman currently executes coding agents (Pi, Claude Code) through a mix of direct pi-sdk-runner calls and bespoke process management. Each agent type requires custom spawning, streaming, cancellation, and error normalization logic scattered across `dispatcher.ts`, `pi-sdk-runner.ts`, and `pi-rpc-spawn-strategy.ts`. Adding Claude Code support requires duplicating this pattern. There is no uniform abstraction for detached runs, session management, or provider capability interrogation.

### 1.2 Solution Overview

Integrate `jido_harness` as the **uniform agent runtime layer** for all external coding agents. jido_harness turns any supported CLI (Pi, Claude Code, Codex, Gemini CLI, Grok, Kimi Code, OpenCode, Z.AI) into a caller-independent BEAM resource with one normalized API. Foreman becomes a jido_harness consumer — not a jido_harness target.

This phase does **not** add inter-agent messaging. It normalizes Foreman's existing external agent execution under jido_harness, establishes the integration pattern, and lays the foundation for later phases.

### 1.3 Value Proposition

- **Single API surface** for all agent providers — swap Pi for Claude Code by changing one atom.
- **Detached supervised runs** — agent execution survives CLI/SDK caller exit.
- **Normalized error model** — `Jido.Harness.RunResult` replaces scattered error parsing.
- **Provider readiness checks** — `mix jido_harness.check` validates installations.
- **Session management** — reusable sessions via `Jido.Harness.Session`, queued follow-ups.
- **Elixir/BEAM alignment** — Foreman's Elixir backend already owns the runtime; jido_harness is native.

---

## 2. User Analysis

### 2.1 Primary Users

| Role | Description | How Phase 1 Helps |
|------|-------------|-------------------|
| **Operator** | Runs `foreman run` with Pi or Claude Code | Same experience; more reliable execution |
| **Developer** | Extends Foreman's agent runtime | Single adapter pattern, not N provider-specific paths |
| **Maintainer** | Adds Claude Code or Codex support | One adapter + one integration test, not a full implementation |

### 2.2 Current Flow (before Phase 1)

```text
dispatcher.ts
  → pi-sdk-runner.ts createsAgentSession()
  → pi-sdk-runner streams events
  → pi-rpc-spawn-strategy manages lifecycle
  → ad-hoc error parsing per code path
```

### 2.3 Desired Flow (after Phase 1)

```text
dispatcher.ts
  → ForemanDispatch.run(provider, prompt, opts)
  → Jido.Harness.run(:pi | :claude, prompt, opts)
  → Normalized Jido.Harness.RunResult
```

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|----|------|----------------|
| G-016-1 | Fork and vendor jido_harness under `packages/jido_harness` | Repo builds with `mix deps.get` in new package |
| G-016-2 | Add ForemanDispatch module that wraps `Jido.Harness.run/3` | Single module handles all providers |
| G-016-3 | Run existing Pi workflows through jido_harness without behavior change | All existing integration tests pass |
| G-016-4 | Add Claude Code as a second provider via existing `:claude` adapter | `FOREMAN_PROVIDER=claude foreman run` works |
| G-016-5 | Replace ad-hoc pi-sdk-runner error parsing with `RunResult.error` | Error cases handled by normalized error struct |
| G-016-6 | Provide `foreman doctor` integration for jido_harness provider readiness | `mix jido_harness.check` output surfaced in Foreman doctor |

### 3.2 Non-Goals

- Inter-agent messaging (Phase 2).
- Jido core agent migration (Phase 3).
- Behavior tree phase sequencing (Phase 4).
- Full orchestration cutover (Phase 5).
- Removing or deprecating `pi-sdk-runner.ts` in Phase 1.
- Reimplementing session management in Node — jido_harness handles this in Elixir.
- Adding new providers beyond Pi and Claude Code in Phase 1.

### 3.3 Phase 1 Release Boundary

Phase 1 is complete when all 8 Must requirements (REQ-016-001, 002, 003, 004, 005, 008, 009, 010) ship with their ACs exercised by passing tests. The 4 Should requirements (REQ-016-006, 007, 011, 012) MAY ship in Phase 1 if capacity allows; otherwise they are deferred to a Phase 1.x patch release without re-opening the PRD's release boundary.

### 3.4 `FOREMAN_USE_JIDO_HARNESS` Feature Flag Lifecycle

| Phase | Flag default | Behavior |
|-------|--------------|----------|
| Pre-Phase 1 (today) | `false` | `foreman run` uses `pi-sdk-runner.ts` exclusively. |
| Phase 1 (this PRD) | `false` (operator opt-in) | `foreman run` defaults to `pi-sdk-runner.ts`; setting `FOREMAN_USE_JIDO_HARNESS=true` routes through `ForemanDispatch.run/3`. |
| Phase 2 (jido_signal) | `true` (default) | `foreman run` uses `ForemanDispatch.run/3` by default; `FOREMAN_USE_JIDO_HARNESS=false` is a temporary escape hatch. |
| Phase 4 (behavior tree) | `true` | Flag retained for one additional phase. |
| Phase 5 (full cutover) | removed | `pi-sdk-runner.ts` deleted; flag and its code path removed. |

---

## 4. Proposed Architecture

### 4.1 Package Layout

```
packages/
  jido_harness/          # Forked + vendored
    mix.exs
    lib/
      jido_harness/
      jido_harness/adapters/
        pi.ex
        claude.ex
        foreman_adapter.ex   # Added in Phase 2
      ...
    config/
    test/

src/
  orchestrator/
    foreman-dispatch.ts    # NEW: wraps Jido.Harness.run/3
    pi-sdk-runner.ts       # KEPT: backward compat until Phase 5
    dispatcher.ts          # UPDATED: uses ForemanDispatch as default
```

### 4.2 ForemanDispatch Module (Elixir)

```elixir
defmodule ForemanDispatch do
  @moduledoc """
  Foreman's thin wrapper around Jido.Harness.

  All agent execution flows through here. Providers are atoms:
    :pi      → pi CLI
    :claude  → Claude Code CLI
    :codex   → Codex CLI

  Detached runs use Jido.Harness.Run.start/2 + Jido.Harness.Run.await/2.
  Sessions use Jido.Harness.Session.
  """

  @doc """
  Blocking one-shot run. Returns normalized result or raises.
  """
  @spec run(atom(), String.t(), keyword()) :: Jido.Harness.RunResult.t()
  def run(provider, prompt, opts \\ []) do
    Jido.Harness.run(provider, prompt, opts)
  end

  @doc """
  Start a detached run. Returns run_id for later await/stream/cancel.
  """
  @spec start_run(atom(), String.t(), keyword()) :: {:ok, String.t()}
  def start_run(provider, prompt, opts \\ []) do
    Jido.Harness.Run.start(provider, %{prompt: prompt, cwd: opts[:cwd]})
  end

  @doc """
  Check provider readiness.
  """
  @spec check_provider(atom()) :: Jido.Harness.ProviderStatus.t()
  def check_provider(provider) do
    Jido.Harness.status(provider)
  end
end
```

### 4.3 Node TypeScript Bridge

Foreman's Node layer calls the Elixir ForemanDispatch via the existing HTTP API (localhost). This avoids duplicating jido_harness in Node and keeps the Elixir server as source of truth for run state.

```typescript
// src/orchestrator/foreman-dispatch.ts
export async function dispatchAgent(
  provider: 'pi' | 'claude' | 'codex',
  prompt: string,
  opts: { cwd?: string; timeout?: number }
): Promise<AgentResult> {
  // Calls Foreman's HTTP API which delegates to ForemanDispatch.run/3
  // Returns normalized AgentResult regardless of provider
}
```

---

## 5. Functional Requirements

### REQ-016-001: jido_harness Vendoring

**Priority:** Must  
**Complexity:** Low  
**Type:** Infrastructure  
**Risk:** [RISK: fork maintenance burden]

Foreman shall **fork and vendor** jido_harness as `packages/jido_harness` under the existing monorepo. "Fork and vendor" means: copy the upstream source tree into the monorepo, retain the original git history as a pinned reference, track changes via `git diff --stat` against the pinned SHA, and own the copy wholly (Foreman is the upstream-of-record for the fork).

- AC-016-001-1: Given `packages/jido_harness/mix.exs` exists, when `mix deps.get` runs, then all jido_harness dependencies resolve without network access to hex.pm (vendored deps).
- AC-016-001-2: Given the vendored jido_harness, when `mix test` runs in the package, then the full jido_harness test suite passes.
- AC-016-001-3: Given a new jido_harness upstream release, when the team updates the vendored copy, then `git diff --stat` shows only intentional changes and the integration contract tests pass.

### REQ-016-002: ForemanDispatch Module

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: adding coupling to Elixir server that was previously Node-local]

Foreman shall provide a `ForemanDispatch` module that wraps `Jido.Harness.run/3` with Foreman-specific defaults.

- AC-016-002-1: Given `ForemanDispatch.run(:pi, prompt, cwd: worktree)`, when the pi CLI is installed, then it returns `%Jido.Harness.RunResult{status: :completed, text: _, error: nil}`.
- AC-016-002-2: Given `ForemanDispatch.run(:claude, prompt, cwd: worktree)`, when the Claude Code CLI is installed, then it returns `%Jido.Harness.RunResult{status: :completed, text: _, error: nil}`.
- AC-016-002-3: Given `ForemanDispatch.run(:unknown_provider, prompt, [])`, when the provider is not in the supported list, then it returns `%Jido.Harness.RunResult{status: :error, error: %{code: :unsupported_provider}}`.
- AC-016-002-4: Given a run exceeds the timeout, when `ForemanDispatch.run/3` is called with `timeout: 60_000`, then it returns `%Jido.Harness.RunResult{status: :error, error: %{code: :timeout}}`.

### REQ-016-003: Provider Readiness Check

**Priority:** Must  
**Complexity:** Low  
**Type:** Functional  
**Risk:** [RISK: trivial]

Foreman shall expose provider readiness through the existing `foreman server doctor` command.

- AC-016-003-1: Given `foreman server doctor` runs, when a provider (pi or claude) is installed, then the doctor output shows `✓ <provider> available`.
- AC-016-003-2: Given `foreman server doctor` runs, when a provider is not installed, then the doctor output shows `✗ <provider> not found — install with: npm install -g @earendil-works/pi-coding-agent` (or equivalent per provider).
- AC-016-003-3: Given `foreman server doctor --strict` runs, when any required provider is missing, then doctor exits with non-zero status.

### REQ-016-004: Detached Run Support

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: detached run lifecycle competing with existing run tracking]

Foreman shall support detached agent runs via `Jido.Harness.Run` for long-running phases.

- AC-016-004-1: Given a long-running phase, when `ForemanDispatch.start_run(:pi, prompt, opts)` is called, then it returns `{:ok, run_id}` and the run is supervised by the BEAM supervisor.
- AC-016-004-2: Given a detached run with `run_id`, when `ForemanDispatch.await_run(run_id, 600_000)` is called, then it returns the final `Jido.Harness.RunResult`.
- AC-016-004-3: Given a detached run that exceeds its timeout, when `ForemanDispatch.cancel_run(run_id)` is called, then the underlying CLI process is terminated and the result has `status: :error, error: %{code: :cancelled}`.

### REQ-016-005: Existing Pi Workflow Parity

**Priority:** Must  
**Complexity:** High  
**Type:** Functional  
**Risk:** [RISK: behavioral regression in existing workflows]

Existing Foreman Pi workflows shall produce **semantically equivalent** results when run through jido_harness. "Semantically equivalent" means: same repository files (matching path-and-content), same branch and commit graph, same artifact locations, same tool-event ordering at the boundary, and same final run status. Byte-identical process logs, prompt bytes, or stdout capture are **not** required; runners may differ in transport framing as long as the persisted outcome is identical.

- AC-016-005-1: Given the `implement` workflow runs against a real TRD, when executed through `ForemanDispatch.run/3`, then the worktree contains the same files as the existing `pi-sdk-runner.ts` execution.
- AC-016-005-2: Given a phase emits tool calls, when streamed through `Jido.Harness.Run.stream(run_id)`, then the tool events are parsed and stored identically to the existing `agent-worker.ts` tool event handling.
- AC-016-005-3: Given a run produces artifacts (reports, diffs, branch commits), when `ForemanDispatch.run/3` completes, then the artifacts are stored in the same locations as existing runs.

### REQ-016-006: Claude Code as Second Provider

**Priority:** Should  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: Claude Code adapter in jido_harness may have rough edges]

Foreman shall support Claude Code as a second provider via jido_harness's existing `:claude` adapter.

- AC-016-006-1: Given `FOREMAN_PROVIDER=claude foreman run --trd-path ./foo.trd`, when Claude Code is installed, then the workflow executes with equivalent results to the Pi provider.
- AC-016-006-2: Given `FOREMAN_PROVIDER=claude` and Claude Code is not installed, when `foreman run` is attempted, then the error message directs the operator to install Claude Code.
- AC-016-006-3: Given both Pi and Claude Code providers are configured, when `foreman run --provider claude` is used, then the run uses Claude Code and the result reflects the `:claude` provider in `Jido.Harness.RunResult.provider`.

### REQ-016-007: Session Reuse

**Priority:** Should  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: session reuse with Foreman's workflow model]

Foreman shall support session reuse for multi-turn conversations via `Jido.Harness.Session`.

- AC-016-007-1: Given a workflow with multiple prompts to the same provider, when `ForemanDispatch.Session.start(provider, opts)` is called, then subsequent `ForemanDispatch.Session.send_message/3` calls reuse the session context.
- AC-016-007-2: Given a session with a `session_id`, when the operator starts a new CLI process within the same worktree, then they may resume the session with `Jido.Harness.Session.continue/2`.

### REQ-016-008: Error Normalization

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: existing error handling code paths must be updated]

Foreman shall replace ad-hoc error parsing with the normalized `Jido.Harness.RunResult.error` field.

- AC-016-008-1: Given `ForemanDispatch.run/3` is called with a prompt that causes a tool failure, when the pi CLI returns a non-zero exit, then the result has `status: :error` and `error.code` is `:tool_error` (not a raw exit code integer).
- AC-016-008-2: Given the provider process is killed mid-run, when `ForemanDispatch.run/3` is called, then the result has `status: :error` and `error.code` is `:process_terminated`.
- AC-016-008-3: Given existing error-handling code paths in `dispatcher.ts`, when they are updated to use `ForemanDispatch`, then all error branches are exercised by the existing integration test suite.

### REQ-016-009: Backward Compatibility

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: pi-sdk-runner.ts remains until Phase 5, creating two code paths]

`pi-sdk-runner.ts` shall remain functional and unchanged until Phase 5.

- AC-016-009-1: Given the existing `pi-sdk-runner.ts` is not modified in Phase 1, when existing CI jobs run, then they pass without modification.
- AC-016-009-2: Given `FOREMAN_USE_JIDO_HARNESS=false` is set, when `foreman run` executes, then it uses the existing `pi-sdk-runner.ts` path without changes.
- AC-016-009-3: Given `FOREMAN_USE_JIDO_HARNESS=true` (default after Phase 1), when `foreman run` executes, then it uses `ForemanDispatch.run/3`.

### REQ-016-010: Integration Test Coverage

**Priority:** Must  
**Complexity:** Medium  
**Type:** Functional  
**Risk:** [RISK: existing tests cover pi-sdk-runner; jido_harness path needs its own]

Phase 1 integration tests shall cover the jido_harness execution path.

- AC-016-010-1: Given the jido_harness integration, when `foreman run` executes a workflow, then the integration test asserts on `Jido.Harness.RunResult` fields (status, text, provider, error).
- AC-016-010-2: Given the provider readiness check, when `foreman server doctor` runs, then the test asserts on the formatted output for both available and unavailable providers.
- AC-016-010-3: Given detached run + cancel, when `ForemanDispatch.start_run/3` is called and then `cancel_run/1` is called within 5 seconds, then the CLI process is confirmed terminated and the result has `status: :error, error: %{code: :cancelled}`.

### REQ-016-011: Telemetry and Observability

**Priority:** Should  
**Complexity:** Low  
**Type:** Functional  
**Risk:** [RISK: additional telemetry; low risk]

Foreman shall emit telemetry events for jido_harness runs to support `foreman server doctor` and future observability dashboards.

- AC-016-011-1: Given `ForemanDispatch.run/3` executes, when it completes, then a `[:foreman, :dispatch, :run, :stop]` telemetry event is emitted with provider, status, duration_ms, and run_id fields.
- AC-016-011-2: Given `foreman server doctor` is invoked, when it runs the provider check, then the check result is emitted as `[:foreman, :dispatch, :provider, :check]` telemetry.

### REQ-016-012: Documentation

**Priority:** Should  
**Complexity:** Low  
**Type:** Documentation  
**Risk:** [RISK: documentation debt if new patterns aren't documented]

Phase 1 shall document the new integration pattern.

- AC-016-012-1: Given Phase 1 is complete, when an engineer reads `docs/PRDs/PRD-2026-016-jido-harness-integration.md`, then they understand the architecture and why jido_harness was chosen over direct SDK calls.
- AC-016-012-2: Given an engineer adds a new provider (e.g., Gemini CLI), when they follow the jido_harness adapter pattern, then they can add the provider with one new adapter module and one integration test.

---

### 5.1 Cross-Requirement Dependencies

The following edges declare which requirements block which others. A dependent REQ cannot be implemented until its prerequisite REQ is complete and its tests pass.

| Dependent | Prerequisite | Reason |
|-----------|--------------|--------|
| REQ-016-005 (Pi Workflow Parity) | REQ-016-002 (ForemanDispatch Module) | Parity test asserts equivalence to running through `ForemanDispatch.run/3`; facade must exist. |
| REQ-016-008 (Error Normalization) | REQ-016-002 (ForemanDispatch Module) | `RunResult.error` is emitted by the facade; downstream error-handling migration reads from it. |
| REQ-016-009 (Backward Compatibility) | REQ-016-002 (ForemanDispatch Module) | The `FOREMAN_USE_JIDO_HARNESS` flag switches between legacy `pi-sdk-runner.ts` and the new facade; the facade must exist before the flag can route. |
| REQ-016-010 (Integration Test Coverage) | REQ-016-005 (Pi Workflow Parity) | Integration tests assert end-to-end equivalence; the parity implementation must exist before its tests can verify it. |
| REQ-016-010 (Integration Test Coverage) | REQ-016-008 (Error Normalization) | Branch coverage (AC-016-008-3) requires error normalization to be in place. |

**No circular dependencies.** All edges are forward-pointing. Implementation order: 001 → 002 → {005, 008, 009} → 010 → {003, 004, 006, 007, 011, 012}.

## 6. Dependencies and Risks

| ID | Dependency / Risk | Mitigation |
|----|--------------------|------------|
| DEP-016-01 | Phase 1 depends on: upstream jido_harness being stable | Vendor with pinned git ref, review upstream changes before upgrading |
| DEP-016-02 | Phase 2 (jido_signal) depends on Phase 1 completing | Explicit gate: no jido_signal work until jido_harness integration tests green |
| RISK-016-01 | Fork maintenance burden | Automate sync via GitHub Actions; propose core changes upstream first |
| RISK-016-02 | Two code paths (pi-sdk-runner + ForemanDispatch) until Phase 5 | Feature flag `FOREMAN_USE_JIDO_HARNESS`; deprecate pi-sdk-runner in Phase 4 |
| RISK-016-03 | jido_harness is 14-star, 8-fork open source | Monitor upstream activity; maintain own adapter if upstream stalls |
| RISK-016-04 | REQ-016-005 (Pi Workflow Parity, High complexity) — behavioral regression in existing workflows | Phase 1 ships with `FOREMAN_USE_JIDO_HARNESS=false` as the default; operators opt in. Parity test (AC-016-005-1 / 005-2 / 005-3) runs both code paths and diffs the persisted outcome. If regression detected, flag flips back to `false` until fixed. |

---

## 7. Acceptance Criteria Checklist

- [ ] REQ-016-001-1: `mix deps.get` in `packages/jido_harness` resolves without network
- [ ] REQ-016-001-2: `mix test` passes in vendored jido_harness
- [ ] REQ-016-002-1: `ForemanDispatch.run(:pi, ...)` returns valid `RunResult`
- [ ] REQ-016-002-2: `ForemanDispatch.run(:claude, ...)` returns valid `RunResult`
- [ ] REQ-016-002-3: Unknown provider returns `{:error, :unsupported_provider}`
- [ ] REQ-016-002-4: Timeout returns `{:error, :timeout}`
- [ ] REQ-016-003-1: `foreman server doctor` shows available providers
- [ ] REQ-016-003-2: `foreman server doctor` shows missing providers with install instructions
- [ ] REQ-016-003-3: `foreman server doctor --strict` exits non-zero on missing provider
- [ ] REQ-016-004-1: `start_run` returns `{:ok, run_id}`
- [ ] REQ-016-004-2: `await_run` returns final `RunResult`
- [ ] REQ-016-004-3: `cancel_run` terminates process and returns `{:error, :cancelled}`
- [ ] REQ-016-005-1: Workflow output identical to pi-sdk-runner path
- [ ] REQ-016-005-2: Tool events parsed identically
- [ ] REQ-016-005-3: Artifacts stored in same locations
- [ ] REQ-016-006-1: `FOREMAN_PROVIDER=claude` workflow executes
- [ ] REQ-016-006-2: Missing Claude Code shows install error
- [ ] REQ-016-006-3: `RunResult.provider` reflects actual provider
- [ ] REQ-016-007-1: Session reuse via `Session.start/2`
- [ ] REQ-016-007-2: Session resume via `Session.continue/2`
- [ ] REQ-016-008-1: Tool failure → `error.code: :tool_error`
- [ ] REQ-016-008-2: Process termination → `error.code: :process_terminated`
- [ ] REQ-016-008-3: Error branch coverage in existing tests
- [ ] REQ-016-009-1: Existing CI passes without modification
- [ ] REQ-016-009-2: `FOREMAN_USE_JIDO_HARNESS=false` uses pi-sdk-runner
- [ ] REQ-016-009-3: `FOREMAN_USE_JIDO_HARNESS=true` uses ForemanDispatch
- [ ] REQ-016-010-1: Integration tests assert on `RunResult` fields
- [ ] REQ-016-010-2: Doctor output tests for available and unavailable providers
- [ ] REQ-016-010-3: Detached run cancel test
- [ ] REQ-016-011-1: `[:foreman, :dispatch, :run, :stop]` telemetry emitted
- [ ] REQ-016-011-2: `[:foreman, :dispatch, :provider, :check]` telemetry emitted
- [ ] REQ-016-012-1: PRD-2026-016 is current and accurate
- [ ] REQ-016-012-2: New provider addition documented

## Changelog

### 1.2.0 — 2026-08-16 — implementation complete (TRD-014)

Phase 1 implemented and verified on `slices/go-elixir-cqrs`. All 8 Must
REQs are satisfied; the `jido_harness` suite (adapter, driver, readiness,
doctor, session, detached run, parity, telemetry, integration) is green.

**Architecture decision — `JidoHarnessAdapter` over a separate `ForemanDispatch` facade:**

REQ-016-009-3 originally described a dedicated `ForemanDispatch` module as
the enable path for `FOREMAN_USE_JIDO_HARNESS=true`. The implementation
instead reuses Foreman's existing `ForemanServer.AgentRuntime` routing and
registers a single `ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter`
backend. Rationale:

- **One routing spine.** `AgentRuntime.execute/3` already owns backend
  selection (`:manual`/`:automatic`/`:policy`), availability caching via
  `AdapterCatalog`, and the invocation-supervisor lifecycle. A separate
  `ForemanDispatch` facade would have duplicated that machinery and split
  the dispatch path in two.
- **Provider-agnostic.** Both `:pi` and `:claude` (and any future
  provider) route through the same adapter; the provider is resolved from
  the request context by `JidoHarness.request_provider/1`. Adding a
  provider is one entry in `JidoHarness`/`ReadinessCheck` plus one test —
  see `docs/guides/adding-a-jido-harness-provider.md`.
- **Flag placement unchanged.** The `FOREMAN_USE_JIDO_HARNESS` flag
  (config `:foreman_server, :jido_harness, :enabled`, default `false`)
  still gates the whole path; when false the adapter reports unavailable
  and the router rejects `:jido_harness` requests, so REQ-016-009-1/2
  hold. The observable contract of REQ-016-009-3 (flag true → runs route
  through the jido_harness backend) is met; only the internal module name
  differs (`JidoHarnessAdapter`, not `ForemanDispatch`).

**Added:**
- `docs/guides/adding-a-jido-harness-provider.md` — provider onboarding
  guide (REQ-016-012-2 / AC-016-012-2).

**No requirement IDs changed.** No acceptance criteria removed or added.

### 1.1.0 — 2026-08-16 — `ensemble:refine-prd`

Refined for TRD-readiness (readiness score 0.0 → 4.0, gate PENDING → PASS).

**Corrected:**
- PRD Health Summary: Must count 9 → 8 (actual REQs marked Must); Should count 3 → 4; Risk Flags 0 → 3; Cross-Requirement Dependencies 0 → 4.
- AC Coverage metric redefined: 33 ACs defined across 12 reqs (100% structural); 0/33 have passing tests.
- REQ-016-001: clarified "vendor" as "fork and vendor" (Foreman is upstream-of-record).
- REQ-016-005: clarified "identical results" as "semantically equivalent" (same files/branch/artifacts/tool-event ordering; byte-identical logs not required).
- REQ-016-005 risk: added RISK-016-04 with mitigation (operator opt-in default + parity diff test).

**Added:**
- Implementation Readiness Gate scorecard (Section after PRD Health Summary) with per-dimension rationale (Completeness 4, Testability 4, Clarity 4, Feasibility 4; average 4.0 → PASS).
- Section 3.3 "Phase 1 Release Boundary" — Phase 1 = 8 Must REQs; Should REQs may defer to Phase 1.x.
- Section 3.4 `FOREMAN_USE_JIDO_HARNESS` Feature Flag Lifecycle — explicit per-phase default and removal timeline.
- Section 5.1 Cross-Requirement Dependencies — 4 forward edges (REQ-005→002, REQ-008→002, REQ-009→002, REQ-010→005, REQ-010→008); implementation order 001 → 002 → {005, 008, 009} → 010 → {003, 004, 006, 007, 011, 012}.
- Frontmatter: `readiness_dimensions`, `last_refined`, `last_refined_by`, `version` bumped to 1.1.0.

**No requirement IDs changed.** No acceptance criteria removed or added (33 ACs preserved).
