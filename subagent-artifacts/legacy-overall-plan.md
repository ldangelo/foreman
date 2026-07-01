# Code Context

## Files Retrieved
1. `docs/reports/legacy-node-backend-removal-inventory.md` (lines 1-121) - source inventory for remaining guarded paths, dispositions, retained bridge/frontend boundaries, test expectations, open product decisions.
2. `src/cli/commands/project.ts` (lines 1-240, 305-379 via grep) - `project add/remove/edit` still hard-gated by `requireNodeProjectCommand`; `register/list` already use Elixir support.
3. `src/cli/commands/jira.ts` (lines 1-220, 232-264 via grep) - all Jira management commands hard-gated by `requireNodeJiraLegacy` and tRPC.
4. `src/lib/backend-mode.ts` (lines 1-32) - default backend is Elixir; Node daemon allowed only under explicit Node mode and migration incomplete.
5. `src/cli/commands/daemon.ts` (lines 1-180) - Node daemon lifecycle product surface remains (`start/stop/status/restart`) and uses `DaemonManager`.
6. `src/cli/commands/run.ts` (lines 580-660) - Elixir default scheduler tick exists; legacy direct-dispatch/resume/dispatch-shaping flags still emit `FOREMAN_BACKEND=node` guidance.
7. `src/cli/commands/run-task.ts` (lines 1-180; grep line 590) - direct operator command is blocked, but file also contains worker/direct execution plumbing likely needed for internal `--run-id` bridge.
8. `src/cli/commands/task.ts` (lines 940-1010; grep lines 84, 360) - normal task create has Elixir path, but `--from-text` is legacy-gated and file still has tRPC helpers.
9. `src/cli/commands/bead.ts` (lines 1-58) - hidden deprecated alias still exposes legacy-only generator gate.
10. `src/cli/commands/project-task-support.ts` (lines 1-121) - shared project registry helper uses Elixir when default, tRPC/ProjectRegistry in Node mode.
11. `packages/foreman_server/lib/foreman_server/command_router.ex` (lines 1-145) - Elixir accepts `project.register` and task commands; no project archive/update/Jira domain commands found.
12. `src/lib/elixir-server-client.ts` (lines 90-142 via grep) - TS client already supports `sendCommand`, `listProjects`, `getTask`, `schedulerTick`.

## Key Code

- `src/lib/backend-mode.ts:12-18`: `foremanBackendMode()` defaults to `elixir`; only explicit `FOREMAN_BACKEND=node` selects Node.
- `src/lib/backend-mode.ts:20-32`: `nodeDaemonAllowed()` still permits Node daemon when `FOREMAN_BACKEND=node` and migration not complete; message still advertises explicit legacy operation.
- `src/cli/commands/project.ts:83-91`: `requireNodeProjectCommand(subcommand)` exits in Elixir mode with `Set FOREMAN_BACKEND=node`.
- `src/cli/commands/project.ts:176-177`, `305-307`, `377-379`: `add`, `remove`, `edit` call the guard then `createTrpcClient()`.
- `src/cli/commands/project-task-support.ts:31-42`: Elixir project list path already exists via `ElixirServerManager` + `ElixirServerClient.listProjects()`.
- `src/cli/commands/project-task-support.ts:80-120`: `registerProjectInElixir()` sends `project.register` command. Reuse this shape for `project add` if kept as local registration, or add new Elixir command types for archive/update.
- `packages/foreman_server/lib/foreman_server/command_router.ex:121-143`: only `project.register` domain event exists for project lifecycle. Need `project.archive/remove/update` if keeping remove/edit.
- `src/cli/commands/jira.ts:35-42`, `84-86`, `140-142`, `188-190`, `232-234`, `262-264`: all Jira subcommands are Node/tRPC-only.
- `src/cli/commands/run.ts:616-626`: legacy operator flags still advise Node mode. For goal, remove options or convert to hard unsupported messages with no `FOREMAN_BACKEND=node` path.
- `src/cli/commands/run-task.ts:589-591`: operator direct worker path is blocked; preserve internal bridge path only (hidden `--run-id`).
- `src/cli/commands/task.ts:979-981`: `task create --from-text` still advertises legacy Node/beads gate.
- `src/cli/commands/bead.ts:43-48`: hidden `foreman bead` still advertises explicit Node legacy operation.
- Residual command tRPC markers from grep: `attach.ts`, `board.ts`, `debug.ts`, `inbox.ts`, `logs.ts`, `plan.ts`, `recover.ts`, `retry.ts`, `sling.ts`, `status.ts`, `task.ts`, `watch/WatchState.ts`, `project-task-support.ts`, `project.ts`, `jira.ts`.

