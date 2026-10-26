# Parity-gap beads: live verification, 2026-10-22

Beads: foreman-nufr9, foreman-pz1ie, foreman-he4yf, foreman-8vf0s. Everything below was observed unless marked UNVERIFIED.

## Environment
- Worktree `foreman-wt/liveverify` off origin/main `81b48d77` (+ the fix in this PR). Real server (`mix phx.server`, dev env, via devbox), port 47913, throwaway DB `foreman_liveverify` (dropped afterwards), `HOME` redirected to `foreman-wt/liveverify-scratch/home` (symlinks `~/.claude`, `~/.claude.json`, `~/Library/Keychains`; pi runs with a private `PI_CODING_AGENT_DIR` holding only `auth.json`/`models.json` and an `mcp.json` pointing at this server, so no worker could reach another Foreman).
- Providers: real `pi` + `minimax/MiniMax-M2.7-highspeed` (workers), real `claude` CLI (coordinator `haiku`, thread `haiku`, reviewer `FOREMAN_REVIEW_PROVIDER=claude FOREMAN_REVIEW_MODEL=haiku`). Claude Code's own session files show the model was `claude-haiku-5-5`. Claude auth worked through the redirected HOME for the whole session (no expiry, no permission hang).
- Scratch repos `work`, `work2`, `work3` (own bare origins, own `br` 0.6.0 DBs). GitHub was FAKED (`gh` dispatcher: the acceptance fake for the primary repo, the recording multi-repo fake for others). `br` and `docker` were wrapped by logging shims on the server PATH. Scratch workflows `lvpi`, `lvclaude`, `lvclaudeprompt`, `lvclaudeauto`, `lvselfadd` (bundled fix/prd/review not used, foreman-pv11k).
- Not attempted: real GitHub, Telegram/Slack, pi in-flight approvals.

## foreman-nufr9 Claude provider paths: PARTIAL (not closed)
| Path | Result | Observed |
|---|---|---|
| Claude coordinator | PASS | `project chat` with `--coordinator-provider=claude --coordinator-model=haiku`: typed reply + `start_thread` in 23 s (first turn 47 s) |
| Claude thread (workflow door) | PASS | `lvclaude`: completed in ~8 s, Write tool created `hello.txt`, committed, `provider_sessions[].model=haiku`, usage `cost_usd` 0.0069 |
| Coordinator -> claude thread -> claude reviewer -> report | PASS | one chat message; thread run completed; `ReviewRecorded` verdict MET (5/3/4/3) reported back into the chat, all within 23 s |
| Claude reviewer | PASS | analysis.json verdict `met`, evaluator claude haiku, usage role `review` rows |
| approval_mode default (no flag) | environment-dependent | session `permissionMode: auto`: Write succeeded with no prompt. This comes from the operator's `~/.claude/settings.json`, not from Foreman. The user-guide sentence "Without it, Claude cannot write files headlessly" is false on such a host |
| approval_mode `prompt` | PASS (after fix) | Write and Bash denied in-session (no hang, run ended in <20 s). **BUG FOUND+FIXED:** the run FAILED with `{:permission_denied, ["Write"]}` and no approval request; E8 pause-for-approval never fired because `awaiting_approval/3` matched only the bare tuple while the real worker returns `%FailureCause{code: {:permission_denied, _}}`. After the fix: run `paused`, requests `perm-1-Write-1`/`perm-1-Bash-1` (`resume_with_override`), `foreman approvals approve --call perm-1-Write-1` -> run resumed with `permissionMode acceptEdits`, completed, `approved.txt` committed. Resume starts a NEW claude session id (d027bed9 -> ef293398) whose file carries the full prior history. The Bash request stayed `requested` after completion (cosmetic) |
| Session resume via thread steer | PASS (foreground tool) | `thread steer` during a 45 s foreground python sleep: RunSteerQueued/Paused/Resumed/SteerConsumed, new session id, both `slow.txt` and `steered.txt` produced |
| Steer while claude waits on a background task | FAIL | message never consumed, run completed without the work (bead foreman-b3jtt) |
| Claude as worker on a fix/PR thread resume (`PrFix` `resume_session`) | PASS on 2026-10-26 (was UNVERIFIED) | `live-claude-prfix-resume.md`: real PR, resumed claude session, head moved, CI green; one defect (no `approval_mode` on the fix agent) fixed |
| `approval_mode: auto_approve` | PASS | `permissionMode bypassPermissions` |
Other claude findings: a phase `provider: claude` cannot pin a model (foreman-ezj0m); an invalid manifest vanishes silently (foreman-gl3nu).

