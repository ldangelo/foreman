# `question.answer` length boundary through a real claude run and a real browser: live run, 2026-10-31

Bead `foreman-7c191` part 2 (parity-audit row C7; part 1, the MCP `foreman_schedule_update` half, is in
`e2e-live-verify-2026-10-30.md`). Harness: `scripts/e2e/question_answer_boundary.sh` (own port 4850 and hook port 4950, own database
`foreman_e2e_claude_projects_qbound`, a scratch git repository with a local bare origin, a private claude HOME from
`claude_projects/claude_home.sh`, headless Chromium through the Playwright of `scripts/e2e/ui-a11y`; browser driver
`scripts/e2e/live_claude/questions_ui.mjs`, which gained a `limit` action and reports `maxlength`). Run it with
`devbox run -- bash scripts/e2e/question_answer_boundary.sh` (`QB_AGENT=none` is the dry run: a task with no run, no claude).

## Result

| Run | Result |
|---|---|
| dry run, `QB_AGENT=none` (no provider, no spend) | `passed=43 failed=0 unverified=3 wall=12s` (the 3 UNVERIFIED are the items that need a claude run) |
| live, real claude `haiku`, attempt 1 | `passed=56 failed=1 unverified=0 wall=52s` |
| live, real claude `haiku`, attempt 2 | **PASS**: `passed=56 failed=0 unverified=0 wall=55s` |

The attempt-1 failure was the harness's own assertion "nothing more is appended" to the agent's claude session record of the steer: the
record was 8808 characters, the first 8000 byte-identical to the steer (that assertion passed) and the other 808 are text Claude Code adds
to a message sent mid-turn (`This is how Claude Code surfaces messages the user sends mid-turn ...`), not something Foreman sent. The
assertion became a recorded note (what follows the steer, and where in the session file); nothing else changed between the attempts. One
short haiku run each (52 and 55 s of wall time; spend not measured). A third run was not made, so the attempt-2 script differs from the
committed one in one informational note: the "tool calls naming the answer files" line printed nothing in attempt 2 because its jq filter
truncated the input before matching `answer-`; the committed filter selects before truncating and was checked on synthetic tool calls only.

## The numbers (computed in the harness, not read from the code under test)

The `run.steer` text cap is 8000 characters; the steer is `Answer to your question <id>: <answer>` (24 + id length + 2 characters of
prefix), so the longest answer is `8000 - 26 - len(id)`: 7960 for `qb-<pid>-exact`, 7961 for `qb-<pid>-over`, 7774 for a 200-character id.
`OperatorQuestion` also refuses a question id longer than 200 characters.

## What was observed

1. **The agent raised both questions itself.** The task prompt told the claude agent to POST two questions to `/webhooks/operator/ingest`
   (curl from its own Bash tool) and then wait in 20 s `python3 time.sleep` tool calls; both opened under the agent's run and task.
2. **Question ids.** A 200-character id opened and its answer box carries the smaller limit 7774. A 201-character id returned HTTP 202 from the
   ingest endpoint (the inbox item exists) but opened no question: no `QuestionOpened` event, and the server log carries
   `OperatorQuestionDispatcher: question.open for <id> failed: {:error, {:question_id_too_long, 201, 200}}`; a direct dispatch on the server
   node returns the same typed error. Note the operator-visible effect: the agent is told 202 and nothing tells it the question was not opened.
3. **Max-length answer (browser).** 7960 characters typed into the answer box (`maxlength=7960`): accepted; `QuestionAnswered` carries 7960
   characters (SHA-256 equal to the typed text), `answered_by dashboard`; exactly ONE `RunSteerQueued` of 8000 characters whose SHA-256 equals prefix + answer;
   `RunSteerDelivered` recorded (mode `live`); the agent obeyed the last sentence of the answer (`answer-exact.txt` = `BOUNDARY-EXACT-OK` on the
   run's branch), so the whole text arrived; the agent's own claude session holds the 8000 characters (first 8000 characters equal by SHA-256).
4. **Max+1.** The box of the second question carries `maxlength=7961`; one more typed character is stopped by the browser; a script-set value of 7962
   characters (a client ignoring the attribute) is refused in the page with an error-styled notice naming the length and the limit; the question stays
   open. The CLI prints `foreman: HTTP 422: {"error":"{:answer_too_long, 7962, 7961}"}` and exits 1; the question is still open; no `QuestionAnswered`
   and no `RunSteerQueued` exists. A 151-character CLI answer then goes through (`answered_by e2e`), is steered into the run (SHA-256 equal) and
   obeyed (`answer-short.txt` = `BOUNDARY-SHORT-OK`); `answer-over.txt` does not exist.
5. The run completed; the agent made 4 tool calls (2 Bash, 2 Write).

## Not proven

- The max-length answer was typed in a browser; the over-length value was refused in the browser and over the CLI. No other client (MCP, raw API) was driven.
- The agent raised the questions because the prompt told it to, and the answers' last sentences told it what to write; this shows delivery and
  comprehension of an 8000-character steer, not a free-form agent decision.
- A steer arriving while the agent is inside a long tool call was not tested (the agent waited in 20 s calls).
- The 201-character id leaves the agent with an HTTP 202 and no question: not changed here (see the note in item 2).
