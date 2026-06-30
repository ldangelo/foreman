# Elixir Transition Inventory

_Last updated: 2026-06-29_

## Goal of this inventory

Track the remaining work to complete the operator-facing transition from Node daemon/tRPC-backed workflows to Elixir-backed commands, projections, and server APIs.

This inventory is intentionally narrower than historical parity work: it focuses on **default operator-facing workflows** and whether they still depend on the legacy Node daemon/tRPC path.

## Status legend

- **Elixir** — default operator path is routed through Elixir-backed APIs/projections/commands.
- **Hybrid** — user-visible command has an Elixir path, but still depends on Node daemon/tRPC or local registry/store behavior for part of its default workflow.
- **Node-only** — default operator path still uses legacy Node daemon/tRPC behavior.
- **Guarded legacy** — command is intentionally legacy-only and must require explicit `FOREMAN_BACKEND=node`.

## Current operator-facing transition status

| Area / workflow | Current status | Evidence | What remains |
| --- | --- | --- | --- |
| `foreman attach --follow` | Elixir | `src/cli/commands/attach.ts` routes Elixir mode through `ElixirServerClient`; parity tests exist in `src/cli/__tests__/attach.test.ts`. | Keep coverage; no known transition blocker. |
| `foreman reset` | Elixir | `src/cli/commands/reset.ts` implements Elixir reset cleanup/preserve-worktree parity; tests in `src/cli/commands/__tests__/reset-elixir-dry-run.test.ts`. | Keep coverage; no known transition blocker. |
| `foreman doctor --fix` / `--clean-logs` | Elixir | `src/cli/commands/doctor.ts` and `src/cli/commands/__tests__/doctor-elixir.test.ts`. | Keep coverage; no known transition blocker. |
| Jira config / webhook projection state | Elixir | `packages/foreman_server/lib/foreman_server/command_router.ex`, `projection_store.ex`, tests in `packages/foreman_server/test/foreman_server_test.exs`. | Keep coverage; no known transition blocker. |
| `foreman board` task rendering / updates | Elixir | `src/cli/commands/board.ts` uses Elixir task APIs/commands for the default registered-project path, and project lookup in Elixir mode now resolves through Elixir-backed `listRegisteredProjects()` from `src/cli/commands/project-task-support.ts`. Focused board context tests cover the Elixir path. | Keep coverage; no known default-path transition blocker. |
| `foreman status` / `status --watch` | Elixir | `src/cli/commands/status.ts` now computes default registered-project status snapshots/counts from Elixir task/run projections, while `watch` already used Elixir-backed reads/mutations. Focused tests cover Elixir-mode status snapshots/counts and watch behavior. | Keep coverage; no known default-path transition blocker. |
| `foreman watch` dashboard state | Elixir | `src/cli/commands/watch/WatchState.ts` and `src/cli/dashboard-state.ts` now use Elixir APIs/commands for default read and mutation paths (board summary, task counts, inbox/event polling, dashboard snapshots, `approve`, and `retry`), with focused tests covering both Elixir and explicit Node mode behavior. | Keep coverage; no known default-path transition blocker in watch. |
| `foreman project add/list/remove` | Hybrid | `src/cli/commands/project.ts` now supports Elixir-default `project register` and `project list`, while the remaining daemon-only subcommands (`project add/remove/edit`) are explicitly legacy-gated with `FOREMAN_BACKEND=node` guidance and focused tests. | Decide whether to implement Elixir-native add/remove/edit later or leave them explicitly legacy-gated/documented as non-default operations. |
| Shared project resolution (`--project`, cwd project lookup) | Elixir | `src/cli/commands/project-task-support.ts` resolves registered projects through Elixir project projections in default mode; daemon/registry fallback is now a Node-mode/local compatibility path rather than part of the default Elixir workflow. | Keep coverage and re-audit any residual compatibility fallback during docs/cleanup. |
| `foreman task ...` | Hybrid | `src/cli/commands/task.ts` now routes structured `task create`, `task list`, `task show`, `task approve`, `task update`, and `task close` through Elixir-backed reads/commands in default mode, with focused tests proving those paths do not instantiate daemon tRPC. The remaining task-family gaps are mainly adjunct capabilities (`show-pr`, richer PR-state/dependency/note parity), import helpers, and the `--from-text` creation path, which still depend on daemon/native-store-era code paths. | Continue porting the remaining adjunct/import/task-generation paths to Elixir-backed APIs/commands, or explicitly legacy-gate any intentionally retained paths. |
| `foreman inbox` / `inbox send` | Hybrid | `src/cli/commands/inbox.ts` now resolves default Elixir mode through `ElixirServerClient` for inbox reads, run/event lookup, and `inbox send`; targeted tests prove Elixir mode does not instantiate daemon tRPC for these paths. The file still carries legacy/local fallback scaffolding and dead Postgres-era branches that should be removed once the remaining transition settles. | Re-audit and simplify remaining fallback scaffolding; keep only explicitly documented legacy paths. |
| `foreman plan` | Hybrid | `src/cli/commands/plan.ts` now uses an Elixir-backed planning task client in default Elixir mode for planning task create/read/update/close/dependency operations, while the explicit planning server subcommands (`plan prd` / `plan trd`) were already Elixir-native. Focused tests cover both default Elixir and explicit Node behavior. | Re-audit whether any remaining local/native planning-store assumptions are still operator-facing in default mode. |
| `foreman recover` | Hybrid | `src/cli/commands/recover.ts` now uses Elixir run/inbox reads for the default registered-project path, with focused tests proving Elixir-mode recover does not instantiate daemon tRPC. Local/unregistered recovery fallback remains for explicit local operation. | Re-audit whether any remaining local/native recovery assumptions are still operator-facing in default mode. |
| `foreman retry` | Hybrid | `src/cli/commands/retry.ts` now uses Elixir task/runs reads plus `task.update` and `scheduler/tick` for the default registered-project Elixir path, with focused tests proving that Elixir-mode retry does not instantiate daemon tRPC. Legacy/local retry behavior remains available in explicit Node mode and for unregistered local worktrees. | Remove or explicitly legacy-gate the remaining local/unregistered retry path if it remains operator-facing in default workflows. |
| `foreman debug` / `foreman logs` / `foreman sling` | Hybrid | `src/cli/commands/debug.ts`, `logs.ts`, and `sling.ts` now use Elixir-backed run/task/inbox/task-write paths for the default registered-project flow, with focused tests proving default Elixir-mode debug/logs/sling avoid daemon tRPC. Remaining risk in this area is mostly residual local/legacy fallback code, not the default registered-project path. | Re-audit whether any residual local/legacy fallback in these commands should remain operator-facing or be explicitly legacy-gated/documented. |
| Node daemon lifecycle (`foreman daemon start|restart`) | Guarded legacy | `src/lib/backend-mode.ts`, `README.md`, `docs/cli-reference.md`, and `docs/guides/elixir-backend-architecture.md` document/guard this as non-default after cutover. | Maintain explicit legacy gating only. |

