# Claude Projects scripted acceptance (E16-S8-T3), 2026-10-22

Evidence for `scripts/e2e/claude_projects_flow.sh` and `scripts/e2e/failure_injection.sh`. Everything below is pasted from the
scripts' own transcripts (`E2E_TRANSCRIPT=...`); nothing is marked PASS unless the script observed it. How to run them:
`docs/user-guide.md`, "Running the live acceptance".

## Environment

- Branch `feat/e16-s8-acceptance` off `origin/main` (81b48d77 at start; rebased before the PR). macOS arm64, Elixir 1.20.4 / OTP 28
  (devbox), Go 1.27.3, git 2.56.0, `br` 0.6.0, `pi` 1.3.0.
- Real: Foreman server (`MIX_ENV=dev`, `mix run` + `scripts/e2e/claude_projects/boot.exs`, private Postgres database on
  `localhost:55432`, own port, `HOME` redirected into the scratch work dir, `FOREMAN_VFS_ALLOWED_ROOT` = work dir), the Go CLI built
  from the same checkout, `git`, `br` (scratch repo with its own `.beads` database; `BeadsWatcher` enabled), and a real `pi` agent on
  **`minimax/MiniMax-M2.7-highspeed`** for threads, coordinator and reviewer (`FOREMAN_REVIEW_PROVIDER=pi`).
- Not real: GitHub (nothing pushed anywhere but the scratch repo's local bare origin; no PRs), notification endpoints (a local HTTP
  sink, `webhook_listener.py`). Workflows are scratch ones pinned to pi/minimax, **not** the bundled defaults
  (BLOCKED-BY `foreman-pv11k`; no defect filed for that).
- Claude provider: used only as the "provider down" injector (the isolated `HOME` holds no credentials, so it is genuinely
  unavailable). Claude provider *success* paths are not exercised here.

## Result per scenario

| Script / scenario | Result | Notes |
|---|---|---|
| flow 1 project: create, goal, instructions, limits | PASS | `project get` and `project context` show the values |
| flow 2 memory, library | PASS | `memory write/read/list`, `library add/list`, HTTP 200 |
| flow 3 bead -> thread; thread sees instructions + memory + library | PASS | three unguessable tokens (one per source) all landed in `notes.txt` on the run branch |
| flow 4 steer / stop / resolve / reopen | PASS | steer obeyed (`steer-marker.txt`), transcript has an `operator/steer` turn; stop -> `cancelled`; resolve -> Overview Resolved group |
| flow 5 Overview groups, coordinator chat | PASS | counts printed at each stage (created / completed / stopped / resolved) |
| flow 5 approve/deny a tool call, answer a question | **UNVERIFIED** | pi has no tool-permission or ask mechanism; only the empty list surfaces are checked |
| flow 6 notifications, usage | PASS | webhook sink received `run_update` deliveries; `usage` exits 0 |
| flow 7 review archive | PASS | all seven archive files, verdict `met` with four scores, verdict posted as a bead comment |
| failure provider-down | PASS | exit 3, unhealthy notice, no thread; restart -> reply; queued request served once; nonexistent model -> `provider_model_preflight_failed ... model_not_found` |
| failure agent-crash | PASS | `{:other, :execution}: ... exit_status 137` recorded, thread in Waiting on you, `failure` notification delivered |
| failure coordinator-crash | PASS in the final run; **FAIL once** (duplicate threads) in an earlier run | see defect `foreman-42t7a`; other early FAILs of this scenario were harness artifacts (the follow-up message said "do not start any thread") |
| failure server-crash (#607) | PASS | exec-port + server killed, agent orphaned to pid 1, restart: `OrphanReaper` killed it, run resumed in a fresh agent |
| failure project-paused | PASS | bead held while paused (no thread), coordinator start rejected `{:project_paused, ...}`, held bead starts after resume |
| failure br-down (writes) | PASS | thread completes, verdict recorded, `bead sink failed` in the summary, no comment on the bead |

## Defects found (all filed with `br create`, none labelled `foreman-exec`)

- `foreman-42t7a` **P2** a killed coordinator `ProjectWorker` leaves its turn task running (`Task.Supervisor.async_nolink`), the next
  worker starts a second turn. Observed once live (excerpt A below: 2 threads for one request, thread count 4 -> 6); later runs of the scenario were clean (LLM-nondeterministic, the race follows from `coordinator/project_worker.ex` `maybe_start/1`).
- `foreman-zmhzw` P3 an agent orphaned when only its exec-port dies (server alive) is never reaped and keeps running (excerpt B); agent tool
  children (`sleep`) also survive graceful server shutdown, `run cancel` and `thread stop` (the `sweep:` lines at the end of each
  transcript are the harness killing them, scoped by working directory).
- `foreman-uxfwb` P3 one `undetermined` / `evaluator_failed` review verdict in one of five healthy flow runs (concurrent load, cause not
  captured; the flow now prints the evaluator transcript tail and review log lines on that outcome).
- No open P0/P1 defect came out of this run.

Harness bugs fixed while writing the scripts (not product defects): CLI flags must precede the positional id; `--restart` and `--history`
cannot be combined with a message; the thread transcript, not an events endpoint, carries steer turns; resolved cards need
`?include_resolved=true`; BeadSink posts after `analysis.json` is written (the comment is polled for); an orphan only exists if exec-port
dies before the server (retry up to 3 attempts).

## Surprises worth knowing (observed, not defects)

- With `br` replaced entirely by a failing stub on the server's PATH, `BeadsWatcher` imports nothing (no thread for the bead within
  180 s). The br-down scenario therefore fails only the write verbs `comments`/`create`, which is what `BeadSink` uses.
