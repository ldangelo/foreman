---
document_id: PRD-2026-016
version: 1.0.0
status: Draft
date: 2026-08-16
scale_depth: STANDARD
author: Lead Agent
total_requirements: 12
readiness_score: 0.0
readiness_gate: PENDING
---

# PRD-2026-016: jido_harness Integration — Phase 1

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 12 (REQ-016-001 through REQ-016-012) |
| **Must** | 9 |
| **Should** | 3 |
| **Could** | 0 |
| **Won't (this release)** | 0 |
| **AC Coverage** | 0/12 (0%) |
| **Risk Flags** | 0 |
| **Cross-Requirement Dependencies** | 0 |
| **Readiness Score** | 0.0 / 5.0 |
| **Ambiguity Markers** | 0 |

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

Foreman shall vendor jido_harness as `packages/jido_harness` under the existing monorepo.

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

Existing Foreman Pi workflows shall produce identical results when run through jido_harness.

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

## 6. Dependencies and Risks

| ID | Dependency / Risk | Mitigation |
|----|--------------------|------------|
| DEP-016-01 | Phase 1 depends on: upstream jido_harness being stable | Vendor with pinned git ref, review upstream changes before upgrading |
| DEP-016-02 | Phase 2 (jido_signal) depends on Phase 1 completing | Explicit gate: no jido_signal work until jido_harness integration tests green |
| RISK-016-01 | Fork maintenance burden | Automate sync via GitHub Actions; propose core changes upstream first |
| RISK-016-02 | Two code paths (pi-sdk-runner + ForemanDispatch) until Phase 5 | Feature flag `FOREMAN_USE_JIDO_HARNESS`; deprecate pi-sdk-runner in Phase 4 |
| RISK-016-03 | jido_harness is 14-star, 8-fork open source | Monitor upstream activity; maintain own adapter if upstream stalls |

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
