# In-flight tool approvals: live run (bead foreman-exofh)

Date 2026-10-22. Worktree `foreman-wt/inflightappr` off origin/main `77277173`. Real server (`mix phx.server` path via `scripts/e2e/claude_projects/lib.sh`, dev env, port 4891, throwaway DB `foreman_e2e_inflight`, dropped afterwards), real `claude` 2.1.308 through a redirected `HOME` (symlinks `~/.claude`, `~/.claude.json`, `~/Library/Keychains`), real `br`/git, scratch repo + local bare origin. Workflow `claudeprompt`: one `provider: claude`, `approval_mode: prompt` phase (default model; a pinned `claude/haiku` is passed to the CLI literally, see foreman-ezj0m). Script: `inflight_live.sh` (not committed). No GitHub involved.

## Probes before building (docs/plans/inflight-approvals.md)
`--permission-prompt-tool` + a stdio and an HTTP MCP server: allow after 4 s (same session, file created), deny (tool_result `Denied by ...`, model quoted it), and a 100 s block: a plain HTTP reply is abandoned by claude after ~60 s ("The operation timed out"; the model then retried with another Write), a `text/event-stream` reply with `notifications/progress` for the request's `progressToken` survived 100 s in one call. That is why the endpoint streams.

## Observed
| Case | Observed |
|---|---|
| A approve (CLI) | Write blocked; `foreman approvals list` showed `status requested`, `approval_delivery inflight`, run `in_progress`, 1 claude process alive 20 s later. `foreman approvals approve --run .. --call ..` -> run `completed` in the SAME claude session (one `provider_sessions` entry), commit `Foreman run .. phase 1` holds hello.txt, request `finished`. No `RunPaused`/steer (run never paused). |
| C timeout | `approval_timeout_ms=15000` (set on the node via rpc): request became `denied`, `decided_by: system`, `reason: timeout`; the Write did not happen; the run then failed `{:permission_denied, ["Write"]}` (claude lists the refused call in `permission_denials`; the post-hoc pause does not re-request it, so the phase fails). |
| B deny (UI) | Workspace thread card showed `Write {...} the agent is waiting on this call [Approve] [Deny]`; clicking Deny gave `Done: tool.deny run../inflight-..`; request `denied`, `decided_by: dashboard`; no hello.txt in the worktree (README.md only); run failed `{:permission_denied, ["Write"]}`. |

Find while running: a LiveView opened on `127.0.0.1` stays `phx-error` (socket refused, buttons inert); on `localhost` (the endpoint's configured host) it connects. Pre-existing check_origin behaviour, not changed here.

## Not exercised (UNVERIFIED)
UI Approve click on a live run (UI Approve covered by the LiveView test only); the exact denial text the agent saw (only: file not created, run reports permission_denied); run stop / server restart while a call is blocked (tested at unit level only: `PermissionPrompt` run-ended and client-gone tests); a blocked call longer than ~100 s (the 15 s progress keep-alive was probed for 100 s and exercised for ~20 s live); other providers.
