# ADR 0001: Go clients over an Elixir core, with a contained Pi worker tier

- Status: Proposed
- Date: 2026-07-09
- Deciders: Leo D'Angelo
- Supersedes: none
- Related: TRD-2026-014 (Elixir migration), `docs/guides/elixir-backend-architecture.md`

## Context

Foreman today is a three-tier system whose tiers happen to share one language in
two of three places:

1. **Clients** — the CLI (`commander`) and the live cockpit TUI (`super-tui`,
   built on Ink/React). These parse commands, send authenticated JSON to the
   Elixir server, and render projections. They own no durable state.
2. **Core** — the Elixir/OTP server. It is already the source of truth:
   it validates commands, appends durable events, rebuilds projections,
   supervises run/phase actors, enforces scheduling capacity, reconciles workers,
   and exposes read endpoints under `/api/v1`.
3. **Agent execution** — Node/Pi workers. These receive phase starts over the
   worker HTTP protocol and run in-process agent sessions via the Pi SDK
   (`@mariozechner/pi-coding-agent`), streaming ordered events/logs/artifacts
   back to the core.

The cockpit is becoming a flagship surface, and we want it to be genuinely
slick: fluid high-refresh rendering, real layout composition, animated phase
progress, and inline rendering of markdown reports. Ink is React reconciliation
over a terminal; it is serviceable but has a lower ceiling for animation and can
flicker or lag on dense, frequently-updating screens. We evaluated the Charm
stack (Bubble Tea + Lip Gloss + Bubbles + Glamour + Harmonica) and found a
materially higher presentation and performance ceiling for exactly this kind of
UI, plus a compiled single-binary distribution.

Because agents perform effectively all of the implementation, per-language
contributor familiarity is no longer a meaningful constraint on the choice.
The remaining real cost is *system* coherence: number of languages, toolchains,
and cross-boundary type contracts.

## Decision

Adopt a clean tier split by language, aligned to responsibility:

- **Clients → Go.** Rewrite the CLI, the cockpit TUI, and the `foreman mcp`
  server as Go programs. Clients are strictly read-model consumers of the Elixir
  HTTP API plus command senders (`POST /api/v1/commands`). They hold no
  authoritative state and infer nothing that the core does not already assert.
- **State and logic → Elixir.** The Elixir/OTP server remains — and is
  reinforced as — the single source of truth and operational trigger. Events are
  authoritative; projections are read models. This is unchanged in kind, only
  strengthened as clients stop carrying any fallback logic.
- **Agent execution → contained Node/Pi tier.** The Node/Pi worker remains for
  now, but is explicitly reframed as a *runtime dependency of Pi*, not as
  application code. Elixir already drives it over the worker HTTP protocol.
  TypeScript is deprecated everywhere except inside this contained execution
  sidecar.

TypeScript is deprecated for all client and orchestration code going forward.
New client work is Go; new state/logic work is Elixir.

## The load-bearing question: the Pi worker tier

"Deprecate Node/TypeScript" does not cleanly resolve the agent-execution tier,
and this ADR calls that out deliberately. The Pi SDK is a TypeScript library,
and the entire agent runtime is bound to it: `pi-sdk-runner`, `pi-sdk-tools`
(`send_mail`, `phase_handoff`, `artifact_write`, `validation_result`, etc.),
the pipeline executor, and role/prompt generation. Clients and core migrate
cleanly; the worker does not.

Two futures, decided later and not blocking the client rewrite:

- **Contain (default).** Keep a minimal Node process whose only job is to host
  Pi and speak the worker HTTP protocol. It stops being "the Foreman codebase in
  TypeScript" and becomes an isolated, replaceable execution shim. Pragmatic;
  lets us deprecate TS everywhere that carries product logic today.
- **Replace.** Migrate off Pi to an agent runtime that Elixir or Go can drive
  directly (an external coding-agent CLI invoked via Elixir ports, or a
  different in-process runtime). Larger bet; entirely dependent on what can
  match Pi's in-process session model and custom tool surface.

Recommendation: **contain now, revisit replace after the client tier is stable.**
Sequencing the hardest, highest-risk migration last keeps the spine (Elixir)
untouched while the visible wins (Go cockpit) land first.

## Consequences

Positive:

- Higher UI/UX ceiling and better high-refresh performance for the cockpit.
- Single static binary per client; no Node runtime required to operate Foreman.
- Bubble Tea's model/update/view (Elm architecture) maps almost 1:1 onto the
  existing `reduceSuperTuiState` reducer, so the state logic ports conceptually
  rather than being redesigned.
- The client/core boundary becomes strictly typed at one place (the HTTP API),
  reducing the surface where a client can drift from the truth.
- Compiled, statically-typed Go with sub-second builds gives agent-driven TDD a
  tighter feedback loop than runtime-surfaced Ink/React errors.

Negative / costs:

- A third language in the system (Go, alongside Elixir and the contained TS/Pi
  sidecar). CI, build, and release pipelines grow a Go toolchain.
- A JSON contract between Elixir projections and Go clients that can drift.
  Mitigation: generate Go types from a shared schema (or a published OpenAPI
  document for `/api/v1`) so the contract is checked, not hand-maintained.
- Temporary duplication: the Go cockpit runs alongside the Node CLI during
  migration until command parity is reached.

## Alternatives considered

- **Stay on Ink, invest in polish.** Lowest system risk and single-language for
  the client tier, but a lower ceiling for the "spectacular" goal and no change
  to distribution. Rejected because the cockpit is a flagship surface.
- **Rust/Ratatui for clients.** Comparable performance ceiling, but a heavier
  authoring model and weaker "batteries-included" TUI ergonomics than the Charm
  stack for this use case. Not chosen.
- **Rewrite the worker tier immediately.** Highest risk, gated on an unproven Pi
  replacement, and would destabilize the core while the client rewrite is also
  in flight. Deferred by design.

## Migration plan (phased)

1. **Phase 1 — Go cockpit POC (this change).** Greenfield Bubble Tea cockpit
   that reads the existing `/api/v1` projections. Runs alongside everything;
   zero risk to current operations. Proves the ceiling.
2. **Phase 2 — Command parity.** Port the read/command CLI commands to Go
   against `/api/v1`. Publish an OpenAPI schema for `/api/v1` and generate Go
   types from it. Retire the Node CLI once parity is verified.
3. **Phase 3 — MCP server in Go.** Move `foreman mcp` to Go over the same API.
4. **Phase 4 — Worker decision.** With clients and core fully on Go/Elixir,
   evaluate contain-vs-replace for the Pi tier against real operational data.

## Notes on the client/core contract

The following existing endpoints already satisfy the cockpit's needs and anchor
the Go client interface:

| Need | Endpoint |
|------|----------|
| What's running / run status | `GET /api/v1/runs` |
| What's available to run | `GET /api/v1/tasks/dispatchable` |
| Recent / all tasks | `GET /api/v1/tasks` |
| Messages + events (drill-down) | `GET /api/v1/inbox`, `GET /api/v1/events` |
| Logs | `GET /api/v1/runs/:run_id/logs` |
| Reports | `GET /api/v1/runs/:run_id/report` |
| Debug timeline | `GET /api/v1/runs/:run_id/debug` |
| Actions (retry/reset/interrupt/resume) | `POST /api/v1/commands`, `POST /api/v1/runs/:run_id/interrupt|resume` |

Authentication is `Authorization: Bearer <FOREMAN_SERVER_AUTH_TOKEN>` when the
server has a token configured, consistent with the current CLI.
