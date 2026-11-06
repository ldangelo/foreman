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
  `mix test` holds you to that: `reset_event_store/1` first takes a session-level Postgres advisory lock on the
  database (`claim_database!/2` in `mix.exs`, held by a connection that stays open until the VM exits or is killed),
  and a run that finds the database held stops at once with `another mix test run already holds the database ...`
  before it empties the first run's log. The lock is per database, so runs on their own `DATABASE_URL` (each CI
  partition has its own Postgres) never meet it. It cannot see `packages/foreman_server/tmp` (ExUnit `tmp_dir`), which
  every run of one checkout shares: concurrent runs need their own checkout as well as their own database.
- A run projected into the real store gets a unique id (`ForemanServer.TestSupport.UniqueIds.unique_run_id/1`),
  not `"run-1"`: `Dispatcher.crash_resume_opts/2`, `PrWatcher`, `Overview` and `Messaging` read runs back by
  id, and a live run left behind turns another test's fresh start into a resume (foreman-b8qjy).
- `ForemanServer.TestSupport.ProjectionLeakGuard` fails the suite, naming the module and the files that
  type the id, when an `async: false` module ends with a non-terminal run whose id is a literal under
  `test/`. It reads the store from an ExUnit formatter and skips a boundary the runner has already left,
  so it never blames the wrong module but can miss a polluter on one seed that another seed catches.
- Wait for `{:projection_event, ...}` with the run, thread, subject or tool-call id in the pattern
  (`data: %{run_id: ^run_id}`): the store broadcasts every test's events to every subscriber.

### State a test did not create (foreman-jertm, gcee, pn0d, n1iw2, w770m)

Each rule names the failure it removed and how it was reproduced, so it can be told apart from load noise:

- **Scripted append results go to ONE actor, never to the `ForemanServer.CommandRouter` singleton.** Every aggregate
  actor in the VM sends `{:append, ...}` to that name, so a fake registered in its place (`Supervisor.terminate_child/2`
  plus a named fake) receives the append of whichever other actor writes while it is installed. One such append
  consumes a scripted `{:conflict, 1}`, the test's own append then gets the default `append_ok`, and `phase.complete`
  succeeds instead of being re-decided against the externally appended `PhaseCompleted` (`ActorCompensationTest`, CI
  seed 317650). Start the fake unnamed and give it to the actor under test with
  `Aggregator.start_aggregate(module, id, router: fake)` (`Aggregate.Actor.start_link/3`, default
  `ForemanServer.CommandRouter`); stop the actor in `on_exit`. Sending one foreign `{:append, ...}` to the swapped
  router reproduces the CI failure exactly; the same message is harmless to the isolated fake.
- **A test that asserts a dedupe outcome owns the cache and the window.** `Inbox.DedupeTable` is one ETS table for the
  VM and an entry lives for the app-env `:inbox_dedupe_window_seconds`. A test that left the window at `0` expires every
  entry as it is written, so the second `SharedInbox.ingest/2` is `:started` instead of `:deduped`: after a test that
  leaves the zero window behind, `PollerTest` and `OperatorQuestionDispatcherTest` fail with exactly the two failures
  reported for seed 217527. Clear the table and set the window in `setup`, restore it in `on_exit`.
- **Ids written to the event log are unique per test.** `{:already_exists, :project, id}` for all five literal project
  ids of `TaskStateTransitionsTest` is what a second run on the same database produces when it registered them first
  (two overlapping `mix test` runs on one database: 5 of 5). Sequential runs do not reproduce it, before or after the
  pre-boot reset. One database per concurrent run stays the rule; unique ids (project id, beads db path, which is part
  of the lease stream id) keep a module independent of whatever else wrote to the log.
- **A project id that repeats across runs breaks `rebuild([])` equality.** Before the pre-boot reset the in-memory
  projection kept the previous run's conversation for a repeating `co-<n>` id while the rebuild was folded from the
  reset log, so `ProjectionStore.coordinator_state(p) == before` failed after `rebuild([])`
  (`ConversationStoreTest`, foreman-n1iw2). With a fixed project id the second and third run failed on that old flow
  and none on the pre-boot reset; 40 random-seed runs of the coordinator tests on the current flow all passed.