## Architecture

- Current default CLI flow is mixed:
  - Elixir-backed default: project `register/list`, task normal create/update/status, scheduler tick in `foreman run`, watch/status paths in many commands.
  - Legacy Node explicit mode: tRPC daemon client via `createTrpcClient()`, Node daemon lifecycle via `DaemonManager`, local/Postgres store/orchestrator helpers.
  - Worker bridge: Node CLI/orchestrator code is still required when Elixir scheduler launches Node/Pi workers. Do not delete `run-task.ts`/worker/orchestrator wholesale.
- Elixir command boundary is `/api/v1/commands` through `ElixirServerClient.sendCommand()`. Server maps known `command_type` strings in `CommandRouter.domain_event/2` to events/projections.
- Project lifecycle gap: Elixir has register/list only. `remove/edit` need new server events/projection handling, or CLI removal messages. `add` product semantics are ambiguous: old command clones GitHub; existing Elixir `register` only registers local repos.
- Jira gap: server has ingestion source support for Jira, but no CLI integration config/status/test/webhook command surface found. Rebuild requires new config storage/events + API/test client, not just TS CLI rewiring.
- Deletion order matters: first remove/replace operator tRPC callers; then delete daemon/tRPC/local backend implementations. Deleting backend first risks breaking bridge/tests and many command imports.

## Implementation Plan

### P0 - Stop advertising Node legacy to operators
- Severity: blocker. Files:
  - `src/cli/commands/project.ts`
  - `src/cli/commands/jira.ts`
  - `src/cli/commands/run.ts`
  - `src/cli/commands/task.ts`
  - `src/cli/commands/bead.ts`
  - `src/cli/commands/daemon.ts`
  - `src/lib/backend-mode.ts`
  - docs: `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`/`AGENTS.md` if they mention rollback/legacy.
- Change:
  - Remove `FOREMAN_BACKEND=node` suggestions from operator-facing errors.
  - Prefer clear messages: “removed after Elixir cutover” or “unsupported; use X”.
  - Keep `FOREMAN_BACKEND=node` only in tests/fixtures or explicitly approved internal bridge docs, if any.

### P0 - Project lifecycle replacement/removal
- Severity: blocker. Files:
  - TS: `src/cli/commands/project.ts`, `src/cli/commands/project-task-support.ts`, `src/lib/elixir-server-client.ts` if adding typed helpers.
  - Elixir: `packages/foreman_server/lib/foreman_server/command_router.ex`, projection/store modules for project events (search next for `ProjectRegistered`).
  - Tests: `src/cli/__tests__/project.test.ts`, `src/cli/__tests__/project-register-command.test.ts`, Elixir command/projection tests.
- Likely path:
  - Keep `project register` as canonical local repo registration.
  - Dangerous decision: decide whether `project add` remains. Safer minimal removal: make `project add` say “removed; clone repo yourself then `foreman project register`”. If product wants clone+register, implement clone in CLI then call Elixir register; avoid daemon/tRPC.
  - Implement `project remove` as Elixir `project.archive` event + projection filter/status update if operator needs it.
  - Implement `project edit` only for fields Elixir projections actually support (`name`, `default_branch`, `status`). Remove Jira flags from `project edit/add` unless Jira config is rebuilt.

### P0 - Jira management decision
- Severity: blocker/dangerous product call. Files:
  - `src/cli/commands/jira.ts`
  - Elixir command/config modules if rebuilt
  - docs/tests listed above.
