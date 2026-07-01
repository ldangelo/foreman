# Legacy Node Backend Removal Inventory

Updated: 2026-06-30

## Scope

This inventory tracks operator-facing legacy Node backend paths after the Elixir backend cutover. The Node CLI/frontend and Elixir-launched Node/Pi worker bridge remain intentionally retained. The old Node daemon/tRPC/local control plane is no longer a supported operator workflow.

## Operator legacy path disposition

| Area | Post-cutover disposition |
| --- | --- |
| `foreman project add` | Removed from the product surface. Operators clone locally and run `foreman project register <path>`. |
| `foreman project remove` | Replaced with Elixir-backed project archive command/event/projection handling. |
| `foreman project edit` | Replaced with Elixir-backed project metadata updates (`name`, `status`, `defaultBranch`). Jira edit flags are removed with guidance to Elixir external trigger ingestion. |
| `foreman jira configure/status/test/enable-webhook/disable-webhook` | Removed from the CLI management surface. Jira transition ingestion remains available through the Elixir `ExternalTriggerCommand` API. |
| `foreman run --task/--bead` | Removed. Operators use normal scheduler-backed `foreman run` or `foreman retry`. |
| `foreman run --resume/--resume-failed` | Removed. Operators use `foreman retry`. |
| `foreman run` dispatch-shaping options (`--no-pipeline`, `--workflow`, `--model`, `--max-agents`, `--no-auto-dispatch`, legacy telemetry/stagger controls) | Removed from normal operator dispatch. Elixir scheduler/workflow/provider config owns dispatch policy. |
| `foreman run task` | Removed for operators. The hidden `--run-id` bridge remains reserved for Elixir scheduler-launched Node/Pi workers. |
| `foreman task create --from-text` | Removed. Operators create structured tasks with `--title` and optional `--description`. |
| hidden `foreman bead` | Removed with explicit message pointing to structured task creation. |
| `foreman daemon start` / `restart` | Removed with guidance to `foreman server start`. `daemon stop/status` remain only to inspect or stop stray legacy daemon processes. |
| Legacy TS delegation envs (`FOREMAN_LEGACY_COMPATIBILITY_MODE`, `FOREMAN_LEGACY_TS_BIN`) | Removed from the CLI entrypoint and docs. |

## Current audit notes

- `rg 'FOREMAN_BACKEND=node|FOREMAN_LEGACY|requireNode' src/cli/commands src/lib` finds no supported operator fallback guidance or legacy requirement helpers.
- `createTrpcClient()` references still identify residual Node daemon compatibility code to delete or isolate in the follow-up deletion task. They are not approved operator paths.
- The retained Node/Pi worker bridge remains in scope because Elixir scheduler launches Node workers for Pi SDK execution.

## Verification expectations

Final completion must include:

1. A source audit for `FOREMAN_BACKEND=node`, `FOREMAN_LEGACY`, `requireNode*`, `createTrpcClient()`, daemon lifecycle, and legacy backend/store/orchestrator references.
2. Targeted tests for each removed or Elixir-backed operator path.
3. Transition coverage gate and full applicable test suite runs.
