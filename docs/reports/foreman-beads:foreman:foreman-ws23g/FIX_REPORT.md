<think>Now let me consolidate my understanding and design the fix. Let me re-read key pieces I need:

1. `Exec.Runners.Overwatch.dispatch/1` — the launch path. Need to add a run-terminal check + single-writer check.
2. `WorkerSupervisor.start_worker/1` — add per-run single-writer guard.
3. Terminal run → stop worker tree.

Let me think about the minimal, surgical fix that satisfies the three EXPECTED items:

**(1) Terminal/paused state stops the whole process tree of every worker for that run, bounded time; worker that cannot be stopped is reported.**

Where does the run fail path currently go? `RunExecutor.finalize_terminal_and_stop` → `cleanup_run_worktree(state, :failure)` → `reap_run_agents(state, "failed")` → `OrphanReaper.reap(path)` (only ppid-1 orphans). The live Overwatch worker (LaunchWorker + adapter + harness agent) is NOT stopped. The agent keeps running.

Also `Dispatcher.handle_run_terminated/3` for RunFailed does `RunControl.request(run_id, :cancel)` + `RunControl.cancel_agent(run_id)` — but `cancel_agent` requires a registered harness_run_id; and the RunExecutor's `terminate/2` calls `RunControl.clear(state.run_id)` which erases the agent id. Race: the dispatcher's cancel may arrive after the executor's terminate cleared it. Actually order: run.fail command dispatched → aggregate emits RunFailed → dispatcher handles → `RunControl.request(:cancel)` + `cancel_agent`. Meanwhile the executor is terminating and calls `RunControl.clear`. Which happens first? The dispatch of `run.fail` is synchronous in `finalize_terminal_dispatch`, but the dispatcher's handling of the RunFailed event is asynchronous (via projection event). So `RunControl.clear` in `terminate/2` very likely wins the race → `cancel_agent` returns `{:error, :no_agent}` → nothing is cancelled → the pi agent keeps running. That matches the evidence exactly!

Wait — but actually even if `cancel_agent` did work, it only cancels the *harness run* (the `Jido.Harness.Run`), which escalates SIGINT→SIGTERM→SIGKILL. But the adapter's `Run.await` may never return... Actually the harness cancels and kills. But the crucial thing: `RunControl.clear` erases the id.

Hmm, but the issue says "Failed runs leave their pi worker processes running". So the key fix: on run failure, stop the run's Overwatch workers and their agent OS trees.

Let me design the fix:

**A. `Overwatch.WorkerSupervisor.stop_run_workers/1`** — terminate all LaunchWorker children for a run (bounded), and report which could not be stopped.

**B. Where to call it.** The cleanest single place: the run's terminal transition. Candidates:
- `RunExecutor.finalize_terminal_and_stop` (failure path) — has state.run_id.
- `Dispatcher.handle_run_terminated/3` — handles RunFailed/RunCancelled/RunFlaggedStuck/RunDeleted/RunCompleted for the run, regardless of who dispatched the terminal event. And `handle_run_stopped/3` for RunPaused.

The dispatcher is the event-driven chokepoint: any run reaching failed/cancelled/paused emits the corresponding event and the dispatcher handles it. That covers "failing a run" from any path (operator `run.fail`, phase failure, cancel, pause). The dispatcher already does `RunControl.cancel_agent(run_id)` there — but that only cancels the harness run, and doesn't stop the worker or the OS tree.

But wait: the issue says "compare how `run pause` ends the worker within ~15s, per docs/lessons". Hmm, `run pause` → `RunPaused` → dispatcher `handle_run_stopped` → `RunControl.request(:pause)` + `cancel_agent` → the agent gets SIGINT and exits → the worker exits. But `cancel_agent` depends on the registered harness_run_id still being in RunControl. For pause, the executor is still alive (paused, not terminated) so `RunControl.clear` hasn't run → id still present → cancel works. For failure, the executor terminates → `RunControl.clear` → id gone → cancel fails. That's the asymmetry! Great: root cause for (1) is the `RunControl.clear` race in `RunExecutor.terminate/2` wiping the agent registration before the dispatcher cancels it, plus the failure path never stopping the Overwatch worker itself.

So the fix for (1): in the dispatcher terminal handler, stop the run's workers *and* reap the agent OS tree — but the id is gone by then. Better: make the failure path stop the agent before clearing.

Alternative cleaner approach: the RunExecutor owns the live worker for the phase it is running (it launched it via `Exec.Runners.Overwatch.dispatch/1`). When the run fails, the executor should stop the worker and the agent tree. But the failure may occur while a worker is still alive: e.g. phase 1's agent is running, phase 2 fails? No — phases run sequentially in one executor. Actually the executor runs phases sequentially; a phase's worker is stopped when `wait_for_worker_result` returns. So at the time of failure, is there a live worker?

Cases:
- The agent phase fails (agent returns error) → `wait_for_worker_result` returns → detached `stop_worker` task → worker stopped. But the agent OS process: the harness `Run` completed (the agent itself returned), so the pi process exited... except pi's *tool children* (detached sessions) survive → re-parented to pid 1 → `OrphanReaper.reap/1` catches those (cwd in worktree + ppid 1). OK.
- The run is cancelled while the agent is running → `RunControl.cancel_agent` → harness cancels → agent exits → `wait_for_worker_result` gets `{:worker_result, ...}`? Hmm, on cancel the harness run returns cancelled error → the adapter's task returns → `{:agent_done, ...}` → worker exits → wait returns error → executor's `handle_phase_body_error` sees intent `:cancel` → cancel path → `reap_cancelled_run_agents` → `await_agent_exit` + `reap_run_agents`. And `terminate/2` → `RunControl.clear`.
- The run fails for a reason *not* tied to the agent — e.g. the operator runs `run.fail` command (or `foreman fail`), or a sibling phase fails while the agent phase is... no, sequential.
- The run is flagged stuck (`RunFlaggedStuck`).
- The server restarts / the executor crashes → orphaned agents (ppid 1) → reaped on resume.

Key evidence scenario: "runs marked failed at 02:21:47Z ... original pi workers (pids 73949,73950,73951, started 01:27Z) still alive with cwd in those worktrees and their session files still being written". So three runs each had a live pi worker for ~1 hour. These were runs whose *phase* agent kept running while the run was marked failed. How does a run get marked failed while its agent is still running? Possibly: `run.fail` operator command, or the run was flagged stuck, or the executor died (server restart) → but then ppid would be 1 and `reap/1` would catch it... unless the agent's parent is the beam/erlexec port alive in a *different* server process.

Actually more likely: the phase's agent ran long; the executor hit the phase deadline / idle timeout → `agent_idle_timeout` → run failed → but the agent kept running! Look: `wait_for_worker_result` timeout → `:worker_timeout` → `Error.new(:agent_idle_timeout, ...)` → phase fails → run fails. The worker is NOT stopped in that path? Let's check: at the end of `wait_for_worker_result/5` there's a detached `stop_worker` — does that run on the timeout path too? I need to check the code: the `after timeout_ms` branch probably returns `{:error, :worker_timeout}` and the function returns from there — is the detached stop after the `receive` (common tail) or inside each branch? I recall the tail `Task.start(fn -> Overwatch.WorkerSupervisor.stop_worker(worker_id, run_id) end)` — need to verify it runs on all paths.

If `stop_worker` runs, the LaunchWorker is terminated → `DynamicSupervisor.terminate_child` → LaunchWorker exits → adapter linked dies → agent Task dies (linked) → but the harness `Jido.Harness.Run` is NOT killed by that: the harness owns the pi process under erlexec in the harness's own supervision tree. So the pi OS process keeps running! That's the crux: killing the Overwatch worker does not kill the harness run's OS process. `RunControl.cancel_agent/1` does that (via `Jido.Harness.Run.cancel/1`), but only if the harness_run_id is still registered.

