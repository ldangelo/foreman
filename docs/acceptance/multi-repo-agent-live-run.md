# Multi-repo with a real agent over Foreman's own MCP endpoint: live verification, 2026-10-25

Beads: `foreman-cnn1l` (bug: `/mcp` answered HTTP 500 on a server booted the way the live harnesses boot it) and `foreman-he4yf`
(multi-repo paths not live-verified). Everything below was observed unless marked UNVERIFIED. Harness:
`scripts/e2e/multi_repo_agent.sh` (assets: `scripts/e2e/multi_repo/agent_probe.exs`, `fake-gh`).

## Environment

- Branch `foreman/parity-gaps` at `c44220e8` plus the uncommitted working tree that holds the fix below.
- The server is booted the way every live harness boots it: `MIX_ENV=dev`, `elixir --name <node> -S mix run --no-start --no-halt
  scripts/e2e/claude_projects/boot.exs`, **not** `mix phx.server`. Own ports (claude run 4871, pi run 4872), private databases
  `foreman_e2e_mcp` / `foreman_e2e_mcp_pi` (dropped afterwards), `HOME` redirected to `<work>/home`.
- Agent 1: the real `claude` CLI (2.1.308, from the `clientInfo` in the server log), model `haiku`, `approval_mode: auto_approve`
  (`--permission-mode bypassPermissions`). Its `HOME` has a private empty `.claude` and a copy of the operator's `.claude.json`
  (login metadata; the OAuth token stays in the keychain) with ONE user-scope HTTP MCP server, `foreman` ->
  `http://127.0.0.1:4871/mcp` with the bearer token. No other MCP server, hook or plugin.
- Agent 2: the real `pi` with `minimax/MiniMax-M2.7-highspeed`; a private agent dir whose only MCP server is `foreman`
  (`pi mcp add foreman --url ... --header Authorization=Bearer ... --exposure direct`).
- GitHub is faked: a recording `gh` (`scripts/e2e/multi_repo/fake-gh`) and local bare origins. Review analysis is off. Real GitHub was
  not touched.

## foreman-cnn1l: `/mcp` answered HTTP 500 on a harness-booted server

**Reproduced** (before the fix) on a throwaway server booted that way: `curl -X POST http://127.0.0.1:4871/mcp` (bearer token,
`initialize`) -> `HTTP/1.1 500`, `** (ArgumentError) ... no persistent term stored with this key`,
`:persistent_term.get({Anubis.Server.Supervisor, ForemanServer.MCP, :session_config})` from
`Anubis.Server.Supervisor.get_session_config/1` (`anubis_mcp` 1.14.0, `supervisor.ex:174`) via `plug.ex:162`. Asked through
`--rpc-eval`, the live node said `Application.get_env(:phoenix, :serve_endpoints) = false`, `PHX_SERVER = nil`,
`ANUBIS_MCP_SERVER = nil` and `Application.get_env(:foreman_server, :mcp)` = `enabled: true, allow_workflow_writes: true,
allow_insecure_local: true`.

**Root cause.** `Anubis.Server.Supervisor.init/1` writes the `:session_config` persistent_term only when `should_start?/1` says so.
For `{:streamable_http, opts}` without a `:start` option that is `http_server_running?/0`: `ANUBIS_MCP_SERVER`, `PHX_SERVER` or
`Application.get_env(:phoenix, :serve_endpoints)` not being false. Phoenix's own `mix.exs` defaults `serve_endpoints` to `false` and
only `mix phx.server` sets it to `true`. `ForemanServer.MCP.child_spec/1` passed the bare atom `:streamable_http`, so on every boot that
serves HTTP some other way the supervisor returned `:ignore`, which OTP counts as a successful start (nothing in the boot log), and
`/mcp` raised on every request. That covers the live harnesses (`mix run --no-start --no-halt boot.exs`) and a release
(`config/prod.exs` sets `server: true`, not `PHX_SERVER`). The earlier live run that did call `foreman_run_request_repo`
(`parity-gaps-live-run.md`) was booted with `mix phx.server`, which is the whole difference.

