# Code Context

## Files Retrieved
1. `src/cli/commands/project.ts` (lines 83-90, 156-218, 223-240, 252-290, 301-318, 362-406) - current project CLI surface; add/remove/edit gated to Node, register/list already Elixir-aware.
2. `src/cli/commands/project-task-support.ts` (lines 1-113) - Elixir helper pattern for register/list; owns server manager/client and `project.register` command payload.
3. `src/lib/elixir-server-client.ts` (lines 1-104, 188-204) - available HTTP client; has `sendCommand()` and `listProjects()`, no project update/archive helpers yet.
4. `packages/foreman_server/lib/foreman_server/command_router.ex` (lines 1-134) - command boundary; only `project.register` domain event exists for projects.
5. `packages/foreman_server/lib/foreman_server/projection_store.ex` (lines 1-153) - project projection list/get and `ProjectRegistered` reducer; no project updated/archived reducer yet.
6. `packages/foreman_server/lib/foreman_server/http/router.ex` (lines 53-72, 401-424) - project read endpoints and generic command POST route; no project-specific write endpoints needed.
7. `src/cli/__tests__/project-register-command.test.ts` (lines 1-106) - existing mock style for Elixir project CLI tests.
8. `src/cli/__tests__/project-legacy-gates.test.ts` (lines 1-60) - tests that must change when remove/edit become Elixir-backed.
9. `src/cli/__tests__/project-node-command.test.ts` (lines 75-170 from grep context) - existing Node-mode edit/add Jira behavior tests; keep or scope to Node mode.
10. `packages/foreman_server/test/foreman_server_test.exs` (lines 88-117) - current project.register command/projection test location.
11. `packages/foreman_server/test/projection_store_test.exs` (lines 1-158) - projection reducer/rebuild test location.

## Key Code

Current blockers:

```ts
// src/cli/commands/project.ts:83-90
function requireNodeProjectCommand(subcommand: string): void {
  if (foremanBackendMode() !== "elixir") return;
  console.error(chalk.red(
    `Error: 'foreman project ${subcommand}' is legacy Node-backed only. Set FOREMAN_BACKEND=node for explicit legacy operation.`,
  ));
  process.exit(1);
}
```

```ts
// src/cli/commands/project.ts:177,306,378
requireNodeProjectCommand("add");
requireNodeProjectCommand("remove");
requireNodeProjectCommand("edit");
```

Existing Elixir pattern:

```ts
// src/cli/commands/project-task-support.ts:78-113
export async function registerProjectInElixir(projectPath, opts = {}) {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
  const response = await client.sendCommand({
    command_id: `project-register-${projectId}-${randomUUID()}`,
    command_type: "project.register",
    payload: { project_id: projectId, path: resolvedPath, status: projectStatus, default_branch: defaultBranch, config: { name }, health: { ok: true } },
  });
}
```

Existing Elixir event/projection:

```elixir
# packages/foreman_server/lib/foreman_server/command_router.ex:121-134
defp domain_event("project.register", payload) do
  project_id = Map.get(payload, :project_id) || Map.get(payload, :id)
  with {:ok, project_id} <- required_binary(project_id, :project_id),
       {:ok, path} <- required_binary(Map.get(payload, :path), :path) do
    {:ok, "ProjectRegistered", %{project_id: project_id, path: path, status: Map.get(payload, :status, "active"), default_branch: Map.get(payload, :default_branch, "main"), config: Map.get(payload, :config, %{}), health: Map.get(payload, :health, %{ok: true})}, "project:#{project_id}"}
  end
end
```

```elixir
# packages/foreman_server/lib/foreman_server/projection_store.ex:133-153
defp apply_domain_event(projection, %{type: "ProjectRegistered", payload: %{project_id: project_id} = payload}, _mode) do
  project = %{project_id: project_id, path: Map.fetch!(payload, :path), status: Map.get(payload, :status, "active"), default_branch: Map.get(payload, :default_branch, "main"), config: Map.get(payload, :config, %{}), health: Map.get(payload, :health, %{ok: true}), updated_at: Map.get(payload, :updated_at)}
  put_in(projection, [:projects, project_id], project)
end
```

## Architecture

- CLI project command has split backend behavior:
  - `register`: always calls `registerProjectInElixir()`.
  - `list`: Elixir mode calls `listRegisteredProjects()`, Node mode calls tRPC.
  - `add/remove/edit`: currently call `requireNodeProjectCommand()`, then Node tRPC.
