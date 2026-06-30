# Elixir Transition Inventory

_Last updated: 2026-06-30_

## Goal of this inventory

Track operator-facing transition from Node daemon/tRPC-backed workflows to Elixir-backed commands, projections, and server APIs.

This inventory is intentionally narrower than historical parity work: it focuses on **default operator-facing workflows**. Legacy Node backend-only daemon/orchestrator/store paths are retained only for explicit `FOREMAN_BACKEND=node` operation or non-default local compatibility and are not part of the default Elixir operator path.

## Status legend

- **Elixir** — default operator path is routed through Elixir-backed APIs/projections/commands.
- **Guarded legacy** — command/subcommand is intentionally legacy-only and must require explicit `FOREMAN_BACKEND=node`.
- **Out of default path** — retained local/legacy compatibility behavior that is not used by the default registered-project Elixir operator workflow.

## Current operator-facing transition status

| Area / workflow | Current status | Evidence | Residual risk / retained legacy |
| --- | --- | --- | --- |
| `foreman attach --follow` | Elixir | `src/cli/commands/attach.ts` routes Elixir mode through `ElixirServerClient`; parity tests exist in `src/cli/__tests__/attach.test.ts`. | No known default-path transition blocker. |
| `foreman reset` | Elixir | `src/cli/commands/reset.ts` implements Elixir reset cleanup/preserve-worktree parity; tests in `src/cli/commands/__tests__/reset-elixir-dry-run.test.ts`. | No known default-path transition blocker. |
| `foreman doctor --fix` / `--clean-logs` | Elixir | `src/cli/commands/doctor.ts` and `src/cli/commands/__tests__/doctor-elixir.test.ts`. | No known default-path transition blocker. |
| Jira config / webhook CLI operations | Guarded legacy | `src/cli/commands/jira.ts` requires explicit `FOREMAN_BACKEND=node` before using the legacy tRPC Jira integration for configure/status/test/webhook commands. | Elixir stores imported Jira projection/config events, but the operator CLI Jira management commands are intentionally legacy-gated until an Elixir command/API path lands. |
| `foreman run` default dispatch | Elixir | `src/cli/commands/run.ts` routes default Elixir mode to the Elixir server scheduler tick and rejects Node-only dispatch-shaping/direct-task options unless `FOREMAN_BACKEND=node` is set. | Explicit Node mode retains the legacy Node dispatcher/orchestrator path. |
| `foreman run task` direct worker execution | Guarded legacy | `src/cli/commands/run-task.ts` rejects interactive/default use in Elixir mode unless `FOREMAN_BACKEND=node` is set; the hidden `--run-id` bridge remains for Elixir scheduler-launched Node/Pi workers. | Direct manual worker execution remains a legacy/debug compatibility path. |
| `foreman board` task rendering / updates | Elixir | `src/cli/commands/board.ts` uses Elixir task APIs/commands for the default registered-project path, and project lookup in Elixir mode resolves through Elixir-backed `listRegisteredProjects()` from `src/cli/commands/project-task-support.ts`. Focused board context/mutation tests cover Elixir field-default mapping and writes. | Explicit Node mode retains tRPC compatibility. |
| `foreman status` / `status --watch` | Elixir | `src/cli/commands/status.ts` computes default registered-project status snapshots/counts from Elixir task/run projections; watch uses Elixir-backed reads/mutations. Focused tests cover Elixir-mode status snapshots/counts and watch behavior. | Explicit Node mode retains legacy compatibility. |
| `foreman watch` dashboard state | Elixir | `src/cli/commands/watch/WatchState.ts` and `src/cli/dashboard-state.ts` use Elixir APIs/commands for default read and mutation paths (board summary, task counts, inbox/event polling, dashboard snapshots, `approve`, and `retry`). | Explicit Node mode retains legacy compatibility. |
| `foreman project register/list` | Elixir | `src/cli/commands/project.ts` supports Elixir-default `project register` and `project list`. | None for default project registration/listing. |
| `foreman project add/remove/edit` | Guarded legacy | Remaining daemon-only project subcommands are explicitly legacy-gated with `FOREMAN_BACKEND=node` guidance and focused tests. | These are intentionally not default Elixir commands. |
| Shared project resolution (`--project`, cwd project lookup) | Elixir | `src/cli/commands/project-task-support.ts` resolves registered projects through Elixir project projections in default mode; daemon/registry fallback is only a Node-mode/local compatibility path. | Explicit Node mode retains legacy compatibility. |
| Structured `foreman task create/list/show/approve/update/close` | Elixir | `src/cli/commands/task.ts` routes structured default task reads/writes through Elixir-backed APIs/commands; tests in `src/cli/__tests__/task-elixir-command-context.test.ts` verify no tRPC instantiation and fail-closed Elixir run activity. | Explicit Node mode retains tRPC/native compatibility. |
| `foreman task create --from-text` / `foreman bead` style natural-language generation | Guarded legacy | `src/cli/commands/task.ts` now rejects `--from-text` unless `FOREMAN_BACKEND=node` is set because it uses the legacy Node/beads task generator. | Elixir-native natural-language generation is not implemented in this transition. |
| `foreman task show-pr`, import helpers, and other adjunct task utilities | Out of default path | These are adjunct/compatibility utilities rather than the default structured task read/write path; import remains described as legacy daemon-backed. | Use explicit Node/legacy operation where needed. |
| `foreman inbox` / `inbox send` | Elixir | `src/cli/commands/inbox.ts` resolves default Elixir mode through `ElixirServerClient` for inbox reads, run/event lookup, and `inbox send`; tests cover Elixir event/message adapters and rendering. Elixir context errors are no longer swallowed into Node fallback. | Explicit Node mode and optional Postgres event reads remain compatibility paths. |
| `foreman plan` | Elixir | `src/cli/commands/plan.ts` uses an Elixir-backed planning task client in default Elixir mode for planning task create/read/update/close/dependency operations; `plan prd` / `plan trd` are server-backed. | Explicit Node mode retains planning-store compatibility. |
| `foreman recover` | Elixir | `src/cli/commands/recover.ts` uses Elixir run/inbox reads for the default registered-project path; Elixir context errors are no longer swallowed into daemon fallback. | Local store reads remain available only outside default Elixir backend resolution. |
| `foreman retry` | Elixir | `src/cli/commands/retry.ts` uses Elixir task/runs reads plus `task.update` and `scheduler/tick` for the default registered-project Elixir path, with tests proving no daemon tRPC in Elixir mode. | Explicit Node mode and unregistered local worktrees retain compatibility. |
| `foreman debug` | Elixir | `src/cli/commands/debug.ts` uses Elixir run/inbox reads for the default registered-project path; Elixir context errors are no longer swallowed into daemon fallback. | Local store artifact/log reads remain for filesystem artifacts, not backend state. |
| `foreman logs` | Elixir | `src/cli/commands/logs.ts` resolves run state through Elixir in Elixir mode and no longer falls back to local store on Elixir resolution failure. | Explicit Node mode may fall back to local store when daemon resolution is unavailable. |
| `foreman sling` | Elixir | `src/cli/commands/sling.ts` writes generated tasks through Elixir commands in default Elixir mode. | Explicit Node mode retains daemon writer compatibility. |
| Node daemon lifecycle (`foreman daemon start|restart`) | Guarded legacy | `src/lib/backend-mode.ts`, `README.md`, `docs/cli-reference.md`, and `docs/guides/elixir-backend-architecture.md` document/guard this as non-default after cutover. | Maintain explicit legacy gating only. |