**A second defect in the same function**, found while writing the test: `Dispatch.transport_opts/2` passed
`authorization: [validator: {Auth, []}]` whenever `allow_insecure_local` was off. Anubis parses that option as an OAuth 2.1 resource
server (Peri requires `resource` and `authorization_servers`) and its plug then calls `validate_token/2` on the validator, which
`ForemanServer.MCP.Auth` does not define. A token-protected MCP could not boot at all (`Peri.InvalidSchema` in `init/1`, which stops
the application). `docs/cli-reference.md` documented that configuration as working.

**Fix** (production code): `ForemanServer.MCP.child_spec/1` passes `{:streamable_http, start: true}` (Foreman's own
`:mcp, enabled` already decided to start it); `Dispatch.transport_opts/2` never passes Anubis' `:authorization` (Foreman authenticates
with the `ForemanServer.MCP.Auth` Plug in front of the transport and `Dispatch.call/4` per tool call, both honouring
`allow_insecure_local`). Files: `lib/foreman_server/mcp.ex`, `lib/foreman_server/mcp/dispatch.ex`.

**Regression tests** (`test/foreman_server/mcp/http_boot_test.exs`, 6 tests, and the pin in `mcp_transport_test.exs`): they start the
child `ForemanServer.Application.children/0` builds for an enabled MCP, under the Phoenix state of such a boot
(`:serve_endpoints` false, neither environment variable), with the persistent_term erased first, and speak to it through the real
endpoint (`initialize`, `notifications/initialized`, `tools/list`, `tools/call`); the token-protected variant must answer 401 without
the token and serve with it.

| Command | Result |
|---|---|
| `mix test test/foreman_server/mcp/http_boot_test.exs test/foreman_server/mcp/mcp_transport_test.exs test/foreman_server_web/mcp_router_test.exs test/foreman_server/mcp_supervisor_test.exs --warnings-as-errors --no-cover` | 30 passed |
| same two files, `start: true` removed from `child_spec/1` (temporary mutation) | 15/21 passed: 6 failures, all `ArgumentError ... no persistent term stored with this key` (the 500) |
| same two files, the old `authorization` branch restored (temporary mutation) | 19/21 passed: the token-protected boot fails with `Peri.InvalidSchema`, and the "never passed" test fails |

The unit suites missed it because the test environment disables MCP and `MCPRouterTest` writes the persistent_term by hand: a test that
seeds the state the production code is meant to create proves nothing about that code (`docs/lessons/typed-boundaries-full.md` 5.6).

## foreman-he4yf: the harness, green

```
E2E_PORT=4871 E2E_HOOK_PORT=4971 E2E_DB_NAME=foreman_e2e_mcp devbox run -- bash scripts/e2e/multi_repo_agent.sh
   passed=52 failed=0 unverified=0 wall=154s          (real claude haiku)
E2E_PROVIDER=pi E2E_PORT=4872 E2E_HOOK_PORT=4972 E2E_DB_NAME=foreman_e2e_mcp_pi devbox run -- bash scripts/e2e/multi_repo_agent.sh
   passed=52 failed=0 unverified=0 wall=116s          (real pi + MiniMax)
```

Stages `phases fanout jobsite`; setup first asserts that `/mcp` answers `initialize` with HTTP 200 on the freshly booted server (it
answered 500 before the fix, and the script stops there when it does).

What the assertions establish (claude run; the pi run passes the same ones):

