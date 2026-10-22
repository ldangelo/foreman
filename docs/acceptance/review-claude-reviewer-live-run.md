# Archive + auto-review with the CONFIGURED DEFAULT reviewer (claude): live run (2026-10-22)

Companion to `review-gap-guard-retest.md`, `review-jobsite-live-run.md`, `review-gap-beads-live-run.md`.
Those ran the reviewer on `pi` (via `FOREMAN_REVIEW_PROVIDER=pi`) because `claude` was assumed
unusable. This run exercises the default: **`FOREMAN_REVIEW_PROVIDER`/`FOREMAN_REVIEW_MODEL` were unset**
(`unset` in the start script), so `config.exs`' `agent: %{provider: :claude, model: nil}` applied.
Everything below was observed unless marked UNVERIFIED.

## Environment

- Worktree `foreman-wt/claudelive` off `origin/main` @ `201e7ad6`; real Foreman server
  (`mix phx.server`, dev env, via `devbox run`), throwaway Postgres DB `foreman_claudelive`
  (dropped afterwards), port 47791, `localhost` (not 127.0.0.1).
- `FOREMAN_START_BEADS_WATCHER=true`, `FOREMAN_JOBSITES_ALLOW_REMOTE_START=true`,
  `FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true`, PR watcher off. Capture + analysis = config defaults (on).
- **Reviewer resolution:** the start script `unset`s `FOREMAN_REVIEW_PROVIDER FOREMAN_REVIEW_MODEL`.
  Evidence the reviewer is claude: every `ReviewRecorded` has `evaluator = "agent:claude"`,
  `usage_provider = "claude"`, and Claude Code wrote session transcripts for each review under
  `~/.claude/projects/-private-var-folders-...-foreman-review-run-<id>/`. I could NOT read the running
  server's env (`ps eww` printed no env for the BEAM) and did not attach a remote console, so the
  "resolved config" is inferred from the above, not read from the VM.
- **How claude auth was reached:** `HOME` was redirected (the scratch HOME carries
  `~/.foreman/workflows/gapimpl.yaml`), and four symlinks were added so both CLIs keep working:
  `~/.pi`, `~/.claude`, `~/.claude.json`, `~/Library/Keychains` -> the real ones. Before starting the server
  `HOME=<scratch>/home claude -p "reply with the single word ok"` answered `ok` in 2 s. The start script
  also unsets `CLAUDECODE`/`CLAUDE_CODE_*` (inherited from the agent shell that launched it). No API key
  env var was passed (`MY_ANTHROPIC_API_KEY` exists in the shell but the server env was not given it
  explicitly; the start script does not unset it, so I cannot exclude that the CLI saw it via inheritance
  of the launching shell: UNVERIFIED which credential claude used).
- Worker: `pi` / `minimax/MiniMax-M2.7-highspeed` in a one-phase `gapimpl` workflow
  (`provider: pi`, prompt = `{{input.prompt}}`) installed in the scratch `~/.foreman/workflows`.
- Scratch project `clscratch`: tiny Python `http.server` app, own git repo, local bare `origin.git`,
  own `br 0.6.0` DB (`br init --prefix cl`), `.beads/` in `.git/info/exclude`. Nothing touched GitHub or
  the real `.beads`. Registered with
  `foreman project create --id clscratch --path <repo> --task-provider beads --task-provider-database-path <repo>/.beads`.

## Results

| # | Scenario | Result |
|---|----------|--------|
| 1 | Workflow door, watcher-dispatched bead, claude reviewer: archive, verdict + 4 scores, `agent:claude`, `error_code` nil, evaluator transcript, bead comment | **PASS** |
| 1b | ...gap beads from the workflow door with claude | **UNVERIFIED** (two attempts, reviewer found 0 gaps each time, see note) |
| 1c | Reviewer cannot modify the project (sandbox read_only / approval default) | **PASS by outcome** (history, status, file mtimes unchanged); process-level enforcement UNVERIFIED |
| 2 | Jobsite door with `bead_id`: `review:jobsite:<id>`, `agent:claude`, comment, gap bead `foreman-exec,foreman-gap` | **PASS** |
| 3 | Depth cap: review of a gap bead creates no beads and says so | **PASS** (hand-labelled bead, see note); natural chain UNVERIFIED for suppression |
| 4 | claude reviewer failure modes (auth, permission hang, sandbox flag, malformed JSON, timeout) | **none observed** in 5 reviews |

### 1. Workflow door (`cl-32v`, then `cl-f2d`)

```
br create "Add /healthz and /metrics with tests, docs, graceful shutdown" -t task -p 2 -l foreman-exec -d "...tests... README... --port..."  -> cl-32v   (13:13:35)
```
Watcher log: `BeadsWatcher project=clscratch bead=cl-32v dispatching task.create workflow_type=gapimpl` (13:13:36),
run `run-3e755f5269acd4dd69c65102c65eae5c`; `ReviewRecorded` appended 13:15:53.

- `.foreman/sessions/run/<run>/`: `analysis.json analysis.md changed-files.txt diff.patch evaluator-transcript.jsonl manifest.json request.md transcript.jsonl`;
  manifest `bead_id=cl-32v`, `diff_status=captured`, `capture_errors=[]`, `transcript_source=run_logs`, `transcript_truncated=false`.
- `analysis.json`: `verdict=met`, scores `correctness 5, tests 5, documentation 5, robustness 4`, `gaps=[]`, `error_code=null`.
- Event (read from the `events` table): `evaluator=agent:claude`, `usage_provider=claude`, `error_code=nil`, `gap_bead_ids=[]`.
- `br comments list cl-32v` shows `# Review verdict: met ... ## Scores ...` + path to `analysis.md`.
- Reviewer duration (first to last `evaluator-transcript.jsonl` timestamp): **6.3 s** (run 1), 20.4 s (`cl-f2d`),
  14.5 s and 11.0 s (gap-bead runs), 41.2 s (jobsite). 85 events, one Bash tool call in run 1.
