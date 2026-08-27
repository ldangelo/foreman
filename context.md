# Code Context

## Files Retrieved
1. `packages/foreman_server/lib/foreman_server/projection_store.ex` (lines 175-210, 383-404, 1224-1248, 1801-1884) - `run_logs/1` gap, activity worker-stream scan pattern.
2. `packages/foreman_server/lib/foreman_server/events/worker_stdout.ex` (lines 1-11) - stdout event struct.
3. `packages/foreman_server/lib/foreman_server/events/worker_stderr.ex` (lines 1-11) - stderr event struct.
4. `packages/foreman_server/lib/foreman_server/event_codec.ex` (lines 1-140, 151-214) - strict auto-derived event codec.
5. `packages/foreman_server/lib/foreman_server/overwatch/worker_protocol.ex` (lines 1-134) - worker emit boundary.
6. `packages/foreman_server/lib/foreman_server/overwatch/tracker.ex` (lines 300-347) - sequenced lifecycle dispatch.
7. `packages/foreman_server/lib/foreman_server/aggregates/worker.ex` (lines 61-76, 149-166, 241-300) - worker aggregate decode/apply/validate.
8. `packages/foreman_server/lib/foreman_server/overwatch/adapters/jido_harness_worker.ex` (lines 1-207) - production Overwatch Jido worker; no stdout/stderr emits.
9. `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/driver.ex` (lines 1-25) - thin Jido.Harness run/await wrapper; no output callbacks.
10. `packages/foreman_server/lib/foreman_server/mcp/tools.ex` (lines 381-433) - MCP `foreman_run_get_logs` mapping.
11. `packages/foreman_server/test/foreman_server/overwatch/worker_protocol_test.exs` (lines 242-278) - existing stdout/stderr emit tests.
12. `packages/foreman_server/test/foreman_server/aggregates/worker_test.exs` (lines 458-477, 622-625) - aggregate coverage for log events.
13. `packages/foreman_server/test/foreman_server/mcp/tools_test.exs` (lines 177-181, 247-258) - current `UNAVAILABLE`/`NOT_FOUND` log tests.
14. `docs/cli-reference.md` (lines 869-880) - current public docs say logs unavailable/no producer.
15. `docs/TRD/TRD-2026-cd07a086-durable-run-log-store.md` (lines 70-96, 245-259) - impl decisions + likely edit map.
16. `docs/PRD/PRD-2026-cd07a086-durable-run-log-store.md` (lines 53-55, 117-150, 179-191, 241-274, 323-327) - source reqs/ACs.

## Key Code

- `ProjectionStore.run_logs/1` is deliberate stub:
  - `projection_store.ex:194-208`: docs: durable channel exists but no producer; known run returns `:no_log_store`.
  - `projection_store.ex:394-403`: `nil -> {:error, :run_not_found}`; known run -> `{:error, :no_log_store}`.
- Existing worker-stream read model pattern:
  - `projection_store.ex:383-391`: `run_activity` checks known run then calls `worker_activity_for_run/1`.
  - `projection_store.ex:1801-1884`: discovers `worker:<run_id>:` streams via `EventStore.paginate_streams/1`, reads each stream forward, builds per-worker activity from recorded events.
- Event structs:
  - `worker_stdout.ex:1-11`, `worker_stderr.ex:1-11`: enforced `worker_id`, `run_id`; optional `sequence`, `line`; `@derive Jason.Encoder`.
- Codec:
  - `event_codec.ex:1-37`: no permissive fallback; registry derived from `lib/foreman_server/events/**/*.ex`.
  - `event_codec.ex:112-140`: `decode!/2`, `decode_recorded!/1`.
  - `event_codec.ex:151-214`: rejects unknown keys, duplicate atom/string forms, missing enforced keys.
- Worker protocol/tracker:
  - `worker_protocol.ex:74-105`: allowed emits include `:worker_stdout`, `:worker_stderr`.
  - `worker_protocol.ex:127-132`: routes to `Tracker.dispatch_lifecycle("WorkerStdout"|"WorkerStderr", payload)`.
  - `tracker.ex:304-343`: allocates `sequence`, merges/stringifies payload, dispatches `worker.record` to `worker:<run_id>:<worker_id>` stream; advances seq only on success.
- Worker aggregate:
  - `worker.ex:61-76`: strips `event_type`, decodes through `EventCodec.decode!/2`.
  - `worker.ex:149-166`: stdout/stderr bump seq and keep status `running`; no counters.
  - `worker.ex:241-300`: command validates next sequence, terminal rules, typed event contract before persist.