- Elixir server already supports generic `POST /api/v1/commands`; adding project lifecycle needs only new `command_type`s in `CommandRouter.domain_event/2` and reducers in `ProjectionStore`.
- Smallest Elixir-backed remove/archive:
  1. Add `domain_event("project.archive", payload)` or `"project.remove"` in `command_router.ex`.
  2. Require `project_id`; emit `ProjectArchived` on stream `project:<id>` with status `"archived"`, maybe `force` and `reason` as audit metadata only.
  3. Add reducer for `ProjectArchived` that merges existing project and sets `status: "archived"`, `archived_at`, `updated_at`. If missing project, either creates tombstone or rejects earlier. Smallest safe product behavior: reject missing project before append.
  4. CLI helper `archiveProjectInElixir(projectId, opts)` sends command and CLI `remove` uses it in Elixir mode; Node mode keeps tRPC path until removed later.
- Smallest Elixir-backed edit:
  1. Add `domain_event("project.update", payload)`.
  2. Require `project_id`; accept `name`, `status`, `default_branch`, `config`, `health`, maybe `jira`.
  3. Emit `ProjectUpdated` with partial payload.
  4. Reducer merges partial fields; if `name` supplied, merge into `config.name` rather than adding top-level name, because list helper reads `project.name ?? project.config?.name`.
  5. CLI helper `updateProjectInElixir(projectId, updates)` sends command; CLI `edit` in Elixir mode supports `--name`/`--status` minimally.
- Add disposition:
  - `project add` semantics are clone GitHub repo + register. Elixir projections do not clone. Smallest honest disposition: remove/rename operator surface or fail with explicit message pointing to `project register <local-path>` until a clone workflow exists.
  - Do not silently map `add owner/repo` to `register`; it lacks path/clone semantics and would be wrong.
  - If keeping useful product surface is preferred, split: keep `register` as Elixir supported; change `add` in Elixir mode to clear unsupported message: "GitHub clone add is not supported by Elixir backend; clone locally then run `foreman project register <path>`." This closes legacy-gated behavior without building clone orchestration.
- Jira edit disposition:
  - Current edit supports Jira config and encrypts token in Node CLI. Elixir projection stores `config`; no Jira schema exists in scoped files.
  - Smallest safe implementation: support only project metadata (`--name`, `--status`, maybe `--default-branch` if option added). For Jira flags in Elixir mode, emit clear unsupported error or include `jira` under `config.jira` only if product accepts opaque projection config. Risk: encrypted token/config semantics differ from Node.

## Files/tests likely needed

Implementation files:
- `src/cli/commands/project.ts`
  - Remove `requireNodeProjectCommand()` calls for `remove` and metadata-only `edit` in Elixir mode.
  - Branch on `foremanBackendMode()` for `remove`/`edit` like list already does.
  - Update parent description from "legacy-gated daemon add/remove/edit".
  - Keep `add` explicit unsupported or legacy-gated depending product decision; recommendation: explicit unsupported in Elixir with `register` guidance, not `FOREMAN_BACKEND=node` guidance.
- `src/cli/commands/project-task-support.ts`
  - Add helpers: `archiveProjectInElixir(projectId, { force? })`, `updateProjectInElixir(projectId, updates)`.
  - Optionally `getRegisteredProject(projectId)` if CLI wants preflight/not-found before command.
- `src/lib/elixir-server-client.ts`
  - Optional typed methods `archiveProject()`/`updateProject()`; not strictly needed because helpers can use `sendCommand()`.
- `packages/foreman_server/lib/foreman_server/command_router.ex`
  - Add `domain_event("project.update", payload)` and `domain_event("project.archive", payload)`.
  - Severity: blocker if omitted; CLI helper command will return unsupported/internal.
  - Consider existence validation before append. Current `domain_event/2` cannot see projections unless it calls `ProjectionStore.project(project_id)`. For remove/edit, smallest safe existence check can happen here.
- `packages/foreman_server/lib/foreman_server/projection_store.ex`
  - Add reducers for `ProjectUpdated` and `ProjectArchived`.
  - Severity: blocker if omitted; events append but list/show will not change.

Test files:
- `src/cli/__tests__/project-register-command.test.ts`
  - Add tests for Elixir `project remove proj-1` calling new helper and logging archived/removed.
  - Add tests for Elixir `project edit proj-1 --name new --status paused` calling new helper.
  - Add test for Elixir `project edit` no changes remains no-op.
  - Add test for Elixir `project add owner/repo` prints unsupported/register guidance if add removed from Elixir surface.
- `src/cli/__tests__/project-legacy-gates.test.ts`
  - Update/remove tests that assert remove/edit are gated in Elixir mode.
  - Keep add gate test only if final message still says explicit legacy; otherwise update to unsupported message not requiring `FOREMAN_BACKEND=node`.
