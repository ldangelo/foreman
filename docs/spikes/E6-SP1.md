# Spike E6-SP1 - does resume rebuild the interrupted phase prompt?

**Verdict: GO** for "inject operator steering into the rebuilt phase prompt".

## Evidence (read from code on feat/cp-e6-threads)

1. `run.pause` -> `RunPaused` -> `Dispatcher.handle_run_stopped/3` calls `RunControl.request(run_id, :pause)` then
   `RunControl.cancel_agent/1`, which fails the in-flight `execute_agent` call. `RunExecutor.handle_phase_body_error/6`
   sees `RunControl.intent/1 == :pause`, commits partial worktree work (`commit_phase_worktree`) and returns
   `{:stopped, %{state | status: :paused}}`; the executor process then stops with `:normal`. The interrupted phase is never
   marked completed.
2. `run.resume` -> `RunResumed` -> `Dispatcher.handle_run_resumed/3` clears `RunControl` (ETS intent **and, once E6-S4
   lands, any mailbox**), then `resume_run/2` starts a brand-new `RunExecutor` with `resume_from:
   resume_from_index/2` = the first phase whose projection status is not `completed`. That is the interrupted phase.
3. The new executor runs `Lowering.lower(phase_specs, start_index: resume_from)` and `Jobsite.Engine`, which reaches
   `build_agent_launch/6` -> `build_request/4` -> `read_phase_prompt/4` -> `render_prompt_template/5`. The prompt is
   therefore rendered from scratch (full phase prompt, re-sent in full) on every (re)start of a phase. There is no
   cached prompt.
4. The previous executor is terminated, so `RunExecutor.terminate/2` runs `RunControl.clear/1`: **anything stored only in
   the ETS mailbox is lost across a pause/resume**. This is the one trap for E6-S4: the durable source of truth for
   pending steering must be the projection (`RunSteerQueued` minus `RunSteerConsumed`); the ETS mailbox may only be a
   cache that is re-populated, never the only copy.
5. Partial work: committed to the run branch/worktree before the executor stops; the resumed phase runs in the same run
   worktree, so the agent sees its own partial commit. The phase restarts from its beginning (full prompt, no provider
   session continuation, since the workflow door is one-shot `Run`).

## Decision

Injection point: `RunExecutor.prompt_template_assigns/4` / the prompt wrapper used by `build_request/4` (shared by all
workflows). Read pending steering from the projection, render a delimited block, and dispatch the system command
`run.steer.consume` only after the request was built successfully.

## Limits

Not verified by a live scratch run here (provider environment unavailable); the E6-S4 run_steering test exercises the
pause -> resume -> rebuilt-prompt path end to end with a fake agent and is the executable evidence.