- Recommended minimal route: remove/disable `foreman jira configure/status/test/enable-webhook/disable-webhook` from product surface with clear Elixir-cutover message, unless user explicitly wants new integration management now.
- Rebuild route is larger: add secure config storage, credential encryption, status projection/API, webhook toggle semantics, Jira connectivity test in Elixir. Current server grep only shows ingestion handling, not management APIs.

### P0 - Run/task/bead legacy paths
- Severity: blocker. Files:
  - `src/cli/commands/run.ts`
  - `src/cli/commands/run-task.ts`
  - `src/cli/commands/task.ts`
  - `src/cli/commands/bead.ts`
  - `src/cli/commands/create-from-text.ts` if deletion follows.
  - Tests: `src/cli/__tests__/run-auto-dispatch.test.ts`, run tests, `src/cli/__tests__/task.test.ts`, `src/cli/__tests__/bead.test.ts`, create-from-text tests.
- Change:
  - Remove or hide `foreman run --task/--bead`, `--resume`, `--resume-failed`, `--no-pipeline`, `--workflow`, `--stagger`, `--telemetry`, `--no-auto-dispatch`, explicit `--max-agents` if no Elixir equivalent.
  - Keep normal `foreman run` Elixir scheduler tick.
  - Preserve `foreman run task --run-id` internal bridge; ensure operator invocation without `--run-id` fails without Node guidance.
  - Remove `task create --from-text` and hidden `foreman bead`, or rewrite as Elixir `task.create` generator. Minimal route: removal message + docs.

### P1 - Residual tRPC/local backend cleanup after callers gone
- Severity: high. Files likely to change:
  - `src/lib/trpc-client.ts`, `src/lib/daemon-manager.ts`, `src/daemon/**`
  - `src/lib/store.ts`, `src/lib/postgres-store.ts`, `src/lib/db/postgres-adapter.ts`, `src/lib/project-registry.ts`
  - `src/lib/task-client-factory.ts`, `src/lib/native-task-client.ts`, `src/lib/task-store.ts`, `src/lib/beads*.ts`, `src/lib/tasks.ts`
  - `src/orchestrator/dispatcher*.ts`, `task-backend-ops.ts`, `store-read-model-adapter.ts`, merge/finalize helpers only after bridge audit.
- Do not delete until grep shows no unapproved operator callers. Worker bridge likely still needs parts of orchestrator, VCS, workflow, prompts, artifacts, setup, worker env, Postgres task mirror.

### P1 - Command tRPC branches outside inventory
- Severity: high. Grep found `createTrpcClient()` in:
  - `attach.ts`, `board.ts`, `debug.ts`, `inbox.ts`, `logs.ts`, `plan.ts`, `recover.ts`, `retry.ts`, `sling.ts`, `status.ts`, `task.ts`, `watch/WatchState.ts`, `project-task-support.ts`.
- Plan:
  - For each command, confirm Elixir path exists and remove Node fallback branch.
  - If branch is only for explicit Node mode, delete branch or fail closed with no operator legacy guidance.
  - Update tests named `*-br-backend`, `*-node`, `*-local-fallback`, `project-task-support-node.test.ts` to either remove or convert to guard tests.

### P1 - Tests and guardrails
- Add/update tests:
  - `src/cli/__tests__/project.test.ts`: add/remove/edit no longer require `FOREMAN_BACKEND=node`; assert Elixir command sent or removal message.
  - `src/cli/__tests__/project-register-command.test.ts`: keep register/list Elixir behavior.
  - `src/cli/__tests__/jira*.test.ts` new/updated: removed messages or Elixir-backed config/status/test.
  - `src/cli/__tests__/run*.test.ts`: legacy flags no longer mention `FOREMAN_BACKEND=node`; scheduler tick still works.
  - `src/cli/__tests__/run-task*.test.ts`: operator direct run removed; hidden `--run-id` bridge remains.
  - `src/cli/__tests__/task.test.ts`, `bead.test.ts`: from-text/bead removed or Elixir-backed.
  - New grep/transition test: fail if command files contain `FOREMAN_BACKEND=node`, `requireNode*`, or unapproved `createTrpcClient()`.
  - Elixir tests for any new `project.archive/update` events/projections.