- **Wait for host-dependent work on its event, not on a budget.** A fake executor that runs git subprocesses
  (`Capture.close_run/2`) or an Analyzer capturing an archive takes as long as the host lets it. Receive the DOWN or
  completion message and `Task.await(task, :infinity)`; the ExUnit test timeout is the hang detector. A budget (1 s,
  then 10 s) only moves the load at which the test fails: with a `git` shim that sleeps 6 s per call the 10 s version
  fails and the event-driven one passes (foreman-w770m).
- **A LiveView page held stale on purpose must not refresh.** Removing an entry "elsewhere" and then clicking its row
  races the page's own refresh (`coalesce_ms`, 20 ms in tests, 250 ms by default): set `coalesce_ms: 60_000` for the
  test, or send the event with `render_click(view, event, params)`.
- **`RunDrain` drains to a fixpoint, because the Dispatcher starts a run when it gets to it, not when the projection shows
  it (foreman-nix1u).** `AdoptionService.continue/5` approves the new thread (`auto_approve: true`); the live Dispatcher
  starts a real `RunExecutor` for it after `RunAdmission.start/2`'s aggregate round trips, and later still while it is
  behind (every `DispatcherRestart.restart!/0` replays the whole event log into its mailbox: seconds in a full-size VM).
  Every `ProjectionStoreReset.reset!/0` drains first, but the drain stopped the executors and only then flushed the
  Dispatcher, so the flush started the very executor the stop had missed. It outlived the reset, found its project gone
  and 31-63 ms later emitted `PhaseStarted`, `PhaseFailed`, `TaskExecutionFailed` and `RunSlotReleased`, none of which
  names a project; an event without a project concerns every workspace, so a view mounted by the next test refreshed.
  `ProjectWorkspaceLiveTest` "an idle workspace does no work" got `[:foreman_server, :workspace, :refresh]` inside its
  100 ms `refute_receive` (main CI run 40436675237: the task id prefix `continue-` and the same
  `run_phases(0) failed: :project_not_found` are in its log). Reproduced by running the flow of `AdoptionProjectionTest`
  "continue creates a new thread..." and then the workspace test's own setup and body: 6 of 6 failed, 0 of 6 with the
  Dispatcher terminated or with the rounds below. `RunDrain.drain!/1` now flushes, stops, and goes round again until a
  round finds no executor to stop; a test whose own point is the approval still keeps the Dispatcher out
  (`Supervisor.terminate_child/2` and `DispatcherRestart.restart!/0`, as every other `continue` test does).
- **A test that waits for ticks of a sweep over shared state owns that state (foreman-p7123).** `PrMonitor` sweeps every
  PR the one `ProjectionStore` watches, and a capped tick (`:pr_monitor_max_per_tick`) takes the first N of them in
  `{updated_at, run_id, pr_url}` order. The PRs earlier tests left open are fetched, one tick each, before a PR whose run id
  sorts behind them, so "the leftovers are polled on the next tick" waited for as many ticks as there were leftovers: 20
  fetches of other PRs in 20 s at the old 1 s floor (main CI run 40436675237), and about 120 leftovers are enough to
  exceed the 2 s window at the 20 ms floor (`:pr_monitor_min_delay_ms`, foreman-r22ik). The tests of "scheduled ticks" now
  start from `ProjectionStoreReset.reset!/0`, so the three PRs they create are the whole watch set. With 250 leftovers
  seeded the old test failed 3 of 3 with the CI message; the new one passes, and still fails when a capped tick is
  scheduled a full interval out instead of at the floor.

### A short timeout around a fresh fake executable (`SystemBrRunnerTest`, 2026-10-29)