## Residual `createTrpcClient()` imports

Several operator command files still import `createTrpcClient()`. These imports are retained for explicit `FOREMAN_BACKEND=node` compatibility, guarded legacy subcommands, or non-default local compatibility. Any default Elixir path that needs backend state must use `ElixirServerClient`/Elixir projections and must not silently fall back to tRPC/local store.

Files currently importing `createTrpcClient()` under `src/cli/commands/`:

- `attach.ts`
- `board.ts`
- `debug.ts`
- `inbox.ts`
- `jira.ts` (guarded legacy only)
- `logs.ts`
- `plan.ts`
- `project-task-support.ts`
- `project.ts`
- `recover.ts`
- `retry.ts`
- `sling.ts`
- `status.ts`
- `task.ts`
- `watch/WatchState.ts`

## Coverage and verification gate

Use `npm run test:coverage:transition` for the Elixir-transition coverage gate. It runs the normal Node coverage workflow and Elixir backend coverage, then writes `.foreman/coverage/transition-scope-summary.json`.

Current transition gate expectations:

- Node frontend/operator CLI plus Elixir-launched Node/Pi worker-bridge scope line coverage >= 70%.
- Node frontend/operator CLI plus Elixir-launched Node/Pi worker-bridge scope branch coverage >= 70%.
- Elixir backend line coverage from `mix test --cover` >= 70%.
- Elixir backend branch-site coverage >= 70%, reported from the same Mix cover HTML hit data over Elixir decision constructs (`if`/`unless`/`case`/`cond`/`with`).

Legacy Node backend-only daemon/orchestrator/store internals are outside this transition coverage target when they are not default operator-facing workflows.

## Exit condition for this inventory task

This inventory task is complete when:

- the file exists in `docs/reports/`,
- default operator-facing workflows are listed with Elixir/guarded-legacy status,
- intentionally retained legacy-only or out-of-default-path behavior is identified,
- and the document is good enough to support final verification without guesswork.
