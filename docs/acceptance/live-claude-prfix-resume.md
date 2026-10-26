# Live claude PR fix: the fix thread resumes its run's claude session on a real GitHub PR (bead foreman-nufr9), 2026-10-26

The last UNVERIFIED item of `foreman-nufr9` (`live-claude-and-approvals.md`, `parity-audit.md`): a PR-fix thread (`ForemanServer.PrFix`,
started by `ForemanServer.PrWatcher`) of a run whose agent was a REAL claude must resume that claude provider session
(`resume_session`), against a REAL GitHub pull request. Everything below was observed unless marked otherwise. Times are UTC.

**Verdict: PASS, after one production defect found by the first run and fixed in the same change.** The resume itself worked from the
first run; what the first run showed is that a resumed claude fix thread could not do anything (it was refused its first `Edit` and `Bash`
call), so the PR was never fixed. With the run's approval mode carried to the fix agent, the stage passes 31 assertions, twice in a row.

| Assertion | Run 1 (before the fix) | Run 2 (after) | Run 3 (repeat) |
|---|---|---|---|
| (a) the run recorded a claude provider session (a UUID; claude's own transcript of it holds the run's task) | PASS `b2e0f4ff-17c1-438a-82e1-2f3e6f576be1` | PASS `f91ff40e-9af7-471e-83fe-4eda6f146217` | PASS `fb31ce0b-a377-4726-8471-0e14489a5f62` |
| (b) `PrFixStarted.resumed_session == true` | the event says `true`; the stage's own check read it wrong (harness bug, below) | PASS | PASS |
| (c) the fix jobsite's first `JobsiteIterationStarted.resumed_session_id` is that session id; the iteration ended on the same id (`JobsiteIterationCompleted.session_id`) | PASS (the end id was not asserted yet; the event carries the same id) | PASS, PASS | PASS, PASS |
| the fix jobsite worked at the SAME path as the run's (cleaned-up) worktree | PASS | PASS | PASS |
| (d) the PR head moved with the fix commit (a fast-forward of the regression), the fix repaired `app.add`, CI is green again | **FAIL**: `PrFixFinished outcome=no_change` 10 s after the start | PASS `869adac6` -> `0cd73e6c` | PASS `56519de2` -> `6682c3b5` |
| (e) claude's own transcript of THAT session grew (same id, more lines), its first N lines are byte-identical, no other session appeared, the appended turns hold the fix prompt | 35 -> 70 lines (read by hand after the stage stopped at (d)) | PASS 36 -> 77 lines | PASS 36 -> 77 lines |
| stage totals | passed=18 failed=2 | passed=31 failed=0 unverified=0 (119 s) | passed=31 failed=0 unverified=0 (91 s) |

## Environment

- Branch `foreman/prfix-claude-live` (worktree `foreman-wt/prfix-claude-live`) off `main` `d6536fdb`; macOS arm64; devbox Elixir 1.20.4 / OTP 28; real `claude`
  2.1.308, model alias `haiku`; Playwright 1.64.1 (headless Chromium) for the Fix CI click.
- Scratch repository `ldangelo/foreman-scratch-202610260959`: PRIVATE, seeded from `scripts/e2e/claude_projects/github-fixture/` (a tiny app, its unit tests,
  `.github/workflows/ci.yml` running `python3 -m unittest`, `approve.yml`, `.coderabbit.yaml`), archived at the end. Its PRs 1, 2, 3 are the three runs.
