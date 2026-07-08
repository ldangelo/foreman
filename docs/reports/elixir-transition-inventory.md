# Elixir Transition Inventory

_Last updated: 2026-06-30_

## Goal of this inventory

Track operator-facing transition from Node daemon/tRPC-backed workflows to Elixir-backed commands, projections, and server APIs, and explicitly account for any retained Node-local code after cutover.

## Status legend

- **Elixir** — operator path is routed through Elixir-backed APIs/projections/commands.
- **Removed** — legacy Node backend surface was removed with explicit operator-facing messaging.
- **Retained bridge** — retained Node CLI/frontend or Elixir-launched Node/Pi worker bridge code, not a Node backend operator path.
- **Approved local utility** — local filesystem/run-log cleanup or artifact utility retained because it does not own scheduler/task/backend state and does not reopen the Node daemon/tRPC backend.

## Current operator-facing transition status

| Area / workflow | Current status | Evidence | Residual risk / retained code |
| --- | --- | --- | --- |
| `foreman project register/list/remove/edit` | Elixir | Project registration/listing plus update/archive commands route through Elixir command APIs and projection events. | `project add` is removed; operators clone locally then `project register <path>`. |
| `foreman project add` | Removed | CLI reports removal after Elixir cutover and gives `project register` guidance. | No Node fallback guidance. |
| Jira management CLI (`configure/status/test/enable-webhook/disable-webhook`) | Removed | `src/cli/commands/jira.ts` returns removed messages and points to Elixir external trigger ingestion. | No CLI Jira config replacement; transition ingestion remains Elixir API-backed. |
| `foreman run` scheduler tick | Elixir | `src/cli/commands/run.ts` sends scheduler ticks to Elixir and rejects removed direct-dispatch/dispatch-shaping options. | Node/Pi worker bridge remains internal. |
| `foreman run --task/--task`, `--resume/--resume-failed`, dispatch-shaping flags | Removed | Removed messages point to `foreman run` or `foreman retry`; no Node backend guidance. | None approved. |
| `foreman run task` | Removed for operators / retained bridge | Operator invocation fails after cutover. Hidden `--run-id` remains for Elixir scheduler-launched Node/Pi workers. | Retained bridge is approved scope. |
| `foreman task create --from-text` / hidden `foreman task` | Removed | CLI reports removal and structured task guidance; legacy generator source/tests were deleted. | None approved. |
| Structured `foreman task create/list/show/approve/update/close` | Elixir | Structured task command paths route through Elixir-backed APIs/commands for registered projects. | No practical tRPC dependency; task adjuncts below are explicitly accounted. |
| `foreman task note` | Elixir | Resolves project/tasks through Elixir and sends `task.annotate`; no `createTrpcClient()` call remains in `task.ts`. | Notes are append-only annotations; no local backend fallback. |
| `foreman task dep add/list` | Elixir | Uses Elixir task projections and `task.add_dependency` for blocker relationships; no tRPC call remains in `task.ts`. | `parent-child` add and dependency removal are removed until Elixir removal events exist. |
| `foreman task dep remove` | Removed | CLI prints an Elixir-cutover removal message. | No local/tRPC backend fallback. |
| `foreman task import --from-tasks` | Elixir | Imports legacy tasks JSONL through Elixir `task.create` and `task.add_dependency`; description now says Elixir-backed task store. | Import reads local `.tasks` files as source data only. |
| `foreman board`, `watch`, `status`, `logs`, `inbox`, `retry`, `recover`, `debug`, `plan`, `sling`, `attach` | Elixir + approved local utilities | Default registered-project backend state uses Elixir projections/APIs and fails closed instead of silently falling back. | Remaining local-store reads are listed below as approved local utilities; residual tRPC calls hit a fail-closed shim and cannot open the daemon socket. |
| `foreman stop` / `foreman reset` | Removed | CLI rejects both commands after cutover instead of mutating local run-store state. | Operators use `foreman retry` or Elixir-backed recovery controls. |
| `foreman daemon start/restart` | Removed | CLI always rejects start/restart with `foreman server start` guidance. | `daemon stop/status` remain for stray legacy process inspection/cleanup only. |
| Legacy TS delegation envs | Removed | CLI entrypoint no longer calls legacy delegation; docs no longer advertise the envs. | None approved. |