And on failure, `RunExecutor.terminate/2` → `RunControl.clear(run_id)` erases the harness_run_id → so the dispatcher (running async) finds `:no_agent` → no cancel → pi keeps running. Plus `reap_run_agents(state,"failed")` only matches ppid-1 → live agent (parented to the harness's erlexec port, alive) not matched.

Hmm wait, but the agent's parent would be the beam process of the server (harness runs in the same BEAM). ppid of `pi` would be the beam OS pid, not 1. So `reap/1` doesn't match. And the worker's cwd in the worktree. Right.

So there are two independent leaks:
(a) The harness OS agent process is never cancelled on the failure path (registration erased by `RunControl.clear`, and the cancel is racing/async).
(b) The Overwatch worker (LaunchWorker/adapter) may not be stopped on all failure paths.

The issue EXPECTED (1): "the whole process tree of every worker for that run is stopped, including the pi/claude child processes, within a bounded time; a worker that cannot be stopped is reported."

So the fix: on run terminal/paused, stop every worker of that run: terminate the LaunchWorker children AND cancel/kill the harness OS agent tree (the `pi`/`claude` child processes) — i.e. use `Driver.agent_os_pids()`-scoped-to-run + `OrphanReaper.reap_trees/1`, plus wait for exit.

Design decision: where to implement? A dedicated module, e.g. `ForemanServer.Overwatch.RunWorkers` or extend `WorkerSupervisor` with `stop_run_workers/1`. Plus a "stop the agent tree" helper.

But scoped-to-run agent OS pids: `Driver.agent_os_pids()` returns all live harness agent pids (all runs). We need per-run. `Driver.await_exit(harness_run_id)` matches `metadata[:run_id] == harness_run_id` — that's the *harness* run id, not foreman run id. The harness process metadata has `:run_id` = harness run id. `RunControl.agent_run_id(foreman_run_id)` maps foreman run → harness run id. But the mapping is cleared on failure.

Hmm. But the harness process registry has all live processes with metadata. We could find harness run ids whose... no link back to foreman run id except via RunControl.

Alternative: `Jido.Harness.Run.info/1`? The harness run request may carry metadata about foreman run id. Let me check what metadata the harness stores — in `JidoHarnessWorker`, `Run.start(provider, prompt, upstream_opts(opts))` — opts include `run_id`? `upstream_opts` drops `:on_start`/`:await_timeout` and hoists `:timeout`. The opts include `:worker_id, :run_id, :env, :cwd, ...`? Let's check what the adapter passes as opts to `Driver.run`. The driver opts come from `driver_opts` in the worker init, which includes `run_id`? In `JidoHarnessWorker.init`, `driver_opts = Keyword.get(opts, :driver_opts, [])` merged with opts → includes `worker_id`, `run_id`... but `upstream_opts` only drops `:on_start`/`:await_timeout`, so `:run_id` stays in the upstream opts and might land in the harness run request → metadata. Let me verify: `Jido.Harness.RunRequest` fields? If `:run_id` is a field of RunRequest, then the harness's `metadata[:run_id]`... hmm, careful: `await_exit` matches `metadata[:run_id] == harness_run_id` — so harness metadata uses `:run_id` for the harness run id. If the request also carries a foreman `:run_id` key, there'd be a collision.

Let me check `Jido.Harness.RunRequest` struct fields and how `Run.start` builds metadata.

Actually simpler: the fix can rely on `RunControl` but ensure it is NOT cleared before the terminal handling, or better: make the terminal handling capture the harness_run_id BEFORE the executor clears it. Order problem again.

Alternative approach that avoids RunControl entirely: the Overwatch worker itself knows its harness_run_id (it registers it). We could keep a per-run registry of live workers → their harness run ids. But the worker is killed...

Cleanest: do the stop **in the RunExecutor** (which owns state.run_id and can call `RunControl.agent_run_id` BEFORE clearing) — but the executor's failure path calls `terminate/2` → `RunControl.clear`. We can add the stop in `finalize_terminal_and_stop` (before dispatch of run.fail) or in `terminate/2` before `RunControl.clear`.

Hmm, but `terminate/2` runs on every exit including success — where the agent already exited. Killing an already-exited agent is a no-op. But on success we don't want to kill other things... it's fine: on success there's no live agent for the run (the phase's worker returned a result). Actually careful: a run can have multiple phases; the last phase's agent has returned. But is the agent really dead? `Run.await` returned → harness run finished → pi process exited (usually). OK.

But there's a subtlety: `terminate/2` is also called for paused runs and cancelled runs. The issue wants paused to also stop the tree ("terminal or paused state (failed, cancelled, paused)").

However, the executor isn't the only path to a terminal state: `run.fail` command dispatched by an operator goes through CommandGateway → aggregate emits RunFailed → executor may not even exist anymore. And `run.cancel`? Let's see: `Dispatcher.handle_run_terminated` for RunCancelled.