- Production gap:
  - `jido_harness_worker.ex:131-140`, `157-160`: emits only `:heartbeat` and `:worker_exited`.
  - `jido_harness_worker.ex:180-207`: `Driver.run/3` + `Driver.await/2`, normalize result; no stdout/stderr capture hook.
  - `driver.ex:6-24`: forwards opts to `Jido.Harness.run/3`; only maps `:timeout` to `:runtime_timeout_ms`; no callback plumbing visible.
- MCP mapping:
  - `tools.ex:381-383`: `foreman_run_get_logs` calls `ProjectionStore.run_logs/1`.
  - `tools.ex:404-433`: `:run_not_found -> NOT_FOUND`; `:no_log_store -> UNAVAILABLE` with explicit no-producer message; other -> `RUN_DETAIL_FAILED`.

## Architecture

- Intended path: JidoHarnessWorker/adapter observes worker process output -> `WorkerProtocol.emit(:worker_stdout|:worker_stderr, %{worker_id, run_id, line})` -> Tracker adds sequence and dispatches `worker.record` -> Worker aggregate validates `WorkerStdout/Stderr` typed events -> EventStore persists worker stream -> ProjectionStore materializes/reads run logs -> MCP Tools returns `foreman_run_get_logs`.
- Current path stops at producer and projection:
  - Event types/protocol/tests exist.
  - Production Jido worker does not emit stdout/stderr.
  - ProjectionStore does not read/project log events; it only returns `:no_log_store` for known runs.
- Activity code is closest reusable pattern for worker-stream discovery/replay, but log retrieval likely needs bounded entries, truncation metadata, channel, timestamp, stream id, event number/order.

## Likely edits

- Core:
  - `packages/foreman_server/lib/foreman_server/projection_store.ex` - add log projection state/rebuild/read or worker-stream read path; change `run_logs/1` contract.
  - `packages/foreman_server/lib/foreman_server/mcp/tools.ex` - map new success payload + typed store/expired/truncated errors; remove `:no_log_store` message once producer exists.
  - `packages/foreman_server/lib/foreman_server/overwatch/adapters/jido_harness_worker.ex` - wire capture/emission around `Driver.run/await`; redaction/bounds/capture failure handling.
  - `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/driver.ex` - likely pass through upstream output callback/options if Jido supports it.
  - `packages/foreman_server/lib/foreman_server/events/worker_stdout.ex`, `worker_stderr.ex` - extend only if channel/timestamp/metadata must be persisted in event payload vs derived.
  - `packages/foreman_server/lib/foreman_server/overwatch/worker_protocol.ex` - tighten payload docs/guards if needed.
- Tests:
  - `packages/foreman_server/test/foreman_server/projection_store*_test.exs` - add logs success/empty/rebuild/bounds tests.
  - `packages/foreman_server/test/foreman_server/mcp/tools_test.exs` - replace current `UNAVAILABLE` known-run test with success/empty/errors; keep unknown/malformed distinct.
  - `packages/foreman_server/test/foreman_server/overwatch/worker_protocol_test.exs` - extend payload/redaction/sequence assertions if event shape changes.
  - `packages/foreman_server/test/foreman_server/overwatch/**/*test.exs` - add JidoHarnessWorker producer tests.
  - `packages/foreman_server/test/foreman_server/aggregates/worker_test.exs` - update strict allow-list/typed fields if event struct changes.
- Docs:
  - `docs/cli-reference.md:869-880` currently says `foreman_run_get_logs` returns `UNAVAILABLE`; must update.
  - `docs/user-guide.md` operator behavior likely update.
  - `README.md`, `AGENTS.md`, `CLAUDE.md` only if user/operator/agent expectations change.
  - `docs/TRD/TRD-2026-cd07a086-durable-run-log-store.md:245-259` already lists expected change files.

## Constraints / risks

- Typed boundaries strict: EventCodec rejects unknown fields; changing event shape requires tests and struct updates.
- Do not bypass `WorkerProtocol`; TRD says producers must be worker runtime adapter path only.
- Do not use `Logger` as source; docs/PRD forbid app console logs as run logs.
- Need redaction before persistence, not only on retrieval.
- Need distinguish: unknown run, known empty logs, projection/store failure, expired/purged source.
- Need bound capture and retrieval; TRD chooses 10k lines/5MiB per `(run_id, worker_id)`, retrieval latest 500, max 5000.
- Upstream `Jido.Harness` output surface not visible in Foreman wrapper. Must inspect dependency/source before choosing callback/stream mechanism.

## Start Here

Open `packages/foreman_server/lib/foreman_server/projection_store.ex` first. It owns current `run_logs/1`, has worker-stream scan code to reuse, and defines the external contract MCP maps.