* **Per-phase repository selection and thread self-add, driven by the agent.** One task over the project's primary repository only
  (no `repo_ids`). Phase 1's agent recorded `printenv FOREMAN_REPOS` and called the MCP tool `foreman_run_request_repo` twice: the
  registered repository `b` by `repo_id`, and a git checkout `c` that no operator registered, by `repo_path` (registered on the spot as
  `repo-c`: `reason: registered_and_attached`). Both are audited `allowed` on `run_repo_audit:<run>`, `requested_by: run:<run>`. The
  worktrees of `b` and `repo-c` were created **during phase 1** (event times: phase 1 `...764053..773953`, worktrees `...771720`,
  `...772040`), yet phase 1's own environment (`FOREMAN_REPOS` keys `["main"]`) and prompt (`{{repositories_count}}` = 1) list only the
  primary; phase 2's environment is `["b","main","repo-c"]`, its prompt renders 3, `b`'s checkout is `<run>/repos/b`, and the agent's
  edit (`PHASE2` containing `phase2-<id>`) is committed on the pushed branch of **each** of the three repositories, while phase 1 wrote
  nothing into `b` or `repo-c`. Three branches, three PR associations, three `pr create` calls, each from its own checkout. The calls
  and their arguments come from the agent's own session file, not from the harness.
* **Env contract.** `FOREMAN_REPOS` as the agent saw it in its own process environment, per phase, not only that the unit tests compute
  it (the earlier harness proved only that an agent could reach `b` through a path in its prompt).
* **Agent-driven fan-out.** A run's agent called `foreman_task_fanout` (`repo_ids: "all"`, a `fanout_id`) and then repeated the
  identical call. The tool answered the first call `created` for every repository and the repeat with the same three task ids; exactly
  one open task `<fanout_id>-<repo_id>` per registered repository exists (`b`, `main`, `repo-c`), every `TaskCreated` carries
  `source: "fanout:<fanout_id>"`, one event each. The operator then approved them (`task.approve` with `approved_by`); each is its own
  single-repository run (the `b` and `repo-c` runs have that repository as primary), commits `FANOUT` with the exact token on its own
  branch, and opens exactly one PR from that repository's checkout.
* **Jobsite multi-repo is refused by design** (`docs/spikes/S3.md`): `POST /api/jobsites` with a `repositories` key answers
  `403 spec_forbidden_key`, message `repositories cannot be supplied in a remote spec: multi-repo jobsites unsupported`, and no
  jobsite exists afterwards.
* Strays: each repository has only its main checkout registered as a worktree; the fake `gh` saw no unsupported invocation.

## Found by running it (and what became of each)

