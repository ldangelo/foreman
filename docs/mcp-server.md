# Foreman MCP Server

Foreman ships an MCP server so agents and remote operator clients can inspect and control Foreman without shelling out to `curl` or parsing CLI output.

## Goals

- Provide typed tools for health, scheduler, tasks, runs, inbox, lifecycle events, and debug timelines.
- Support both local agent sessions and future remote Foreman deployments.
- Keep the first implementation thin: TypeScript MCP adapter over the Elixir HTTP API plus Postgres read models.
- Route mutations through Foreman's command boundary instead of direct database writes.

## Transports

### stdio

Use for local MCP clients that spawn Foreman directly:

```bash
foreman mcp --transport stdio
```

### HTTP

Use for local or remote clients that connect to a long-running MCP endpoint:

```bash
foreman mcp --transport http --host 127.0.0.1 --port 4777
# endpoint: http://127.0.0.1:4777/mcp
```

The HTTP transport accepts JSON-RPC MCP requests via `POST /mcp` and exposes `GET /health` for load balancers/supervisors.

## Tool Set

| Tool | Purpose |
|------|---------|
| `foreman.health` | Combined MCP/Elixir/Postgres readiness. |
| `foreman.scheduler.status` | Scheduler state, capacity, active runs, stale active runs. |
| `foreman.scheduler.tick` | One manual scheduler tick for smoke checks/controlled dispatch. |
| `foreman.projects.list` | Registered project inventory. |
| `foreman.tasks.list` | Project task list from Postgres read model. |
| `foreman.tasks.get` | One task from Postgres with Elixir projection fallback. |
| `foreman.tasks.update` | Mutate task through Elixir command boundary. |
| `foreman.runs.list` | Recent project runs. |
| `foreman.inbox.list` | Agent messages by run or project. |
| `foreman.events.list` | Lifecycle events by run or project. |
| `foreman.debug.timeline` | Elixir debug timeline for one run. |

## Future Use Cases

- Remote Foreman server where CLI/client sessions are not on the scheduler host.
- Rich operator dashboards using MCP HTTP instead of bespoke REST clients.
- Policy-gated remote approvals and task state changes.
- Cross-project task/runs/activity feeds.
- Agent startup context: health + scheduler + active run summary in one tool call.
- Support bundle generation from events, inbox, reports, and debug timelines.
- Project-scoped auth and multi-tenant remote Foreman deployments.

## Architecture

```text
MCP client
  ├─ stdio: foreman mcp --transport stdio
  └─ HTTP:  POST /mcp
        ↓
Foreman MCP adapter (TypeScript)
  ├─ Elixir HTTP API: health, scheduler, command boundary, debug timelines
  └─ Postgres read model: projects, tasks, runs, inbox, lifecycle events
        ↓
Foreman Elixir backend / Postgres
```

The adapter intentionally keeps writes behind Elixir commands (`task.update`, future approvals, etc.). Direct Postgres access is used for read-model parity while CLI cutover is still in progress.

## Remote Deployment Notes

- Run the MCP HTTP transport next to the Foreman backend or behind a private network/VPN.
- Pass `--server-url` when the Elixir API is remote.
- Use `FOREMAN_SERVER_AUTH_TOKEN` for authenticated Elixir endpoints.
- Future hardening should add MCP-level auth, project-scoped authorization, audit events for all mutating tools, and TLS termination guidance.
