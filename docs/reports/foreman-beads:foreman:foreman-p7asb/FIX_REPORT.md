# Fix report — OperatorQuestionDispatcher: a failed `question.open` or a deduped ingest never records the question

## 1. Root cause

`packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex`, `ingest/1` (line 84): the
ingest result was matched as `{:ok, :started, _item}`, so **only** the delivery that started the inbox item
reached `record_question/4` (line 126). `ForemanServer.Agents.SharedInbox.ingest/2` answers `{:ok, :deduped,
_item}` for a repeat delivery of the same `signal.id` inside its 300-second window, and that branch neither
recorded the question nor scheduled its timeout. Because `record_question/4` only logs a failed
`question.open` (`Logger.error`, line 150) and never raises or returns an error, a question whose open command
failed was therefore never listed on `GET /api/projects/:id/questions`, never answerable, and never expired by
the dispatcher's `OperatorTimeout` fast path — while the inbox dedupe entry hid the question from every later
delivery, so nothing ever retried the open.

## 2. Change

`packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex`:
- `ingest/1` (line 84) matches `{:ok, outcome, _item} = result when outcome in [:started, :deduped]` and calls
  `record_question/4` for **both** outcomes. `question.open` is idempotent — a deterministic
  `command_id` (`"question-open:" <> question_id`) plus the aggregate's `question.open` guard, which answers
  `{:ok, nil}` for a question that already exists — so re-recording on a deduped delivery is a retry, not a
  duplicate `QuestionOpened`.
- `ingest/1` now arms `ForemanServer.Agents.OperatorTimeout.schedule/3` only when `outcome == :started`, so a
  deduped delivery cannot stack a second timeout timer on the same `question_id`; the `:started` delivery still
  arms exactly as before, and `Approvals.Sweeper` remains the durable backstop for a question that was never
  recorded at all.
- Module doc (step 3) and the `@doc` for `dispatch/1` updated to state the two outcomes and that the fast-path
  timer is armed only by the `:started` delivery.

`packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs` — two tests:
- line 356 `"a failed question.open is retried by the next delivery of the same signal"` — the first delivery
  (`:meck`-stubbed `ForemanServer.Approvals.Dispatch.system/1` → `{:error, :gateway_down}`) logs the failure and
  records nothing; the second, deduped delivery goes through the real path and produces the `QuestionOpened`
  event with the same fields (`run_id: "global"`, `question_id`, `agent_id`, `timeout_ms: 300_000`).
- line 403 `"the operator timeout is armed once, by the ingest that started the item"` —
  `OperatorTimeout.schedule/3` is observed once on the `:started` delivery and not reached on the `:deduped` one.

## 3. Deviations from the plan

None. The implementation is PLAN.md §4 Edits 1–4 as written, in the same order and shape.

## 4. Tests

New: the two tests above. Run (the PLAN §5 command):
`test/foreman_server/agents/operator_question_dispatcher_test.exs`,
`test/foreman_server/agents/operator_question_flow_test.exs`,
`test/foreman_server_web/controllers/webhook_controller_test.exs`.

## 5. Local verification

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test \
  MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/agents/operator_question_dispatcher_test.exs \
  test/foreman_server/agents/operator_question_flow_test.exs \
  test/foreman_server_web/controllers/webhook_controller_test.exs'
→ 36 passed, 0 failed, exit 0

devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted' → exit 0
```

## 6. Follow-ups

- A `question.open` that fails on the *last* delivery of a signal is still only logged: no further delivery
  arrives inside the dedupe window to retry it, so the question stays unlisted until `Approvals.Sweeper` has
  something to expire. PLAN.md §6 rules out changing `record_question/4`'s error handling or return shape in
  this run, so this is recorded rather than fixed.
- The repo-rules review phase (phase 4) restored `REVIEW_CODERABBIT_REPORT.md` from commit `5a187245` after this
  run's commit step had left only a prose version carrying no machine-read blocks, authored this missing
  `FIX_REPORT.md`, and reconciled `CLAUDE.md` (the E8 questions bullet) and `docs/user-guide.md` (Questions
  bullet) with the new `:deduped` behavior.
