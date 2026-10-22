# Review gap-beads flow: live acceptance run (2026-10-21)

Plan verification steps 4 (end-to-end, real agent, real bead) and 5 (depth cap) for the
session archive + auto-review feature (PR #565). Everything below was observed unless marked
UNVERIFIED. No code was changed by this run.

## Environment

- Worktree `foreman-wt/gapverify` off `origin/main` feccef35; real Foreman server (`mix phx.server`,
  dev env), throwaway Postgres DB `foreman_gapverify` (dropped afterwards), port 47771, `HOME`
  redirected to `gap-scratch/home` (with `~/.pi` symlinked for provider auth).
- `FOREMAN_START_BEADS_WATCHER=true`. Review capture + analysis are the config defaults (true).
- Reviewer and worker: real `pi`, model `minimax/MiniMax-M2.7-highspeed`
  (`FOREMAN_REVIEW_PROVIDER=pi FOREMAN_REVIEW_MODEL=...`).
- Scratch project `gapscratch`: a tiny Python `http.server` app in `gap-scratch/repo`, local bare
  `origin`, its OWN `br` database (`br init --prefix gap`); nothing pushed to GitHub, the real
  `.beads` untouched.
- Workflow: a one-phase `gapimpl` workflow (pi/minimax, `task_types: [task,bug,chore,feature,docs]`)
  installed in the isolated `~/.foreman/workflows` (bundled workflows need litellm, unreachable).
- Registered with
  `foreman project create --id gapscratch --path <repo> --task-provider beads --task-provider-database-path <repo>/.beads`.

## Results

| # | Check | Result |
|---|-------|--------|
| (a) | archive files for the bead run | PASS |
| (b) | verdict + scores in `analysis.json` | PASS |
| (c) | analysis comment on the source bead | PASS |
| (d) | one `foreman-exec,foreman-gap` bead per gap, description names origin bead + archive | PASS |
| (e) | `ReviewRecorded` carries `gap_bead_ids` | PASS |
| (f) | project git history untouched by the reviewer | PASS |
| 5 | depth cap | PASS (see note on hand-labelled beads) |
| - | bead-less run | PASS |
| - | reviewer failure | PASS |

### Step 4 (first try; no second under-specified bead was needed)

`br create "Add a /healthz route returning 200" -t task -p 2 -l foreman-exec -d "In app.py add a GET /healthz route ... ALSO add unit tests in test_app.py ... and document the endpoint in README.md."`
-> `gap-zg5`. The BeadsWatcher dispatched it itself within ~3 s
(`line_outcome=:imported`, then `in_progress`); run `run-c8c7bba0...`, workflow `gapimpl`.

- (a) `ls .foreman/sessions/run/run-c8c7bba0235a3adba3c2c9a63471b82d/`:
  `analysis.json analysis.md changed-files.txt diff.patch evaluator-transcript.jsonl manifest.json request.md transcript.jsonl`.
- (b) `jq -r '.verdict, .scores' analysis.json` -> `met`, `{correctness:5, documentation:4, robustness:4, tests:4}`.
  Reviewer reported one gap: committed `__pycache__/*.pyc` artifacts with no `.gitignore` coverage.
  (The first-try "ask for more than a minimal-effort agent does" setup did not make the worker skip
  tests/docs; the reviewer still found a real, minor gap, so no fake gap was needed.)
- (c) `br comments list gap-zg5` shows `# Review verdict: met`, scores, the gap and
  `Full analysis: <archive>/analysis.md`.
- (d) `br list -l foreman-gap --json` -> `gap-i6k` labels `["foreman-exec","foreman-gap"]`. Its description
  ends: `Found by automated review of run run-c8c7..., which was working on bead gap-zg5.` /
  `Session archive: /Users/.../gap-scratch/repo/.foreman/sessions/run/run-c8c7...` /
  `Full analysis: .../analysis.md`; `agent_context.foreman.task_id = review:run:run-c8c7...`,
  `command_id = review:run-c8c7...:gap:1`.
- (e) Event store (`events` where `event_type='ReviewRecorded'`, stream
  `review:run:run-c8c7...`): `verdict=met`, `bead_id=gap-zg5`, `gap_bead_ids=["gap-i6k"]`,
  `evaluator=agent:pi`, `error_code=nil`, `analysis_path`/`archive_path` set, usage recorded.
- (f) Project `main` stays `1ccb877 init`; `git status --short` is empty; each `foreman/<bead>/<run>`
  branch holds only the worker's `[pi] ...` commit, none from the reviewer.

### Step 5: depth cap

- `gap-i6k` was dispatched by the watcher (not by hand): `BeadsWatcher ... bead=gap-i6k dispatching task.create workflow_type=gapimpl`
  at 20:45:54, run `run-3b1d0282...`. Its review: verdict `met`, 0 gaps, comment posted; no new
  `foreman-gap` bead. That round does not exercise the guard (no gaps).
- To get a gapful run, a second bead `gap-9kp` ("rate limiting, request logging, /metrics") was created
  by hand **already labelled `foreman-exec,foreman-gap`**. Its review (verdict `met`, 2 gaps)
  created `gap-qgy` and `gap-n4m`: the guard did NOT suppress it (see Finding 1).
- `gap-n4m` (created by the review, dispatched by the watcher) was reviewed: verdict `met`, 1 gap.
  `ReviewRecorded` for `review:run:run-26d0d1fc...` carries
  `suppressed: source bead is itself a foreman-gap bead`; `gap_bead_ids` is empty; its comment was
  posted (`br comments list gap-n4m`); `br list -l foreman-gap -a` stayed at 4 beads
  (`gap-i6k gap-9kp gap-qgy gap-n4m`). `gap-qgy` (0 gaps) likewise added none.

### Bead-less run

`foreman run submit --project-id gapscratch --workflow gapimpl --work-id adhoc-nobead --prompt "Add a /version route ..."`
-> `run-b3c58454...`: archive with all 8 files, manifest `bead_id: null`, verdict `met` with 2 gaps
in `analysis.json`, `ReviewRecorded` with `bead_id` nil and empty `gap_bead_ids`; server log:
`review bead sink skipped: run run-b3c5... has no originating bead`; `br` issue count unchanged
(5 -> 5), no comment. (No `br` invocation tracing was installed; "no br calls" is inferred from the
log line and the unchanged DB, not observed at the process level.)

### Reviewer failure

Server restarted with `FOREMAN_REVIEW_MODEL=nonexistent/no-such-model`; bead `gap-r0w`
("Add a /ping route ... tests and README"): `analysis.json` `verdict: "undetermined"`,
`error_code: "evaluator_failed"`, `summary: "reviewer run ended failed"`; archive complete;
`ReviewRecorded` has `error_code` set; the comment (`# Review verdict: undetermined ... Error: evaluator_failed`)
was posted; zero new gap beads (`foreman-gap` count stayed 4).

## Findings

1. **Loop guard keys on the event log, not the label** (`BeadSink.publish/2` ->
   `ProjectionStore.gap_bead?/1`; the plan specified `get` + label check). A bead labelled
   `foreman-gap` by hand (or from before the event log) gets full gap creation: `gap-9kp` spawned
   `gap-qgy`/`gap-n4m`. Naturally created chains are capped correctly. Filed as bead
   `foreman-s9pvf` (no code change here).
   **Resolved afterwards** (bead `foreman-s9pvf`): `BeadSink` now also reads the source bead's
   `foreman-gap` label through the provider (the event-log check stays first and needs no provider
   call), and an unreadable label fails closed with a note. The live run above predates that change
   and was NOT repeated after it; the fix is covered by `bead_sink_test.exs` (hand-labelled bead,
   unreadable label), mutation-checked.
2. The "minimal effort" instruction in the scratch workflow prompt was ignored by the agent; it
   wrote tests and docs anyway. Irrelevant to the flow, noted for reproducibility.

## Not done / UNVERIFIED

- Real GitHub/PR behaviour (none used). `br` process-level call tracing for the bead-less run.
- Reviewer sandbox in effect (PR #605) was verified only by outcome (f), not by tracing reviewer writes.
