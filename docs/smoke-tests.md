# Smoke Tests

This document describes Foreman's smoke test suite for the Elixir backend. Smoke tests are intentionally lightweight, deterministic, and CI-safe — they run in isolation without live credentials, VCS connections, or network access.

## Running Smoke Tests

Smoke tests are tagged by smoke sub-category (`smoke: :projection`, `smoke: :integration`, etc.) and may also carry a category tag such as `:projection`. Run all smoke tests:

```bash
cd packages/foreman_server
mix test --trace --only smoke
```

Run only projection smoke tests:

```bash
cd packages/foreman_server
mix test --trace --only smoke:projection
```

## Projection Smoke

**File:** `packages/foreman_server/test/foreman_server/smoke_test.exs`  
**Module:** `ForemanServer.SmokeTest`  
**Tags:** `smoke: :projection`, `:projection`, `async: false`

### What it tests

The projection smoke test exercises the complete Foreman event/projection lifecycle end-to-end:

1. **Task creation** — a synthetic task is created via the command boundary, producing a `TaskCreated` event and updating the task projection.
2. **Pipeline dispatch** — a run is started and advances through `developer` and `qa` phases to completion, producing `RunStarted`, `PhaseStarted`, `PhaseCompleted`, and `RunCompleted` events.
3. **PR/merge simulation** — `PrCreated` and `PrMerged` events are appended directly to the event store, simulating VCS completion.
4. **Projection rebuild** — `EventStore.rebuild_projections/0` is called to rebuild read models deterministically.
5. **Projection agreement** — asserts that:
   - The run projection status is `"merged"`
   - The task projection status is `"merged"` (propagated by `PrMerged`)
   - All events are present in the event store in correct stream order
   - `metrics.gauges.projection_lag == 0` (projection is caught up)
   - Rebuilding from scratch produces the same merged state

### Isolation guarantees

- Each test gets its own temporary event log file (`System.tmp_dir()/foreman-smoke-<unique>/events.term.log`).
- The foreman_server application is stopped and restarted per-test via `setup`/`on_exit`.
- No environment variables or credentials are read.
- `async: false` prevents parallel execution interference.

### Adding new smoke tests

Add new `describe` blocks or `test` cases to `packages/foreman_server/test/foreman_server/smoke_test.exs`. Tag sub-categories as needed:

```elixir
describe "my new smoke scenario" do
  @describetag smoke: :my_new_category
  @describetag :my_new_category

  test "does the thing", %{...} do
    # ...
  end
end
```

Run with `mix test --trace --only smoke:my_new_category`.
