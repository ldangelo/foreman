# Live verification of project archive, MCP `foreman_schedule_update` and value-based redaction, 2026-10-30

Beads: `foreman-5fqso` (C11, archive/reactivate/delete live; closed), `foreman-7c191` part 1 (C9, MCP `foreman_schedule_update`;
stays open for part 2), `foreman-ngky4` (C2/C4, value-based redaction end to end; stays open). Everything below was observed
unless marked UNVERIFIED or "not observed". Three new scripts, each starting its own throwaway server.

## Environment

- Branch `test/e2e-live-verify-scripts`. The harness builds the Go CLI from the worktree at the start of each run; the product code under
  test is main `b5af2d4c`, and the last redaction run's `summary.txt` records the worktree HEAD as `e07913e8`. The server is the real BEAM
  dev server the harness boots (`scripts/e2e/claude_projects/lib.sh`: own port, own Postgres database, own work dir, scratch git repo
  with a local bare origin, own `br` database, redirected `HOME`). pi 1.4.0 and `br` 0.6.0 (recorded in the redaction run's
  `summary.txt`), model `minimax/MiniMax-M2.7-highspeed`, Postgres `localhost:55432`. No claude, no GitHub.
- Host load average during the runs was 3-9 (9.53 at the start of the first archive run, 5.01 at the end of the last redaction run;
  `environment.txt` / `summary.txt` of the kept evidence).
- Every run below used `devbox run -- bash scripts/e2e/<script>`; the results are the final `== summary ==` line of the run's log.

## The scripts

| Script | Port / hook port / database | Needs | Model | Result |
|---|---|---|---|---|
| `scripts/e2e/project_archive_flow.sh` (+ `project_archive/pi-held.sh`) | 4880 / 4980 / `foreman_e2e_claude_projects_parch` | `git jq curl psql go elixir mix python3 br pi`, a pi with working minimax credentials | real pi for the workflow runs; the jobsite agent is a shim that blocks one marked prompt until a release file exists and forwards every other pi call to the real pi | run 2: passed=55 failed=0 unverified=0 (summary wall=23 s); run 1: passed=39 failed=1 unverified=1 (28 s) |
| `scripts/e2e/mcp_schedule_update.sh` | 4890 / 4990 / `foreman_e2e_claude_projects_mcpsched` | same tools (pi only checked for existence) | none: plain JSON-RPC over `/mcp`, the real Go CLI, the real projection | passed=84 failed=0 unverified=0 (summary wall=13 s) |
| `scripts/e2e/redaction_value_live.sh` | 4840 / 4940 / `foreman_e2e_redaction_value` | the same plus `pg_dump`; pi only (`E2E_PROVIDER=claude` exits 2 by owner decision) | real pi agent and real pi coordinator | run 3: passed=62 failed=2 unverified=1 (79 s); runs 1 and 2 below; re-sweep after `foreman-mw5rz` (runs 4 and 5, 2026-10-31): run 5 passed=62 failed=0 unverified=2 (113 s), server log 0 hits |

Run each as `devbox run -- bash scripts/e2e/<script>`. A failing run keeps its evidence in `tmp/e2e-evidence/<name>-<UTC start>-<pid>/`
(see the README "Run the flow" section for its layout); a passing run keeps nothing. Exit 3 = a FAIL, as for the other harnesses.
Optional environment for the redaction script: `E2E_AGENT_MODEL`, `E2E_AGENT_ATTEMPTS` (default 2: the memory-writing bead is
  retried once with a fresh bead because the first thread of a stack intermittently fails at kickoff, `foreman-azc2o`), `E2E_KEEP=1`.

## 1. Archive, reactivate, delete (`foreman-5fqso`, C11)

`foreman project delete` is a soft delete (archive; `docs/decisions/project-delete.md`). Run 2 (clean), 55 assertions, none failed:

**Item 1, a workflow run in flight blocks the archive.**
- A real pi workflow run was `in_progress`; `project delete` exited 3 with HTTP 409 `project_has_active_runs` naming the run id;
  `project delete --force` exited 3 and printed `project archive blocked by active runs: <run id>` on stderr; the project stayed listed
  and the run kept running; after `run cancel` the run was terminal.
- The archive was then accepted (`archived project e2e-cp-28608`). `GET /api/projects` hid the project,
  `GET /api/projects?include_archived=true` showed it, `GET /api/projects/:id` still answered 200 with `status: archived`.
- `run submit` against the archived project exited 1 with the typed `project_archived` error (HTTP 422) and created no run (no run
  exists for the refused task).
- Nothing was purged: the `.foreman` marker file, the memory topic (also readable through the CLI), the library entry and the earlier
  (cancelled) run were still there while archived and again after `project reactivate`.
- `project reactivate` restored the project in `GET /api/projects`, and a new run was accepted and reached `running`.

