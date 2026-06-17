# Elixir Backend Architecture

TRD-2026-014 moves Foreman orchestration toward a three-part runtime:

- **Node CLI** remains the operator entry point. It parses commands, auto-starts or locates the local Elixir server, sends authenticated JSON commands, renders projections, and preserves legacy aliases/warnings while migration completes.
- **Elixir server** owns durable orchestration state. It validates commands, appends events, rebuilds projections, supervises run/phase actors, enforces scheduling capacity, manages inbox/debug/attach/recovery views, records VCS/PR/security decisions, exposes doctor/metrics endpoints, and reconciles workers after crashes or drift.
- **Node/Pi worker layer** executes agent work. Workers receive phase starts over the worker HTTP protocol, run Pi SDK-backed sessions, stream ordered worker events/heartbeats/logs/artifacts back to Elixir, and use scoped per-project/per-run environment metadata.

## Command and event flow

1. An operator runs a CLI command such as `foreman plan prd`, `foreman import --to-elixir`, or `foreman server doctor`.
2. The CLI starts or locates the Elixir server and sends a JSON command or read request. If `FOREMAN_SERVER_AUTH_TOKEN` is configured, protected requests include `Authorization: Bearer <token>`.
3. Elixir validates command state and appends durable events before updating projections.
4. CLI status, watch, logs, reports, debug, inbox, attach, doctor, and metrics views read projections instead of reconstructing state from worker logs.
5. Node/Pi workers stream ordered events to Elixir. Out-of-order worker sequences are rejected to keep projections deterministic.

## Deprecated and renamed command surface

Legacy spellings remain hidden or compatibility-only during migration and point to the replacement command:

| Old spelling | Replacement |
|--------------|-------------|
| `foreman dashboard` | `foreman watch` |
| `foreman bead` | `foreman task create --from-text` |
| `foreman purge-logs` | `foreman purge logs` |
| `foreman purge-zombie-runs` | `foreman purge runs` |
| `foreman run --skip-explore` / `--skip-review` | `foreman run --workflow quick` or a custom workflow without those phases |
| `foreman inbox send` replaces removed `foreman mail send` | Use `foreman inbox send` |

When TypeScript-era migration is incomplete, `FOREMAN_LEGACY_COMPATIBILITY_MODE=1` with `FOREMAN_LEGACY_TS_BIN=/path/to/legacy/foreman` delegates supported commands to the legacy binary only when `FOREMAN_BACKEND=node` is set. Elixir is the default after cutover: legacy delegation is disabled and `foreman daemon start|restart` refuses to launch the Node daemon scheduler. Use `foreman server start` so the Elixir scheduler is the only active scheduler for the project. The scheduler ticks every 5 seconds by default and claims dispatchable `ready` tasks within configured capacity.

## Troubleshooting model

Elixir state is append-only first, projection-backed second:

- **Events** are durable facts such as `RunStarted`, `PhaseCompleted`, `WorkerRestarted`, `AuthorizationChecked`, or `AuditRecorded`. When debugging, verify whether the expected event exists before assuming a projection bug.
- **Projections** are rebuildable read models for CLI/status/debug/inbox/metrics views. If a view looks stale, compare `/api/v1/metrics` projection lag with `foreman server doctor`, then rebuild projections or restart the server if the lag does not catch up.
- **Recovery** starts by recording observations, e.g. `ExternalWorkerObserved`, before emitting resolution events such as `WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`. This makes crash recovery auditable.

Example investigation:

```bash
foreman server doctor
# If projection lag is non-zero, inspect /api/v1/metrics or server logs.
# If a run status is inconsistent, open the debug timeline:
#   GET /api/v1/runs/<run-id>/debug?view=raw
# The first anomaly points to the earliest inconsistent transition.
```

Secrets must not appear in durable events, projections, logs, or debug timelines. Worker start payloads persist only redacted environment values plus key metadata.
