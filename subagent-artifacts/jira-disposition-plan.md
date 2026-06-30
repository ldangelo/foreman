# Code Context

## Files Retrieved
1. `src/cli/commands/jira.ts` (lines 1-294) - all Jira operator commands; all are legacy-gated and call tRPC.
2. `src/cli/__tests__/jira-command.test.ts` (lines 1-201) - current tests assert Node/tRPC behavior and guard message.
3. `packages/foreman_server/lib/foreman_server/integration_ingestion.ex` (lines 1-214) - existing Elixir Jira/GitHub/sentinel ingestion path.
4. `packages/foreman_server/lib/foreman_server/command_router.ex` (lines 1-170, 220-280) - `ExternalTriggerCommand` routes to ingestion; only `project.register` config event exists.
5. `packages/foreman_server/lib/foreman_server/http/router.ex` (lines 401-488) - `/api/v1/commands` accepts `ExternalTriggerCommand`; no Jira management endpoints.
6. `packages/foreman_server/lib/foreman_server/projection_store.ex` (lines 171-183, 665-674) - project config stored only on register; integration dedupe/commands projected.
7. `packages/foreman_server/test/integration_ingestion_test.exs` (lines 64-272) - Jira transition ingestion, dedupe, invalid input, rebuild tests.
8. `packages/foreman_server/test/http_router_test.exs` (lines 248-340) - HTTP command boundary tests for external trigger ingestion.
9. `docs/reports/elixir-transition-inventory.md` (lines 20-59) - marks Jira CLI management as guarded legacy.
10. `docs/reports/legacy-node-backend-removal-inventory.md` (lines 25-48, 80-87) - asks whether Jira management should be rebuilt or removed.

## Key Code

### Current Jira CLI is pure legacy/tRPC
`src/cli/commands/jira.ts`:
```ts
function requireNodeJiraLegacy(): void {
  if (foremanBackendMode() === "node") return;
  console.error(chalk.red("Error: foreman jira uses the legacy Node/tRPC Jira integration ..."));
  process.exit(1);
}
```
Every subcommand calls `requireNodeJiraLegacy()` then `createTrpcClient()`:
- `configure` sends encrypted credentials + projects to `client.jira.configure`.
- `status` reads `client.jira.getStatus`.
- `test` encrypts token and calls `client.jira.testConnection`.
- `enable-webhook`/`disable-webhook` call `client.jira.enableWebhook` / `disableWebhook`.

### Existing Elixir supports Jira event ingestion, not management
`packages/foreman_server/lib/foreman_server/integration_ingestion.ex`:
```elixir
@sources ~w(sentinel jira github)
```
For Jira, it can normalize a transition into `task.create` via `CommandRouter.handle/1`, with dedupe:
```elixir
{"jira", site, _repo, _project, issue, _event_id, _fingerprint, transition, _event_type}
when is_binary(site) and is_binary(issue) and is_binary(transition) ->
  {:ok, "jira:#{site}:#{issue}:#{transition}"}
```
It requires `external_link` / `url` for Jira/GitHub.

### HTTP route exists only for commands, no Jira admin API
`packages/foreman_server/lib/foreman_server/http/router.ex` has:
```elixir
post "/api/v1/commands" do
  ... ForemanServer.handle_command(command) ...
end
```
`normalize_command/1` explicitly accepts top-level `ExternalTriggerCommand`, but there are no routes like `/api/v1/integrations/jira/status`, `/api/v1/jira/test`, or webhook toggle/config endpoints.

### Project config exists only at registration
`packages/foreman_server/lib/foreman_server/command_router.ex` supports `project.register` with `config: Map.get(payload, :config, %{})`.
No `project.update`, `integration.configure`, `jira.configure`, `integration.status`, or connectivity-test command exists.

## Architecture

- Node CLI command `foreman jira *` currently targets old Node daemon tRPC Jira router.
- Elixir backend currently owns external trigger ingestion:
  - external system/adapter submits `ExternalTriggerCommand` to `/api/v1/commands`.
  - `CommandRouter` forwards to `IntegrationIngestion`.
  - `IntegrationIngestion` creates idempotent `IntegrationCommandIngested` and `task.create` events.
  - `ProjectionStore` records `integration_commands`, `integration_dedupe`, and tasks with external links.