- Server: `MIX_ENV=dev`, own port, own Postgres database (dropped afterwards), a real `cloudflared` quick tunnel and webhook, `FOREMAN_PR_MONITOR_ENABLED=true`,
  `FOREMAN_PR_FIX_SANDBOX=host`, the review analysis off (`E2E_REVIEW_ANALYSIS=0`), no `pr_auto_fix` policy (the fix is the operator's request).
- **claude runs through a private `HOME`** (`claude_projects/claude_home.sh`, `claude_private_home`): an empty `~/.claude` (stock settings: no hooks, plugins or
  permission default; its own session store under the work dir), a copy of `~/.claude.json` and the `Library/Keychains` link (the OAuth login). The operator's own
  `~/.claude/settings.json` has `defaultMode: auto` and hooks, which would have hidden the defect (below) and added noise.

```bash
FOREMAN_E2E_GITHUB_REPO=ldangelo/foreman-scratch-202610260959 E2E_NAME=pfc E2E_PORT=4871 E2E_HOOK_PORT=4971 \
  devbox run -- bash scripts/e2e/github_live_extras.sh serve          # stack, tunnel, webhook; prints SERVE-READY
... same variables ... bash scripts/e2e/github_live_extras.sh stage claude_fix_ci
... same variables ... bash scripts/e2e/github_live_extras.sh stage safety    # read-only content scan of the scratch repository
... same variables ... bash scripts/e2e/github_live_extras.sh stop
```

## What the stage does (`gh_x_claude_fix_ci`, `claude_projects/github_extras.sh`)

1. Without a logged-in claude the stage records `UNVERIFIED` (never a failure). Otherwise it installs the `claudeedit` workflow (one claude phase, haiku,
   `approval_mode: auto_approve`, worktree cleaned up on success, task type `claude-e2e`) and waits until the RUNNING server's catalog maps `claude-e2e` to it
   (the catalog polls every 2 s; no restart, which would lose the environment the harness gave the server).
2. A bead of issue type `claude-e2e` (`new_bead`/`gh_new_pr` take the type now) makes a real claude run create `note_claude1.txt`; AutoPR opens a real PR.
3. (a): the run's last `provider_sessions` entry (`GET /api/runs/:id`), claude's own transcript under the private HOME, its line count and sha256.
4. The PR is green and Ready for review; the operator pushes a regression to the PR branch (`gh_inject_code_bug`: `app.add` subtracts). Unlike the failing test the
   older stages inject, only a change to the code clears it: the fix prompt forbids deleting or weakening a test. GitHub Actions fails, the card says `ci_failing`.
5. Fix CI is clicked in the workspace (the CLI verb that dispatches the same command when the browser driver is not installed).
6. (b), (c) and the path check are read from the event store on the server node (`claude_projects/pr_fix_evidence.exs`: the run's `PrFix*` events, its
   `WorktreeCreated`/`WorktreeCleaned`, the fix jobsite's own stream), (d) from GitHub and git, (e) from claude's transcript.

## Run 1: the resume worked, the fix did not (defect)

`PrFixRequested trigger=operator` 15:05:24.1; `PrFixStarted` 15:05:27.7 with `"resumed_session":true`; the fix jobsite `js-ca10ca7df9e4f371`:

```json
{"type":"JobsiteStarted","data":{"agent":{"approval_mode":null,"binary":"claude","effort":null,"model":"haiku","provider":"claude","provider_options":{}},"push":true,"sandbox_provider":"host","bead_id":"gh-1ho",...}}
{"type":"JobsiteIterationStarted","data":{"index":1,"resumed_session_id":"b2e0f4ff-17c1-438a-82e1-2f3e6f576be1"}}
{"type":"JobsiteIterationCompleted","at":"15:05:36.46","data":{"index":1,"session_id":"b2e0f4ff-17c1-438a-82e1-2f3e6f576be1","status":"completed","text":"I couldn't make the fix. The file edit to `app.py` was refused with a permission request that hasn't been granted, so nothing has changed and nothing is committed or pushed. ..."}}
{"type":"PrFixFinished","at":"15:05:37.7","data":{"kind":"ci","attempt":1,"outcome":"no_change","new_head_sha":"e55f40e4...(the regression head, unchanged)"}}
```

Claude's transcript of session `b2e0f4ff` shows both halves: the run's own turns (`Write` note_claude1.txt, `done`), then, appended to THE SAME file at 15:05:29, the
fix prompt, a `Bash` (read the repo; allowed), the agent's diagnosis ("a real bug in `app.add`, which returns `a - b` ... I'll fix it in the code"), and then

```text
Edit   -> is_error: "Claude requested permissions to write to <worktree>/app.py, but you haven't granted it yet."
Bash   -> is_error: "This Bash command contains multiple operations. The following part requires approval: python3 -m unittest -v 2>&1"
```

The PR record stayed `checks_state failing`, `fixes.last_outcome.ci = no_change`.

**Root cause.** `PrFix` carried the run's provider, model and session id (and the path), but built the fix agent without an `approval_mode`. `JobsiteStarted.agent.approval_mode`
was `null`, `Jido.Harness.Adapters.Claude` then adds no `--permission-mode`, and a headless claude without one runs in its interactive permission mode (the moduledoc of
`Jobsite.Agent` and `docs/user-guide.md` say so: "an unattended run then cannot write files or run commands"). The run's own phase had `approval_mode: auto_approve`
(`--permission-mode bypassPermissions`, visible as `"permissionMode":"bypassPermissions"` in the transcript); nothing recorded that, so the fix thread had no way to ask for it.
Earlier live fix threads (`live-github-protection-ui-autofix.md`, stages 9c to 9e) ran pi, which has no permission prompts, and the operator's own claude settings
(`defaultMode: auto`) would also have allowed everything **[INFERENCE: the unfixed code was not run against the real HOME]**; both hid it.

**Fix** (`approval_mode` is the one thing that was missing; resume was already right):

- `Events.WorkerSessionBound` has an optional `approval_mode` (the harness mode name); `Overwatch.Adapters.JidoHarnessWorker` fills it from its driver options (the effective
  mode `RunExecutor.maybe_put_approval_mode/3` set: the phase's `approval_mode:` or an approved tool call's override), omitted when none was set.
- `ProjectionStore` keeps it on the run's `provider_sessions` entry (only when present, so every earlier entry keeps its shape).
- `PrFix.agent/2` gives the fix agent the last session's mode (`agent.approval_mode` in the jobsite spec), except `prompt`: a jobsite has nobody to answer a per-call approval and
  `--permission-mode default` would override what the host's own claude settings allow. A run with no recorded session uses `config :foreman_server, :pr_fix, agent:` as before.
- Tests (each fails without its part of the change, checked by reverting `pr_fix.ex` alone: 6 failures; reverting all of `lib`: 10): `pr_fix_test.exs` (every mode is carried,
  none and `prompt` are not, the last session wins, carried even when nothing is resumed, every kind of fix), `projection_store_provider_session_test.exs`,
  `jido_harness_worker_session_test.exs`.

## Runs 2 and 3: after the fix

Run 2 (PR 2, bead `gh-2us`, run `run-165e762ef6446b0654da306ce4eb2705`, fix jobsite `js-3825d054ef021e4f`), event store excerpts:

```json
{"i":11,"at":"15:34:57.52","type":"PrFixRequested","data":{"kind":"ci","attempt":1,"trigger":"operator","requested_by":"dashboard","head_sha":"869adac648635830e07d850a29f82e3833345150"}}
{"i":12,"at":"15:35:00.67","type":"PrFixStarted","data":{"kind":"ci","attempt":1,"jobsite_id":"js-3825d054ef021e4f","resumed_session":true}}
{"stream":"vcs:wt-run-165e...","i":0,"at":"15:33:46.37","type":"WorktreeCreated","data":{"worktree_path":"<work>/home/.foreman/worktrees/e2e-gh-15573/gh-2us/run-165e.../workspace"}}
{"stream":"vcs:wt-run-165e...","i":1,"at":"15:33:53.46","type":"WorktreeCleaned"}
{"stream":"jobsite:js-3825...","i":0,"type":"JobsiteStarted","data":{"agent":{"approval_mode":"auto_approve","model":"haiku","provider":"claude",...},"push":true,"sandbox_provider":"host"}}
{"stream":"jobsite:js-3825...","i":1,"at":"15:35:01.63","type":"JobsiteWorktreeProvisioned","data":{"path":"<work>/home/.foreman/worktrees/e2e-gh-15573/gh-2us/run-165e.../workspace"}}
{"stream":"jobsite:js-3825...","i":3,"at":"15:35:01.65","type":"JobsiteIterationStarted","data":{"index":1,"resumed_session_id":"f91ff40e-9af7-471e-83fe-4eda6f146217"}}
{"stream":"jobsite:js-3825...","i":4,"at":"15:35:09.80","type":"JobsiteIterationCompleted","data":{"session_id":"f91ff40e-9af7-471e-83fe-4eda6f146217","status":"completed","text":"The CI failure is fixed and pushed to `foreman/gh-2us/run-165e...` as commit `0cd73e6`. ..."}}
{"stream":"jobsite:js-3825...","i":5,"type":"JobsiteCommitsRecorded","data":{"commits":[{"sha":"0cd73e6cfaab13ca9e0f73a73bf92acb2cb06837","subject":"fix: restore addition in app.add"}]}}
{"i":15,"at":"15:35:11.60","type":"PrFixFinished","data":{"kind":"ci","attempt":1,"outcome":"pushed","new_head_sha":"0cd73e6cfaab13ca9e0f73a73bf92acb2cb06837"}}
```

The run's worktree was created at 15:33:46 and cleaned up at 15:33:53 (`cleanup: on_success`), so the fix recreated it at the SAME path (`attach_new/1`: the path was free) and resumed. GitHub: the head went `869adac6`
(operator, "ci: inject a regression in app.add") -> `0cd73e6c` (`foreman-e2e`, "fix: restore addition in app.add", a fast-forward), checks `failing` -> `pending` (15:35:11) ->
`passing` (15:35:32), `app.py` has `return a + b` again, the card is back in Ready for review. Claude's transcript `f91ff40e...jsonl` (36 lines before): the run's turns (`Write`, `done`),
then at 15:35:02 the fix prompt, `Bash`, `Edit`, `Bash` (the unit tests), `Bash` (commit and push), all `is_error: false`, 77 lines; `"permissionMode":"bypassPermissions"` in both
halves; the first 36 lines hash to `d267f77d985285c12b575e82a3cb40d13d0ff7098484eac7f1157eec8143ef47` before and after; the set of session transcripts under the private HOME is
unchanged (the run's, and the readiness probe's); the appended turns name `https://github.com/ldangelo/foreman-scratch-202610260959/pull/2`.

Run 3 (PR 3, bead `gh-cyv`, run `run-a76ed0b042613947f5462c9c59f2382b`, jobsite `js-6c7e167e3f704ada`, session `fb31ce0b-...`): the same events and the same 31 passes, head
`56519de2` -> `6682c3b5`, 36 -> 77 lines.

## Harness changes and observations

- `gh_prfix_field` printed a JSON object pretty-printed and kept its first line (`{`), so run 1's (b) read `''`; it prints compact JSON now. This was the only harness fix.
- `scripts/e2e/claude_projects/github_extras.sh` has the stage (`claude_fix_ci`, `gh_x_claude_fix_ci` and its helpers), `pr_fix_evidence.exs` is new, `new_bead`/`gh_new_pr` take an
  optional issue type, `github_live_extras.sh` registers the stage (after `ui_conflicts`, before `autofix`, which turns the policy on) and sources `claude_home.sh`.
- The setup assertion "a 2xx ping delivery is recorded by GitHub" failed in both stack starts (`FAIL no 2xx ping delivery recorded`, 90 s window): GitHub delivered the first ping minutes
  late. The webhook itself worked (a re-sent ping was answered 202 by Foreman; the unsigned and wrongly signed probes were refused 401). PrMonitor polling covers the stage either way. Not changed.
- `stage safety` (the read-only content scan, run on the repository after the stage): paths ever committed (8) are the fixture plus `note_claude1.txt`; no token, `FOREMAN_*` dump,
  transcript or local path in any file at any of 11 commits, in PR text, check output or the 17 Actions logs. It flags two commit identities, neither a leak of this run: GitHub's own
  `refs/pull/N/merge` test merges are authored by the account holder, and Foreman's phase commits use `Foreman <foreman@localhost>`. The repository is private and archived.

## Not exercised

- Only `haiku`, only the host sandbox (`FOREMAN_PR_FIX_SANDBOX=host`), only the Fix CI kind; Address comments and Resolve conflicts build their plan through the same code (unit tested for every kind) and were not run with claude.
- A run whose phase had `approval_mode: prompt` gets the harness default on its fix thread (documented in `PrFix`), a run with no recorded session uses `:pr_fix, agent:` (no approval mode);
  neither was run live. The docker sandbox (the production default) was not run: its claude login is a separate matter (`foreman-jobsite-template`).
- The unfixed code against the operator's real `~/.claude` (`defaultMode: auto`).
- Rollback: an event written with `approval_mode` is refused by an older server's strict `EventCodec` (unknown keys raise), which skips the session record. Forward only.

## Cleanup

Both stacks were stopped with `stop` (server, notification sink, tunnel and webhook removed, database dropped, work dir removed, scratch `main` restored to the seed commit; PRs 1 to 3
closed); no `cloudflared`, server or listener of the harness was left, no `foreman_e2e*` database. The scratch repository was archived. The private transcripts, evidence files and claude
session files stayed under the gitignored `tmp/` of the worktree and are not part of this change.
