# PLAN — foreman-p7asb: OperatorQuestionDispatcher never records a question on dedupe / after a failed `question.open`

All paths are repository-relative from the repo root.

## 1. Verdict

**Real bug**, present on the current tree (HEAD `018da6b1`).

`packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex:82-104`
(`ingest/1`) matches only `{:ok, :started, _item}`; every other result (including
`{:ok, :deduped, _item}`) falls into `other -> other` and does nothing. Consequences:

- A re-delivered signal (`SharedInbox.ingest/2` returns `:deduped` from
  `ForemanServer.Inbox.DedupeTable`, window `:inbox_dedupe_window_seconds`, default 300 s)
  skips `record_question/4`, so no `question.open` is dispatched.
- `record_question/4` (`:116-144`) only logs when `Dispatch.system/1` fails (`:139-143`).
  After that failure the dedupe entry exists, so every retry is `:deduped` and the question
  is **never** opened: absent from `GET /api/projects/:id/questions` and the Overview, and
  unanswerable/unexpirable (`OperatorTimeout.handle_info/2` finds no open question and
  no-ops; `Approvals.Sweeper` has nothing in the projection to sweep).

Existing tests cover only the `:started` path
(`packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs`,
`describe "dispatch/1 opens the question (question.open)"`, lines 178-355): 15 tests pass
today, so nothing asserts the dedupe/failure behaviour.

## 2. Root cause

`ingest/1` couples two independent concerns to the `:started` outcome:

- recording the question (`question.open`; idempotent by aggregate state and by the
  deterministic `command_id` `"question-open:<question_id>"`) — must happen on every
  successful ingest;
- arming the fast-path expiry timer (`OperatorTimeout.schedule/3`) — must happen once.

Fix: call `record_question/4` for `:started` **and** `:deduped`; schedule the timeout on
`:started` only. A failed `question.open` is then retried by the next (deduped) delivery.

## 3. Failing check first

