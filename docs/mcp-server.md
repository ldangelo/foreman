# Foreman MCP Server

Foreman ships an MCP server so agents and remote operator clients can inspect and control Foreman without shelling out to `curl` or parsing CLI output.

## Goals

- Provide typed tools for health, scheduler, tasks, runs, inbox, lifecycle events, and debug timelines.
- Support both local agent sessions and future remote Foreman deployments.
- Keep the implementation thin: TypeScript MCP adapter over the Elixir HTTP API/projections only.
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
foreman mcp --transport http --host 0.0.0.0 --port 4777 --mcp-auth-token "$FOREMAN_MCP_AUTH_TOKEN"
# endpoint: http://127.0.0.1:4777/mcp
```

The HTTP transport accepts JSON-RPC MCP requests via `POST /mcp` and exposes `GET /health` for load balancers/supervisors.

## Tool Set

| Tool | Purpose |
|------|---------|
| `foreman.smoke.status` | One-call operator smoke check with health, scheduler, active tasks, and recent open tasks. |
| `foreman.health` | Combined MCP/Elixir readiness. |
| `foreman.scheduler.status` | Scheduler state, capacity, active runs, stale active runs, and terminal-log reconciliations from the last tick. |
| `foreman.scheduler.tick` | One manual scheduler tick for smoke checks/controlled dispatch; also reconciles active runs with terminal worker-log markers before capacity checks. |
| `foreman.projects.list` | Registered project inventory. |
| `foreman.tasks.list` | Project task list from the Elixir projection. |
| `foreman.tasks.get` | One task from the Elixir projection. |
| `foreman.tasks.update` | Mutate task through Elixir command boundary. |
| `foreman.tasks.approve` | Approve an open task through Elixir command boundary. |
| `foreman.runs.list` | Recent project runs. |
| `foreman.runs.logs` | Event-backed run logs; tails entries for one run or recent runs. |
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
  └─ Elixir HTTP API: health, scheduler, projects, tasks, runs, inbox, lifecycle events, command boundary, debug timelines
        ↓
Foreman Elixir backend
```

The adapter keeps all reads and writes behind the Elixir HTTP API/command boundary. MCP does not read Postgres directly. Worker phase observability also writes `PhaseStarted`/`PhaseCompleted` lifecycle events through the Elixir command boundary so MCP inbox/events can show post-dispatch phase activity instead of relying only on log-file tails.

## Pi Slash Commands

The project-local Pi extension `.pi/extensions/foreman-mcp.ts` also registers operator slash commands backed by the same MCP tools:

- `/foreman-health` — MCP/Elixir readiness.
- `/foreman-smoke [project] [limit]` — health, scheduler, active count, recent open tasks.
- `/foreman-tasks [status|all] [limit]` — compact task list; defaults to `open`.
- `/foreman-task <task-id>` — one task detail.
- `/foreman-approve [project]` — interactively select open/backlog tasks and approve them.
- `/foreman-runs [status|all] [limit]` — compact run list.
- `/foreman-logs [run-id] [limit]` — tail event-backed logs for one run, or recent runs when no run id is passed; defaults to a compact tail and clamps very large log lines/results to protect Pi context.
- `/foreman-inbox [run-id] [limit]` — recent inbox messages.
- `/foreman-events [run-id] [limit]` — recent lifecycle events.
- `/foreman-scheduler` — scheduler state summary.
- `/foreman-tick` — run one scheduler tick.

Run `/reload` in Pi after changing the extension. Generic MCP tool output is also capped before being returned to Pi; request smaller `limit`/`runs` values or inspect raw log files directly when full log payloads are required.

## Remote Deployment Notes

- Run the MCP HTTP transport next to the Foreman backend or behind a private network/VPN.
- Pass `--server-url` when the Elixir API is remote.
- Use `FOREMAN_SERVER_AUTH_TOKEN` for authenticated Elixir endpoints.
- Use `--mcp-auth-token` or `FOREMAN_MCP_AUTH_TOKEN` to require a bearer token for HTTP MCP requests.
- Future hardening should add project-scoped authorization, audit events for all mutating tools, and TLS termination guidance.