So the robust place to catch ALL terminal/paused transitions is the **dispatcher** (it's the event subscriber for RunFailed/RunCancelled/RunPaused etc.), which already has the run_id and already tries `RunControl.cancel_agent(run_id)`.

The blocker is that `RunControl.clear/1` erases the harness run id before the dispatcher reacts. Fix options:
- (A) Don't clear the agent id on terminate; instead keep it until the run's terminal handling is done. But `clear/1` is also used on resume (handle_run_resumed) — where clearing is right.
- (B) Have the dispatcher capture the harness run id at the time of the event, before the executor's terminate clears it — race, not reliable.
- (C) Make the stop path not depend on `RunControl` for the OS tree: stop the worker tree via the worker supervisor (terminate LaunchWorker children) and then kill the agent's OS process tree directly.

For (C): the agent OS pid is discoverable from the harness process registry — `Driver.live_processes()` gives harness processes with `os_pid` and metadata. If the harness run's metadata includes the foreman run id, we can scope by it. Let me check what metadata the harness process carries.

Let me look at jido_harness: `Run.start(provider, request)` → `RunManager` → creates a `HarnessProcess` with metadata. Let me grep.

Actually — alternative simpler scoping: `Jido.Harness.Run.list/1`? The harness may support listing runs by metadata.

Let me investigate the harness metadata and the `RunRequest` struct to see if foreman's run_id travels. Also check `Driver.agent_os_pids/0`.

Another idea: `JidoHarnessWorker` (the adapter) knows `run_id` (foreman) and `harness_run_id`. When the worker is terminated, we could have it cancel its harness run on exit... but a killed adapter can't do that reliably (Process.exit :kill). Actually `DynamicSupervisor.terminate_child` → `Process.exit(pid, :shutdown)`. The adapter traps exits? The adapter's `init` sets `Process.flag(:trap_exit, true)`? Need to check. If the adapter traps exits, it could handle `{:EXIT, parent, :shutdown}` by cancelling the harness run and killing the OS tree. Hmm, but the adapter is linked to the agent Task, and the agent Task is linked to the harness process? The harness run lives in the harness's own supervisor tree (Jido.Harness.RunManager), so it survives the adapter's death — that's exactly why pi kept running.

OK let me look at the harness to find the cleanest per-run scoping: does `HarnessProcess` metadata include the foreman run id? Let me grep the harness lib for metadata construction.

Let me do this efficiently with a couple of greps.

Plan of investigation (next messages):
1. `grep -n "metadata" packages/jido_harness/lib/jido_harness/run/*.ex` and `run.ex` to see metadata keys.
2. `grep -n "defstruct\|@enforce_keys" packages/jido_harness/lib/jido_harness/run/request.ex`.
3. Check `Driver.run` opts → what upstream_opts passes → does `:run_id` reach the harness request? In `JidoHarnessWorker`, opts include `run_id` (foreman). `driver_opts` = `Keyword.get(opts, :driver_opts, [])` merged with `put_env`. Then `run_agent` calls `Driver.run(provider, prompt, driver_opts)`. driver_opts includes `:run_id`? Let me check `init/1` of JidoHarnessWorker: `driver_opts = put_env(Keyword.get(opts, :driver_opts, []), opts)`. Hmm — `opts` there is the worker opts (worker_id, run_id, provider, prompt, env...). `put_env(driver_opts, opts)` — need to see. Then `driver_opts` may not include foreman's run_id.

Let me check how the harness request is built: `Jido.Harness.Run.start(provider, prompt, opts)`? In driver: `Run.start(provider, prompt, upstream_opts(opts))` — wait, `Jido.Harness.Run.start/3`? Let me check the signature: in `run.ex` we saw `start(request)` / `start(provider, request)`. Driver calls `Run.start(provider, prompt, upstream_opts(opts))` — hmm that's 3 args. Let me verify the actual API.

I need to look at these files. Let me read the key parts.

Given context budget, let me be surgical: grep for `metadata` in jido_harness and for `def start` in run.ex.

Actually, hold on. Maybe there's a much simpler and more robust way to scope OS pids per foreman run: **the worktree path**. The agent's cwd is the run's worktree. `OrphanReaper.reap/1` already scans by cwd but requires ppid==1. We could add a `reap_in_worktree/1` that kills processes whose cwd is inside the worktree regardless of ppid — that would catch the live pi (cwd in worktree) plus its descendants. That is per-run scoping by worktree, matching "the whole process tree of every worker for that run is stopped".

But careful: `pi`'s cwd — the evidence says "still alive with cwd in those worktrees". Yes! The operator observed cwd in the worktree. So cwd-based scoping works and is already the mechanism used by OrphanReaper.

But danger: killing by cwd could kill *other* runs' agents if worktrees overlap — they don't (per-run worktrees). But the *review* agents have cwd in /tmp/foreman-review/... — different path, not inside the run worktree. Fine.

However, the run's worktree path is known to the executor (`state.run_worktree`), not to the dispatcher. Hmm. The dispatcher has run_id; it could query projections for the run's worktree. Let me check what's in the run projection: `ProjectionStore.run(run_id)` might include `worktree_path`.

Alternatively the Overwatch worker knows its cwd: `WorkerProtocol.start_worker` passes opts including `cwd`? The adapter's `driver_opts` include `:cwd` (from `JidoHarnessAdapter.driver_opts` → cwd). Actually the pi process cwd = the sandbox worktree.

Hmm. Let me think about the minimal robust design:

**New module `ForemanServer.Overwatch.RunWorkers`** (or add to WorkerSupervisor) with:
```elixir
stop_run_workers(run_id) :: {:ok, [stopped_worker_ids]} | {:error, {:worker_survived, [...]}}
```
- Terminates each LaunchWorker child of the run (bounded retries) — removes relaunch possibility and kills the adapter.
- Returns list of workers that could not be stopped → "a worker that cannot be stopped is reported".

**Agent OS tree stop**: need per-run agent pids. Options:
(a) `RunControl.agent_run_id(run_id)` → harness run id → `Driver.agent_os_pids` filtered by harness run id... `Driver.agent_os_pids/0` returns all; need `Driver.agent_os_pids_for_run(harness_run_id)`? We can implement by listing live processes and matching metadata run_id (same as await_exit does).
(b) cwd-based: `OrphanReaper.reap_trees` on pids whose cwd is inside the run's worktree (new function `reap_in_worktree/2`).

Given the race with `RunControl.clear`, (b) is more robust but needs the worktree path in the dispatcher.

Hmm, wait. Let me reconsider: maybe the right fix is to make the *executor* do the stop, at the point where it still knows everything (run_id + worktree + agent id), and additionally make the dispatcher path work by NOT clearing the agent id until after the terminal handling...

Actually, let's reconsider the ordering issue more carefully. Who calls `RunExecutor.terminate/2` → `RunControl.clear`?

Scenario: phase fails → `finalize_terminal_and_stop(state, reason)`:
1. `cleanup_run_worktree(state, :failure)` → `reap_run_agents(state, "failed")` (worktree sweep of ppid-1 orphans only)
2. `finalize_terminal_dispatch(state, reason)` → dispatches `run.fail` command → aggregate emits `RunFailed` → projection → dispatcher subscriber notified **asynchronously** (via ProjectionStore/pubsub).
3. `{:stop, :normal, ...}` → executor terminates → `terminate/2` → `RunControl.clear(run_id)` → agent id gone.
4. Later, the dispatcher processes the `RunFailed` event → `RunControl.cancel_agent(run_id)` → `{:error, :no_agent}` → nothing cancelled. **The pi agent survives.**

So the fix could be as simple as: cancel/stop the agent BEFORE the run.fail dispatch and before `RunControl.clear`. I.e. in `finalize_terminal_and_stop` (and in the cancel path), call a new "stop run workers" routine.

But: is `finalize_terminal_and_stop` the path for all failures? `fail_phases` → `finalize_terminal_and_stop`. Also `initialization_failed`. Also an operator `run.fail` command → aggregate emits RunFailed → does the executor learn? The executor is subscribed to run events? There's `RunExecutor` reacting to `run.pause`/`run.cancel` via RunControl intent. For an operator `run.fail`, the executor may keep running the phase until it finishes or its deadline hits. Then the dispatcher must handle the stop.

To cover both, the stop routine should be callable from the dispatcher (event-driven, covers all terminal transitions) AND the executor (covers the racing clear).

The cleanest: **don't erase the agent id on terminate before the dispatcher acts**; instead, make the *dispatcher* the single place that stops workers for terminal/paused runs, and have it obtain the harness run id from a source that survives `RunControl.clear`.

Option: keep a per-run registry of live workers that maps foreman run_id → harness_run_id, owned by the worker layer. But the adapter registers `RunControl.register_agent(run_id, harness_run_id)` — and RunControl is the natural place... The problem is `clear/1` wipes it.

What if we change `RunControl.clear/1` semantics? It's called in two places: `run_executor.terminate/2` (every exit) and `dispatcher.handle_run_resumed/2` (resume). Changing clear to not erase the agent id would leak stale ids → `cancel_agent` would cancel a harness run that no longer exists → `Run.cancel` returns error → `{:error, :no_agent}`? Let me check `cancel_agent`: it calls `Run.cancel(harness_run_id)` and maps errors to `{:error, :no_agent}`. Stale id → cancel of an already-finished run → probably returns `{:error, :not_found}` → mapped to `{:error, :no_agent}` → harmless. But it also means `agent_run_id(run_id)` returns a stale id, and `await_agent_exit` would await an unknown run → `Driver.await_exit(harness_run_id)` → `HarnessProcess.await` on unknown → `{:error, :not_found}` → treated as exited → `:ok`. OK-ish. But it changes semantics elsewhere (`LiveSteer`).

Alternative: **stop the agent from the executor before it clears**, and in the dispatcher, keep the existing `cancel_agent` as a fallback but ALSO stop the workers via the worker supervisor. Then for the "operator run.fail while agent live" case: dispatcher stops the LaunchWorker children of the run (terminate_child) → adapter dies → but the harness run (pi) survives! Because the harness run is not linked to the adapter. So we ALSO need to cancel the harness run → needs the harness run id → which RunControl may have cleared.

Hmm, so killing the worker tree isn't enough; we must cancel the harness run.

⇒ We need a durable per-run mapping from foreman run_id → harness run id that survives `RunControl.clear`. Where? The Overwatch Tracker? Or a dedicated ETS table owned by a supervisor: e.g. `Overwatch.RunAgents`? Hmm, but the adapter registers into RunControl; we could ALSO have the worker supervisor track it.

Wait — maybe simpler: **make `JidoHarnessWorker` cancel its harness run when it is terminated.** If the adapter traps exits and handles `{:EXIT, parent, :shutdown}` (or `:kill`?) by calling `Jido.Harness.Run.cancel(harness_run_id)` and awaiting exit + killing the OS tree, then terminating the worker reliably stops the pi tree. The adapter knows harness_run_id and run_id. That's a tight, local fix at the layer that owns the agent.

But `Process.exit(pid, :kill)` from `safe_stop` in LaunchWorker (adapter start failure) is untrappable. However `DynamicSupervisor.terminate_child` sends `:shutdown` exit signal — trappable if the adapter traps exits. Does `JidoHarnessWorker` trap exits? The moduledoc described "the adapter start_link/1 → init/1 returns immediately → ...". I need to check `init/1` for `Process.flag(:trap_exit, true)`. `LaunchWorker` traps exits (`Process.flag(:trap_exit, true)` in init) so the adapter's death is signaled as `{:EXIT, launch_pid, reason}` to LaunchWorker. The adapter is linked to LaunchWorker; if the adapter doesn't trap exits, adapter death kills LaunchWorker too (linked). Actually LaunchWorker traps exits so it survives adapter death and handles DOWN? No—DOWN comes from the monitor. Trap_exit makes `{:EXIT, ...}` messages arrive instead of killing it. The monitor still fires.

So: if the adapter traps exits, on `{:EXIT, launch_pid, :shutdown}` it can cancel the harness run. Let me check the adapter source.

Also for the OS tree: `Run.cancel(harness_run_id)` → harness escalates SIGINT→SIGTERM→SIGKILL on the pi process → pi dies. But pi's *tool children* (bash sessions) survive as ppid-1 orphans → `OrphanReaper.reap(worktree)` after the agent is gone catches them (cwd-based + ppid 1) — the executor's `reap_run_agents(state, "failed")` does that for failure; for cancel `reap_cancelled_run_agents` does it. But if the executor has already terminated/cleared, the dispatcher path doesn't reap the worktree. The issue's EXPECTED (1) says "the whole process tree of every worker for that run is stopped, including the pi/claude child processes". The pi/claude child processes = the harness's agent process (pi/claude) — that's the main thing.

OK. Given the complexity, let me now decide the design, favoring minimal but complete:

### Design

**1. `Overwatch.WorkerSupervisor.stop_run_workers(run_id)`** — new public function: terminate every LaunchWorker child for the run (bounded), return `{:ok, stopped_worker_ids}` or `{:error, {:worker_survived, ids}}`.

**2. Adapter (`JidoHarnessWorker`) cancels its harness run when the worker is torn down.** Needs: trap exits + handle `{:EXIT, ...}` → `Jido.Harness.Run.cancel(harness_run_id)`, await exit bounded (`Driver.await_exit/2` → 15s? maybe shorter), then kill the OS tree of that harness run (`Driver.agent_os_pids_for_run`? or `OrphanReaper.reap_trees`).

Hmm, this is getting big. Let me consider the alternative: put the "stop the run's workers AND their agent trees" logic in one place that the dispatcher and the executor both call, using info available there:
- worker supervisor: gives us worker pids (LaunchWorker pids per run).
- For each worker pid, we need its harness run id → we can ask the adapter: `GenServer.call(worker_pid, :harness_run_id)`? The adapter is `JidoHarnessWorker` — a GenServer with `harness_run_id` in state (after start). But the worker pid in the registry is the **LaunchWorker** pid, not the adapter. LaunchWorker's state has `worker_pid` (the adapter). We could add a message to LaunchWorker: `{:harness_run_id, ...}`? Too invasive.

Alternative: keep the mapping in the **adapter** → `RunControl.register_agent(run_id, harness_run_id)` already stores it per foreman run. The problem is only `RunControl.clear/1` on terminate.

**Simplest robust fix for the race**: in `RunExecutor.terminate/2`, don't clear the agent registration blindly; instead cancel+stop first. Specifically, reorder: `terminate/2` currently does `maybe_stop_shell_session` + `RunControl.clear`. We could add to `terminate/2`: stop the run's workers and cancel the agent — but `terminate/2` also runs on success (no live agent) and on pause.

Hmm, but `terminate/2` doesn't know whether the exit was a failure or success. It could stop workers regardless — on success there are none live. But wait: is that true? On success the last phase's agent finished → the harness run completed → pi exited. But `stop_worker` detached task may still be running. Terminating it is harmless.

Hmm, but on **pause** the executor stops too (paused state) — and the issue wants paused to stop the worker tree as well. Good, consistent.

But careful: `terminate/2` runs when the executor stops for ANY reason, including when the run is *resumed*? No—resume is a new executor.

Hmm, what about `terminate/2` running while the run is still live? The executor stops only on terminal/pause/cancel.

However, the aggregate-level `run.fail`/`run.cancel` commands (operator-issued) don't necessarily stop the executor promptly... The executor does check `RunControl.intent` (pause/cancel) but for `run.fail`? Let me check whether RunExecutor handles RunFailed events (e.g. `handle_run_failed`). Not sure. There's `run.fail` command → aggregate → RunFailed event → executor might be subscribed to run events and stop. Let me check the RunExecutor's event handling.

I think the strongest, most faithful-to-EXPECTED implementation is:

**A single function**: `ForemanServer.Overwatch.RunWorkers.stop_run_workers(run_id, opts)` that:
1. Terminates the run's Overwatch workers (bounded, reports survivors) — via WorkerSupervisor.
2. Cancels the run's harness agent (via `RunControl.cancel_agent/1`) — but needs the id to survive; so ALSO make the adapter cancel its own harness run on teardown (belt and braces, and covers the case where RunControl was cleared).

Hmm, two mechanisms is not "narrowest". Let me think about which single mechanism covers all three expectations best.

Alternative unified mechanism: **the adapter owns the agent; killing the adapter kills the agent.** Make the adapter trap exits and, on parent shutdown, cancel the harness run + kill its OS tree + await exit. Then "stop the worker tree" = "terminate the LaunchWorker children" → adapter's shutdown handler cancels the harness run → pi dies (bounded) → done. And the OS tree of pi's children: after pi dies, its children are ppid-1 orphans in the worktree → reaped by `OrphanReaper.reap/1` if the executor reaps the worktree (failure/cancel paths do). Or the adapter can call `OrphanReaper.reap_trees(os_pids)`? Overkill.

And the "reported" requirement: `stop_run_workers` returns which workers could not be stopped; log a warning.

But there's a catch: `DynamicSupervisor.terminate_child(sup, pid)` → `Process.exit(child_pid, :shutdown)`. If the adapter traps exits, it gets `{:EXIT, launch_pid, :shutdown}` (the link) and can react. But `terminate_child` waits for the child to die (`Process.exit(pid, :shutdown)` and then waits? DynamicSupervisor's terminate_child calls `Process.exit(pid, reason)` and removes it from the table; it does NOT wait for the process to die (unless `Process.exit(pid, :shutdown)` and the process traps... it just sends the signal). Actually `DynamicSupervisor.terminate_child/2` sends `:shutdown` exit signal and returns `{:ok, child}`. If the child traps exits and doesn't die, the supervisor's child is removed from the table but the process lingers! That's a known caveat: terminating a trapping child doesn't guarantee death. So the adapter must exit after handling.

OK so: adapter traps exits; on `{:EXIT, parent, reason}` (parent = LaunchWorker) → cancel harness run, await exit (bounded, e.g. 5s), then `{:stop, :normal, state}` (or `:shutdown`).

Hmm wait. But there's a subtlety: the adapter is also linked to the agent Task (the Task running the harness). If the adapter stops normally while the Task is alive, the Task dies (linked, adapter's death kills linked task? No — if the adapter exits normally, linked processes receive `{:EXIT, adapter, :normal}`; a Task not trapping exits dies on normal exit? A linked process that receives an exit signal with reason `:normal` and doesn't trap exits → the process does NOT die (normal exit signals are ignored by non-trapping processes). Hmm, actually: "If the process is not trapping exits and receives an exit signal with reason :normal, it is ignored." Yes, `:normal` is ignored unless it's the parent... but the Task is not the parent.

So the adapter should explicitly stop the agent Task (cancel it) — the Task runs `Driver.run(...)` which awaits the harness run; cancelling the harness run makes `Run.await` return an error → the Task returns `{:error, ...}` → the Task's `{:agent_done, ...}` message to a dead worker is dropped. Fine.

OK. Now the second expectation: **(2) Before launching or relaunching a worker for a run, Foreman verifies no live worker already exists for that run (single writer per worktree) and refuses to start a second one.**

Implement in `Overwatch.start_phase/2` or `WorkerSupervisor.start_worker/1`: if `list_pids_for_run(run_id) != []` → refuse with `{:error, {:worker_already_running, run_id}}`. Where's the best place? `WorkerSupervisor.start_worker/1` is the choke point for all worker starts (including relaunches by the supervisor after a crash). The `LaunchWorker` registry key is `"#{run_id}:#{worker_id}"`, and `list_pids_for_run` returns pids for the run.

But careful: sequential phases! A run has multiple phases, each with its own worker_id. Phase 1's worker is stopped (detached `stop_worker` task) before phase 2 starts... but the stop is asynchronous (detached Task!) → the registry may still hold phase 1's pid when phase 2 launches → false "already running" → breaks normal sequential phase execution!

Hmm. That's a real hazard. The detached stop means the previous worker may still be registered. Options:
- Make the guard check only workers that are *live and not finishing*. Hmm.
- Do the guard in `LaunchWorker.init/1` (the supervisor's start path) — same race.
- Track "active writer" per run in a single place with explicit claim/release: e.g. the Overwatch Tracker knows registered workers per run; a worker registers on start and unregisters on exit. Then the guard = "is there a live registered worker for this run?" — same as registry-based but with proper lifecycle.

The race: phase 1 worker exits (agent returned result) → LaunchWorker gets DOWN :normal → `{:stop, :normal, state}` → child removed → registry entry removed (Registry removes on process death). The detached `stop_worker` is just belt-and-braces (it removes the child spec from the supervisor so it can't be relaunched). The worker process actually dies as soon as the agent finishes: `JidoHarnessWorker` sends `{:worker_result, ...}` then `{:stop, :normal, state}`. So by the time phase 2 starts, phase 1's pid is likely dead and unregistered. But "likely" — the executor proceeds immediately after `wait_for_worker_result` returns (which is triggered by the `{:worker_result, _}` message, sent BEFORE the adapter stops). So there's a tiny window where phase 1's worker is still registered when phase 2 launches → false positive!

Mitigation: the guard should be "a live worker for this run that is not already finished" — or better: the guard belongs at the *run* level, i.e. "is another worker already writing to this run's worktree?" The cleanest: the Overwatch Tracker already registers workers per (worker_id, run_id) and unregisters on exit. We could add a per-run "active worker" claim that is released when the worker exits normally.

Alternatively: implement the guard where the evidence points — the relaunch path. The evidence: "for run-77d5281a... a second pi (pid 5660) started at 02:21:40Z by the relaunch was running in the SAME worktree as the original (two writers)". The "relaunch" = the supervisor relaunching a crashed worker (restart: :transient) after the run failed. That's the `LaunchWorker` crash-relaunch path: the worker crashed → supervisor restarts it → new pi in the same worktree while the old pi is still alive (the old one didn't die!).

Hmm, in that scenario the old worker crashed but its agent (pi) kept running? The `LaunchWorker` crash means the adapter died → but the harness run (pi) survives → the relaunched worker starts a second pi in the same worktree. That's precisely "two writers". So the guard for the relaunch path: the supervisor must not relaunch a worker whose run is terminal, and must not relaunch while an agent for that run is still alive.

Now, the tracker has `terminal?/3` — the worker's own terminal state (RunFailed event on the worker aggregate). The LaunchWorker's `init` checks `Tracker.terminal?(worker_id, run_id)` and refuses to start if the worker stream is terminal — that's the guard for relaunch after the worker's terminal event. But the evidence shows a relaunch at 02:21:40 that started a new pi in the same worktree — presumably the worker stream hadn't yet recorded the terminal event, or the terminal event went to a different aggregate.

The EXPECTED (2) says: "Before launching or relaunching a worker for a run, Foreman verifies no live worker already exists for that run (single writer per worktree) and refuses to start a second one." So: check `list_pids_for_run(run_id)` (or the tracker's live workers) — if a live worker exists for that run → refuse.

To avoid the sequential-phase false positive, the check must exclude the worker that is finishing. Options: check the *run's* active worker claim where the claim is released when the worker process exits. The registry-based `list_pids_for_run` includes a worker that is exiting-but-not-yet-dead. Timing: `{:worker_result, _}` is sent by the adapter just before `{:stop, :normal}`. The executor then proceeds to the next phase: it must collect artifacts, dispatch phase events, etc. — many ms. The adapter's `{:stop, :normal}` is processed by its own supervisor (the adapter's supervisor = the LaunchWorker's supervisor? The adapter is started with `adapter.start_link` from within LaunchWorker's `init` → linked to LaunchWorker, and supervised by...? `WorkerProtocol.start_worker` calls `adapter.start_link(base_opts ++ opts)` from inside `LaunchWorker.init` → the adapter is linked to LaunchWorker, and since LaunchWorker traps exits, the adapter's death is survivable... but the adapter's `start_link` from inside a GenServer init links to the LaunchWorker process.

So: adapter sends result → executor proceeds → adapter stops (dies) → LaunchWorker monitors → DOWN :normal → LaunchWorker stops → registry entry removed. This chain takes ~ms but not guaranteed before the next phase's `start_phase`. The false-positive window is small but real → a flaky test would be bad. The AGENTS.md says a red main is a regression; flaky tests are bad.

To be deterministic: the guard should be based on a per-run *claim* that is explicitly released, not on process liveness timing. E.g. `Overwatch.RunWriter` (a GenServer/ETS) that grants a run-level writer lease to a worker_id when it starts and releases it when the worker exits/terminates. Then:
- `start_phase` → claim(run_id, worker_id): if another worker_id holds a live claim → refuse `{:error, {:worker_already_running, ...}}`.
- The claim is released when the worker terminates (monitor DOWN in the claimer) → deterministic ordering? The claim release happens on the claimer's DOWN processing, which may lag the next phase's claim attempt. Ugh, same race.

Hmm. But we can make the claim release *synchronous* with the worker's own lifecycle: the claim is held by the worker process itself (the LaunchWorker), released in its `terminate/2`. The next phase's `start_phase` would then need to wait for the release.

Alternative pragmatic approach: the guard is at the *run* level, not worker level: "this run already has a live worker" — where "live" means registered in the Tracker with a live pid AND that worker is not in a "finishing" state. Hmm.

Let's step back: what does the real hazard look like? Two *agent processes* writing to the same worktree. The proper invariant is per-run: at most one *agent* at a time. The worker (LaunchWorker) is the proxy for the agent.

Sequential phases: phase 1's agent has FINISHED (it delivered its result) before phase 2 starts. So the correct predicate is "is there a live worker whose agent is still running?" — i.e. the worker hasn't delivered a result / isn't shutting down.

The Overwatch Tracker knows the worker's lifecycle events (worker_started, worker_exited). A worker that has emitted `worker_exited` is done. But a crashed worker (never emitted worker_exited) is not done — yet its agent may still be alive (the harness run survives) → relaunching it creates two agents. Hmm, but the crashed worker is *not* live (its process is dead) → `list_pids_for_run` returns nothing → guard passes → relaunch → second agent while the first agent (harness run) is still alive. So the pid-based guard does NOT catch the two-writer case from the evidence!

So the predicate must be about the *agent*, not the worker process: "is there a live harness agent (harness run) for this Foreman run?" The mapping foreman run → harness run id is in RunControl (cleared on terminate...) or in the adapter.

Given the evidence (pi started 01:27Z still alive at 02:34Z, run failed 02:21:47Z), the harness agent outlived both the worker and the run.

So the invariant "single writer per worktree" should be enforced at the harness-agent level: before starting an agent for a run, check whether a harness agent for that run is still alive → refuse.

How to check "harness agent alive for foreman run_id"? The harness's process registry metadata may not carry the foreman run id. Let's check: `Driver.run(provider, prompt, driver_opts)` → `upstream_opts(opts)` → `Run.start(provider, prompt, opts)`. What does `Jido.Harness.Run.start/3` do with opts? Need to read. If the harness `RunRequest` supports arbitrary metadata, the foreman run id could ride along. `JidoHarnessAdapter` puts `:timeout`, `:await_timeout`, cwd, env into driver_opts. `JidoHarnessWorker` merges opts. Does anything put foreman's `run_id` into the harness request? `run_agent/6` in the adapter: `driver_opts` includes `:run_id`? Let me look at the adapter's `init/1` more carefully — `driver_opts = put_env(Keyword.get(opts, :driver_opts, []), opts)`: `put_env(driver_opts, opts)` probably sets `:env` from opts[:env_map]... Then `run_agent(worker, provider, prompt, driver_opts, ...)`.

Hmm — `opts` passed to `JidoHarnessWorker.start_link` comes from `WorkerProtocol.start_worker` → `base_opts ++ opts` where base_opts = [worker_id:, run_id:]. So the adapter's opts include `run_id` (foreman's) and `worker_id`. But `driver_opts` is `Keyword.get(opts, :driver_opts, [])` — a separate keyword list, so foreman run_id may not be in driver_opts... unless `put_env` merges all opts.

I need to read the adapter source properly. Let me do that now — targeted reads.

Also need: `Jido.Harness.Run.start/3` signature and whether it accepts metadata.

Let me now plan the investigation commands (parallel):
1. Read `packages/foreman_server/lib/foreman_server/overwatch/adapters/jido_harness_worker.ex` fully (431 lines) — targeted: init/1, run_agent, trap_exit.
2. Read `packages/jido_harness/lib/jido_harness/run.ex` (start/3, metadata) and `run/manager.ex`/`run/worker.ex` metadata handling.
3. Read `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/driver.ex` fully (110 lines) — already summarized but need exact code for upstream_opts and agent_os_pids.

Given context, let me use targeted greps with context.

Let me proceed.

Also for expectation (3): "No review or other agent phase is started for a run that is already terminal." — I earlier concluded the *archive review* (Review.Evaluator.Agent) is intended behavior for finished runs (documented + tested). But the issue explicitly says the operator saw three `pi` processes in `/private/var/folders/.../T/foreman-review/run/<run-id>` — reviewer agents for the failed runs — and calls it out as a defect: "Foreman also starts reviewer agents for runs that have already failed." and EXPECTED (3): "No review or other agent phase is started for a run that is already terminal."

Hmm. So the operator DOES consider the archive-review agent a defect: reviewers for runs that already failed shouldn't run (wasted tokens, can't land). But the product intentionally reviews finished runs including failed ones ("Every finished run and jobsite leaves a session archive and an automated review"). Conflict!

Resolution: the review agent should not run for a run that is *already terminal* **at the time the review is triggered**? That's exactly the trigger case (RunFailed event → review). Hmm.

Let me re-read the issue: "Foreman also starts reviewer agents for runs that have already failed." — the run failed at 02:21:47; the reviewers ran at ~02:34? The evidence says at 02:34Z three pi processes ran from foreman-review/run/<run-id>. Those reviewers were started *after* the runs were marked failed — i.e. the review was triggered by the failure (legitimately) but the review agent ran long after. Hmm, but "spending model tokens on work that cannot land" — for a failed run, the archive review still produces a review verdict about the run; it's a QA artifact. The docs say every finished run gets a review. So is the operator wrong? The issue says EXPECTED (3): "No review or other agent phase is started for a run that is already terminal."

Reading strictly: when a run reaches terminal state, no further agent phase (including review) should be *started* for it. The archive-review subsystem starts a reviewer agent when the run *becomes* terminal (event-driven). Under a strict reading, that violates (3)... but the whole review feature would die, and it's tested + documented.

Hmm, but maybe the intent is: the review agent shouldn't be started for a run that is *already* terminal when some *other* trigger fires (e.g. a rerun of the workflow, or a `run.fail` on an already-failed run, or the `pr-review` phase of the fix workflow). Recall the fix workflow's phases: `fix` → `pr-review`. And the review phase in workflows (`coderabbit-review`, `repo-rules-review`) — those are *workflow phases* that run as agents. If the run already failed (e.g. the fix phase failed), the next phase (`pr-review`) should not start an agent! That matches "no review or other agent phase is started for a run that is already terminal" — i.e., the *phase pipeline* must not launch agents for a terminal run.

And "a terminal run starts no reviewer" in the task's test list: "Add tests with a fake worker process: failing a run stops the worker tree; a relaunch while a worker is live is refused; a terminal run starts no reviewer." → the third test: starting a phase (e.g. a review phase) for a terminal run must not start an agent.

So: the guard at `Overwatch.start_phase/2` (or in the phase engine before launching an agent) — "if the run is already terminal, refuse to start the worker". Where do we learn the run's terminal state? `ProjectionStore.run(run_id)` → status in ~w(failed cancelled completed ...). There's `Dispatcher.run_paused?/1` and `Tracker.terminal?/3` for workers. For runs: let me check ProjectionStore.run/1 fields (status). Also `RunAggregate`? Let me grep for a helper like `run_terminal?`.

So the design crystallizes:

**Fix 1 (worker tree stopped on terminal/paused run)**: A single stop routine invoked when the run reaches a terminal or paused state; stops the run's Overwatch workers (terminate child specs, bounded) AND cancels the harness agent(s) for the run (kill the pi/claude process tree), reporting survivors.

**Fix 2 (single writer per run)**: Before starting (or relaunching) a worker for a run, refuse if a live worker for that run exists (or a live harness agent for that run exists).

**Fix 3 (no agent phase for a terminal run)**: `Overwatch.start_phase/2` (or the runner) refuses when the run's projected status is terminal.

Now, where to hook Fix 1? The dispatcher handles run events. But `RunControl.clear` race... Let's design Fix 1 to not depend on RunControl's agent id at the moment of the event: instead, capture the harness run id from the *worker* side.

Idea: keep the foreman→harness run id mapping in the **Overwatch Tracker** (which already owns worker lifecycle and persists per (worker_id, run_id)), or in a small dedicated registry that survives RunControl.clear. But an ETS table needs an owner process; `RunControl` owns its ETS table and is a GenServer in the supervision tree — it survives.

Actually, simplest: **don't clear the agent id in `RunExecutor.terminate/2`** — instead, clear it when the run's terminal handling completes (dispatcher) or leave it (stale ids are harmless because `Run.cancel` on a finished run errors → mapped to `{:error, :no_agent}`). But `RunControl.clear/1` is also called on resume — clearing there is correct.

Hmm, but there's a subtle issue: `RunControl.agent_run_id(run_id)` is used by `await_agent_exit` (executor) and `LiveSteer.deliver`. A stale id after a terminal run would make `await_agent_exit` await a non-existent harness run → `Driver.await_exit(harness_run_id)` → `HarnessProcess.await` → probably `{:error, :not_found}` → treated as exited → `:ok`. Fine.

But wait: does `RunExecutor.terminate/2`'s `RunControl.clear` matter for correctness elsewhere? It clears the *intent* too — pause/cancel intents are cleared so a stale intent doesn't affect a later run with the same id (ids are unique per run, so fine).

Hmm, changing `RunControl.clear` semantics is a bit invasive but small and targeted: e.g. `RunControl.clear(run_id)` currently clears intent + agent id + messages. We could add `RunControl.forget_agent(run_id)`? But then terminate should call `clear` for messages/intent but keep the agent id for the dispatcher to cancel. Then who clears the agent id? The dispatcher's terminal handler after cancelling → `RunControl.forget_agent(run_id)`.

That's a clean, narrow change:
- `RunControl.clear/1` → keep as is? or split. Let me define: `RunControl.clear(run_id)` = clear intent + messages + agent id (used on resume). Add `RunControl.clear_intent_and_messages?` hmm.

Alternative that avoids touching RunControl: **the dispatcher captures the agent id from the worker layer.** The Overwatch Tracker could expose `harness_run_id` per run... but the tracker doesn't know it either (the adapter knows).

Alternative: the adapter registers the harness run id with the **Overwatch Tracker** (`Tracker.register_agent(run_id, worker_id, harness_run_id)`) in addition to RunControl — the Tracker survives terminal handling and its state is per-worker. Then the dispatcher's stop routine asks the Tracker: `Tracker.agent_run_ids(run_id)` → cancel each. But the Tracker unregisters workers on DOWN (`unregister/3`) → the mapping would be dropped when the worker dies — exactly when we still need it (the agent outlives the worker!). Unless the Tracker keeps the last known harness run id even after unregister (a "last agent" record). Hmm, that's state creep.

OK let me reconsider: maybe the cleanest is to make the **adapter** own the agent lifetime, so that "stop the worker" ⇒ "stop the agent". Then no cross-process mapping is needed at all:

- `JidoHarnessWorker` traps exits; when the parent (LaunchWorker) goes away (`:shutdown`), it cancels its harness run and awaits exit (bounded) → pi dies → then the adapter stops.
- The dispatcher/RunExecutor stop routine: terminate the run's LaunchWorker children (bounded) → adapters cancel their harness runs → agents die. Report survivors.

This kills the agent tree without any RunControl id. And the harness's `Run.cancel` is the documented way to stop an agent ("the harness escalates SIGINT→SIGTERM→SIGKILL on its own schedule"). But `Run.cancel` "reports the run cancelled at once" while the agent may still be running → so after cancel we should await exit (`Driver.await_exit(harness_run_id, timeout)`) and, if it times out, kill the OS tree (`OrphanReaper.reap_trees(os_pids)`) — but scoped per harness run: `Driver.agent_os_pids()` returns all; we need per-harness-run. `Driver.await_exit` already matches metadata run_id per harness run — so we can write `Driver.agent_os_pids_for(harness_run_id)`? We don't have a per-run pid function; but the adapter knows its own harness_run_id → `JidoHarness.ProcessRegistry`... the adapter can ask `Jido.Harness.Run.info(harness_run_id)`? Hmm.

Alternatively the adapter can capture the OS pid when the harness run starts: `Jido.Harness.Run.info(run_id)` → maybe includes `os_pid`. The `JidoHarnessWorker` already gets `{:harness_run_started, harness_run_id}` in `on_start`. It could then fetch the process's os_pid from the harness registry (`HarnessProcess.list`/`get`).

This is getting deep. Given "narrowest change" and the risk of over-engineering, let me scope the fix as:

### Concrete plan

**New module** `ForemanServer.Overwatch.RunStopper` (or extend `WorkerSupervisor` + reuse `RunControl`):

```elixir
@spec stop_run_workers(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, {:worker_survived, [String.t()]}}
```

Steps:
1. `WorkerSupervisor.stop_run_workers(run_id)` → terminate each LaunchWorker child for the run (bounded 30×50ms like stop_worker) → list of stopped worker_ids; survivors → error.
2. Cancel the run's harness agent(s): `RunControl.cancel_agent(run_id)` (if an id is registered) — but the id may be cleared. To make this deterministic, **the executor must cancel before clearing** OR **the adapter must cancel on teardown**.

I'll do BOTH minimal pieces:
 (a) `RunExecutor.terminate/2`: stop the run's workers + cancel the agent BEFORE `RunControl.clear(state.run_id)`. Wait — but terminate also runs on success/pause. On success, no live agent; on pause, we DO want to stop (EXPECTED includes paused). Hmm, but on pause, the current behavior is: `run pause` → dispatcher sets intent :pause → the executor's phase loop notices the intent → `pause_mid_phase` → stops the phase. The pause path already cancels the agent via the dispatcher (`RunControl.cancel_agent`) — the issue says pause ends the worker within ~15s. Fine.

 Hmm, careful: terminate/2 → stopping workers on EVERY executor exit could interfere with... the executor's exit is terminal-ish. But `terminate/2` is also called when the executor is asked to stop for a *resume*? Let me check: `handle_run_resumed` → `resume_run` → starts a NEW executor? Or restarts the same one? If resume restarts the same executor process, terminate would kill... hmm, the agent was already stopped. Let me check the resume path.

Let me look at how `resume_run` works before deciding.

 (b) The adapter cancels its harness run when torn down (covers the "worker died but agent survived" case, and the dispatcher path when RunControl was cleared).

**Guard 2** (single writer): in `Overwatch.start_phase/2` (before starting a worker), check:
 - the run's projected status is not terminal (Fix 3),
 - no live worker for the run (Fix 2).
Use `WorkerSupervisor.list_pids_for_run(run_id)`.

The sequential-phase false-positive concern: solve it by checking liveness of the *agent* rather than the worker pid? Or by making the previous worker deterministically gone before the next phase starts.

Hmm — wait. Maybe simpler: the guard could be implemented in `LaunchWorker.init/1` (the actual start point, covering supervisor relaunches too), and use `Tracker`-based liveness: the Tracker knows each worker's registered pid and monitors it; a worker that has exited is unregistered. But same timing issue.

Alternative: The sequential case has the previous worker *delivering a result* → the executor proceeds → but the previous worker is still registered for a few ms. If the guard refuses, the run breaks. So the guard must tolerate "a worker that is finishing".

Robust way: the guard asks "is there a live worker for this run that has NOT reported its result?" Equivalent: "is the run's worktree being written by an agent?" Hmm.

What if the guard is implemented at the point where a worker *starts an agent* — i.e. the adapter's `run_agent`? The adapter could ask the harness: "is there another live harness agent for this foreman run?" — needs foreman run id in harness metadata.

OK, decision: I think the cleanest deterministic approach is to introduce a per-run **writer lease** held by the worker that owns the agent, released by the worker *when it stops*, and acquired by the next worker *with a bounded wait* (since the previous worker is finishing). But "refuses to start a second one" then becomes "waits up to N ms then refuses".

Hmm, hold on. Let's reconsider the sequential-phase flow. Does the executor start the next phase's worker while the previous worker is still registered? Look at `Exec.Runners.Overwatch.run/4` → `dispatch/1` → `Overwatch.start_phase` → worker → `wait_for_worker_result` → on result, `Task.start(stop_worker)` (detached). The engine then proceeds to the next phase → `dispatch/1` → `start_phase` → `WorkerSupervisor.start_worker` → new child with a NEW worker_id. The old worker: the adapter sent `{:worker_result, ...}` and then `{:stop, :normal}`. The adapter's stop → its supervisor? The adapter is linked to LaunchWorker (started via start_link inside LaunchWorker.init) — when the adapter exits normally, LaunchWorker (trapping exits) receives `{:EXIT, pid, :normal}` AND the monitor DOWN. LaunchWorker's DOWN handler: `reason in [:normal, :shutdown]` → `{:stop, :normal, state}`. So the LaunchWorker exits normally too. Both happen within microseconds-to-ms after the result message. But the *executor* continues in parallel — it received `{:worker_result, ...}` from the adapter *before* the adapter stopped. Between that and the next `start_phase`, the executor does: collect artifacts, dispatch phase events (`phase.completed`?), maybe write artifacts → likely ≥ a few ms. Risky but probably fine? "Probably fine" = flaky. Not acceptable.

Deterministic alternative: have the *worker* hold the lease and have `start_phase` **wait** for the lease to be free with a bounded timeout (e.g. 5s), and refuse if still held. Since the previous worker releases the lease when it stops (deterministically, ~immediately), the wait ends quickly. If a worker is genuinely stuck (agent alive), the wait times out → refuse. This satisfies "verifies no live worker already exists for that run and refuses to start a second one" — with a bounded grace.

Hmm, but "refuses" after a 5s wait in the test would be slow but fine.

Hmm, wait. Is a lease even needed? Let me reconsider using the *harness* as the source of truth: "is there a live harness agent for this foreman run?" If the adapter registers the harness run id with RunControl *and* the mapping is per-run (not cleared prematurely), then: before starting an agent, check `RunControl.agent_run_id(run_id)` → if a harness run id exists AND `Driver` says that harness run is still live → refuse (an agent is already running for this run). That's semantically exact: single *agent* per run. And for the sequential case: phase 1's agent has finished (Run.await returned) → the harness run is no longer live → no conflict.

But "still live" must be evaluated at the moment of the check, and phase 1's harness run might still be *live* (harness process in :stopping state) briefly → `Driver.live_processes()` includes `:stopping` states. Use `HarnessProcess.list(states: [:starting, :running])` (excluding :stopping) → a finished run's process is gone.

But the mapping foreman run → harness run id must be available at check time. `RunControl.register_agent(run_id, harness_run_id)` is called in `on_start` — i.e. when the agent STARTS. The next phase's check happens after phase 1's agent finished → RunControl still holds the id (cleared only on terminate/resume) → check "is that harness run still live?" → no → proceed.

And the *crash* case: worker crashes but the harness run stays live → RunControl still holds the id (not cleared) → a relaunch would detect "live harness agent for this run" → refuse → **two writers prevented**! That's exactly the evidence case.

And the failure case: run fails → we must cancel the live harness agent → `RunControl.cancel_agent(run_id)` → uses the same mapping → but the executor's `terminate/2` clears it → race. Fix: stop the agent BEFORE clearing (in terminate/2) or don't clear on terminal.

Now, how does the check know the harness run is live? Need a Driver function: `Driver.agent_alive?(harness_run_id)` or reuse: `Driver.await_exit(harness_run_id, 0)`? `await_exit` with timeout 0 → returns `{:error, :timeout}` if live, `:ok` if exited. Hacky. Better: add `Driver.agent_running?(harness_run_id)` → list live processes (states [:starting,:running]) with matching metadata run_id → boolean. Small, clean addition mirroring `await_exit`'s matching logic.

Hmm, but careful: `RunControl.agent_run_id(run_id)` returns the id of the *most recent* agent for the run. If phase 1's agent finished and phase 2's agent starts, register_agent overwrites → fine.

But: the check "no live harness agent for this run" doesn't cover a *different* worker for the same run whose agent hasn't started yet (e.g. two workers launched concurrently). The registry/worker-level check covers that. Do we need both? EXPECTED (2): "Foreman verifies no live worker already exists for that run (single writer per worktree) and refuses to start a second one." — a "live worker" per the issue. I'll implement the worker-level check (registry pids) as the primary, with the finishing-worker race handled by... hmm, back to that.

Let me look at the actual sequencing risk more concretely and decide: implement the guard as "a live *agent* for this run" (via RunControl + Driver) — semantically "single writer per worktree" — and ALSO "no live worker process for this run whose agent is still running"? The second is implied by the first.

I think the agent-level check is both semantically right (single writer = one agent writing) and race-free (a finished agent is not live). The worker-process-level check is racy. But the issue's wording says "no live worker already exists for that run". I can implement: refuse if there is a live *harness agent* for the run (i.e. the worker's agent is still running) — and describe it as "a live worker for that run". Hmm, but a test "a relaunch while a worker is live is refused" would use a fake worker process — e.g. spawn a fake worker (agent) for a run and then try to launch again → expect refusal.

With a fake worker process in a test: how would the test simulate "a worker is live"? If the guard is agent-level (harness), a fake worker process isn't a harness agent → the test would need the fake to register a harness run id... complicated. If the guard is worker-process-level (registry pids), a fake LaunchWorker (registered under the run's key) is easy to simulate: `WorkerSupervisor.start_worker` with a fake adapter that stays alive → then a second `start_worker` for the same run must be refused.

