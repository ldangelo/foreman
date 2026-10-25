# Durable run logs, MCP run status, known issues, stall/messaging notes

> Archived verbatim from the former monolithic `AGENTS.md` (2026-10-18) to keep the always-loaded agent context small. Run logs, test-failure policy, test non-determinism, stall detection, outbound messaging.
> Section-number references inside (e.g. "section 4", "§5.4") point at the pre-split `AGENTS.md`; the §5 rules are summarised in `AGENTS.md` and full text is in `typed-boundaries-full.md`.

## Durable Run Logs and MCP Run Status

`foreman_run_status` is a bounded DTO built from `ProjectionStore.run/1` and
`ProjectionStore.phases_for_run/1`; do not rebuild it from logs or raw event
streams, and keep `foreman_run_get`'s full projection shape distinct.

`foreman_run_get_logs` is backed by worker events and `ProjectionStore`.
Only `WorkerProtocol.emit(:worker_stdout | :worker_stderr, ...)` may produce
persistent run log entries. Do not copy ordinary server `Logger` output into run
logs, and do not return empty success for an unknown run — that is `NOT_FOUND`.

**`Overwatch.Tracker` folds `"event_type"` into the payload it persists, so a
persisted worker event does NOT round-trip through `EventCodec.decode!/2`.**
`dispatch_lifecycle/3` builds `%{"event_type" => type, "worker_id" => …,
"run_id" => …, "sequence" => …}` and merges it over the caller's payload
(`tracker.ex:314-324`), while no struct under `ForemanServer.Events` declares an
`event_type` field and the codec rejects undeclared keys. The worker handlers
that predate durable logs read those payloads with `get/2` and never decode
them, so nothing had ever hit this. The first typed handler to decode one —
`WorkerStdout` / `WorkerStderr` — raised `ArgumentError` inside
`rebuild_state_from_event_log/1`, which runs in `ProjectionStore.init/1`: the
store failed to start and took the entire application down at boot for any
event store holding a single worker log event. `decode_for_projection/2` now
strips `event_type` alongside the `_projection_*` keys, at that one boundary, so
the next typed handler cannot rediscover it.

The lesson is the one section 5.5 already states: this was not a subtle bug, it
was an unexecuted one. The implementation was written, committed, and reviewed
as complete without the application ever being started against it.

## Known Issues

### Test Failures Are Never Acceptable

**A failing test is a failed build, full stop.** There is no category of
"acceptable" or "expected" test failure — not a documented flakiness
pattern, not a pre-existing known issue, not a singleton-pollution artifact.
If `mix test` reports any failure, the build is red and the work is not
done. This applies equally to a PR's own changes and to a failure observed
on `main` after merging: a red run on `main` is a regression to fix
immediately, not a baseline to accept and move past.

The "38-43 failures on identical `--seed 1234` runs" entry directly below is
**a bug to fix, not a threshold to tolerate.** Citing it to justify ignoring
or waving off a new failure is a misuse of this section — it exists to
document a known root-cause investigation in progress, not to license
shipping with failing tests. When a failure's signature plausibly matches
that investigation (shared singleton/projection state leaking across
tests), that is grounds to prioritize fixing the isolation bug, not grounds
to close the loop without a passing suite.

### Shared `ProjectionStore` in tests (foreman-a4ec2, foreman-fhe9o, foreman-quki6)

The store is one process for the whole VM, so what a test projects into it is visible to every
later test. Rules that keep the suite order-independent:

- `test_helper.exs` resets the event log, the aggregate actors **and** the in-memory projection. The projection replays
  the previous run's log at boot, before the helper runs, so resetting only the log made a second
  local `mix test` inherit the last run's runs and tasks (CI starts from a fresh DB and never saw it).
  Aggregate actors hydrate from the log once, when they start; boot-time Dispatcher work starts some for the previous
  run's projects, and they keep `exists?: true` after the log is emptied, so a test registering a project with a repeating
  id (fixed `--seed`, `:rand`) got `{:already_exists, :project, id}` on every second run.
  `ForemanServer.TestSupport.AggregateActorReset` removes every actor right after the log reset so the next command
  rehydrates from the empty log. This does not contradict the 2026-09-02 note below: the log reset itself is sound;
  the state held in memory is what survived it.
- A run projected into the real store gets a unique id (`ForemanServer.TestSupport.UniqueIds.unique_run_id/1`),
  not `"run-1"`: `Dispatcher.crash_resume_opts/2`, `PrWatcher`, `Overview` and `Messaging` read runs back by
  id, and a live run left behind turns another test's fresh start into a resume (foreman-b8qjy).
- `ForemanServer.TestSupport.ProjectionLeakGuard` fails the suite, naming the module and the files that
  type the id, when an `async: false` module ends with a non-terminal run whose id is a literal under
  `test/`. It reads the store from an ExUnit formatter and skips a boundary the runner has already left,
  so it never blames the wrong module but can miss a polluter on one seed that another seed catches.
- Wait for `{:projection_event, ...}` with the run, thread, subject or tool-call id in the pattern
  (`data: %{run_id: ^run_id}`): the store broadcasts every test's events to every subscriber.

### Elixir Test Suite Non-Determinism (2026-09-02)

`mix test` produces 38-43 failures on identical `--seed 1234` runs. **Hypothesis:**
shared singleton GenServer state (ProjectionStore, TaskProvider.Registry, RunSlots) mutated via
`:sys.replace_state`/`persistent_term` across async/sync test boundaries. **Ruled out:** cross-run EventStore pollution (EventStore reset in `test_helper.exs` had no effect on flakiness).

Investigation and remediation options:
1. Per-file `setup :reset_singletons` calls for ~20-30 problematic files
2. Disable `async: true` on leaking test files
3. Investigate async/sync interleaving of shared singletons, then implement the required isolation fix
Do NOT run `br sync --force-jsonl` against a drifted workspace — has destroyed issues here before.
See ``skill://beads-corrupt-db-recovery-safe`` for safe recovery procedure.

## Phase stall detection notes

When editing stall detection, keep one durable fact: `RunStallReported` from `run.report_stall`. Do not infer messaging scope from phase names, do not count `WorkerHeartbeat` as agent output, and do not recompute stall rules in CLI/MCP/HTTP surfaces; read `latest_stall` from projections.

## Outbound messaging delivery notes

`ForemanServer.Messaging.notify/2` only enqueues provider-neutral notification
state; it never calls provider HTTP. `ForemanServer.Messaging.Dispatcher` owns
delivery: on catch-up it treats only a recorded success or a non-retryable
failure as terminal — a bare `NotificationDeliveryAttempted` or a retryable
`NotificationDeliveryFailed` must stay pending and be redelivered. Within one
dispatcher process lifetime a claimed notification id is never released, which
closes the catch-up/live-delivery race where a notification committed during
startup could otherwise be delivered twice. Run every payload, reason, and
metadata value through `ForemanServer.Messaging.Redactor.redact/1` before it
reaches `Logger` or an event — including charlist-shaped values, since a
charlist is text and the generic list clause alone leaves it unredacted.
Distinguish an absent provider-destination field from a malformed one with
distinct error tags (`:missing_field` / `:invalid_field` in the Telegram/Slack
adapters, `:provider_not_configured` when the currently active provider does
not match the notification's); never collapse both causes into one
`:missing_or_invalid` code (§5.3).