**Item 2, a running jobsite does NOT block the archive** (deliberate: a jobsite holds no run reservation;
`test/foreman_server/jobsite/project_archive_test.exs`, `docs/decisions/project-delete.md`; bead `foreman-msgf8` was closed as not a bug).
- A jobsite started through `POST /api/jobsites` (HTTP 202) whose agent was the held pi shim: `running`, agent pid alive.
- `project delete` was ACCEPTED (exit 0). The jobsite stayed `running` and its agent pid was alive 6 s later.
- A second `POST /api/jobsites` answered HTTP 422 `spec_project_unavailable` ("project ... is archived"); `GET /api/jobsites` still
  listed exactly one more jobsite than before.
- After the release file was written the jobsite completed (`status completed`, `last_error: null`) inside the archived project and
  the held agent exited.
- After `project reactivate` a new `POST /api/jobsites` was accepted (HTTP 202) and the jobsite completed.

**Run 1** (passed=39 failed=1 unverified=1) hit a transient: the script's own check `pi --version` through the shim returned exit 134
(FAIL), and both attempts to start a workflow run failed at kickoff with `provider_model_preflight_failed`, class `catalog_unavailable`
(model `minimax/MiniMax-M2.7-highspeed`, phase `edit`), so "archive refused while a run is in flight" was recorded UNVERIFIED. The run's
`environment.txt` shows `pi --list-models minimax/MiniMax-M2.7-highspeed` exiting 0 after 1 s as the server runs it. Run 2 passed with no
change; the cause of the transient is not established (a bounded probe did not reproduce it; see the `foreman-azc2o` comment).

**Not covered:** a multi-iteration jobsite's later iterations and PR creation inside an archived project (the script's jobsite makes one
iteration): bead `foreman-7p068` stays open.

## 2. MCP `foreman_schedule_update` (`foreman-7c191` part 1, C9)

`scripts/e2e/mcp_schedule_update.sh`: 84 assertions, all passed. The schedule is created with the CLI (`--every 1h`, never fires).
- `tools/list` advertises `foreman_schedule_update` and the other five schedule tools; 62 tools with writes on.
- It is a write tool: with `allow_workflow_writes` switched off at runtime, exactly the 27 tools of `Policy.write_tools()` are dropped
  (the list was read from the node, not hard-coded), no other tool appears, `foreman_schedule_list` is still listed, and a `tools/call` of update is
  answered exactly as `foreman_schedule_create`: `{"code":-32602,"message":"Invalid params","data":{"message":"Tool not found: <tool>"}}`.
  Writes back on restores the original list.
- Update of `name`, `prompt`, `every` and `cron` each, and `name`+`prompt`+`every` in one call, returns exactly
  `{"status":"updated","project_id":...,"schedule_id":...}`; `foreman project schedule list --json` shows each change and the fields
  not named keep their values.
- No change fields (only `project_id` and `schedule_id`): the aggregate's typed `missing_or_invalid`, NOT `INVALID_PARAMS` (the bead text
  said INVALID_PARAMS; that was wrong). `INVALID_PARAMS` is the answer for a missing `schedule_id` and for an unknown argument.
- After `foreman project schedule delete` the update is refused `schedule_deleted` and the schedule does not come back; an unknown id is
  refused `schedule_not_found` and creates nothing.

~~Observation (bead `foreman-n2eh3`, P4): these typed errors reach the client as a STRING JSON-RPC `error.code` (`"missing_or_invalid"`,
`"INVALID_PARAMS"`, `"schedule_deleted"`), HTTP 200, not the integer codes JSON-RPC defines.~~ Resolved (`foreman-n2eh3`): the error now carries an
integer `error.code` (`-32602` for `missing_or_invalid`/`INVALID_PARAMS`, `-32000` for `schedule_deleted`/`schedule_not_found`) and the typed string in `error.data.code`
(`mcp/dispatch.ex` `error/2`, `wire_code/1`; pinned in `mcp_transport_test.exs`). The script accepts either form.

**Not run:** part 2 of the bead, the `question.answer` boundary with a real claude and a browser. `foreman-7c191` stays open for it.

## 3. Value-based redaction (`foreman-ngky4`, C2/C4)

