# Live mid-phase steering (beads foreman-s48kc, foreman-b3jtt)

Status: GO for `claude` and `pi` (workflow door). Supersedes the S2 NO-GO for steering only (S2 tested the
Session API; this uses the one-shot Run path the workflow door already runs on). Probes and raw logs:
`docs/spikes/LS1/` (real claude 2.1.308, real pi 1.3.0 / minimax).

## 1. Mechanism per provider (all measured)

| | claude | pi |
|---|---|---|
| Live-input mode | `claude -p --input-format stream-json --output-format stream-json --verbose --replay-user-messages`, prompt and steers are JSON lines on stdin (`{"type":"user","uuid":ID,"message":{"role":"user","content":TEXT}}`) | `pi --mode rpc`, stdin JSON commands `{"type":"prompt"}` then `{"id":ID,"type":"steer","message":TEXT}` |
| Semantics | **Queued, injected at the next safe point**: the in-flight tool call finishes, then the message is taken as a user turn of the SAME session (`claude-A.txt`: `sleep 12` ran to completion, then `a.txt` = BETA, one `result`). No interrupt. | Same (`pi-steer.txt`, `pi-steer2.txt`): `queue_update` shows it queued, the tool finishes, `turn_start` + user `message_start` consume it. |
| Delivery ack | none needed: the write is the delivery | `response {success:true, data:{disposition:"queued"}}` |
| **Consumption proof** | the echoed user event (`isReplay:true`) carries **our `uuid`** (`claude-bg.txt`) at the moment the model takes it | user `message_start` with the steer text + `queue_update` removes it from `steering[]` (no id: matched FIFO by text) |
| Turn end | `result` event. With stdin open the process stays alive and a later stdin message starts a new turn in the same session (`claude-C-replay.txt`) | `agent_settled`; **pi exits 0 ~3 s after stdin EOF** |
| Background task (b3jtt) | with stdin open, a steer sent after the first `result` while a `run_in_background` task runs IS consumed as a new turn (`claude-bg.txt`); the CLI also wakes itself when the task completes | n/a |
| Session id | `result.session_id` (already mapped) | rpc mode emits no `session` header; `get_state` -> `data.sessionId` (measured) |

Other adapters (codex, gemini, opencode, kimi, grok, amp, zai) keep `pause_resume`; the capability is typed
(`:live | :pause_resume`) and a steer to a non-live phase says so in its delivery event rather than degrading silently.

## 2. Delivery model (reuses the E6-S4 commands/events, adds delivery state)

`run.steer` -> `RunSteerQueued` (unchanged, still the durable queue). Then, per message:

1. **Live path** (running phase whose agent was launched in live-input mode): `Jido.Harness.Run.send_input/3` writes the
   line. Success -> new `RunSteerDelivered {message_id, mode: "live"}`; the run is NOT paused. Failure
   (`:not_live`, `:input_closed`, `:not_running`) -> fall back to the existing pause -> resume path.
2. **Consumed**: the harness emits `:input_accepted` when the provider echoes/starts the message; a Foreman watcher
   turns it into `RunSteerConsumed {message_ids, delivery: "live"}` (existing event, new optional field).
3. **Closing the input** is serialized in the harness RunWorker: on `:input_idle` (claude `result` / pi `agent_settled`) stdin is
   closed only if no written message is awaiting consumption, so a steer is never dropped by a racing close; a write after
   close returns `:input_closed` (-> fallback), never silence.
4. **Never silent (b3jtt)**: a message still pending (queued or delivered-not-consumed) when its run goes terminal
   (`RunCompleted/Failed/Cancelled/...`) gets `RunSteerUndelivered {message_id, reason}`; the projection moves it out of `pending_steering`
   into `undelivered_steering`. If the phase ends but the run continues, the message stays pending and the next phase prompt injects it (existing path).

## 3. What the operator sees
Thread transcript: steer turn plus system rows `steer delivered (live)`, `steer consumed (live|next phase)`, `steer NOT delivered: <reason>`.
`foreman thread show` and the MCP/REST run projection expose `steering: [{message_id, state: queued|delivered|consumed|undelivered, mode}]`.
The steer API stays operator-only (no agent path).

## 4. Restart / stop
Stop/cancel kills the CLI (existing `RunControl.cancel_agent`); written-but-unconsumed messages go undelivered at the terminal event.
Server restart: the provider process dies with the worker; the durable queue is the event log, so pending messages are re-injected by the
rebuilt phase prompt (at-least-once: a message consumed live just before a crash may be re-injected).

## 5. Out of scope
Jobsite door (it already resumes via follow-up sessions), approvals (InFlightApprovals), non-claude/pi providers.