## foreman-pz1ie: PARTIAL
- Thread-produced library files: PASS. `--library-collect-produced=true`; each run got `produced-<run>-<hash>` with `archive/analysis.md`, `archive/diff.patch`, `phase-N/phase-N.md`. Side effect: every later thread prompt lists all previous produced entries.
- Agent-written memory via MCP: PASS. pi called `foreman_project_memory_write`; `project memory list` shows `agent-learned`, author `agent`.
- Per-thread usage rows: PASS. `foreman usage --project lv --by thread` lists one row per run (claude rows partial-cost `*`), `--by role` shows `thread`/`review`. Coordinator turns have no usage row.
- BeadSink with br down: PASS with different code than the bead says. Bead `lv-75z` (watcher-dispatched), `br` made to fail (shim) after dispatch: the review was still recorded (`met`) and the summary ends `bead sink failed: bead_write_failed`; no comment, no crash. `bead_unresolved` is not what br-down produces. The same outage failed finalize with `BR_PARSE_ERROR` (non-JSON stderr, exit 1) which misdescribes an outage.
- Coordinator tasks have no bead, so BeadSink is skipped (`has no originating bead` logged): by design.

## foreman-he4yf multi-repo: PARTIAL
- Task with `repo_ids:["b"]` (gate on): PASS. Worktrees `workspace` and `repos/b`; the pi agent read `$FOREMAN_REPOS` (env contract) and committed `VERSION` in both; branch pushed to both origins; archive `diffs/b.patch`, manifest `repositories[]`. The primary PR failed only because the single-repo fake `gh` state file was corrupted by concurrent writes (test infra); the run still completed and reported no `completed_with_errors`.
- Thread self-add: PASS. pi called `foreman_run_request_repo` (allowlist = scratch dir); `RunRepoRequested` on `run_repo_audit:<run>`; phase 2 wrote `SELFADD` in the primary and in `work2`.
- Fanout: PASS (called directly over MCP JSON-RPC, not by an agent). `repo_ids:"all"` created `fan1-main`, `fan1-b`, `fan1-work2`; the same `fanout_id` again created no duplicates. Tasks were not started.
- Jobsite multi-repo: refused by design (`403 spec_forbidden_key: multi-repo jobsites unsupported`); nothing to run.
- Real GitHub: not run.

## foreman-8vf0s: PASS for what was exercised, bead left open (see UNVERIFIED)
- Env delivery: `LV_COLOR` and the secret reached a real pi agent on both doors.
- Secrets: events table (byte search), server log, `transcript.jsonl` clean; an agent that echoed the secret got `TOKEN-IS-[REDACTED]`. Exception: `diff.patch`/reviewer transcript hold the secret if the agent commits it (foreman-gkrfw).
- Setup script: ran in the worktree with `FOREMAN_RUN_ID` and project env on both doors; exit 7 -> run failed `{:setup_script_failed, 7, "boom\n"}`.
- Network policy: `none` -> `docker run --network none` observed in the docker shim log; `allowlist` -> egress image build, `--internal` network, tinyproxy sidecar with the allow list, all removed after the jobsite. Host sandbox with a non-default policy -> ghost jobsite (foreman-bg2kq). In-container blocking itself UNVERIFIED (agent binary absent in the alpine test image, `pi` exit 127).
- Schedules: cron `* * * * *` fired runs at 20:12 and 20:13 UTC; `pause` stopped firing (thread count unchanged for 75 s); resume/delete worked. Dashboard Scheduled tab not looked at (UNVERIFIED).
- Adopt: Move (run into another project, archive manifest updated), Mint (`path_in_use` refusal while the path owner is live, success after archiving it), Continue (new task seeded from the archive; needed a manual `task.approve`, foreman-7nvf8). Recommend: findings, `--fail-on warn` exit 1, `--fail-on action` exit 0, `agents_md_missing` disappeared after adding AGENTS.md.

## Fix in this PR
`RunExecutor.awaiting_approval/3` now accepts `%FailureCause{code: {:permission_denied, tools}}`. Regression test: `run_executor_run_worktree_test.exs` "pauses awaiting approval when the denial arrives as a FailureCause". Mutation check: making `denied_tools(%FailureCause{})` return nil fails exactly that test (54/55). The existing test only used the bare tuple, which is why this shipped.

## Beads filed
foreman-ezj0m, foreman-gl3nu, foreman-bg2kq, foreman-b3jtt, foreman-gkrfw, foreman-7nvf8.