"lock is released after command times out; second call succeeds" failed once in the local gate's partition 3 (seed
413717, `Task.await(5_000)` exit, 5.25 s) and in 1 of the first 5 local partition-3 runs of unmodified `main` (same seed,
same message); hosted CI (Linux) never showed it. **It is not the lock.** `:global.del_lock/2` is synchronous in the
pinned OTP 28 (a `gen_server:multi_call` to `global_name_server`), and across 7,022 traced `:global.trans` entries the wait
for the lock was 0.09 ms at the median and 12.5 ms at worst. In both failures caught with a trace, call 2 HELD the lock and
sat in `receive_port_messages`, `timeout.flag` did not exist when call 1 returned, and the only `START` in the log was
call 2's: call 1 had been killed before the fake `br` ran its first line, so call 2 was "the first invocation" and ran the
`exec sleep 30` meant for call 1.

- **The marker raced the timeout.** Call 1 had `timeout_ms: 200` plus the ~45 ms the runner needs to signal and reap, and
  the script was to `touch` a marker inside that. Every test's fake `br` embeds its own temp path, so it is a script whose
  bytes macOS has never executed, and the first exec of those takes ~90 ms on an idle machine (p99 150-230 ms, worst seen
  290 ms), against 15 ms for a known script copied to a new path and 6 ms for a second exec of the same file. The marker
  showed up at 241 ms in one of 14 instrumented in-suite runs. Under 36 CPU hogs the test, and an instrumented copy of
  it, failed 3 of 4,513 runs; with 64 shells exec-ing fresh scripts, 26 of 60 (the CI message each time).
- **A fake that a timeout can kill takes its behaviour from state the TEST owns, never from state the fake writes about
  itself.** The test creates `hang.flag` for call 1 and removes it before call 2, so which call hangs no longer depends
  on how far call 1 got. A second test pins the interleaving that failed (`sleep 1` ahead of the hang, so the 200 ms
  timeout always lands first): the old test body failed it 12 of 12, the new tests pass it 21 of 21, and under the 64-shell
  load the new tests passed all 202 runs. The module's other short timeouts have more room: `Port.info captures OS PID...`
  asserts only that the call timed out (true wherever the kill lands), and `a timeout kills the whole process tree` has a
  500 ms budget (101 of 101 under the same load), which a first exec past ~500 ms would still exhaust.

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
heartbeats (`JidoHarnessWorker` emitted the agent's `WorkerStdout` when the run ENDED, so a run that never ended had none:
historical, it records them while the run is live since foreman-h1j5y, see the section below), the
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