- Missing for Jira management:
  - no Elixir persistent Jira config mutation except initial `project.register` config blob.
  - no Elixir Jira API client for credential testing.
  - no Elixir poller/webhook manager or webhook registration/toggle state.
  - no status projection for active monitor, last poll, webhook enabled, projects count.

## Disposition

Recommendation: **remove `foreman jira` from the product surface for this legacy-removal goal**, while preserving/documenting the existing Elixir `ExternalTriggerCommand` Jira ingestion path.

Severity findings:
- **blocker:** `src/cli/commands/jira.ts:35-40` - all normal Jira CLI operations require `FOREMAN_BACKEND=node`; violates success criterion if retained.
- **blocker:** `src/cli/commands/jira.ts:84-123`, `141-168`, `189-220`, `233-254`, `263-273` - commands depend on `createTrpcClient().jira.*`; no Elixir equivalent exists.
- **major:** `packages/foreman_server/lib/foreman_server/integration_ingestion.ex:1-214` - Elixir can ingest Jira transition events, but does not configure polling/webhooks or test credentials.
- **major:** `packages/foreman_server/lib/foreman_server/http/router.ex:401-488` - `/api/v1/commands` can accept external triggers; no Jira management endpoints.
- **major:** `packages/foreman_server/lib/foreman_server/command_router.ex:121-134` - project config is only accepted on registration; no update/config events for Jira management.

Why not route quickly:
- `configure` would need new event types, config projection, secure secret policy/storage, and server/client contract.
- `status` needs a real monitor projection (`lastPoll`, `configured`, `webhookEnabled`, project count). Current integration projection only records ingested commands/dedupe.
- `test` needs an Elixir Jira HTTP client and auth/error semantics.
- `enable-webhook`/`disable-webhook` need webhook URL contract, secret handling, and persisted enabled state.
- Mapping to `ExternalTriggerCommand` would only create tasks from already-detected transitions. It cannot replace management commands.

## Exact implementation changes to make later

### CLI
- Edit `src/cli/commands/jira.ts`:
  - remove `createTrpcClient`, `encrypt`, and `foremanBackendMode` imports if command is fully removed/deprecated.
  - replace subcommand actions with one shared `removedJiraManagement()` fail-closed message, or remove subcommands and set command action/help text.
  - suggested message: `Jira management commands were removed with the Elixir backend cutover. Submit Jira transitions through the Elixir ExternalTriggerCommand API (/api/v1/commands) or use project registration config only where documented.`
  - ensure message does **not** advise `FOREMAN_BACKEND=node`.
- Keep `jiraCommand` only if needed to provide operator-facing removed/deprecated messaging. Otherwise remove `program.addCommand(jiraCommand)` in `src/cli/index.ts` and delete command file/tests if no longer reachable.

### Elixir
- No Elixir code needed for removal path.
- Keep `IntegrationIngestion` Jira support intact; it satisfies external transition ingestion.
- Optional small test add only if parent wants explicit Jira-over-HTTP coverage: add a Jira `ExternalTriggerCommand` case in `packages/foreman_server/test/http_router_test.exs` mirroring the GitHub HTTP cases.

### Tests
Update `src/cli/__tests__/jira-command.test.ts`:
- Replace tRPC happy-path tests with removal tests.
- Assert each subcommand exits 1 and prints removed message:
  - `configure`
  - `status`
  - `test`
  - `enable-webhook`
  - `disable-webhook`
- Assert output does not contain `FOREMAN_BACKEND=node`.
- Assert `createTrpcClient` is not called/imported. Best: remove the tRPC mock and add a focused module mock that throws if `../../lib/trpc-client.js` is imported.
- If command is removed from `index.ts`, add/adjust CLI help/index test proving `foreman jira` is not listed or returns unknown command.

