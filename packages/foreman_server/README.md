# ForemanServer

Elixir/OTP application shell for Foreman's backend orchestration migration.

This package is internal to the Foreman repository. It establishes the first server runtime boundary for TRD-2026-014:

- OTP application supervisor: `ForemanServer.Supervisor`
- Projection process: `ForemanServer.ProjectionStore`
- dependency-free durable event log shell: `ForemanServer.EventStore`
- dynamic project process supervisor: `ForemanServer.ProjectDynamicSupervisor`
- configured project registry: `ForemanServer.ProjectRegistry`
- minimal command boundary: `ForemanServer.CommandRouter`

Later TRD tasks replace the dependency-free shell stores with Postgres-backed event storage, projections, HTTP APIs, and Node/Pi worker protocols.

## Development

```bash
cd packages/foreman_server
mix test
```