**Follow-up: a run whose last turn failed is not a completed run (2026-11-06, foreman-vbfmo.2).** The mirror image of the
hang. `run-4290a162` (the `prd` workflow, seven pi phases) was recorded `completed`, opened PR #835 with two empty report
files and reported the work done, although every model call of every phase had failed (HTTP 429: four assistant turns per
phase with `stopReason: "error"`, zero tokens, 0-byte `phase-N.md`). The harness's process journals of the seven pi
processes (`~/Library/Caches/jido_harness/proc_*`, rpc mode) hold their exact stdout: three retries (2, 4, 8 s), a final
`agent_end` with `willRetry: false`, `auto_retry_end {success: false}`, `agent_settled`, exit status 0. `Pi.map_event/1`
fails a run on that `agent_end`, but the global pi extension `notify.ts` notifies on every `agent_end` through stdout, so
each `agent_end` line began with a BEL (`\x07{"type":"agent_end",...}`): `String.trim/1` keeps it, `Jason.decode/1` refuses
it, and the record became a `provider_event` with a `decode_error`. What was left was `agent_settled`, which maps to
`:input_idle`: the run closed stdin on it and `RunWorker.finish_success/1` recorded a run with no terminal event as
`run_completed`. (The first RCA read "pi wrote no `agent_end`" off pi's session file, which never holds `agent_end`
records.) The end of a pi process is not a success by itself, whatever became of its terminal record: `Pi.run/2` keeps the
latest assistant turn it saw (`message_end` / `turn_end`) as the mapper state and hands `CLIStream` a `stream_end` hook,
asked once after a process that exited 0. A mapped terminal event (`agent_end` failed or aborted, a failed `prompt`
response) already ended the run: nothing is added. Otherwise the latest turn failed (`stopReason: "error"`, with or without
partial output, as `agent_end` already treats it): `run_failed` carrying that turn's own `errorMessage` (`429 {...}`). No
assistant turn at all (pi answered the `prompt` and went quiet): `run_failed` saying so. The latest turn did not fail:
nothing is added, so a turn that failed and was retried successfully is not a failure. This is still not an idle timeout: it
runs only once the process has EXITED, and a silent but alive pi is a running agent. Not changed: `CLIStream` still cannot
decode a record with a control character in front of it, so such a pi's `agent_end` (and its `willRetry`) stays invisible.
Not covered either: the hook runs only for a pi that exits by itself. A live pi that outlives its closed stdin past
`live_exit_grace_ms` is stopped, and when its failure was unreadable (the BEL case) the run still finishes completed from
its idle turn (`run/worker.ex`, as before). A final turn that ended `aborted` behind an unreadable `agent_end` counts as a
worked turn.
Pinned by `live_input_test.exs` (`FAKE_PI_OUTCOME=exhausted`: the incident's stream, BEL included; `=no_settle`: four 429
turns, then exit 0 with no `agent_end` / `agent_settled`; `=silent`: answers the prompt, then exit 0) and `adapter_test.exs`
("Pi.run/2 once pi has exited 0": json and rpc mode, replayed process events); against the pre-fix `pi.ex` /
`cli_stream.ex` the e2e runs end `:completed`.

## A headless pi's `ask` is an RPC dialog nobody can answer, so the harness cancels it (2026-11-06, foreman-vbfmo.3)

