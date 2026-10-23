# Live mid-phase steering: live acceptance run (2026-10-22)

Real Foreman server (dev, port 47671, throwaway DB, dropped afterwards), `HOME` redirected with `~/.claude`, `~/.claude.json`,
`~/Library/Keychains`, `~/.pi` symlinked; scratch git repo + local bare origin under `foreman-wt/livesteer-scratch/live`.
One-phase workflows `steerclaude` (claude) and `steerpi` (pi, `models.default: minimax/MiniMax-M2.7-highspeed`).
jido_harness comes from the vendored path dep `packages/jido_harness`. Steer sent with `foreman thread steer`.
Event order read from the event store (`stream_events`). Probes: `docs/spikes/LS1/`.

| # | Scenario | Observed | Result |
|---|----------|----------|--------|
| 1 | claude, steer 15 s into `sleep 25` | `RunSteerQueued` 20:41:47.011, `RunSteerDelivered` .014, `RunSteerConsumed` (delivery live) 20:42:05, `RunCompleted`. No `RunPaused`/`RunResumed`, one `PhaseStarted`, one `WorkerSessionBound`. Worktree: `a.txt`=BETA, `b.txt`=GAMMA, committed. Transcript rows: steer, "Steer delivered to the running agent: live", "Steer taken by the agent: live" | PASS |
| 2 | pi (minimax), steer 20 s into `sleep 30` | same sequence, no pause, one phase; `a.txt`=BETA, `b.txt`=GAMMA committed | PASS |
| 3 | steer queued before any agent exists (`--no-resume`), then `run cancel` | pause fallback, then `RunCancelled` followed by `RunSteerUndelivered` (reason `run_cancelled`); transcript "Steer NOT delivered: run_cancelled" | PASS |
| 4 | b3jtt shape: claude ends its turn with a `run_in_background` task running, steer sent then | live input was already closed after the first `result` (nothing pending), so the steer fell back to pause/resume and was consumed by prompt injection (`delivery: prompt`); final transcript says it created `d.txt`=DELTA and `done.txt`. Not dropped | PASS (fallback, not in-session) |

## Not verified
- Full `mix test` suite, `mix doctor --raise`, Go tests: not run by this agent (only targeted files below).
- Steer to a run whose live session ended with the message written but unconsumed (grace-timer path, `RunSteerUndelivered` from a delivered message): covered only by the harness unit design, no live run.
- Server restart / stop with a delivered-unconsumed steer.
- Claude cost model: the claude phase used the CLI default model.

Targeted tests passed: jido_harness `live_input_test.exs` (6), `run_steer_test.exs`, `live_steering_test.exs` (3), `run_steering_test.exs`.