- `{:other, :execution}` is still the failure class for a killed agent, but the reason now carries `exit_status 137` (F4, #605).

## Not covered (UNVERIFIED)

Real GitHub (PR, CI, webhooks, merge), Claude provider success paths, tool approvals and agent questions, Telegram/Slack delivery,
scheduled tasks, adopt/recommend, environment/secrets/network policy, thread-produced library files, per-thread usage rows, multi-repo
(see `docs/lessons/multi-repo-e2e-2026-10-21.md`), the full unit suite.

## Transcripts

### `claude_projects_flow.sh` (final run, exit 0)

```text

== setup: scratch repo, br database, database, notification sink, server ==
   scratch repo /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-cp/repo (local bare origin /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-cp/origin.git, br database /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-cp/repo/.beads)
   workflows: /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-cp/workflows (edit: pi minimax/MiniMax-M2.7-highspeed)
   CLI built: /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-cp/bin/foreman
   database foreman_e2e_claude_projects_cp ready
   notification sink pid 80970 on 127.0.0.1:4910 -> /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-cp/webhook-capture.jsonl
   server pid 80971, node e2ecp78732@127.0.0.1, http://127.0.0.1:4810 ready after 5s

== 1. project: create, goal, instructions, model/effort, limits ==
   project e2e-cp-78732 registered (task provider beads, database /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-cp/repo/.beads/beads.db)
  PASS        project update accepted
  PASS        project get shows the goal
  PASS        project get shows the instructions
  PASS        project get shows max_concurrent_runs 3
  PASS        standing context an agent would receive carries the instructions

== 2. memory and library ==
  PASS        memory topic house-style written
  PASS        memory read returns the content
  PASS        memory list names the topic
  PASS        library file facts.txt added
  PASS        library list shows the file
  PASS        library HTTP listing exits 200 (= 200)

== 3. a bead becomes a thread; the thread sees instructions, memory and library ==
   bead e2e-2ef created (label foreman-exec) in the scratch br database
  PASS        thread run:run-ca3864b3d837a0b21b9a9383a639cd6a created from bead e2e-2ef
   Overview counts, thread just created: {"idle":0,"landing":0,"ready_for_review":0,"resolved":0,"waiting_on_you":0,"working":1}
  PASS        thread run:run-ca3864b3d837a0b21b9a9383a639cd6a reached terminal-success status 'completed'
   Overview counts, thread completed: {"idle":1,"landing":0,"ready_for_review":0,"resolved":0,"waiting_on_you":0,"working":0}
   run run-ca3864b3d837a0b21b9a9383a639cd6a, branch foreman/e2e-2ef/run-ca3864b3d837a0b21b9a9383a639cd6a
  PASS        notes.txt on the branch carries the memory token
  PASS        notes.txt on the branch carries the library token
  PASS        notes.txt on the branch carries the instruction token

== 4. thread control: steer a running thread, stop one, resolve one ==
  PASS        two more threads running (run:run-f4b5bdb265c4aae4b9017bdef4bbd3e0, run:run-1a12176c3943f81f20645d68abcb91e3)
  PASS        steer target is working
  PASS        Overview shows running threads under Working (= yes)
  PASS        thread steer accepted
  PASS        steered thread: the agent obeyed the steering message (= STEERED-BY-OPERATOR)
   steered thread transcript turns:       3 agent/text;      1 operator/steer;      3 system/status;
  PASS        transcript shows the operator steer turn
  PASS        thread stop accepted
  PASS        stopped thread reached 'cancelled'
   Overview counts, one thread stopped: {"idle":2,"landing":0,"ready_for_review":0,"resolved":1,"waiting_on_you":0,"working":0}
  PASS        thread resolve accepted
  PASS        resolved thread reads back resolved=true (= true)
  PASS        Overview puts the resolved thread in the Resolved group (= 1)
   Overview counts after resolve: {"idle":1,"landing":0,"ready_for_review":0,"resolved":2,"waiting_on_you":0,"working":0}
  PASS        thread reopen accepted
  PASS        reopened thread reads back resolved=false (= false)

== 5. Overview groups, coordinator chat, approvals and questions ==
  PASS        overview endpoint answers with JSON (= "object")
   overview: {"attention":{"count":0,"needed":false,"reasons":[]},"counts":{"idle":2,"landing":0,"ready_for_review":0,"resolved":1,"waiting_on_you":0,"working":0},"generated_at":"2026-10-22T20:56:42.557Z","groups":{"idle":[{"actions":["thread.resolve"],"branch":"foreman/e2e-no9/run-f4b5bdb265c4aae4b9017bdef4bbd3e0","door":"workflow","failure_reason":null,"group":"idle","hint":null,"last_report":null,"merge_gat
  PASS        overview lists the first thread
  PASS        coordinator chat exits 0 (= 0)
  PASS        coordinator replied
  PASS        approvals list works (exit) (= 0)
  PASS        questions list works (exit) (= 0)
  UNVERIFIED  approve/deny a tool call and answer an agent question -- pi has no tool-permission or ask mechanism, so no approval or question is ever raised; only the empty list surfaces are checked

== 6. notifications and usage ==
  PASS        notification sink received 4 deliveries
   delivery classes:       1 action_needed;      3 run_update;
  PASS        usage report exits 0 (= 0)
   usage: {   "by_model": [     {       "cache_read_tokens": 51236,       "cache_write_tokens": 0,       "cost_unknown_events": 0,       "cost_usd": 0.021495359999999995,       "events": 6,       "input_tokens": 18450,       "model": "minimax/MiniMax-M2.7-highspeed",       "output_tokens": 3063,       "total_

== 7. review archive and verdict ==
  PASS        archive file manifest.json exists
  PASS        archive file request.md exists
  PASS        archive file transcript.jsonl exists
  PASS        archive file diff.patch exists
  PASS        archive file changed-files.txt exists
  PASS        archive file analysis.json exists
  PASS        archive file analysis.md exists
  PASS        request.md carries the bead's request
  PASS        diff.patch contains notes.txt
  PASS        analysis verdict recorded: met
   analysis.json: {"verdict":"met","scores":{"correctness":5,"documentation":3,"robustness":4,"tests":3},"error_code":null}
  PASS        the verdict was posted as a comment on the source bead

== summary ==
   passed=48 failed=0 unverified=1 wall=100s
   UNVERIFIED:
  - approve/deny a tool call and answer an agent question (pi has no tool-permission or ask mechanism, so no approval or question is ever raised; only the empty list surfaces are checked)
   sweep: killing stray process 97748 (cwd inside /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-cp): sleep 600
```

### `failure_injection.sh` (final run, all six scenarios, exit 0)

```text

== setup: scratch repo, br database, database, notification sink, server ==
   scratch repo /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail/repo (local bare origin /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail/origin.git, br database /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail/repo/.beads)
   workflows: /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail/workflows (edit: pi minimax/MiniMax-M2.7-highspeed)
   CLI built: /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail/bin/foreman
   database foreman_e2e_claude_projects_fail ready
   notification sink pid 49380 on 127.0.0.1:4930 -> /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail/webhook-capture.jsonl
   server pid 49381, node e2ecp48712@127.0.0.1, http://127.0.0.1:4830 ready after 4s
   project e2e-cp-48712 registered; scenarios: provider-down agent-crash coordinator-crash server-crash project-paused br-down

== scenario provider-down ==
   EXPECTED: unreachable coordinator provider -> typed unhealthy notice, no thread; restore -> reply, still no thread; nonexistent model -> run failed with a typed reason, not an opaque one
   ACTUAL chat exit=3: [system notice] The coordinator has not responded - last error: coordinator run ended failed. It will not retry until restarted (foreman project chat e2e-cp-48712 --restart). foreman project chat: the coordinator for project e2e-cp-48712 is unhealthy after 3 consecutive failures; last error: agent_f
  PASS        chat against a down provider fails visibly (exit 3, not a silent success)
   conversation: [   {     "at": "2026-10-22T21:26:13.651824Z",     "kind": "message",     "message_id": "cli-1792704373614387000-d02aba0b",     "report_key": null,     "role": "operator",     "seq": 1,     "source": "cli",     "suppressed": false,     "text": "Start a thread that creates hello.txt.",     "thread_ref": null,     "turn_id": null   },   {     "at": "2026-10-22T21:26:25.744393Z",     "kind": "notice",     "message_id": "unhealthy:cli-1792704373614387000-d02aba0b:a3",     "report_key": null,     "ro
  PASS        conversation records a typed unhealthy/error notice
  PASS        no thread was created while the provider was down (= 0)
  PASS        after restore + restart the coordinator answers (exit) (= 0)
  PASS        coordinator answered
  PASS        recovery served the queued request at most once (1 thread(s) for hello.txt): no duplicates
  PASS        run with a nonexistent model ended 'failed'
   ACTUAL failure_reason: "{:provider_model_preflight_failed, [%ForemanServer.Workflow.PreflightFailure{phase: \"edit\", provider: :pi, class: :model_not_found, model: \"minimax/no-such-model-e2e\", detail: nil}]}"
  PASS        run failure carries a recorded reason: "{:provider_model_preflight_failed, [%ForemanServer.Workflow.PreflightFailure{phase: \"edit\", provider: :pi, class: :model_not_found, model: \"minimax/no-such-

== scenario agent-crash ==
   EXPECTED: kill -9 of the agent mid-run -> run failed with a recorded reason, thread under Waiting on you, a failure notification delivered
   agent process tree: 79900 
  PASS        kill -9 sent to the agent processes of run run-1975e9f8cb97f0d13bf44c27b25d1190 (pids 79900 )
  PASS        run after agent kill (= failed)
   ACTUAL failure_reason: "{:other, :execution}: execution: pi: %{\"exit_status\" => 137, \"reason\" => \"{:exit_status, 9}\"}"
  PASS        agent kill recorded a reason: "{:other, :execution}: execution: pi: %{\"exit_status\" => 137, \"reason\" => \"{:exit_status, 9}\"}"
  PASS        thread status after the kill (= failed)
   Overview counts after the crash: {"idle":1,"landing":0,"ready_for_review":0,"resolved":1,"waiting_on_you":2,"working":0}
  PASS        Overview shows the failed thread under Waiting on you (= 1)
  PASS        a failure notification reached the webhook sink

== scenario coordinator-crash ==
   EXPECTED: killing the coordinator project worker mid-turn does not wedge the project: the next message is answered and the requested thread exists exactly once
   ACTUAL kill: KILLED #PID<0.1089.0>
  PASS        coordinator project worker killed mid-turn (KILLED #PID<0.1089.0>)
   ACTUAL chat after the kill: exit=0 [system notice] Too many thread reports this hour: further reports are listed here but will not start a coordinator turn until the hour rolls over. [system report] Thread run:run-c1dada6e4191fe3d60781
  PASS        coordinator answers after the crash (exit) (= 0)
  PASS        the requested thread exists exactly once after the crash (0 = request lost, 2 = duplicate actions) (= 1)
   thread count: 4 -> 7

== scenario server-crash ==
   EXPECTED: kill -9 of exec-port + server orphans the agent; after restart OrphanReaper reaps it and the run is not stuck on 'worktree already exists'
   agent pids: 13761 
   exec-port pids: 49979
   process tree before the crash:
     13406 49979 13406 S    pi        
     13761 49979 13761 S    pi      
     14160 13761 14160 Ss   sleep 300
     49432 49381 49432 Ss   erl_child_setup 1048576
     49979 49432 49979 Ss   /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/packages/foreman_server/_build/dev/lib/erlexec/priv/aarch64
     50544 49432 50544 Ss   /nix/store/jqc5i31qvkl45xf0xn4mhzmbdvkjy5p4-erlang-28.5.0.5/lib/erlang/erts-16.4.0.5/bin/inet_gethost 4
     50545 50544 50544 S    /nix/store/jqc5i31qvkl45xf0xn4mhzmbdvkjy5p4-erlang-28.5.0.5/lib/erlang/erts-16.4.0.5/bin/inet_gethost 4
     51402 49432 51402 Ss   /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/packages/foreman_server/_build/dev/lib/file_system/priv/mac
  PASS        agent orphaned to pid 1 after the crash (pids 13761)
   server pid 14862, node e2ecp48712@127.0.0.1, http://127.0.0.1:4830 ready after 5s
   ACTUAL run status after restart: in_progress; reason: null
  PASS        run resumed after the crash: a fresh agent (pids 20464 21522 ) is running in its worktree
  PASS        restart did not fail the run with 'worktree already exists'
  PASS        OrphanReaper terminated the orphaned agent(s)
  PASS        server log records the reap

== scenario project-paused ==
   EXPECTED: while paused no new thread starts (typed project_paused rejection), a running thread continues, resume restores admissions
  PASS        project pause accepted
  PASS        project reads back paused (= paused)
  PASS        no thread started for the bead while paused (= 8)
   ACTUAL chat while paused: I'm asking Foreman to start one new thread, "Create x.txt", whose task is to add a file `x.txt` at the repository root containing `X`, staged and committed on its own branch with nothing else touched. [system notice] I did not run start_thread: {:task_create_failed, {:project_paused, "e2e-cp-48712"}
  PASS        no thread started through the coordinator while paused (= 8)
  PASS        project resume accepted
  PASS        after resume the held bead started thread run:run-670b5ee13873887c4f3742a94f425ab2 (not lost)

== scenario br-down ==
   EXPECTED: with br writes (comments/create) failing for the server the thread still completes and its review verdict is still recorded; the bead-sink failure is visible in the recorded summary; no comment lands on the bead
   server pid 84340, node e2ecp48712@127.0.0.1, http://127.0.0.1:4830 ready after 4s
  PASS        thread completed while br was down (= completed)
   ACTUAL review report: verdict='met' summary='The delivered diff creates exactly one new file, brdown.txt, whose sole content is the word UP on a single line, fully satisfying the request. No unrelated changes are included, and the transcript/manifest show the run completed cleanly with the diff captured and no capture errors. Tests and documen'
  PASS        review verdict recorded while br was down: met
  PASS        the bead-sink failure is visible in the recorded summary
  PASS        no review comment landed on the bead

== summary ==
   passed=32 failed=0 unverified=0 wall=299s
   sweep: killing stray process 21522 (cwd inside /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail): sleep 300
   sweep: killing stray process 80240 (cwd inside /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail): sleep 300
   sweep: killing stray process 89141 (cwd inside /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail): /bin/bash -c date -u +%FT%TZ; sleep 300; echo "sleep 300 completed at $(date -u 
   sweep: killing stray process 89155 (cwd inside /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/tmp/e2e-claude-projects-fail): sleep 300
```

### Excerpt A: coordinator-crash FAIL (earlier run, duplicate actions)

```text
== scenario coordinator-crash ==
   EXPECTED: killing the coordinator project worker mid-turn does not wedge the project: the next message is answered and the requested thread exists exactly once
   ACTUAL kill: KILLED #PID<0.1079.0>
  PASS        coordinator project worker killed mid-turn (KILLED #PID<0.1079.0>)
   ACTUAL chat after the kill: exit=0 ACK [system notice] Too many thread reports this hour: further reports are listed here but will not start a coordinator turn until the hour rolls over.
  PASS        coordinator answers after the crash (exit) (= 0)
  FAIL        coordinator crash produced 2 threads titled 'e2e-51148 coordinator crash probe' (duplicate actions)
   thread count: 4 -> 6

```

### Excerpt B: server-crash, variant 1 (only the exec-port is killed, server stays alive 1 s) - agent orphaned, run failed, orphan never reaped

```text
== scenario server-crash ==
   EXPECTED: kill -9 of exec-port + server orphans the agent; after restart OrphanReaper reaps it and the run is not stuck on 'worktree already exists'
   agent pids: 93698 
   exec-port pids: 92321
   process tree before the crash:
     91866 91802 91866 Ss   erl_child_setup 1048576
     92321 91866 92321 Ss   /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/packages/foreman_server/_build/dev/lib/erlexec/priv/aarch64
     92587 91866 92587 Ss   /nix/store/jqc5i31qvkl45xf0xn4mhzmbdvkjy5p4-erlang-28.5.0.5/lib/erlang/erts-16.4.0.5/bin/inet_gethost 4
     92588 92587 92587 S    /nix/store/jqc5i31qvkl45xf0xn4mhzmbdvkjy5p4-erlang-28.5.0.5/lib/erlang/erts-16.4.0.5/bin/inet_gethost 4
     93462 91866 93462 Ss   /Users/ldangelo/Development/Fortium/foreman-wt/accscripts/packages/foreman_server/_build/dev/lib/file_system/priv/mac
     93698 92321 93698 S    pi      
     94291 93698 94291 Ss   sleep 300
   agent processes right after exec-port was killed:
     93698     1 93698 S    pi      
  PASS        agent orphaned to pid 1 after the crash (pids 93698)
   server pid 95855, node e2ecp90928@127.0.0.1, http://127.0.0.1:4830 ready after 5s
   ACTUAL run status after restart: failed; reason: "{:other, :execution}: execution: pi: %{\"exit_status\" => nil, \"reason\" => \":port_closed\"}"
  PASS        restart did not fail the run with 'worktree already exists'
  FAIL        orphaned agent(s) still alive after restart: 93698
  FAIL        server log records the reap: 'OrphanReaper' not found in: 
15:25:53.699 [info] Loading 164 CA(s) from :otp store

15:25:54.563 [info] Exporter :otel_exporter_traces_otlp successfully initialized

15:25:54.656 [info] SessionManager started

```