- Required validation commands after implementation:
  - `npx tsc --noEmit`
  - `npm run test:coverage:transition`
  - `npm test`
  - `cd packages/foreman_server && mix test`
  - targeted Vitest for touched command tests.

## Start Here
Open `src/cli/commands/project.ts` first. It has a contained guarded path (`add/remove/edit`), an existing Elixir registration helper to reuse, and it exposes the first hard product decision: remove `project add` in favor of `project register` or implement clone+register without Node daemon.

## Supervisor coordination
No blocker for scouting. Dangerous decisions for parent/user:
1. `project add`: remove in favor of clone + `project register`, or keep as clone+register Elixir-backed.
2. Jira management: remove now, or fund a full Elixir integration management rebuild.
3. `run task`: keep only hidden `--run-id` bridge, or add an Elixir debug/rerun command.
4. Legacy TS delegation and Node daemon explicit mode: delete outright, or approve as rollback exception.
5. Backend deletion: approve isolation of any required worker-bridge stores/orchestrator pieces before deleting broad `src/orchestrator/**` or Postgres helpers.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Reviewed legacy inventory plus source markers; findings include concrete file paths, line ranges, severity, planned file-level changes, tests, and dangerous decisions."
    }
  ],
  "changedFiles": [
    "subagent-artifacts/legacy-overall-plan.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "read docs/reports/legacy-node-backend-removal-inventory.md",
      "result": "passed",
      "summary": "Loaded inventory and dispositions."
    },
    {
      "command": "grep requireNode|FOREMAN_BACKEND=node|createTrpcClient\\(|FOREMAN_LEGACY|daemon start|legacy src --glob *.ts",
      "result": "passed",
      "summary": "Mapped legacy guards, tRPC callers, daemon references."
    },
    {
      "command": "grep requireNode|FOREMAN_BACKEND=node|createTrpcClient\\( src/cli/commands --glob *.ts",
      "result": "passed",
      "summary": "Identified residual command-level tRPC/legacy markers."
    },
    {
      "command": "grep project.register|project.archive|jira|webhook packages/foreman_server/lib",
      "result": "passed",
      "summary": "Found Elixir project.register and Jira ingestion only; no project archive/update or Jira management command support found."
    }
  ],
  "validationOutput": [
    "Scout only. No tests run. No product files edited."
  ],
  "residualRisks": [
    "Product decisions needed for project add, Jira management, run task debug replacement, legacy TS delegation, and exact backend deletion boundary around worker bridge.",
    "Grep output was targeted, not exhaustive full AST reachability. Follow-up should use strict grep guard and test coverage after changes."
  ],
  "noStagedFiles": true,
  "diffSummary": "Wrote scouting plan artifact only; no source/docs/tests changed.",
  "reviewFindings": [
    "blocker: src/cli/commands/project.ts:83 - project add/remove/edit still require legacy Node mode and use tRPC.",
    "blocker: src/cli/commands/jira.ts:35 - all Jira management commands still require legacy Node/tRPC.",
    "blocker: src/cli/commands/run.ts:616 - direct dispatch/resume/dispatch-shaping flags still advise FOREMAN_BACKEND=node.",
    "blocker: src/cli/commands/task.ts:979 - task create --from-text still requires legacy Node/beads generator.",
    "blocker: src/cli/commands/bead.ts:43 - hidden bead alias still exposes legacy Node generator guidance.",
    "high: src/cli/commands/daemon.ts:44 - daemon lifecycle remains operator-visible and backed by Node DaemonManager.",
    "high: src/cli/commands/* - residual createTrpcClient callers remain in attach/board/debug/inbox/logs/plan/recover/retry/sling/status/task/watch/project-task-support."
  ],
  "manualNotes": "Preserve Node CLI/frontend and Elixir-launched Node/Pi worker bridge. Do not delete run-task/orchestrator/store pieces until bridge dependencies are audited."
}
```