## Confirmed code-level transition blockers

### 1. Residual `createTrpcClient()` imports still need audit

Several operator commands still import `createTrpcClient()`, but after the transition work most default Elixir paths no longer instantiate it. The remaining work is to distinguish:

- imports that are now only used in explicit Node mode or local compatibility paths,
- imports that support intentionally legacy-gated subcommands,
- and any true remaining default-path dependency.

### 2. `createTrpcClient()` is still imported by many operator commands

Files currently importing `createTrpcClient()` under `src/cli/commands/`:

- `attach.ts`
- `board.ts`
- `debug.ts`
- `inbox.ts`
- `jira.ts`
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

Not every import is automatically a remaining blocker, but any **default Elixir path** that still requires this client is a transition gap until it is removed or explicitly legacy-gated.

### 3. Remaining user-visible transition work is now mostly cleanup and documentation

The earlier operator failures around `status --watch`, `board`, and missing `project register` have been addressed by the Elixir-first registration/discovery work. The remaining user-visible transition work is now mainly:

- documenting which `project` subcommands are explicitly legacy-gated,
- deciding whether those legacy-gated paths should remain or get Elixir replacements,
- and simplifying residual local/legacy fallback scaffolding where it is no longer needed.

## Recommended work order

1. **Elixir-first project identity / registration resolution**
   - Unify how current repo/project identity is resolved in default mode.
   - Remove reliance on daemon-era registration for `status`, `board`, and other cwd-based commands.

2. **High-frequency operator workflows**
   - Finish `status`, `board`, and `watch`.
   - These are the most visible day-to-day commands and currently expose the registration gap.

3. **Task and inbox surfaces**
   - Port `task`, `inbox`, `retry`, `recover`, and `plan` default flows away from daemon tRPC.

4. **Project command family**
   - Decide and implement the Elixir-default replacement for `foreman project add/list/remove`, or explicitly constrain them to legacy mode with clear docs if the goal allows that. Current goal suggests removing practical Node dependencies from operator-facing workflows, so this likely needs an Elixir-backed implementation.

5. **Coverage and verification**
   - Add/adjust tests per migrated command path.
   - Use `npm run test:coverage:transition` for the Elixir-transition coverage gate: Node frontend transition bridge line/branch coverage must be at least 70%, and Elixir backend line coverage from `mix test --cover` must be at least 70%.
   - Legacy Node backend-only daemon/orchestrator/store paths are outside this transition coverage target when they are not default operator-facing workflows.

## Exit condition for this inventory task

This inventory task is complete when:

- the file exists in `docs/reports/`,
- the remaining operator-facing Node dependencies are explicitly listed,
- the highest-priority blockers are identified with concrete code references,
- and the document is good enough to drive the next implementation step without guesswork.
