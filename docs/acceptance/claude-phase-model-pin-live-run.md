# Live verification: `provider: claude` phase pins a bare model (foreman-ezj0m), 2026-10-22

Contract: a phase with `provider: claude` declares `models.default` as a bare alias/id
(`haiku`); a slashed value (`claude/haiku`, `litellm-stack/x`) is refused at manifest load.
`provider: pi` keeps `<provider>/<model>`. Foreman passes the string verbatim.

## Setup
Worktree `foreman-wt/claudepin` off origin/main + this change. Real server
(`mix phx.server`, dev env via devbox) on port 4871, throwaway DB `foreman_e2e_claudepin`
(dropped), scratch repo + local bare origin + own `br` DB under `foreman-wt/claudepin-scratch`
(removed). Server `HOME` redirected to a scratch dir symlinking `~/.claude`, `~/.claude.json`,
`~/Library/Keychains`. Harness: `scripts/e2e/claude_projects/lib.sh` with two custom workflows:
`claudeit` (`task_types: [bug]`, `provider: claude`, `models.default: haiku`) and `pidit`
(`task_types: [task]`, `provider: pi`, `models.default: minimax/MiniMax-M2.7-highspeed`).
Two `foreman-exec` beads (one `bug`, one `task`) dispatched by BeadsWatcher.

## Observed
| Phase | Result | Evidence |
|---|---|---|
| claude, `models.default: haiku` | run `completed` | `provider_sessions: [{provider: claude, model: haiku, ...}]`; Claude Code's own session file for that session id has every assistant turn `model: claude-haiku-5-5`; `hello.txt` committed on `foreman/<task>/<run>`; usage cost_usd 0.0053 |
| pi, `minimax/MiniMax-M2.7-highspeed` | run `completed` | `provider_sessions: [{provider: pi, model: minimax/MiniMax-M2.7-highspeed}]`; `hello.txt` committed |

Before the change the same claude phase could not pin a model: `claude/haiku` passed load
validation and failed the run at dispatch ("issue with the selected model"), bare `haiku`
was refused at load.

Note: my first two live attempts were harness mistakes (a flow-style `worktree: {..}` mapping that
the manifest loader rejects with "must be a mapping", and a server restart racing the port); neither
touched the change.
