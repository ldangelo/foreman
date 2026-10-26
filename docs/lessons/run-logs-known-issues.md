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

- The `test` alias in `mix.exs` empties the event log **before the app boots** (`reset_event_store/1`, run ahead of
  `mix test`'s own app start, `MIX_ENV=test` only); `test_helper.exs` resets nothing and fails the suite when the log is
  not empty at that point (alias bypassed, or another `mix test` on the same database). `mix test` boots the app before it
  requires the helper, and the boot is what replays the log: ProjectionStore rebuilds the projection from it, the Dispatcher
  re-admits every run it says is in flight (executors, `run_slots:global` appends, warnings), and aggregate actors hydrate
  from it once and keep `exists?: true` after a later log reset. Emptying the log from the helper (the first fix) therefore
  needed a projection reset, an actor reset and an executor drain on top and still left the boot noise: a second local
  `mix test` inherited the last run's runs and tasks (CI starts from a fresh DB and never saw it), and a test registering a
  project with a repeating id (fixed `--seed`, `:rand`) got `{:already_exists, :project, id}`. With the pre-boot reset there
  is no such state to reset. This does not contradict the 2026-09-02 note below: the log reset itself is sound. Give every
  concurrent `mix test` its own database (`DATABASE_URL`, then `mix event_store.create && mix event_store.init`): one shared
  database is emptied under the other run.
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
`:sys.replace_state`/`persistent_term` across async/sync test boundaries. **Ruled out:** cross-run EventStore pollution (the EventStore reset, then in `test_helper.exs`, had no effect on flakiness).

Investigation and remediation options:
1. Per-file `setup :reset_singletons` calls for ~20-30 problematic files
2. Disable `async: true` on leaking test files
3. Investigate async/sync interleaving of shared singletons, then implement the required isolation fix
Do NOT run `br sync --force-jsonl` against a drifted workspace — has destroyed issues here before.
See ``skill://beads-corrupt-db-recovery-safe`` for safe recovery procedure.

## Phase stall detection notes

When editing stall detection, keep one durable fact: `RunStallReported` from `run.report_stall`. Do not infer messaging scope from phase names, do not count `WorkerHeartbeat` as agent output, and do not recompute stall rules in CLI/MCP/HTTP surfaces; read `latest_stall` from projections.

## A live (rpc) agent run ends only when its stdin closes, so every terminal event must close it (2026-10-26)

**Symptom.** `scripts/e2e/claude_projects_flow.sh` step 4 (live steer of a running thread, real pi on MiniMax): the steered
thread stayed `in_progress` for the whole 600 s wait although its worktree already held `steer-target.txt` and
`steer-marker.txt`. pi was alive and idle (0 CPU, no sockets, no children), the worker stream held only `WorkerStarted` and
heartbeats (`JidoHarnessWorker` emits the agent's `WorkerStdout` when the run ENDS, so a run that never ends has none), the
transcript read `Steer delivered/taken: live`, and Foreman never saw an end event. An unsteered batch hung the same way:
it is not about steering, and not about pi's RPC protocol (pi answered every command; with the same steer at +3 s, 6 of 6
standalone runs and 56 of 72 runs through the harness ended cleanly, the other 16 are the provider failures below).

**Root cause: `Jido.Harness.RunWorker`, live-input runs.** A `live_input` run starts the CLI in streaming-input mode
(`pi --mode rpc`, claude `--input-format stream-json`). That process never exits by itself. The run ends when its stdin
closes, and the harness closed it in exactly one place: on `:input_idle` (pi `agent_settled`, claude `result`) with no steer
pending. A provider that FAILS the turn reverses the order. pi sends `agent_end` with `stopReason: "error"` (after its own
three retries) and only then `agent_settled`; claude sends a `result` with `is_error: true`. The mapper turns the first
into `run_failed`, a terminal event, and `handle_info({:adapter_event, _}, %{terminal_event: %Event{}})` drops everything
after a terminal event, the `:input_idle` with it. Nothing closed stdin, the CLI idled on it for ever, `Run.await/2` (the
phase wait, `timeout_ms: :infinity` when the workflow declares no `timeout_minutes:`) never returned, and
`StuckDetector`/`StallDetector` exempt a run whose executor holds an `:infinity` deadline (`RunExecutorLiveness`), so
nothing else ever noticed. A plain (`--mode json`) run cannot do this: pi exits by itself after `agent_end`. The same
bug hung claude, and a THIRD shape had no terminal event at all: pi answers a `prompt` it cannot start (no API key for the
model) with `response {success:false}` and then sends no `agent_*` event of any kind.

**What failed the turn.** The provider. MiniMax answers `429 rate_limit_error "Token Plan rate limit reached ... (2062)"`
when several agents run at once, which is what the e2e does (the steered thread, the stop target, the coordinator and the
reviewer run side by side, next to whatever else shares the token plan). Reproduced through the harness with the same steer
at +3 s: 72 real pi runs at 12 concurrent, 56 completed, 16 hung, and ALL 16 had `run_failed` as the last journal event with
the pi process still `:running`, three of them with both files already written (the e2e's shape: work done, FINAL turn
failed). Deterministic reproduction, no tokens spent: a bogus `MINIMAX_API_KEY` (401 on the turn) or none at all, live
versus plain, `scripts/e2e/live_input_failure.sh`; before the fix the live runs were still `running` at its 45 s deadline,
the plain control failed in 0.5 s.

**Fix (`packages/jido_harness`).** (1) `RunWorker.live_after_event/2`: a terminal event closes the CLI's stdin at once.
(2) Closing starts a clock. A CLI still alive `live_exit_grace_ms` after its stdin closed (default 10 s, `:provider_config`;
pi exits in ~5 ms) is stopped like a cancel and the run finishes from what it recorded: the terminal event if there is
one, otherwise the idle turn it ended on is a completion. A `:provider_event` with `"kind" => "live_exit_grace_expired"`
lands in the run's events, so a wedged CLI is visible instead of silent; this is the only watchdog, and it is armed by the
close, not by silence. (3) pi's failed `prompt` `response` maps to `run_failed` with pi's own message (`Pi.map_live_event/1`).
The e2e's thread now ends `failed` with the provider's error in its `FailureCause` instead of waiting out the deadline.

**Do not "fix" this with an idle timeout.** A silent agent is not a hung one: a tool call such as `sleep 600` (the e2e's
stop target) emits no event for minutes, and the unattended-run-control rule is that a phase has no wall-clock ceiling. The
hang was a finished run nobody told the CLI about, so the fix is to end the CLI when the run ends, not to guess from
silence. A stall policy that marks a run failed does not stop its agent either: `RunStallReported` only changes the
projection.

**Tests that pin it.** `jido_harness` `live_input_test.exs` ("live runs that do not end in a success") replays REAL records
(`pi_live_error.jsonl`: a pi 1.4.0 turn that failed with a 401; `claude_live_error.jsonl`: claude 2.1.308 on an unknown model)
through the fake CLIs, which, like the real ones, stay alive on stdin until EOF; `FAKE_PI_IGNORE_EOF=1` is the CLI wedged in
its own shutdown. Each fails against the pre-fix `worker.ex`/`pi.ex` (`Run.await/2` times out). `live_steering_test.exs`
drives the same through a real `JidoHarnessWorker`, including the e2e's own shape (`FAKE_PI_OUTCOME=steer_error`: steer
consumed, last turn fails). Tell a fake CLI what to do through the run's env (`env_map:`), not `System.put_env/2`: an
already-running erlexec port hands its children the environment it was started with.

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
