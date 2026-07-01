# Elixir Transition Inventory

_Last updated: 2026-06-30_

## Goal of this inventory

Track operator-facing transition from Node daemon/tRPC-backed workflows to Elixir-backed commands, projections, and server APIs.

## Status legend

- **Elixir** — operator path is routed through Elixir-backed APIs/projections/commands.
- **Removed** — legacy Node backend surface was removed with explicit operator-facing messaging.
- **Retained bridge** — retained Node CLI/frontend or Elixir-launched Node/Pi worker bridge code, not a Node backend operator path.

## Current operator-facing transition status

| Area / workflow | Current status | Evidence | Residual risk / retained code |
| --- | --- | --- | --- |
| `foreman project register/list/remove/edit` | Elixir | Project registration/listing plus update/archive commands route through Elixir command APIs and projection events. | `project add` is removed; operators clone locally then `project register <path>`. |
| `foreman project add` | Removed | CLI reports removal after Elixir cutover and gives `project register` guidance. | No Node fallback guidance. |
| Jira management CLI (`configure/status/test/enable-webhook/disable-webhook`) | Removed | `src/cli/commands/jira.ts` returns removed messages and points to Elixir external trigger ingestion. | No CLI Jira config replacement; transition ingestion remains Elixir API-backed. |
| `foreman run` scheduler tick | Elixir | `src/cli/commands/run.ts` sends scheduler ticks to Elixir and rejects removed direct-dispatch/dispatch-shaping options. | Node/Pi worker bridge remains internal. |
| `foreman run --task/--bead`, `--resume/--resume-failed`, dispatch-shaping flags | Removed | Removed messages point to `foreman run` or `foreman retry`; no Node backend guidance. | None approved. |
| `foreman run task` | Removed for operators / retained bridge | Operator invocation fails after cutover. Hidden `--run-id` remains for Elixir scheduler-launched Node/Pi workers. | Retained bridge is approved scope. |
| `foreman task create --from-text` / hidden `foreman bead` | Removed | CLI reports removal and structured task guidance; legacy generator source/tests were deleted. | None approved. |
| Structured `foreman task create/list/show/approve/update/close` | Elixir | Structured task command paths route through Elixir-backed APIs/commands for registered projects. | Residual Node compatibility code is being deleted/isolated in follow-up cleanup. |
| `foreman board`, `watch`, `status`, `logs`, `inbox`, `retry`, `recover`, `debug`, `plan`, `sling`, `attach` | Elixir | Default registered-project paths use Elixir projections/APIs and fail closed instead of silently falling back. | Residual unreachable compatibility branches call a fail-closed `createTrpcClient()` shim; no practical daemon socket dependency remains. |
| `foreman daemon start/restart` | Removed | CLI always rejects start/restart with `foreman server start` guidance. | `daemon stop/status` remain for stray legacy process inspection/cleanup only. |
| Legacy TS delegation envs | Removed | CLI entrypoint no longer calls legacy delegation; docs no longer advertise the envs. | None approved. |

## Retained Node areas

- Node CLI/frontend command parsing/rendering remains in scope.
- Elixir-launched Node/Pi worker bridge remains in scope for Pi SDK execution.
- Filesystem artifacts/log readers remain in scope where they read worker output rather than owning backend state.

## Approved retained exceptions

- Residual `createTrpcClient()` call sites remain only in unreachable compatibility branches; the client itself is an isolated fail-closed shim and the Node daemon server/router entrypoints were deleted, so no operator command can open the old daemon socket.
- `foreman daemon stop/status` remain only for inspecting or stopping stray legacy daemon processes; start/restart are removed.

## Coverage and verification gate

Use `npm run test:coverage:transition` for the Elixir-transition coverage gate. It runs the normal Node coverage workflow and Elixir backend coverage, then writes `.foreman/coverage/transition-scope-summary.json`.

Current transition gate expectations:

- Node frontend/operator CLI plus Elixir-launched Node/Pi worker-bridge scope line coverage >= 70%.
- Node frontend/operator CLI plus Elixir-launched Node/Pi worker-bridge scope branch coverage >= 70%.
- Elixir backend line coverage from `mix test --cover` >= 70%.
- Elixir backend branch-site coverage >= 70%.