Optional Elixir test:
- Add to `packages/foreman_server/test/http_router_test.exs`: `authorized Jira external trigger command creates and dedupes integration task` using payload equivalent to `packages/foreman_server/test/fixtures/integration-jira-transition.json`.

### Docs
Surgical docs edits:
- `docs/reports/elixir-transition-inventory.md`:
  - change `Jira config / webhook CLI operations` status from `Guarded legacy` to `Removed product surface`.
  - evidence: `src/cli/commands/jira.ts` removed/deprecation message; Elixir `ExternalTriggerCommand` remains for Jira transitions.
  - residual risk: no built-in Jira poller/webhook management after cutover.
- `docs/reports/legacy-node-backend-removal-inventory.md`:
  - mark all `foreman jira *` rows as `Remove product surface` / complete disposition.
  - remove open decision #2 or answer it as removed until integration management is reintroduced.
- `docs/cli-reference.md` and `docs/user-guide.md`:
  - remove any active `foreman jira configure/status/test/enable-webhook/disable-webhook` instructions if present.
  - add a concise note where integrations are discussed: Jira transition ingestion is supported via Elixir `ExternalTriggerCommand`; built-in Jira monitor management CLI is not part of default product surface after cutover.
- `README.md`:
  - current grep showed no Jira command docs. No change unless a broader integrations section exists nearby.
- `CLAUDE.md` / `AGENTS.md`:
  - no change expected unless they mention Jira legacy fallback.

## Start Here
Open `src/cli/commands/jira.ts` first. It is self-contained, fully legacy-gated, and has direct tests in `src/cli/__tests__/jira-command.test.ts`. Removal is faster and lower risk than inventing partial Elixir management APIs.

## Supervisor coordination
No blocker. No supervisor decision needed for scout. Product decision still required by parent if choosing between removed command vs hidden deprecation stub.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Concrete findings include exact file paths, line ranges, severity findings, tests, docs, and disposition recommendation in /Users/ldangelo/Development/Fortium/foreman/subagent-artifacts/jira-disposition-plan.md."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "read/grep/find inspections only",
      "result": "passed",
      "summary": "Reviewed Jira CLI, CLI tests, Elixir ingestion/router/projection modules, Elixir tests, and transition docs."
    }
  ],
  "validationOutput": [
    "No validation suite run; review-only scout task."
  ],
  "residualRisks": [
    "Parent must decide exact UX: keep a deprecated `foreman jira` stub with removal message or remove from root command entirely.",
    "Removing Jira management leaves only ExternalTriggerCommand ingestion; built-in polling/webhook registration remains absent until future Elixir integration management work."
  ],
  "noStagedFiles": true,
  "diffSummary": "No source edits. Wrote scout artifact only.",
  "reviewFindings": [
    "blocker: src/cli/commands/jira.ts:35 - `requireNodeJiraLegacy()` makes every Jira management command require FOREMAN_BACKEND=node.",
    "blocker: src/cli/commands/jira.ts:84 - `configure` calls legacy `createTrpcClient().jira.configure`; no Elixir config command/API exists.",
    "blocker: src/cli/commands/jira.ts:141 - `status` calls legacy `createTrpcClient().jira.getStatus`; no Elixir monitor status projection exists.",
    "blocker: src/cli/commands/jira.ts:189 - `test` calls legacy `createTrpcClient().jira.testConnection`; no Elixir Jira API client/connectivity test exists.",
    "blocker: src/cli/commands/jira.ts:233 - `enable-webhook` and `disable-webhook` use legacy tRPC webhook controls; no Elixir webhook management API exists.",
    "major: packages/foreman_server/lib/foreman_server/integration_ingestion.ex:1 - Elixir supports Jira transition ingestion only, not Jira management.",
    "major: packages/foreman_server/lib/foreman_server/http/router.ex:401 - `/api/v1/commands` accepts ExternalTriggerCommand but exposes no Jira management endpoints."
  ],
  "manualNotes": "Recommendation: remove Jira management from product surface for this goal; preserve and document Elixir Jira ExternalTriggerCommand ingestion."
}
```