- **Model claude used:** the `ReviewRecorded` `usage.model` and the manifest `agent.model` are `nil`/`null`
  (config `model: nil`). From Claude Code's own session files for the five reviews: `claude-opus-5-5`
  (2 assistant messages) and `claude-sonnet-5-5` (4-10 messages) each time.
- Claude's cwd was `/var/folders/.../T/foreman-review/run/<id>` (a product-created scratch dir; permissionMode `default`);
  it read the archive by absolute path with Bash. These dirs are never removed (about 20 left from previous runs).

**No gaps.** The first request (`/healthz`, `/metrics`, SIGTERM, tests, README, `--port`) was fully satisfied by pi.
The spec says retry once with something more demanding: `cl-f2d` (rate limiting + JSON request logging + `/version` +
env validation + `/ready`, tests for every item, CHANGELOG, README) was also fully delivered (`met`, tests 4/5:
"could not confirm a test run from the transcript"). So the **workflow-door gap-bead creation with claude was not observed**.
It was observed on the jobsite door (scenario 2).

### 2. Jobsite door with `bead_id` (`js-e86f76fe662b9521`, bead `cl-xhb`)

Spec (`POST /api/jobsites`): `project_id clscratch, bead_id cl-xhb, strategy.branch jobsite/uptime, sandbox host,
max_iterations 1, agent pi/minimax`, prompt = `/uptime` route + Dockerfile verified by a real `docker build` + a 5000-request
load test recorded in README + tests. Status `completed`, commit `03c0f87 [pi] Done. No git commands run.`

- Archive dir `.foreman/sessions/jobsite/js-e86f76fe662b9521/` has the same 8 files; manifest `bead_id=cl-xhb`,
  `diff_status=captured`, `capture_errors=[]`, `transcript_source=harness_events`, one provider session id.
- `ReviewRecorded` on `review:jobsite:js-e86f76fe662b9521`: `evaluator=agent:claude`, `error_code=nil`, `verdict=met`,
  `gap_bead_ids=[cl-0qc]`.
- `analysis.json`: scores 5/4/4/4 (correctness/documentation/robustness/tests), 1 minor gap
  "Remove committed __pycache__ artifacts" (the diff really did add `.pyc` files).
- Comment on `cl-xhb` posted (verdict, scores, `## Gaps`, path). Gap bead `cl-0qc`: labels `['foreman-exec','foreman-gap']`,
  priority 3, type `chore`; description names the gap, dimension/severity, `jobsite js-e86f... ... working on bead cl-xhb`,
  the absolute archive dir and `analysis.md` path.

### 3. Depth cap

- Natural chain: the watcher itself dispatched `cl-0qc` (run `run-8e23efc3...`). Its claude review: `met`, 0 gaps (it
  confirmed `.gitignore` added and no `.pyc`), comment posted, `br list -a` unchanged. No gaps means no suppression was needed,
  and no suppression note appears: **suppression via the natural chain UNVERIFIED**.
- To exercise it I hand-labelled bead `cl-3x8` (`-l foreman-exec,foreman-gap`, "prod cluster verification" request) and let the
  watcher dispatch it (run `run-c22be70b...`). Claude returned `not_met`, **4 gaps**, scores 1/1/1/1. The event summary carries
  `suppressed: source bead carries the foreman-gap label`, `gap_bead_ids=[]`, `error_code=nil`; the comment on `cl-3x8` was posted
  (lists all 4 gaps); `br list -a` stayed at 5 beads. Hand-labelling is the deviation from a natural chain.
- Side finding (worker, not review): for `cl-3x8` pi's final message claimed it edited app.py/test_app.py/README/CHANGELOG, but the run
  worktree was clean, no commit was made (`AutoPR ... noop: ... has no commits beyond main`), manifest `diff_status=empty`. The claude
  reviewer caught it: "That claim is not backed by any diff content." Why pi's edits did not land was not investigated.

### 1c. Sandbox / project untouched

After all five reviews: `git -C repo rev-parse main` = `62288cb` (init, unchanged), `git status --short` = only the untracked `.foreman/`,
no file outside `.git .foreman .beads` newer than the server start, refs only the worker's `foreman/*` and `jobsite/uptime` branches.
Claude ran with `permissionMode default` (Claude Code session file); I did not inspect the actual `--sandbox`/permission arguments, so enforcement is shown only by outcome.

### 4. Failures

None: all five claude reviews returned a well-formed JSON verdict (`error_code` nil) in 6-41 s; no permission prompt, auth, flag or
parse problem. No bug found, so no fix/regression test/bead was filed. Minor observations: manifest `agent` is `{provider:null, model:null}`
for the workflow runs I inspected (reviewer identity lives only on the event); `usage.model` is nil so the model claude chose is only visible
in Claude's own session files.

## Not done / UNVERIFIED

- Workflow-door gap-bead creation with claude (no gaps in either natural attempt).
- Suppression on a naturally created gap bead that has gaps (hand-labelled substitute used).
- Server-side resolved config read from the VM; which Anthropic credential claude used (keychain vs inherited env var).
- Process-level read-only enforcement for claude; reviewer timeout path; review of a failed run.

## Cleanup

Server killed by PID (52702 and its `sh -c` parent 52489 only); DB `foreman_claudelive` dropped with `DROP DATABASE ... WITH (FORCE)`
(for both EventStore and Repo URLs, which are the same DB here); scratch under `foreman-wt/claude-scratch/` left for inspection.
