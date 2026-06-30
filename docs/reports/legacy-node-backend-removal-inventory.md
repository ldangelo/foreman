# Legacy Node Backend Removal Inventory

_Last updated: 2026-06-30_

## Purpose

This inventory identifies remaining Node backend/server dependencies after the Elixir cutover and assigns each one a disposition for the legacy-removal goal.

The goal scope preserves the Node CLI/frontend and the Elixir-launched Node/Pi worker bridge. The removals below target the old Node daemon/tRPC/local/Postgres control plane and operator-facing paths that still require `FOREMAN_BACKEND=node`.

## Disposition legend

- **Replace with Elixir** — keep the operator behavior, but route through Elixir APIs/events/projections.
- **Remove product surface** — delete or hide the command/option because it is obsolete after Elixir cutover.
- **Delete backend implementation** — remove old Node backend/server code after callers are gone.
- **Retain bridge/frontend** — keep because it belongs to the Node CLI/frontend or Elixir-launched worker bridge, not the legacy backend.
- **Needs decision** — behavior is likely obsolete, but needs a product call before deletion.

## Operator commands currently requiring or advertising `FOREMAN_BACKEND=node`

| Path | Evidence | Current behavior | Planned disposition |
| --- | --- | --- | --- |
| `foreman project add` | `src/cli/commands/project.ts` calls `requireNodeProjectCommand("add")`. | Guarded legacy tRPC project creation. | **Replace with Elixir** local project registration or remove if `project register` is the only supported add path. |
| `foreman project remove` | `src/cli/commands/project.ts` calls `requireNodeProjectCommand("remove")`. | Guarded legacy daemon archive/remove. | **Replace with Elixir** project archive/remove event + projection filtering. |
| `foreman project edit` | `src/cli/commands/project.ts` calls `requireNodeProjectCommand("edit")`. | Guarded legacy daemon project/Jira config mutation. | **Replace with Elixir** project settings/config commands or split unsupported Jira config into removed surface. |
| `foreman jira configure` | `src/cli/commands/jira.ts` calls `requireNodeJiraLegacy()`. | Guarded legacy tRPC Jira configuration. | **Replace with Elixir** integration config commands/events or **remove product surface** if Jira management is no longer supported. |
| `foreman jira status` | `src/cli/commands/jira.ts` calls `requireNodeJiraLegacy()`. | Guarded legacy tRPC Jira status. | **Replace with Elixir** integration projection/status endpoint or remove. |
| `foreman jira test` | `src/cli/commands/jira.ts` calls `requireNodeJiraLegacy()`. | Guarded legacy tRPC Jira credential/connectivity test. | **Replace with Elixir** integration test command or remove. |
| `foreman jira enable-webhook` / `disable-webhook` | `src/cli/commands/jira.ts` calls `requireNodeJiraLegacy()`. | Guarded legacy tRPC webhook toggle. | **Replace with Elixir** integration config mutation or remove. |
| `foreman run --task` / `--bead` | `src/cli/commands/run.ts` rejects unless Node mode. | Legacy direct dispatch through Node dispatcher. | **Remove product surface** or map to an Elixir scheduler/debug command if a direct dispatch use case remains. |
| `foreman run --resume` / `--resume-failed` | `src/cli/commands/run.ts` rejects unless Node mode. | Legacy Node recovery path. | **Remove product surface**; `foreman retry`/Elixir recovery should own this. |
| `foreman run --no-pipeline`, `--workflow`, `--stagger`, `--telemetry`, `--no-auto-dispatch`, `--model`, explicit `--max-agents` | `src/cli/commands/run.ts` rejects Node-only dispatch-shaping options. | Legacy Node dispatcher controls. | **Remove product surface** or reintroduce only via Elixir scheduler config if needed. |
| `foreman run task` operator use | `src/cli/commands/run-task.ts` rejects unless Node mode; hidden `--run-id` bridge remains. | Legacy direct worker/debug path. | **Remove product surface** for operator use; **retain bridge/frontend** for Elixir scheduler-launched `--run-id` worker bridge. |
| `foreman task create --from-text` | `src/cli/commands/task.ts` rejects unless Node mode. | Legacy Node/beads natural-language generator. | **Replace with Elixir** task-generation command or **remove product surface**. |
| Hidden `foreman bead` | `src/cli/commands/bead.ts` rejects unless Node mode. | Legacy alias for natural-language generator. | **Remove product surface**. |
| `foreman daemon start` / `restart` | `src/lib/backend-mode.ts`, `src/cli/commands/daemon.ts`, docs. | Node daemon scheduler blocked by default. | **Remove product surface** or convert to a hard deprecation message; delete daemon manager after callers/tests are gone. |
| Legacy TS delegation envs | `FOREMAN_LEGACY_COMPATIBILITY_MODE`, `FOREMAN_LEGACY_TS_BIN` documented in README/user guide/CLI reference. | Can delegate to legacy TypeScript CLI only with `FOREMAN_BACKEND=node`. | **Remove product surface** unless user explicitly approves retaining rollback delegation. |