Add two tests to the existing describe block
`describe "dispatch/1 opens the question (question.open)"` in
`packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs`
(insert after the test ending at line 355, before that describe block's closing `end`).
The file already has `import ExUnit.CaptureLog`, `meck_passthrough/1` + `meck_expect/3`
(lines 31-38), `question_signal/3` (357), `question_events/2` (418), `atomized/1` (425);
the describe `setup` supplies `question_id`/`agent_id` and cancels the timer on exit.

Test A — the one that fails before the fix:

```elixir
    # A `question.open` that failed leaves the inbox item behind, so every later delivery of
    # the same signal is `:deduped`: the deduped path must retry the open or the question is
    # never listed, answerable or expirable.
    test "a question whose first question.open failed is recorded on the next (deduped) ingest",
         %{question_id: question_id, agent_id: agent_id} do
      meck_passthrough(ForemanServer.Approvals.Dispatch)
      on_exit(fn -> :meck.unload(ForemanServer.Approvals.Dispatch) end)

      meck_expect(ForemanServer.Approvals.Dispatch, :system, fn _command ->
        {:error, :gateway_down}
      end)

      log =
        capture_log(fn ->
          assert {:ok, :started, _item} =
                   OperatorQuestionDispatcher.dispatch(
                     question_signal(question_id, agent_id, "may I continue?")
                   )
        end)

      assert log =~ "question.open for #{question_id} failed"
      assert {:error, :stream_not_found} = question_events("global", question_id)

      # The gateway recovers; the agent re-sends the same signal.
      meck_expect(ForemanServer.Approvals.Dispatch, :system, fn command ->
        :meck.passthrough([command])
      end)

      assert {:ok, :deduped, _item} =
               OperatorQuestionDispatcher.dispatch(
                 question_signal(question_id, agent_id, "may I continue?")
               )

      assert [%{event_type: "QuestionOpened", data: data}] =
               question_events("global", question_id)

      assert %{question_id: ^question_id, agent_id: ^agent_id, text: "may I continue?"} =
               atomized(data)

      assert %{status: "open"} =
               Eventually.await(fn -> ProjectionStore.question("global", question_id) end)
    end
```

Test B — regression guard for the second half of the fix (passes before and after):

```elixir
    test "a deduped ingest does not re-arm the operator timeout",
         %{question_id: question_id, agent_id: agent_id} do
      meck_passthrough(ForemanServer.Agents.OperatorTimeout)
      on_exit(fn -> :meck.unload(ForemanServer.Agents.OperatorTimeout) end)

      test_pid = self()

      meck_expect(ForemanServer.Agents.OperatorTimeout, :schedule, fn id, agent, timeout_ms ->
        send(test_pid, {:scheduled, id, agent, timeout_ms})
        :ok
      end)

      signal = question_signal(question_id, agent_id, "twice, please")

      assert {:ok, :started, _item} = OperatorQuestionDispatcher.dispatch(signal)
      assert_receive {:scheduled, ^question_id, ^agent_id, 300_000}, 1_000

      assert {:ok, :deduped, _item} = OperatorQuestionDispatcher.dispatch(signal)
      refute_receive {:scheduled, ^question_id, ^agent_id, _}, 200
    end
```

Command showing Test A failing before the edits (fails at
`assert [%{event_type: "QuestionOpened", data: data}] = question_events(...)`, actual
`{:error, :stream_not_found}`):

```bash
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test test/foreman_server/agents/operator_question_dispatcher_test.exs'
```

Environment (not a test failure): run `MIX_ENV=test mix deps.get` under devbox once first,
and always pass the `DATABASE_URL` override above — the inherited run env points at port
55434, which rejects the credentials.

## 4. Edits

All in `packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex`.

**Edit 1 — `ingest/1` (lines 82-104).** Replace the whole function with:

```elixir
  defp ingest(data) do
    case SharedInbox.ingest(OperatorQuestionSource, data) do
      {:ok, outcome, _item} = result when outcome in [:started, :deduped] ->
        question_id =
          data |> Map.get("question_id") |> non_empty() ||
            data |> Map.get(:question_id) |> non_empty()

        agent_id =
          data |> Map.get("agent_id") |> non_empty() ||
            data |> Map.get(:agent_id) |> non_empty()

        if question_id && agent_id do
          timeout_ms = resolve_operator_timeout(agent_id)
          record_question(data, question_id, agent_id, timeout_ms)

          # The timer is armed once, by the ingest that started the item; a deduped
          # delivery must not stack a second one.
          if outcome == :started do
            _ = OperatorTimeout.schedule(question_id, agent_id, timeout_ms)
          end
        end

        result

      other ->
        other
    end
  end
```

**Edit 2 — comment above `record_question/4` (lines 109-110).** Replace:

```elixir
  # Idempotent on the question id, so a re-ingested signal opens it once. A
  # failure is logged, never raised: the inbox item already exists.
```

with:

```elixir
  # Idempotent on the question id, so a re-ingested signal opens it once. A failure is
  # logged, never raised: the inbox item already exists. It is called on a deduped ingest
  # too, so a `question.open` that failed is retried by the next delivery of the same
  # signal — otherwise the dedupe entry would hide the question forever.
```

**Edit 3 — moduledoc step 3 (lines 12-14).** Replace:

```elixir
    3. On `:started`, resolves the per-workflow operator timeout from
       the workflow manifest (TRD-027) and schedules it via
       `OperatorTimeout.schedule/3`.
```

with:

```elixir
    3. On `:started` and on `:deduped`, resolves the per-workflow
       operator timeout from the workflow manifest (TRD-027) and
       records the question (`question.open`, idempotent); on
       `:started` only, also arms `OperatorTimeout.schedule/3`.
```

**Edit 4 — `@doc` for `dispatch/1` (line 53).** Replace:

```elixir
  On `:started`, schedules an operator timeout (JSI-T009).
```

with:

```elixir
  On `:started` and `:deduped`, records the question; on `:started`
  only, schedules an operator timeout (JSI-T009).
```

## 5. Verification

```bash
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/agents/operator_question_dispatcher_test.exs test/foreman_server/agents/operator_question_flow_test.exs test/foreman_server_web/controllers/webhook_controller_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
```

Success = 17 tests pass in the dispatcher file (15 existing + 2 new), the other two files
stay green, and `mix format --check-formatted` exits 0. If time allows, finish with the full
suite: `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors'`.

Documentation gate: no externally visible identifier is added, removed or renamed (no new
command type, route, MCP tool, CLI verb, env var or config key — `question.open` and
`OperatorQuestionDispatcher.dispatch/1` already exist). `CLAUDE.md:1164` and
`docs/user-guide.md:3425` describe `question.open` as idempotent and the question as
listed/answerable/expirable, which is what this change makes true; `README.md` and
`docs/cli-reference.md` have no hits. **No documentation file needs editing.**

## 6. Out of scope

- `lib/foreman_server/inbox/shared_inbox.ex`, `inbox/dedupe_table.ex`, the dedupe window —
  the dedupe behaviour is correct.
- `lib/foreman_server/agents/operator_timeout.ex`, `approvals/sweeper.ex`,
  `approvals/timeout_policy.ex`.
- Do not make `record_question/4` raise or return a typed error, and do not retry
  `Dispatch.system/1` inside it — the retry is the next deduped ingest.
- No new command type, event, route, MCP tool or CLI verb; do not widen
  `Approvals.Dispatch.command_types/0`.
- Do not restructure `resolve_operator_timeout/1` or the `non_empty/1` key lookups.
- Do not edit `AGENTS.md`; no change note in `docs/PRD/*` or `docs/TRD/*`.