- `src/cli/__tests__/project-node-command.test.ts`
  - Ensure Node mode still uses tRPC add/remove/edit if retained.
- `packages/foreman_server/test/foreman_server_test.exs`
  - Add command tests for `project.update` and `project.archive`: event type, stream, projection state.
  - Add invalid/missing project id tests.
- `packages/foreman_server/test/projection_store_test.exs`
  - Add reducer/rebuild test: register -> update -> archive produces status archived and merged config/default_branch/name.
- `packages/foreman_server/test/http_router_test.exs`
  - Optional but high-value: POST `/api/v1/commands` with `project.update`/`project.archive` returns 202 and GET `/api/v1/projects/:id` reflects state.

## Start Here

Start with `packages/foreman_server/lib/foreman_server/command_router.ex`.
Reason: CLI can already send generic commands, but Elixir lacks project update/archive event definitions. Add events first, then projection reducers, then CLI helpers.

## Review Findings

- blocker: `src/cli/commands/project.ts:306` - `foreman project remove` is still hard-gated to Node in Elixir mode.
- blocker: `src/cli/commands/project.ts:378` - `foreman project edit` is still hard-gated to Node in Elixir mode.
- major: `src/cli/commands/project.ts:177` - `foreman project add` remains GitHub clone + Node daemon only. Smallest post-legacy disposition is explicit unsupported/register guidance unless Elixir clone workflow is added.
- blocker: `packages/foreman_server/lib/foreman_server/command_router.ex:121-134` - only `project.register` exists; no `project.update`/`project.archive` command types.
- blocker: `packages/foreman_server/lib/foreman_server/projection_store.ex:133-153` - only `ProjectRegistered` changes project projection; no update/archive reducers.
- major: `src/cli/commands/project.ts:366-376` - Jira edit flags have no scoped Elixir projection/API contract. Treat as unsupported in Elixir mode or store under `config.jira` only after approval.

## Residual Risks

- Existence checks for update/archive need a product choice: fail missing project at command boundary vs create tombstone/partial projection. Recommendation: fail closed with 404-ish validation before append.
- Active agents check for `remove --force` exists only in Node semantics. Scoped Elixir files do not expose active agent/project supervisor checks. Smallest archive can ignore `force` or record it; if active-run safety is required, more server logic needed.
- `ProjectSupervisor` active project processes are loaded from `ProjectStore`, not projection events. Archiving projection may not stop supervised project processes. If operator expects runtime unload, scope expands.
- `add` clone behavior cannot be faithfully replaced using only project projections/events.
- Docs/inventory updates needed by repo policy after implementation, but out of this scout scope.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Concrete findings include exact paths, line ranges, blocker/major severities, implementation files, and test files for project remove/archive plus add/edit disposition."
    }
  ],
  "changedFiles": [
    "subagent-artifacts/project-lifecycle-plan.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "grep/read/find inspections via provided tools; git status --short -- scoped files",
      "result": "passed",
      "summary": "Mapped CLI project commands, Elixir command/projection code, client, router, and tests; scoped git status showed no pre-existing changes in target files/artifact before write."
    }
  ],
  "validationOutput": [
    "No tests run; review-only scout task."
  ],
  "residualRisks": [
    "Active agent safety and ProjectSupervisor unload semantics not solved by projection-only archive.",
    "GitHub clone-backed project add has no Elixir equivalent in scoped files.",
    "Jira edit config needs approval or explicit unsupported handling in Elixir mode."
  ],
  "noStagedFiles": true,
  "diffSummary": "Only wrote scout artifact; no source edits.",
  "reviewFindings": [
    "blocker: src/cli/commands/project.ts:306 - project remove requires legacy Node gate in Elixir mode.",
    "blocker: src/cli/commands/project.ts:378 - project edit requires legacy Node gate in Elixir mode.",
    "major: src/cli/commands/project.ts:177 - project add remains GitHub clone + Node daemon only; recommend explicit Elixir unsupported/register guidance.",
    "blocker: packages/foreman_server/lib/foreman_server/command_router.ex:121 - no project.update/project.archive command events.",
    "blocker: packages/foreman_server/lib/foreman_server/projection_store.ex:133 - no ProjectUpdated/ProjectArchived reducers.",
    "major: src/cli/commands/project.ts:366 - Jira edit flags lack scoped Elixir API/projection contract."
  ],
  "manualNotes": "Do not edit source from this scout. Start implementation in CommandRouter, then ProjectionStore, then project-task-support helpers and CLI branch tests."
}
```