## Residual tRPC/client touchpoints

`createTrpcClient()` is the clearest marker for the old Node daemon socket. Current source touchpoints outside tests:

| File | Current use | Planned disposition |
| --- | --- | --- |
| `src/lib/trpc-client.ts` | tRPC Unix-socket client implementation and parity-gap message. | **Delete backend implementation** after all callers are removed. |
| `src/daemon/index.ts` | Node daemon process uses tRPC client internally. | **Delete backend implementation** with the daemon. |
| `src/cli/commands/project.ts` | Node-mode add/remove/edit/list fallback. | Replace add/remove/edit with Elixir or remove; then drop tRPC fallback. |
| `src/cli/commands/jira.ts` | All Jira CLI management commands. | Replace with Elixir integration commands or remove. |
| `src/cli/commands/run.ts` / `run-task.ts` related callers | Node dispatcher/direct-worker paths. | Remove operator Node paths; keep hidden worker bridge only if it does not require tRPC. |
| `src/cli/commands/task.ts` | Node-mode task reads/writes and `--from-text` path. | Remove tRPC task client; keep Elixir task client. |
| `src/cli/commands/status.ts` | Node-mode status compatibility. | Remove after local/tRPC fallback tests are retired. |
| `src/cli/dashboard-state.ts` and `src/cli/commands/watch/WatchState.ts` | Node-mode dashboard/watch compatibility helpers. | Remove tRPC branches; keep Elixir dashboard/watch path. |
| `src/cli/commands/attach.ts`, `debug.ts`, `inbox.ts`, `logs.ts`, `plan.ts`, `recover.ts`, `retry.ts`, `sling.ts`, `board.ts`, `project-task-support.ts` | Mostly explicit Node-mode or local compatibility branches after Elixir cutover. | Remove tRPC branches once Elixir equivalents are confirmed. |

## Node backend/server implementation candidates

These modules are candidates for deletion once operator callers/tests are removed:

- `src/daemon/**` — old Node daemon, routers, Jira/GitHub pollers/webhook handlers.
- `src/lib/trpc-client.ts` — daemon socket client.
- `src/lib/daemon-manager.ts` — Node daemon lifecycle helper.
- `src/lib/store.ts` — local SQLite/legacy run/task store used by old backend compatibility paths.
- `src/lib/postgres-store.ts`, `src/lib/db/postgres-adapter.ts`, `src/lib/postgres-mail-client.ts`, `src/lib/project-registry.ts` — old Node/Postgres control-plane stores/adapters, unless a specific worker-bridge call still requires them temporarily.
- `src/lib/task-client-factory.ts`, `src/lib/native-task-client.ts`, `src/lib/task-store.ts`, `src/lib/beads-rust.ts`, `src/lib/beads.ts`, `src/lib/seeds.ts` — legacy task backend/beads compatibility; delete or isolate if not needed by Elixir-backed imports/tests.
- `src/orchestrator/dispatcher.ts`, `dispatcher-dependencies.ts`, `refinery.ts`, `refinery-agent*.ts`, `postgres-merge-queue.ts`, `postgres-merge-cost-tracker.ts`, `merge-queue.ts`, `sentinel.ts`, `task-backend-ops.ts`, `store-read-model-adapter.ts`, `read-models.ts`, `write-models.ts` — old Node orchestration/control-plane pieces. Audit carefully because some merge/finalize/worker helpers may still be used by the Elixir-launched worker bridge.

## Explicitly retained areas

These are not removal targets under the current goal unless a later goal tweak expands scope:

- `src/cli/**` command parsing/rendering for Elixir-backed behavior.
- `src/lib/elixir-server-client.ts` and `src/lib/elixir-server-manager.ts`.
- Node/Pi worker bridge code required by Elixir scheduler launches, including Pi SDK phase execution, workflow loading, prompts, logs, artifacts, VCS helpers, and worker protocol support.
- VCS abstraction and generic frontend libraries used by the Node CLI or worker bridge.

## Tests to add/update

- For every removed gated command/option, add/update tests proving the command no longer advises `FOREMAN_BACKEND=node` and either calls the Elixir API or reports removal.
- Add project lifecycle tests for Elixir-backed archive/remove if implemented.
- Add Jira integration command tests for Elixir-backed replacements or removal messages.
- Add grep-based or script-based guard test for unapproved `FOREMAN_BACKEND=node`, `requireNode*`, and `createTrpcClient()` references in operator command files.

## Open decisions

1. Should `foreman project add` be removed in favor of `foreman project register`, or should it clone/register GitHub repos through Elixir?
2. Should Jira management commands be rebuilt in Elixir now, or removed until integration management is reintroduced?
3. Should `foreman run task` be replaced with an Elixir debug/retry command for manual reruns, or should the operator-facing direct worker command disappear entirely?
4. Should legacy TypeScript delegation (`FOREMAN_LEGACY_COMPATIBILITY_MODE`) be deleted outright, or retained as an explicitly approved rollback exception?
