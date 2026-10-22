# Review archive + auto-review: live pass of the JOBSITE door (2026-10-22)

Companion to `review-gap-beads-live-run.md` / `review-gap-guard-retest.md` (workflow door). Everything
below was observed unless marked UNVERIFIED.

**Provider note: `claude` (the configured default reviewer/worker) was NOT exercised** because the
Claude OAuth is expired. Everything here ran on `pi` with `minimax/MiniMax-M2.7-highspeed`
(`FOREMAN_REVIEW_PROVIDER=pi FOREMAN_REVIEW_MODEL=minimax/MiniMax-M2.7-highspeed`; worker the same).

## Environment

- Worktree `foreman-wt/jobsitelive` off `origin/main` `3efe0303`; real server (`mix phx.server`, dev env,
  via `devbox run`), throwaway DB `foreman_jobsitelive`, port 47781, `HOME` redirected
  (`~/.pi` symlinked), `localhost` (not 127.0.0.1). Capture + analysis are the config defaults (on).
  `FOREMAN_API_TOKEN`, `FOREMAN_JOBSITES_ALLOW_REMOTE_START=true`, `FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true`.
  BeadsWatcher, E12 multi-repo and the PR watcher were OFF.
- Scratch project `foreman-wt/jobsite-scratch/repo` (tiny Python `http.server` app, local bare origin,
  its own `br 0.6.0` DB, prefix `js`). Registered with
  `foreman project create --id jsscratch --path <repo> --task-provider beads --task-provider-database-path <repo>/.beads`.
- Public surface: the installed `foreman` CLI has no jobsite *start* verb (`foreman thread` only
  lists/stops), so jobsites were started with the documented `POST /api/jobsites` (user-guide
  "Remote Jobsite API") and read with `GET /api/jobsites/:id`.
  `bead_id` is a documented-by-code spec key (`Jobsite.Spec @allowed_keys`).
- From the second server start on, a `br` shim on the server's `PATH` logged every `br` invocation.
- ReviewRecorded was read from the `events` table (`select ... from events e join stream_events ... where stream_uuid = 'review:jobsite:<id>'`).

## Results

