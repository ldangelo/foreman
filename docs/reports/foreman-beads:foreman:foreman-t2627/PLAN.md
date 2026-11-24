# PLAN — foreman-t2627: Questions.Deliverer never retries a failed steer/resume while the server is up

## 1. Verdict

**Real bug**, present on this tree (HEAD `018da6b1`).

Evidence, `packages/foreman_server/lib/foreman_server/questions/deliverer.ex`:

- line 65 (`handle_info({:projection_event, event}, state)`): `_ = deliver(run_id, id, text, answered_by(event), state.opts)` — the outcome (`:delivered | {:failed, reason} | {:undeliverable, _}`) is discarded.
- lines 54-58: `handle_continue(:recover, state)` is the only caller of `recover/1` in the process; `init/1` (line 49) returns `{:continue, :recover}`. No `Process.send_after/3` anywhere in the module.
- `deliver/5` (around line 145) returns `{:failed, reason}` for a refused `run.steer`/`run.resume` and only logs it.

So a transient gateway/aggregate failure leaves the `QuestionAnswered` event recorded, no steer queued, and the paused run waiting until the next server start. Existing tests encode the current (no-retry) behaviour only (`test/foreman_server/questions/deliverer_test.exs:509`, `:523`).

## 2. Root cause

`ForemanServer.Questions.Deliverer` has no in-process retry: the only re-delivery path (`recover/1`) is triggered by `handle_continue(:recover, _)` at boot. A `{:failed, _}` outcome from the live event path (and from the boot pass itself) is dropped, so nothing ever schedules another attempt.

Fix: when a delivery pass yields any `{:failed, _}`, schedule another `recover/1` pass on a bounded backoff with `Process.send_after/3`, as `ForemanServer.PrReport.Publisher` does for its start-up scan (`lib/foreman_server/pr_report/publisher.ex:395-412`). Safe to repeat: command ids are deterministic (`question-steer:<run>:<question>`, `question-resume:<run>:<question>`) and the resume is gated by `paused?/1` + `steer_pending?/2`.

## 3. Failing check first

Add two tests to `packages/foreman_server/test/foreman_server/questions/deliverer_test.exs`, in the existing `describe "a delivery fails" do` block (starts line 508), plus one gateway module after `DiesBeforeResumeGateway` (ends around line 105):

```elixir
  # The real gateway, except that the FIRST `run.steer` is refused: a transient failure the
  # deliverer must retry without a restart.
  defmodule FlakySteerGateway do
    @moduledoc false
    def dispatch_system(%{type: "run.steer"} = command) do
      if Agent.get_and_update(:questions_deliverer_test_flaky, &{&1, true}),
        do: ForemanServer.CommandGateway.dispatch_system(command),
        else: {:error, :steer_refused}
    end

    def dispatch_system(command), do: ForemanServer.CommandGateway.dispatch_system(command)
  end
```

```elixir
    test "a transient steer failure is retried while the server is up" do
      start_supervised!(%{
        id: :questions_deliverer_test_flaky,
        start: {Agent, :start_link, [fn -> false end, [name: :questions_deliverer_test_flaky]]}
      })

      {project_id, run_id} = start_run!()
      pause!(run_id)
      question_id = open_question!(run_id, project_id)
      start_deliverer!(gateway: FlakySteerGateway, retry_delays_ms: [10])

      capture_log(fn ->
        answer!(run_id, question_id, "use postgres")
        steer = await("RunSteerQueued", run_id)
        assert field(steer, :message_id) == "question:" <> question_id
        await("RunResumed", run_id, &(field(&1, :reason) == "question_answered"))
      end)

      assert [_once] = run_events(run_id, "RunSteerQueued")
    end

    test "the retries are bounded and the last one says so" do
      {project_id, run_id} = start_run!()
      pause!(run_id)
      question_id = open_question!(run_id, project_id)
      deliverer = start_deliverer!(gateway: SteerRefusingGateway, retry_delays_ms: [5, 5])

      log =
        capture_log(fn ->
          answer!(run_id, question_id, "use postgres")

          # One live attempt plus two retries, then nothing more.
          Eventually.await(fn -> length(dispatched_steers()) == 3 end,
            message: "the steer was not attempted once and retried twice"
          )

          _ = :sys.get_state(deliverer)
        end)

      assert log =~ "questions: answer delivery still failing after 2 retries"
      Process.sleep(50)
      assert length(dispatched_steers()) == 3
    end

  # Every `run.steer` the recording gateways have reported to this process so far.
  defp dispatched_steers do
    {:messages, messages} = Process.info(self(), :messages)
    for {:dispatched, %{type: "run.steer"} = command} <- messages, do: command
  end
```

(`dispatched_steers/0` goes with the other helpers, after `defp run_events/2`, line 968.)