`scripts/e2e/redaction_value_live.sh`, pi only. It stores two secrets whose NAMES look like nothing secret: `DEPLOY_TARGET` (a random
22-character value, per run) and `DEPLOY_REGION` (a random 7-character value, below the 8-character floor
`ProjectEnvironment.min_stored_secret_chars/0`). The value goes in on stdin. The real pi agent is told to run `printenv DEPLOY_TARGET`
(secrets are injected into the agent's environment) and to call the MCP tool `foreman_project_memory_write` with it. The value is in no
prompt, bead or task text.

Run 3 (79 s), observed:
- The agent's own transcript shows `foreman_project_memory_write` called with the 22-character value 4 times in `content` and once in
  `description`; the tool result reported `redactions=5`.
- The topic file `deploy-notes.md`, `foreman project memory read`, `memory list`, the `MEMORY.md` index, the `ProjectMemoryWritten` event
  row and the thread transcript API all carry `[REDACTED]` and not the value; the 7-character value stays where written (the floor).
- An operator chat message carrying both values (sent on stdin): `project chat --history N --format json`, the
  `CoordinatorMessageAppended` events and the persisted conversation hold the marker for the 22-character value only. The coordinator's
  own reply was not asserted to contain the value (UNVERIFIED by design, below).
- A thread started afterwards (from a bead whose text has no value): its archived `project-context.md` and
  `foreman project context --format json` (`system_text`) carry `[REDACTED]` and not the value; the memory topic is listed.
- A hand edit appended the value to the topic file (it held it once); `foreman project memory sync` recorded 1, forgotten 0, failed 0 and the
  file, `memory read` and `MEMORY.md` were redacted again (markers in the topic file: 5 before the hand edit, 6 after sync).

**Byte search** (before cleanup removes the database and the work dir; `$WORK` = `tmp/e2e-redaction-value`, `<V22>` the run's
22-character value, `<V22-hex>` its hex; counts are occurrences per file unless marked). Excluded as legitimate holders: the 0600 secret
store and the agent's own session files.

| Location | Command | 22-char | 7-char |
|---|---|---|---|
| secret store | `find $WORK/home/.foreman/secrets -type f \| xargs grep -aoF -- '<V22>' \| wc -l` | 1 (expected) | 1 (expected) |
| Postgres `events` table (rows) | `psql -h localhost -p 55432 -U postgres -d foreman_e2e_redaction_value -At -v v='<V22>' <<< "select count(*) from events where position(convert_to(:'v','UTF8') in data) > 0 or position(convert_to(:'v','UTF8') in metadata) > 0;"` | **0** | 2 rows (`CoordinatorMessageAppended`, `CoordinatorActionRecorded`; floor) |
| whole database, plain text and hex | `pg_dump -h localhost -p 55432 -U postgres --data-only foreman_e2e_redaction_value \| grep -aoF -e '<V22>' -e '<V22-hex>' \| wc -l` | **0** | 2 (`public.events`) |
| project memory dir | `find <repo>/.foreman/memory -type f \| xargs grep -aoF -- '<V22>' \| wc -l` | **0** | 2 (`deploy-notes.md` 1, `deploy-region-code.md` 1; the hand edit kept it) |
| run archive | same, `<repo>/.foreman/sessions` | **0** | 0 |
| runs dir | same, `$WORK/home/.foreman/runs` | **0** | 0 |
| webhook capture | same, `$WORK/webhook-capture.jsonl` | **0** | 0 |
| every other file under `$WORK` | same over `$WORK`, pruned of the locations above, the secret store, pi session dirs, the jido_harness cache and harness `out/` | **0** | 0 |
| server stdout log | same, `$WORK/server.log` | **11 (FAIL)** | 1 |
| server file log | same, `$WORK/home/.foreman/logs/foreman-server.log` | **11 (FAIL)** | 1 |
| jido_harness cache | `grep -rlaF -- <V22> $WORK/home/Library/Caches/jido_harness` (INFO, not pass/fail) | 38 in 2 files | not counted |

The 7-character rows are informational: below the floor the value is not redacted by design (`docs/user-guide.md`, Secrets).

### Findings

| Bead | Type | What |
|---|---|---|
| `foreman-mw5rz` | P2 bug, ~~open (owner decision: not fixed in this change)~~ fixed by PR #775 (free-text keys, the MCP `params` envelope and `token` added to `filter_parameters`) and re-verified live 2026-10-31: 0 hits of the 22-character value in the server stdout and file logs, in two runs (re-sweep below) | The 22-character value is in the server log, stdout and `~/.foreman/logs/foreman-server.log`: 11 occurrences in 3 Phoenix debug `Parameters:` lines (the same lines in both files): 2 MCP `tools/call` arguments (the agent's memory write) and 1 chat `text` (the operator message). The events table, the whole-database dump, memory, archive, runs dir and webhook capture are clean. |
| `foreman-4ohex` | P3, INFO | The `jido_harness` cache (`$WORK/home/Library/Caches/jido_harness`) holds the agent's own event stream, including the value the agent read: 38 occurrences in 2 files. Reported as an INFO line, not a PASS/FAIL. |
| `foreman-6u1s0` | P3 | Found while building the script: a workflow phase with `commit: true` whose agent only writes project memory fails with `checkout_written_instead_of_worktree`, because ~~the guard ignores only `.beads/`~~ (resolved: the guard now also ignores `.foreman/.gitignore` and `.foreman/sessions/`, the paths Foreman itself writes) (the files it named in run 1: `.foreman/.gitignore`, and `.foreman/sessions/run/<run>/manifest.json` + `project-context.md`). The script uses a valid `commit: false` workflow. |
| `foreman-n2eh3` | P4 | ~~String JSON-RPC `error.code` for typed MCP errors (section 2).~~ Resolved: integer `error.code`, typed code in `error.data.code`. |

PR #764 carries these beads (`foreman-mw5rz`, `foreman-6u1s0`, `foreman-4ohex`, `foreman-n2eh3`), closes `foreman-5fqso` and adds comments
to `foreman-7c191`, `foreman-ngky4` and `foreman-azc2o`.

### Re-sweep after `foreman-mw5rz` (2026-10-31, pi on minimax, real agent and coordinator)

- Run 4 (merged `main` at `5081ad87`, PR #775 in): passed=62 failed=2 unverified=1 (100 s). The 22-character value: 0 hits in the server stdout log and 0 in the file log (run 3: 11 occurrences in 3 lines); the 7-character value 0 hits there too (informational). The 2 FAILs were a flaw in the script, not a leak: the real coordinator answered step 3's chat and rewrote the memory topic (`ProjectMemoryWritten` v1 by the agent, description `Deploy target: [REDACTED]`, 4 redactions; v2 by `coordinator:<project>` 13 s later, clean description, 0 redactions), so the later thread's standing-context index had nothing to redact and no marker.
- Run 5 (branch of PR #776, which makes the two marker checks `UNVERIFIED` with the reason when `MEMORY.md` carries no marker at step 4): passed=62 failed=0 unverified=2 (113 s), exit 0. Server log 0 hits. The coordinator rewrote the topic again (2 of 2 runs), so the marker checks were UNVERIFIED; absence of the value from `project-context.md` and `foreman project context` is still asserted and passed.
- Still reported, not fixed: the `jido_harness` cache holds the value (INFO line, `foreman-4ohex`).

### The runs before run 3 (not clean; kept for the record)

- Run 1: passed=42 failed=3 unverified=3 (151 s). Both memory-writing threads failed with `checkout_written_instead_of_worktree`
  (`foreman-6u1s0`), so agent-written memory was UNVERIFIED. FAILs: the 22-character value in the server log (15 hits, stdout and file log
  each) and in "every other file" (76 hits; not analysed; run 3 reports the jido cache as its own INFO line).
- Run 2: passed=41 failed=3 unverified=2 (494 s). The memory write was UNVERIFIED: no thread appeared for the bead within 180 s because the script's own workflow was INVALID and never loaded (`commit: false` with `worktree.cleanup: on_success` is refused at load, since the deferred work would be destroyed), so every bead stayed `:unmapped`; run 3 uses `cleanup: never`. It was not a BeadsWatcher problem.
  FAILs: a completed thread's `project-context.md` was not archived within 60 s (unexplained, below), and 1 hit of the value in each server
  log (the chat `Parameters:` line).

### Not covered

- The claude haiku provider (the script refuses `E2E_PROVIDER=claude`).
- "A coordinator reply that contains the value": UNVERIFIED by design. The operator message is redacted before the event, so the
  coordinator never sees the value and a reply that echoes it would depend on model compliance; only the persisted conversation and the
  reply it did give are asserted (reply text not asserted to hold the value).
- ~~A re-sweep after `foreman-mw5rz` is fixed. `foreman-ngky4` stays open for it.~~ Done 2026-10-31 (re-sweep above).

## Unexplained observations

- Redaction run 2: a thread that had completed had no archived `project-context.md` after 60 s (it was archived in runs 1 and 3). Not
  reproduced; cause not established.
- Archive run 1: `pi --version` exit 134 and two kickoff failures with `catalog_unavailable` (above). Not reproduced; cause not established.

## Where the raw evidence is

In this worktree's git-ignored `tmp/` (not committed; it disappears with the worktree): the run logs `tmp/run-parch.log`,
`tmp/run-parch-2.log`, `tmp/run-mcpsched.log`, `tmp/run-rv.log`, `tmp/run-rv-2.log`, `tmp/run-rv-3.log`, and the kept evidence of the
four runs that failed or had an assertion fail under `tmp/e2e-evidence/`: `parch-20261030T160950Z-79671` (archive run 1),
`rv-20261030T161516Z-34142`, `rv-20261030T161958Z-52189`, `rv-20261030T163001Z-368` (redaction runs 1-3). The passing archive run 2 and
the passing MCP run keep nothing but their log. Each kept directory starts at `summary.txt`; the server-log hits of run 3 are in
`rv-20261030T163001Z-368/server.log` (`grep -a Parameters:`, then count the value).