**Symptom.** A phase sat on an `ask` until an operator stepped in: `run-ec9d1ce7` (ensemble `br-mvaw`, `coderabbit-review`: "Which
extension do you mean?") for 5+ minutes, until pause/resume; `run-552e1f41` (`create-prd`: "Confirm how to proceed with the
operator-dashboard restyle ...") for 45+ minutes, until cancelled. `latest_stall` stayed null: nothing was failing, the agent was
waiting for a person, and an absent `timeout_minutes` is no deadline (`FailurePolicy.resolve/2`).

**Cause.** `ask` is a tool of a global pi extension (`ask-user.ts` in `~/.pi/agent/extensions`). It returns an error at once when
`ctx.hasUI` is false, but `pi --mode rpc`, which every live phase runs, reports `ctx.hasUI` true and turns `ctx.ui.select` /
`ctx.ui.input` into an `extension_ui_request` on stdout; the call resolves only when the client writes an
`extension_ui_response` with the same id to stdin (pi 1.5.0: `docs/rpc-extension-ui.md`, `dist/modes/rpc/rpc-mode.js`
`createDialogPromise`; no timeout unless the request carries one). `Pi.map_event/1` turned the record into an unmapped
`provider_event` and nothing answered it. The process journals of such runs (`~/Library/Caches/jido_harness/proc_*`) all read
the same: `tool_execution_start` for `ask`, then `{"type":"extension_ui_request","id":"…","method":"select","title":"…",
"options":[…]}`, then no more agent output until the cancel (a steer written meanwhile only queues). The dialog methods are
`select`, `confirm`, `input` and `editor`; `notify`, `setStatus`, `setWidget`, `setTitle` and `set_editor_text` are
fire-and-forget (a pi with extensions writes dozens per run) and take no answer.

**Fix.** `Pi.run/2` in rpc mode (`live_input`) answers every dialog request at once on pi's stdin with
`{"type":"extension_ui_response","id":<the request's id>,"cancelled":true}` (`Helpers.live_process_id/2` and `send_input/2`, the
path a steer takes): the answer a dismissed dialog gets, so the extension sees `undefined` (`false` for `confirm`), `ask`
returns "User cancelled or provided no answer." and the agent decides for itself. The answer is recorded as a
`provider_event` with `"kind" => "ui_request_cancelled"` (`method`, `request_id`, `title`); one that cannot be written (no live pi
process to write to, or the process manager refuses the write, e.g. `:not_running`, `:not_found`) is `"ui_request_unanswered"` with
the `error`, and the run goes on. A dialog raised after the run has closed pi's stdin is still recorded `ui_request_cancelled`:
the process manager accepts a write into a closed stdin and drops it (erlexec: "Data sent to closed stdin is ignored"), so the
harness cannot tell; pi shuts down when its stdin ends, so nothing is left waiting. Fire-and-forget requests
stay unmapped provider events. Not changed: no deadline was added (`timeout_minutes` stays unset on the bundled phases), so a
phase that hangs for another reason still has none; and `Jido.Harness.Session` over pi rpc (`session/transports/pi_rpc.ex`)
is a separate transport and answers nothing (the coordinator's pi runs with `no_extensions`). The four dialog methods are the
documented contract, so a pi that adds a fifth would block again until `@ui_dialogs` in `pi.ex` learns it.
Pinned by `live_input_test.exs` (`FAKE_PI_OUTCOME=ask`: all four dialogs with fire-and-forget requests in between, each
blocking until answered; against the pre-fix `pi.ex` the run never finishes) and `adapter_test.exs` ("Pi.run/2 answering pi's
extension UI requests": every method, the recorded event, the unanswerable case, json mode).

## Worker stdout/stderr is recorded while the agent runs (2026-11-02, foreman-h1j5y)

**Symptom.** A running phase's worker stream held `WorkerStarted` and heartbeats only: `foreman_run_get_logs` returned no
entries and `GET /api/threads/:id/transcript` no turns until the worker exited. Dev event store (`docker exec
foreman-postgres psql -U postgres -d foreman_eventstore_dev`; worker streams are `worker:<run_id>:<worker_id>`): run
`run-f9e7ac6b…`, 22 minutes in, had 1 `WorkerStarted` + 262 `WorkerHeartbeat` and no `WorkerStdout` / `WorkerStderr` while
its worktree was changing. In the completed `run-94c27e30…` every `WorkerStdout` / `WorkerStderr` of each of its 3 workers
(143+4, 92+9, 107+8) was stored within 1-2 s of the worker's exit, ahead of `WorkerSessionBound` / `UsageRecorded` /
`WorkerExited` (fix phase: worker started 23:16:59, heartbeats until 23:25:25, log events stored 23:25:27).

**Cause 1: nothing wrote them before the exit.** `JidoHarnessWorker` ran the agent in a task, `Driver.run/3` blocked until
the agent exited, and only then `log_events/1` built the entries from the finished `RunResult` for
`handle_info({:agent_done, ...})` to write.

**Cause 2 (found checking the timeline): the finished run did not hold the early output either.** `RunResult.events` is the
harness's in-memory buffer (`Jido.Harness.Buffer`: `memory_bytes`, 1 MiB by default, measured as `term_to_binary` with the
raw payloads), not the run's history; the oldest events are trimmed as new ones arrive. The journal on disk
(`Jido.Harness.Journal.default_base_dir/0`: a directory per run of `<run>/NNNNNNNN.jsonl` segments, a new one every 8 MiB,
the oldest dropped once the run's journal passes 256 MiB) keeps the events up to that cap. For the three workers above the
stored log events were exactly a SUFFIX of the journal: worker 1 stored events 3761-4592 of 4592 (147 of its 255 log
lines), worker 2 670-1571 of 1571 (101 of 124), worker 3 408-1534 of 1534 (115 of 142). The agent was writing from +0.7 s
(worker 1, lines per minute: 34, 4, 25, 31, 1, 0, 0, 29, 131), so "the first entry is 7.5 minutes after the worker started"
was the buffer, not a quiet agent: the first 108 lines were never recorded at all.

**What changed (`JidoHarnessWorker`).**

- The agent task's `:on_start` hook sends the worker the harness run id and the worker starts a **tail**: a process of its
  own, monitored and not linked, that follows the harness run from event 0 by cursor and sends the log entries of each page
  to the worker, one message per page. `Run.info/1` (cheap) gates `Run.replay/2` (it re-reads the journal from its first
  line: 8 ms for a 1.4 MB journal), so an idle agent costs one small call per 250 ms round, and the tail also waits 250 ms
  after a page that was not full; pages are 500 events. Not `Run.stream/2`: its idle wait is a sleep nothing can interrupt,
  so a tail built on it outlives a dead worker.
- The worker is the single writer of its stream: tail pages, heartbeats and the terminal events share one mailbox. It writes
  at most 25 entries per turn and keeps the rest of a page in its state (`log_backlog`), queueing the next slice behind
  whatever arrived meanwhile, so a heartbeat waits for one slice at most. One message per entry, each written as it came,
  held the heartbeat back for as long as the burst took (measured in review: 2.3 s for 500 lines, 23-28 s for 2,000), against
  an idempotency lease that only heartbeats renew (30 s) and a Tracker heartbeat timeout of 60 s. The backlog is state, not
  messages the worker sends itself: a re-sent remainder would queue behind the next page, be handled after it and be skipped
  by `log_cursor` as already written. No log line follows `WorkerExited` because the worker stops in the callback that writes
  it, so nothing queued behind `:agent_done` is ever handled. (The Worker aggregate would accept such a line: `WorkerExited`
  does not seal a worker stream, only `WorkerCrashed`, `RunCompleted` and `RunFailed` do.)
- Harness events become entries in ONE place (`events_to_logs/1`, for the tail and the finished run alike), as a
  `WorkerLogEntry` (`@enforce_keys`, so an entry cannot lack its `sequence`). Each entry carries its event's `sequence`,
  which a run numbers from 1; an event with sequence 0 (the default of one no run has seen) raises instead of being skipped.
  `log_cursor` is the sequence of the last entry handled: an entry at or behind it is skipped, so the exit writes what the
  tail delivered and the worker had not written, then exactly the entries the tail did not deliver, in order, then
  `WorkerSessionBound`, `UsageRecorded` and `WorkerExited`. Redaction and the 10,000-line / 5 MiB cap (`WorkerLogPolicy`)
  run in the same place on one set of counters, live and at exit.
- Stop paths: `:agent_done` stops the tail first; a worker that dies any other way (kill, shutdown, or a crashed task:
  `Task.async` links it, so it takes the worker down and `LaunchWorker` relaunches it) is seen by the tail's own monitor.
  The `{:error, {:task_crashed, reason}}` clause that was meant to report a crashed task never ran, for that reason (the
  worker is already dead), and is gone. A tail that fails is logged (`operation: "worker.log_tail"`) and costs timeliness
  only: the worker stays up and the exit still writes what it can from the finished run. What was written live stays in
  the stream whatever happens to the agent.
- Volume is unchanged: one `WorkerStdout` / `WorkerStderr` per harness event. What differs is that output the buffer used
  to drop is now recorded (still capped by `WorkerLogPolicy`), and that `output_activity_at_ms` (the `agent_no_output` stall
  clock, touched by every `WorkerStdout` / `WorkerStderr` in `ProjectionStore`) moves while the agent writes instead of
  once at its exit.

**Known limits.**

- Tool activity is not output. The quiet stretches of a run are `tool_call` / `tool_result`, `turn_started` /
  `turn_completed`, `usage`, `thinking_delta` and non-stderr `provider_event`s, none of which the mapping turns into a log
  line: worker 1's longest silence (175 s) held 41 `provider_event`, one turn, one tool call and result and one `usage`, and
  of its 4,592 events 255 are log lines. A phase that runs one long tool call still looks quiet. Showing tool calls is a
  separate piece of work.
- Output the tail had not delivered when the agent exits comes from `RunResult.events`, the harness's in-memory window
  (1 MiB). If the tail dies, or the agent writes more than a window between the tail's last page and its exit, what is
  older than that window and was not delivered is lost, as it was before.
- The caps now keep the FIRST lines. `WorkerLogPolicy` keeps the first 10,000 lines / 5 MiB of a worker and drops the rest
  without a word. Before, the exit wrote only the newest window the harness still held (1 MiB) through the same cap, so what
  was kept was the newest output. No journal checked reaches the cap (307 journals over 1 MB: at most 3,211 log lines,
  48 KB), but a phase now has more entries than the window held (`run-94c27e30`: 521 instead of 363), so a default 500-line
  read of it is honestly `truncated`.
- Which path delivers a line is race-dependent, and the two store different text. The tail reads the run's JOURNAL, where
  the values of secret-named env vars (the run's and the server's) and `Bearer` tokens are already `[REDACTED]` and text
  that is not valid UTF-8 is a `%{"encoding" => "base64", ...}` map, which `WorkerLogPolicy` stores `inspect`ed. The exit
  reads `RunResult.events`, the raw text, which `WorkerLogPolicy` redacts. A line the tail had not polled before the agent
  exited is stored the second way, so the same output can read differently from one run to the next. The live text is the
  safer one.
- `ForemanServer.Threads.Transcript` still withholds the trailing agent turn until the phase ends or 10 s of quiet. That is
  deliberate and unchanged.

**Tests that pin it.** `jido_harness_worker_live_output_test.exs` drives a real `JidoHarnessWorker` and a real harness run
around a stand-in provider (the `DriverTest.Stub` pattern) that blocks until the test releases it, so "the output is in
the worker stream before the agent finishes" cannot pass on exit-time recording; with a 1.5 KB buffer it also pins "output
the harness no longer holds is recorded". Where the agent's own output has no honest trigger a test pulls a lever and says
so: it kills the tail (the worker lives, beats, and the exit writes the rest once, with `operation: "worker.log_tail"`
logged), kills or shuts down the worker (the tail goes with it), suspends the Tracker to hold the worker inside its exit
(the tail is already stopped), traces what the worker and the harness run receive (an entry is sent once; an idle tail
makes one `Run.info/1` call per poll period and no `Run.replay/2`), sends the worker a page with the agent's result right
behind it (the page is written first, once), and writes six lines of 1,000,000 bytes (the byte cap counts live and exit
lines together). A burst of 240 lines over three pages checks that heartbeats are recorded between its lines and that order
and exactly-once hold across pages. `jido_harness_worker_log_capture_test.exs` pins the event-to-entry mapping, the
`sequence` tag and the refusal of an event without one. To re-check the evidence on a dev machine, read a run's journal
(`<run>/*.jsonl`, the segments in order: one JSON event per line with its `sequence`) and compare it with the worker stream.

## Secrets split across output chunks are stored in clear (2026-11-03, foreman-l30ao.5)

`WorkerLogPolicy.normalize/3` redacts each log entry on its own, and a streamed message is one entry per
`output_text_delta` chunk, so a secret (or a `password=` and its value) that straddles two chunks matches no pattern and
is stored in clear. This is older than the live tail: the exit path wrote the same chunks. Everything that takes entries
as stored returns both halves: `foreman_run_get_logs`, `GET /api/threads/:id/transcript`, its SSE stream and the MCP
transcript tool. `Threads.Transcript` redacts per entry too and joins a group's entries with `"\n"`, which does not
rejoin them. Only the dashboard thread pane re-redacts after it has joined the chunks (`ProjectWorkspaceLive`), so a
split secret is hidden there once its last chunk has arrived; a prefix can show until then, and a message whose deltas
hide a split secret is shown twice, both redacted. The fix is write-time assembly with redaction applied to the whole
message (`foreman-l30ao.5`). Until it lands, do not treat stored run output as free of secret values an agent echoed in
pieces.

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