Command that shows both failing before the fix (missing retry):

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test test/foreman_server/questions/deliverer_test.exs'
```

If `mix` stops on dependencies, run `MIX_ENV=test mix deps.get` in `packages/foreman_server` first (devbox, same shell form).

## 4. Edits

All in `packages/foreman_server/lib/foreman_server/questions/deliverer.ex`.

1. **Moduledoc** (before the closing `"""`, after the `answer too long` paragraph, around line 28) — add:

```
  A `{:failed, reason}` delivery (a refused `run.steer` or `run.resume`) is retried in process on
  a bounded backoff (`@retry_delays_ms`, overridable with the `:retry_delays_ms` option): each
  retry is one `recover/1` pass, which is idempotent through the deterministic command ids and
  the `paused?`/`steer_pending?` gates. After the last delay the failure is logged once and left
  to the next start. A failed bus reply (a question of no run) is not re-published by `recover/1`,
  so its pass simply finds nothing.
```

2. **Attribute** — after `alias ForemanServer.ProjectionStore` (line 38) add:

```elixir
  # Delays before each retry of the recovery pass, oldest first. A transient refusal must not
  # wait for the next boot; an endless retry must not spin either.
  @retry_delays_ms [1_000, 5_000, 30_000, 120_000]
```

3. **`@doc` for `start_link/1`** (line 40) — append the new option:

```elixir
  @doc "Start the deliverer. Options: `:name`, `:gateway`, `:bus` (signal bus, default the supervised one), `:retry_delays_ms` (backoff before each delivery retry, default `#{inspect(@retry_delays_ms)}`)."
```

4. **`init/1`** (line 49) — carry the retry timer in the state:

```elixir
      :ok -> {:ok, %{opts: opts, retry_ref: nil, retry_attempt: 0}, {:continue, :recover}}
```

5. **`handle_continue(:recover, state)`** (lines 54-58) — replace the body with:

```elixir
  @impl true
  def handle_continue(:recover, state) do
    {:noreply, arm_retry(state, recover_outcomes(state.opts))}
  end
```

6. **`handle_info({:projection_event, event}, state)`** (lines 60-73) — replace with:

```elixir
  @impl true
  def handle_info({:projection_event, event}, state) when is_map(event) do
    if event_type(event) == "QuestionAnswered" do
      case data(event) do
        %{run_id: run_id, question_id: id, text: text} when is_binary(text) ->
          outcome = deliver(run_id, id, text, answered_by(event), state.opts)
          {:noreply, arm_retry(state, [outcome])}

        _malformed ->
          Logger.error("questions: malformed QuestionAnswered event dropped")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end
```

7. **New retry clause** — immediately after the clause from edit 6 and BEFORE `def handle_info(_other, state), do: {:noreply, state}` (line 75):

```elixir
  def handle_info({:questions_retry, attempt}, state) do
    state = %{state | retry_ref: nil, retry_attempt: attempt}
    outcomes = recover_outcomes(state.opts)

    state =
      if Enum.any?(outcomes, &match?({:failed, _}, &1)),
        do: schedule_retry(state),
        else: %{state | retry_attempt: 0}

    {:noreply, state}
  end
```

8. **`recover/1`** (lines 88-100) — keep the `@doc`/`@spec` and the return value (the number attempted), split the pass out so the outcomes are visible:

```elixir
  @spec recover(keyword()) :: non_neg_integer()
  def recover(opts \\ []), do: length(recover_outcomes(opts))

  defp recover_outcomes(opts) do
    pending =
      for %{run_id: run_id, question_id: id, undelivered_reason: nil} <-
            ProjectionStore.answered_questions(),
          match?(%{terminal?: false}, ProjectionStore.run(run_id)),
          text = answer_text(run_id, id),
          is_binary(text),
          do: {run_id, id, text}

    for {run_id, id, text} <- pending, do: deliver(run_id, id, text, opts)
  end
```

   Append to that `@doc` after "Returns the number attempted.": `A pass that still fails is retried on a bounded backoff (see the module doc).`

9. **Retry helpers** — add at the end of the module, just before the final `end`:

```elixir
  # Only a failure arms a retry, and only one timer is ever pending: a success must not cancel
  # the timer another answer's failure armed.
  defp arm_retry(%{retry_ref: ref} = state, _outcomes) when is_reference(ref), do: state

  defp arm_retry(state, outcomes) do
    if Enum.any?(outcomes, &match?({:failed, _}, &1)), do: schedule_retry(state), else: state
  end

  defp schedule_retry(%{retry_attempt: attempt} = state) do
    case Enum.at(retry_delays(state.opts), attempt) do
      nil ->
        Logger.error(
          "questions: answer delivery still failing after #{attempt} retries; " <>
            "it is retried again at the next start"
        )

        %{state | retry_ref: nil, retry_attempt: 0}

      delay ->
        ref = Process.send_after(self(), {:questions_retry, attempt + 1}, delay)
        %{state | retry_ref: ref, retry_attempt: attempt + 1}
    end
  end

  defp retry_delays(opts), do: Keyword.get(opts, :retry_delays_ms, @retry_delays_ms)
```

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/questions/deliverer_test.exs test/foreman_server/questions/restart_durability_test.exs test/foreman_server/approvals/deliverer_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format lib/foreman_server/questions/deliverer.ex test/foreman_server/questions/deliverer_test.exs && mix format --check-formatted'
```

Success = all tests pass (the two new ones included), zero warnings, formatter clean. These suites are `async: false` and take >60 s; give the shell an explicit long timeout.

Documentation gate: the only externally visible identifier added is the `:retry_delays_ms` start option (documented in the `start_link/1` `@doc`, edit 3). No route, env var, config key, command type, CLI verb or MCP tool changes. `CLAUDE.md:1164` covers `Questions.Deliverer.recover/1` only for the undeliverable (answer-too-long) path, which is unchanged — no edit needed there, nor in `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`.

## 6. Out of scope

- `ForemanServer.Approvals.Deliverer` (same no-retry shape, different bead).
- The `outcome` type, the `{:undeliverable, _}` / `question.answer.undeliver` path, the answer-length limit.
- Re-publishing bus replies in `recover/1` (no durable delivery marker — deliberate, see its `@doc`).
- `recover/1`'s arity or return value; existing tests assert the attempted count.
- App-env/config for the backoff, telemetry, supervisor restart strategy.
- Any refactor of `data/1`, `answered_by/1`, or the string-vs-atom key handling.

Status updates: neither `foreman_inbox_send` nor `foreman_task_add_comment` is exposed in this phase, so no operator progress notes were sent.