That strongly suggests implementing the worker-level guard (registry/Tracker-based), which is also what the issue says. Then I must solve the sequential-phase race.

Solution for the race: make the guard check "a live worker for the run that is not in the process of finishing". Alternatively: make the *stop* of the previous worker deterministic before the next phase starts — i.e. remove the detached `Task.start(stop_worker)` and instead stop the worker synchronously *after* the result arrives but *outside* the deadlock hazard. The comment says synchronous `stop_worker` deadlocked the executor (because `DynamicSupervisor.terminate_child` round-trips through CommandRouter back to the same run's aggregate actor). Hmm — terminate_child → LaunchWorker exits → the worker emits `worker_exited` → CommandGateway dispatch → routed to the Run aggregate actor → which is the same actor the executor needs → deadlock if synchronous.

Alternative: have the guard ignore workers that have already delivered their result. We could track "finishing" state in the Overwatch Tracker: when a worker emits `worker_exited`, the Tracker knows it's done. But the worker process might still be alive for a few ms after emitting worker_exited.

Hmm, what about the guard checking the *harness agent* liveness for the run, but implemented so a test can simulate it: the fake worker registers an agent id via RunControl? In the test we can call `RunControl.register_agent(run_id, fake_harness_run_id)`... but then "live" needs the harness process to be live → needs a real harness process. Ugly.

Alternative: implement the guard in the **Tracker**: the Tracker registers workers (worker_id, run_id, pid) and knows liveness (monitors). Add a Tracker API `active_worker_for_run(run_id)` → returns the worker whose pid is alive AND has not been marked finished. The Tracker learns "finished" from the `worker_exited` event (dispatched by the adapter before it stops) — hmm, but `worker_exited` is dispatched via CommandRouter asynchronously; the Tracker receives it when the aggregate processes it? `Tracker.dispatch_lifecycle` → CommandRouter → the Worker's aggregate → event → projection → ... The Tracker mirrors sequences locally. The Tracker may learn of exit via its monitor DOWN too.

Simpler idea: **the guard checks the registry pids, but the executor ensures the previous worker is fully stopped before starting the next phase.** We can achieve determinism by having `wait_for_worker_result` (in the runner) stop the worker *synchronously* in a way that doesn't deadlock: the deadlock came from `DynamicSupervisor.terminate_child` → LaunchWorker exits → `Tracker` dispatches `worker_exited` → CommandRouter → Run aggregate actor (the one the executor is talking to) → deadlock. But the Tracker's dispatch happens in the Tracker process, not the executor's; the deadlock was: terminate_child is synchronous and the DynamicSupervisor waits for the child to die; the child (LaunchWorker) traps exits and, on exit, ... hmm, actually the deadlock: `DynamicSupervisor.terminate_child` → sends :shutdown → LaunchWorker (trapping) handles? LaunchWorker's terminate → it might call Tracker.unregister → GenServer.call to Tracker → Tracker dispatches `worker_exited` via CommandRouter → CommandRouter routes to the Run aggregate → the Run aggregate's handle_event → ... → maybe calls back into the executor? The comment says: "terminate_child blocks on DynamicSupervisor.terminate_child, which round-trips through CommandRouter back to the same run's aggregate actor; calling it synchronously deadlocked the RunExecutor against itself". Right: the CommandGateway dispatch is a GenServer.call to the aggregate actor; the aggregate actor is busy handling the executor's own command? Possibly.

OK — avoid re-litigating that. Use a **bounded wait** in the guard: when starting a worker for a run, if other workers for the run are registered, wait up to N ms for them to disappear; if still present → refuse. The previous phase's worker disappears within ms → the wait resolves quickly and no false refusal. In the "stuck" case → refuse after N ms (bounded). A test can use a fake worker that never exits → refusal after the bounded wait (test duration = N ms; choose N small, e.g. 500ms–1s, configurable via opts for tests).

Wait, but there's a subtlety: `terminate_child` removes the child from the supervisor's table but the *Registry* entry (name via Registry) is removed when the process dies. `list_pids_for_run` uses the Registry → the pid disappears when the LaunchWorker process exits. Good.

Hmm, but the bounded-wait guard has a flaw: the "second pi" in the evidence started at 02:21:40 — the relaunch. With the guard, the relaunch (same worker_id? the relaunched child has the SAME worker_id — child spec id `{LaunchWorker, worker_id, run_id}`) → the registry key is the same → `pid_for` → the old pid is dead (it crashed) → registry entry gone → the guard sees NO live worker → the relaunch proceeds → **two writers** (the old agent still alive!). So the worker-level guard alone does NOT catch the evidence case; the agent-level guard does.

⇒ We need BOTH: (i) no live harness agent for the run (catches crashed-worker-with-live-agent), and (ii) no live worker process for the run (catches concurrent launches).

For (i) we need the foreman→harness mapping to survive: RunControl holds it; cleared on terminate/resume. In the evidence case the run had failed → executor terminated → RunControl cleared → mapping gone → relaunch wouldn't detect the live agent. Hmm! But wait: if the mapping is cleared and the agent is still alive, we ALSO have the bug (1) — the agent wasn't stopped. So fixing (1) properly (stop the agent tree on terminal) removes the precondition for the two-writer scenario. And for the relaunch case, the run is terminal → guard (3) refuses anyway.

So the ordering: fix (1) so that a terminal run has NO live agent; fix (