1. `foreman-cnn1l` and its twin (the token-protected MCP that could not boot): fixed here, above.
2. **`ForemanServer.Notifier` crash-looped on every typed event** (a defect in an uncommitted change made by another agent the same
   hour, not in the committed tree): `Notifier.process/3` normalised every event's payload, but a freshly appended event's `data` is a
   typed struct and `Rule.normalize_payload!/1` was guarded `not is_struct/1`. Live: `FunctionClauseError ... normalize_payload!/1 ...
   %ForemanServer.Events.ProjectRepositoryAdded{}`, seven restarts in a quiet run. In one run (`passed=43 failed=6`) the server stopped
   answering mid-fan-out (`connection refused` for the rest of the ten minutes) while the Notifier was restarting several times a
   second, and the server log ended right after four Notifier crashes within five seconds (the application supervisor's default
   restart intensity; that this is what took the endpoint down is likely, not proven: that run's log was not kept). Reported to its
   owner, fixed the same hour (struct read through `Map.from_struct`, unmapped types untouched), pinned with a real
   `%ProjectRepositoryAdded{}` and `%RunBlocked{}`; after it the claude and pi runs show no `Notifier terminating`.
3. Harness corrections, no product change: `task.approve` over `/api/commands` needs `approved_by`; the task read model does not carry
   `source` (the `TaskCreated` events do), so the harness reads it there; a repeated `foreman_task_fanout` reports each task `created`
   again (the replayed command id appends nothing and is acknowledged), not `exists` as the `TaskFanout` moduledoc said; the
   moduledoc now says what the live run showed.
4. Observed, harmless: Anubis 1.14.0 answers claude 2.1.308's first probe (`MCP-Protocol-Version: 2026-07-28`) with a logged
   `unsupported_protocol_version` 400, and claude then initializes at `2025-11-25`; once per claude session, nothing fails.
5. Host load (load average 40 to 70 from other work) made one pi server boot fail with a 5 s `GenServer.call` timeout registering the
   `AdapterCatalog` adapter; the same run passed on retry. Not touched.

## UNVERIFIED / not exercised

* Multi-repository runs against **real GitHub** (PR creation, mergeability and branch protection through the real `gh`): the fake `gh`
  is what stands in, as in `docs/lessons/multi-repo-e2e-2026-10-21.md`. That needs two real private repositories and is out of scope.
* Models other than `haiku` for claude and MiniMax for pi.

## Transcript (claude run, as printed by the harness; long lines cut)

```

== foreman multi-repo agent live e2e: provider=claude model=haiku stages=[phases fanout jobsite] ==

== setup: scratch repo, br database, database, notification sink, server ==
   scratch repo <repo>/tmp/e2e-mcp-agent/repo (local bare origin <repo>/tmp/e2e-mcp-agent/origin.git, br database <repo>/tmp/e2e-mcp-agent/repo/.beads)
   workflows: <repo>/tmp/e2e-mcp-agent/workflows (edit: pi minimax/MiniMax-M2.7-highspeed)
   CLI built: <repo>/tmp/e2e-mcp-agent/bin/foreman
   database foreman_e2e_mcp ready
   notification sink pid 33387 on 127.0.0.1:4971 -> <repo>/tmp/e2e-mcp-agent/webhook-capture.jsonl
   server pid 33388, node e2ecp30998@127.0.0.1, http://127.0.0.1:4871 ready after 46s
   repositories: <repo>/tmp/e2e-mcp-agent/repo (primary, id main)  <repo>/tmp/e2e-mcp-agent/repo-b (b)  <repo>/tmp/e2e-mcp-agent/repo-c (c, never registered by the operator); local bare origins, fake gh first on the server PATH
   claude answers through <repo>/tmp/e2e-mcp-agent/home (private .claude, copied .claude.json + user-scope MCP server foreman -> http://127.0.0.1:4871/mcp)
   restarting the server so it loads the workflows and the new PATH entries
   server pid 37966, node e2ecp30998@127.0.0.1, http://127.0.0.1:4871 ready after 25s
   project e2e-cp-30998 over <repo>/tmp/e2e-mcp-agent/repo; repositories: [{"id":"main","primary":true},{"id":"b","primary":false}]; repo_allowlist=[<repo>/tmp/e2e-mcp-agent]
  PASS        /mcp answers initialize with HTTP 200 on this harness-booted server (foreman-cnn1l: it answered 500) (= 200)
  PASS        /mcp initialize names the Foreman MCP server (= foreman-mcp)

== phases: one run, two phases; phase 1 asks for b (repo_id) and c (repo_path), phase 2 works in all three ==
  PASS        task.create (primary repository only, no repo_ids) (= 201)
   run id: run-473fefb352885da7594a992ddba8470f
   run run-473fefb352885da7594a992ddba8470f: awaiting_worker (+0s)
   run run-473fefb352885da7594a992ddba8470f: in_progress (+3s)
   run run-473fefb352885da7594a992ddba8470f: completed (+24s)
   terminal status 'completed' after 25s
  PASS        phases: run completed
   timeline: [{"type":"PhaseStarted","repo_id":null,"index":1,"decision":null,"reason":null,"at_ms":1792983764053},{"type":"WorktreeCreated","repo_id":null,"index":null,"decision":null,"reason":null,"at_ms":1792983764399},{"type":"WorktreeCreated","repo_id":"b","index":null,"decision":null,"reason":null,"at_ms":1792983771720},{"type":"RunRepoRequested","repo_id":"b","index":null,"decision":"allowe …
  PASS        audit: RunRepoRequested events (one per request the agent made) (= 2)
  PASS        audit: both requests were allowed (= ["allowed"])
  PASS        audit: requested by the run itself (= run:run-473fefb352885da7594a992ddba8470f)
   repository c was registered by the request under the id 'repo-c'
  PASS        audit: the registered repository was requested by repo_id (= 1)
  PASS        worktree of 'b' was created DURING phase 1 (phase 1 1792983764053..1792983773953, worktree 1792983771720)
  PASS        worktree of 'repo-c' was created DURING phase 1 (phase 1 1792983764053..1792983773953, worktree 1792983772040)
  PASS        phase 2 started after phase 1 completed (= yes)
   phase 1 $FOREMAN_REPOS (as the agent captured it): {"main":{"base_branch":"main","base_ref":"89e147cca4e87c98106faece896a504b2efa9e35","branch":"foreman/phases-task-30998/run-473fefb352885da7594a992ddba8470f","path":"<repo>/tmp/e2e-mcp-agent/home/.foreman/worktrees/e2e-cp-30998/phases-task-30998/run-473fefb352885
   phase 2 $FOREMAN_REPOS (as the agent captured it): {"b":{"base_branch":"main","base_ref":"b30574f1289894cc45d79e54d650c76aad8248cd","branch":"foreman/phases-task-30998/run-473fefb352885da7594a992ddba8470f","path":"<repo>/tmp/e2e-mcp-agent/home/.foreman/worktrees/e2e-cp-30998/phases-task-30998/run-473fefb352885da7594a992ddba8470f/repos/b","primary":false},"main":{"base_branch":"main","base_ref": …
  PASS        phase 1 environment: FOREMAN_REPOS lists ONLY the primary (= ["main"])
  PASS        phase 2 environment: FOREMAN_REPOS lists the primary and both requested repositories (= ["b","main","repo-c"])
  PASS        phase 2: b's checkout is <run>/repos/b
  PASS        phase 1 prompt: {{repositories_count}} rendered as (= 1, exact content)
  PASS        phase 2 prompt: {{repositories_count}} rendered as (= 3, exact content)
  PASS        phase 2 edit reached repository 'main' (committed on its pushed branch) (= phase2-main, exact content)
  PASS        phase 2 edit reached repository 'b' (committed on its pushed branch) (= phase2-b, exact content)
  PASS        phase 2 edit reached repository 'repo-c' (committed on its pushed branch) (= phase2-repo-c, exact content)
  PASS        phase 1 wrote nothing into b or c (they only became visible in phase 2) (= no)
  PASS        pr_associations: one PR per repository (= 3)
  PASS        fake gh: 'pr create' calls for the run branch (= 3)
  PASS        fake gh: the PR of repo was created from its own checkout (= 1)
  PASS        fake gh: the PR of repo-b was created from its own checkout (= 1)
  PASS        fake gh: the PR of repo-c was created from its own checkout (= 1)
   agent's foreman_run_request_repo calls: {"run_id":"run-473fefb352885da7594a992ddba8470f","repo_id":"b"} {"run_id":"run-473fefb352885da7594a992ddba8470f","repo_path":"<repo>/tmp/e2e-mcp-agent/repo-c"}
  PASS        the agent called foreman_run_request_repo twice (its own transcript) (= 2)
  PASS        every call named this run's id (= run-473fefb352885da7594a992ddba8470f )
   stage phases took 27s

== fanout: an agent calls foreman_task_fanout for every repository, twice ==
  PASS        task.create for the agent that fans out (= 201)
   run id: run-38918bec6a3100b631086e3aeebe0109 (registered repositories: b,main,repo-c)
   run run-38918bec6a3100b631086e3aeebe0109: in_progress (+0s)
   run run-38918bec6a3100b631086e3aeebe0109: completed (+9s)
   terminal status 'completed' after 10s
  PASS        fanout: the agent's run completed
   agent's foreman_task_fanout calls: {"project_id":"e2e-cp-30998","title":"E2E fan-out 30998","prompt":"Create a file named FANOUT in the repository root containing exactly FANOUT-30998-1792983790 followed by a newline.","workflow":"repo-one","repo_ids":"all","fanout_id":"fan30998"} {"project_id":"e2e-cp-30998","title":"E2E fan-out 30998","prompt":"Create a file named FANOUT in the repository roo …
  PASS        the agent called foreman_task_fanout twice (its own transcript) (= 2)
  PASS        both calls carried the same fanout_id (= fan30998 )
  PASS        first call: the tool created a task for every repository (= created)
  PASS        repeat call: the same task ids, nothing new (idempotent per fanout_id) (= ["fan30998-b","fan30998-main","fan30998-repo-c"])
  PASS        repeat call: every task reported created (replayed command) or exists, never rejected (= 0)
   tasks: [{"task_id":"fan30998-b","status":"open","repo_id":"b","workflow_type":"repo-one"},{"task_id":"fan30998-main","status":"open","repo_id":null,"workflow_type":"repo-one"},{"task_id":"fan30998-repo-c","status":"open","repo_id":"repo-c","workflow_type":"repo-one"}]
  PASS        one task per registered repository, no duplicate from the second call (= 3)
  PASS        task ids are <fanout_id>-<repo_id> (= b,main,repo-c)
  PASS        every fanned-out task is open until the operator starts it (= open)
  PASS        every fanned-out task carries the fan-out source (TaskCreated.source) (= fanout:fan30998)
  PASS        one TaskCreated event per repository (the repeat created nothing) (= 3)
   approved 3 fanned-out tasks; waiting for their runs
   run run-daa899cd32b41e783e089fcfc749fcf9: awaiting_worker (+0s)
   run run-daa899cd32b41e783e089fcfc749fcf9: in_progress (+3s)
   run run-daa899cd32b41e783e089fcfc749fcf9: completed (+6s)
  PASS        fan-out run in repository 'b': FANOUT committed on its own branch (= FANOUT-30998-1792983790, exact content)
  PASS        fan-out run in repository 'b': exactly one PR, from that repository's checkout (= 1)
   run run-9f75fab8341ccc5a3b299efc10c0dbb7: completed (+0s)
  PASS        fan-out run in repository 'main': FANOUT committed on its own branch (= FANOUT-30998-1792983790, exact content)
  PASS        fan-out run in repository 'main': exactly one PR, from that repository's checkout (= 1)
   run run-115661d2aa8893492bd11cf3feb6d455: completed (+0s)
  PASS        fan-out run in repository 'repo-c': FANOUT committed on its own branch (= FANOUT-30998-1792983790, exact content)
  PASS        fan-out run in repository 'repo-c': exactly one PR, from that repository's checkout (= 1)
   stage fanout took 17s

== jobsite: a multi-repository jobsite is refused with its typed error, and nothing starts ==
  PASS        POST /api/jobsites with `repositories`: HTTP status and typed error (= 403 spec_forbidden_key)
  PASS        the refusal names the reason
  PASS        no jobsite was started (= 0)
   stage jobsite took 1s

== strays: nothing left behind by the runs ==
  PASS        repo: only its main checkout is a registered worktree (= 1)
  PASS        repo-b: only its main checkout is a registered worktree (= 1)
  PASS        repo-c: only its main checkout is a registered worktree (= 1)
  PASS        fake gh: unsupported invocations over the whole run (= 0)

== summary ==
   passed=52 failed=0 unverified=0 wall=154s
```

## How to run

```
devbox run -- bash scripts/e2e/multi_repo_agent.sh                      # claude (haiku), stages phases fanout jobsite
E2E_PROVIDER=pi devbox run -- bash scripts/e2e/multi_repo_agent.sh      # pi + MiniMax
E2E_STAGES="phases" E2E_KEEP=1 ...                                      # one stage; keep server, database and work dir
```

Needs the `scripts/e2e/claude_projects/lib.sh` prerequisites (Elixir/OTP, `jq`, `git`, `go`, `psql`, `br`, `pi`, the dev Postgres at
`localhost:55432`) and, for claude, a logged-in `claude` (a host without one records UNVERIFIED, never a pass). Exit status: 0 all
passed, 1 environment problem, 2 setup failed, 3 an assertion failed. After `E2E_KEEP=1` kill the node and the webhook sink by pid,
`DROP DATABASE <name> WITH (FORCE)` and remove the work dir.