| # | Scenario | Result |
|---|----------|--------|
| 1 | bead-driven jobsite, real pi commit, full archive, ReviewRecorded, comment | **PASS** |
| 1b | gap beads from a jobsite review (`foreman-exec,foreman-gap`) | **PASS** (obtained from the failed run `js-8838...`, see 3; the two completed bead runs found 0 gaps) |
| 2 | jobsite without `bead_id` | **PASS** |
| 3 | failed jobsite | **FAIL as found** (no diff archived although the agent's work was committed to the branch); **PASS after the fix in this PR** |
| 4 | reviewer sandbox: repo history untouched | **PASS** (by outcome; reviewer writes not traced, UNVERIFIED at process level) |

### 1. Bead-driven jobsite (`js-154e89f914913d75`, bead `js-ttc`)

```
br create "Add a /healthz route returning 200 ok" -t task -p 2        -> js-ttc
curl -XPOST -H "Authorization: Bearer ..." --data @spec1.json http://localhost:47781/api/jobsites
  spec: {"project_id":"jsscratch","bead_id":"js-ttc","name":"healthz","strategy":{"branch":"jobsite/healthz"},
         "sandbox":"host","max_iterations":1,"agent":{"provider":"pi","model":"minimax/MiniMax-M2.7-highspeed"},
         "prompt":"In app.py add a GET /healthz route ... unit tests in test_app.py ... README.md ... Do not run git commands"}
  -> {"id":"js-154e89f914913d75"}        # status running -> completed in ~30 s
```

- `GET /api/jobsites/<id>` -> `"bead_id": "js-ttc"`, commit `1dad980 [pi] Done.`; the `JobsiteStarted` event
  (both on `jobsite:<id>` and `$all`) carries `bead_id` `js-ttc`.
- `.foreman/sessions/jobsite/<id>/`: `manifest.json request.md transcript.jsonl diff.patch changed-files.txt analysis.json analysis.md evaluator-transcript.jsonl`.
- manifest: `bead_id: "js-ttc"`, `provider_session_ids: ["01a163c5-d38a-77af-bd58-b3d942118bf7"]`,
  `capture_errors: []`, `diff_status: "captured"`, `status: "completed"`, `transcript_source: "harness_events"`.
- `cmp prompt1.txt request.md` (prompt extracted from the submitted JSON): byte-identical (251 bytes).
  The archived text is the variable `Engine` hands to the iteration loop (`open_archive/3` and `iterate_agent/8`
  both receive `prompt_text`); I did not intercept the bytes at the provider process.
- `git diff --find-renames f0f8eb0..1dad980 | diff - diff.patch` and the `--name-status` variant against
  `changed-files.txt`: both identical (`M README.md / M app.py / A test_app.py`).
- `transcript.jsonl`: 167 lines (types: provider_event 84, thinking_delta 28, output_text_delta 17, tool_call 8,
  tool_result 8, usage 6, turn_* 12, output_text_final 2, run_started/completed 1 each).
- `analysis.json`: `verdict: met`, scores `{correctness:5, documentation:5, robustness:4, tests:4}`, 0 gaps.
- `ReviewRecorded` on `review:jobsite:js-154e89...`: `evaluator agent:pi`, `verdict met`, `bead_id js-ttc`,
  `error_code nil`, `gap_bead_ids []`, `analysis_path`/`archive_path` set, usage recorded.
- `br comments list js-ttc` -> `# Review verdict: met ... Full analysis: <archive>/analysis.md`.
- The demanding retry (`js-7eb47af0104ab62a`, bead `js-kta`: rate limit + JSON logging + /metrics +
  SIGTERM + `--port`, tests and docs for each): again `met`, 0 gaps, comment posted, diff/changed-files/request
  all byte-identical, no beads. The task asked for one retry; the gap-bead path was exercised via run 3 instead.

### 1b. Gap beads (from `js-8838f3bf618b91d9`, bead `js-en0`)

The failed run's review (`not_met`, 3 gaps) produced, per the `br` shim log:
`br comments add js-en0 --message ...`, `br show ... js-en0 --json` (loop-guard label read; works against real
br 0.6.0), then three `br create ... --type bug --priority 1 --description <gap + "Found by automated review of
jobsite ..., which was working on bead js-en0." + archive path + analysis.md path> --agent-context {"foreman":{"task_id":"review:jobsite:<id>","command_id":"review:<id>:gap:N"...}} --labels foreman-exec,foreman-gap --json`.
`br list -a -l foreman-gap` -> `js-h3c js-i7a js-wni` (all `bug`, p1), `br show` labels `['foreman-exec','foreman-gap']`.

### 2. Jobsite without `bead_id` (`js-23642b49811e965c`)

Archive complete (8 files incl. `analysis.*`), manifest `bead_id: null`, `capture_errors: []`; `analysis.json`
verdict `met` with **2 gaps**. `ReviewRecorded`: `bead_id nil`, `error_code nil`, `gap_bead_ids []`.
Server log: `review bead sink skipped: jobsite js-23642b49811e965c has no originating bead`. The `br` shim log file
did not exist after the run (no `br` invocation by the server, the shim creates it on first call);
`br list -a --json` total stayed 3. No comment, no beads.

### 3. Failed jobsite

Agent killed mid-iteration (`kill <pi pid>`; harden prompt, bead `js-en0`): `GET /api/jobsites/<id>` ->
`status failed`, `last_error.code agent_failed` (`exit_status 143`). **Observed bug (unfixed code):**
`js-8838f3bf618b91d9` archive had `manifest.json request.md transcript.jsonl` and, after the review,
`analysis.*`, but **no `diff.patch`/`changed-files.txt`**; manifest `diff_status: "unavailable"`,
`base_ref`/`worktree_path` null, `capture_errors: []` (so "unavailable" was not explained), while the branch
`jobsite/harden` held the agent's 379-line change as `b8cd525 [pi] Work in progress`. The reviewer then graded
`not_met` partly because "the archive contains no diff". A review was recorded (verdict `not_met`, evaluator
`agent:pi`, not skipped) and the comment and gap beads were created.

Cause: the diff is captured only at the commit step (`Observer`) or on cancel/resume; `Executor.fail/4` goes
straight to `cleanup/3`, which discards the worktree. **Fix** (`jobsite/executor.ex`): `fail/4` calls
`capture_diff(jobsite_id, worktree, :worktree)` before `cleanup/3`, exactly as `handle_interrupt(:cancel)` does
(a failure after the commit step re-captures the same content). Regression test
`session_archive_test.exs` "a failed run archives the working-tree diff before the worktree is discarded"
(fake agent that writes a file then dies, `merge_to_head`). Mutation check: with the `capture_diff` line
commented out the test fails (`4/5 passed`, `diff.patch` missing); restored, `mix test test/foreman_server/jobsite`
-> `Result: 187 passed, 2 excluded`, format clean.

**Live re-run with the fix** (`js-320b733f9bc1c016`, no bead; prompt "create marker.txt, then `sleep 600`", pi
killed): `failed`; archive has `diff.patch` (`+wip` for `marker.txt`), `changed-files.txt` (`A marker.txt`),
manifest `diff_status captured`, `capture_errors []`, `base_ref` and `worktree_path` set; review
`partially_met`, 1 gap, no beads (no bead). The preserved branch has `487024c [pi] Work in progress`.

### 4. Reviewer sandbox

Scratch repo `git status --short`, `git log --oneline --all`, `git branch -a`, `git worktree list` before vs
after each run: the only differences were the jobsite's own commit (`[pi] Done.` / `[pi] Work in progress`),
its `jobsite/<name>` branch and Foreman's own untracked `.foreman/` (worktrees, sessions). `main` stayed at
`f0f8eb0 init`. The reviewer's own writes were not traced (UNVERIFIED beyond this outcome check).

## Other observations

- `branch` in a jobsite manifest is always `null`, although `strategy` is `branch:<name>`
  (the plan's manifest shape names a `branch`). Not fixed; the strategy field carries the name.
- `agent.model: "minimax/no-such-model-xyz"` with provider `pi` did **not** fail the jobsite: pi fell back and
  the run completed (`js-5011aaaa58c2c9d5`). A bad model is therefore not a usable failure trigger on pi.
- A 4th run (bead `js-en0` harden prompt) sat in the 10k-connection benchmark for over 20 minutes before I
  killed its agent for scenario 3.

## Not done / UNVERIFIED

- Provider `claude`, the configured default (OAuth expired). Docker sandbox, resumed/paused jobsites, push.
- The natural "source bead already `foreman-gap`" chain on the jobsite door (covered on the workflow door).
- Process-level tracing of reviewer writes.