## Approved local-store and filesystem utility exceptions

These references were audited because they match `ForemanStore`, `PostgresStore`, `local-store-adapter`, or `task-client-factory`. They are approved only for local artifact/run-log cleanup or worker-bridge bookkeeping, not as alternate operator backend state.

| File / command surface | Retained use | Approval rationale |
| --- | --- | --- |
| `src/cli/commands/run-task.ts` | Internal `--run-id` worker bridge and worker-store metadata for Pi execution. | Required retained Elixir-launched Node/Pi worker bridge. Operator direct use is removed. |
| `src/cli/commands/run.ts` | Worker/refinery support and sentinel wrapping around scheduler-driven work. | `foreman run` operator dispatch is Elixir scheduler tick; local store code supports retained worker execution/cleanup paths. |
| `src/cli/commands/retry.ts` | Local run lookup/cleanup around retry flows. | Default retry state resolution is Elixir; local store adapter is cleanup/compatibility around worker records. |
| `src/cli/commands/status.ts`, `src/cli/dashboard-state.ts`, `src/cli/commands/watch/*` | Dashboard/log/render helpers may read local worker artifacts or historical local store records. | Backend state for registered projects is Elixir; local reads are display/artifact helpers and not a scheduler/backend fallback. |
| `src/cli/commands/logs.ts`, `debug.ts`, `attach.ts`, `recover.ts`, `inbox.ts` | Read local logs, reports, or historical worker artifacts. | Artifact inspection remains part of the Node CLI/frontend; backend run/task state uses Elixir where registered. |
| `src/cli/commands/worktree.ts`, `purge-logs.ts`, `purge-zombie-runs.ts`, `doctor.ts` | Cleanup of local worktrees/logs/stale run records and health checks. | Local cleanup utilities are not a Node backend control plane; run-state reset/stop surfaces were removed. |
| `src/cli/commands/sentinel.ts` | Sentinel configuration/run history helpers. | Retained until sentinel state is fully Elixir-native; does not reopen daemon/tRPC and is not gated to Node backend. |
| `src/cli/commands/local-store-adapter.ts` | Async wrapper for local cleanup/run-store methods used by the above utilities. | Approved support module for local cleanup utilities only. |

## Retained Node areas

- Node CLI/frontend command parsing/rendering remains in scope.
- Elixir-launched Node/Pi worker bridge remains in scope for Pi SDK execution.
- Filesystem artifacts/log readers remain in scope where they read worker output rather than owning backend state.

## Approved retained daemon/tRPC exceptions

- Residual `createTrpcClient()` call sites remain only in unreachable compatibility branches or fail-closed paths; the client itself is an isolated fail-closed shim and the Node daemon server/router entrypoints were deleted, so no operator command can open the old daemon socket.
- `foreman daemon stop/status` remain only for inspecting or stopping stray legacy daemon processes; start/restart are removed.

## Coverage and verification gate

Use `npm run test:coverage:transition` for the Elixir-transition coverage gate. It runs the normal Node coverage workflow and Elixir backend coverage, then writes `.foreman/coverage/transition-scope-summary.json`.

Current transition gate expectations:

- Node frontend/operator CLI plus Elixir-launched Node/Pi worker-bridge scope line coverage >= 70%.
- Node frontend/operator CLI plus Elixir-launched Node/Pi worker-bridge scope branch coverage >= 70%.
- Elixir backend line coverage from `mix test --cover` >= 70%.
- Elixir backend branch-site coverage >= 70%.
