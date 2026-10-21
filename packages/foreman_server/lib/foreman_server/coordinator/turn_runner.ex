defmodule ForemanServer.Coordinator.TurnRunner do
  @moduledoc """
  One coordinator turn: context -> agent -> reply -> actions -> complete.

  Crash safety comes from the event log, not from process state:

    * `turn.start` is a deterministic command (`turn_id` = first trigger message
      id + attempt) and the aggregate rejects a second open turn;
    * a turn found open (the server stopped mid-turn) is closed with
      `turn.fail` code `interrupted` and re-run as the next attempt;
    * the reply message id is `reply:<trigger message id>`, so a re-run never
      shows the operator two replies, and action ids are hashes of the trigger
      and action content, so a re-run issues byte-identical commands that
      `CommandRouter` deduplicates. A thread is never created twice.

  `run/2` returns `:idle` (nothing pending, or unhealthy), `:ok` (a turn
  completed) or `{:failed, code}`.
  """

  require Logger

  alias ForemanServer.Coordinator.{
    Action,
    Authority,
    Commands,
    Context,
    Conversation,
    Error,
    Executor,
    Runtime,
    Tuning,
    Turn
  }

  alias ForemanServer.AgentRuntime.JidoHarness
  alias ForemanServer.ProjectionStore

  @spec run(String.t(), Runtime.t()) :: :idle | :ok | {:failed, atom()}
  def run(project_id, %Runtime{} = rt) do
    case ProjectionStore.coordinator_state(project_id) do
      {:error, :project_not_found} ->
        :idle

      {:ok, conv} ->
        cond do
          Conversation.status(conv) == :unhealthy -> :idle
          is_map(conv.open_turn) -> recover_interrupted(project_id, rt, conv)
          true -> start_turn(project_id, rt, conv)
        end
    end
  end

  @doc "Close the open turn as failed (used for hard timeouts and crash recovery)."
  @spec fail_open_turn(String.t(), Runtime.t(), atom(), String.t()) :: :ok
  def fail_open_turn(project_id, %Runtime{} = rt, code, message) do
    with {:ok, %{open_turn: %{turn_id: turn_id, attempt: attempt}}} <-
           ProjectionStore.coordinator_state(project_id) do
      fail_turn(project_id, rt, turn_id, attempt, code, message)
    end

    :ok
  end

  defp recover_interrupted(project_id, rt, %{open_turn: %{turn_id: turn_id, attempt: attempt}}) do
    fail_turn(
      project_id,
      rt,
      turn_id,
      attempt,
      :interrupted,
      "the coordinator was interrupted mid-turn"
    )

    run(project_id, rt)
  end

  defp start_turn(project_id, rt, conv) do
    case Conversation.pending(conv) do
      [] -> :idle
      pending -> do_turn(project_id, rt, conv, pending)
    end
  end

  defp do_turn(project_id, rt, conv, [first | _] = pending) do
    trigger_key = first.message_id
    attempt = attempts_for(conv, trigger_key) + 1
    turn_id = "#{trigger_key}:a#{attempt}"
    trigger_ids = Enum.map(pending, & &1.message_id)

    case Commands.turn_start(rt.gateway, project_id, turn_id, attempt, trigger_ids) do
      {:ok, _} ->
        execute(project_id, rt, conv, pending, turn_id, attempt)

      {:error, :coordinator_unhealthy} ->
        :idle

      other ->
        Logger.warning("coordinator #{project_id}: turn.start failed: #{inspect(other)}")
        {:failed, :turn_start_failed}
    end
  end

  defp attempts_for(conv, trigger_key) do
    Enum.count(conv.turns, fn {_id, turn} ->
      List.first(turn.trigger_message_ids) == trigger_key
    end)
  end

  defp execute(project_id, rt, conv, [first | _] = pending, turn_id, attempt) do
    with {:ok, context} <- build_context(project_id, rt, pending),
         {:ok, %Turn{} = turn} <- call_agent(project_id, rt, context) do
      complete(project_id, rt, conv, pending, first, turn_id, turn)
    else
      {:error, %Error{} = error} ->
        fail_turn(project_id, rt, turn_id, attempt, error.code, error.message)
        {:failed, error.code}
    end
  end

  defp build_context(project_id, rt, pending) do
    Context.build(project_id, sources: rt.sources, trigger_messages: pending)
  end

  defp call_agent(project_id, rt, context) do
    opts = Keyword.merge(agent_settings(project_id, rt), rt.agent_opts)

    try do
      case rt.agent.turn(context, opts) do
        {:ok, %Turn{}} = ok -> ok
        {:error, %Error{}} = error -> error
        other -> {:error, Error.new(:agent_failed, "agent returned #{inspect(other, limit: 5)}")}
      end
    rescue
      exception ->
        {:error, Error.new(:agent_failed, "agent raised: " <> Exception.message(exception))}
    catch
      kind, reason ->
        {:error, Error.new(:agent_failed, "agent #{kind}: #{inspect(reason, limit: 5)}")}
    end
  end

  # Provider, model and effort come from the project's E1 settings, falling
  # back to the configured defaults (pi + MiniMax: the verified provider path).
  defp agent_settings(project_id, rt) do
    settings = ProjectionStore.project_settings(project_id)

    [
      project_id: project_id,
      provider: provider(settings && settings.coordinator_provider, rt.default_provider),
      model: (settings && settings.coordinator_model) || rt.default_model,
      effort: (settings && settings.coordinator_effort) || rt.default_effort,
      timeout_ms: rt.agent_timeout_ms
    ]
  end

  defp provider(nil, default), do: default

  defp provider(name, default),
    do: Enum.find(JidoHarness.providers(), default, &(Atom.to_string(&1) == name))

  defp complete(project_id, rt, conv, pending, first, turn_id, %Turn{} = turn) do
    trigger_key = first.message_id
    authority = Authority.of(pending)

    # Persist the reply before dispatching any action: a crash later still
    # leaves the operator an answer, and the id is stable across attempts.
    Commands.append(rt.gateway, project_id, "reply:" <> trigger_key, %{
      role: "coordinator",
      kind: "reply",
      text: turn.reply,
      turn_id: turn_id
    })

    items = Enum.map(turn.actions, &normalize(&1, project_id, trigger_key))

    ctx = %Executor.Ctx{
      project_id: project_id,
      turn_id: turn_id,
      trigger_key: trigger_key,
      authority: authority,
      operator_texts: for(m <- pending, Authority.operator_authored?(m), do: m.text),
      tuning: Tuning.read(project_id),
      workflows: Enum.map(rt.sources.workflows(), & &1.name),
      recorded: conv.actions,
      gateway: rt.gateway,
      threads: rt.threads,
      thread_actions: rt.thread_actions,
      max_actions: rt.max_actions,
      max_threads_per_turn: rt.max_threads_per_turn
    }

    outcomes = Executor.run(items, ctx)

    if notice = Executor.notice(outcomes) do
      Commands.append(rt.gateway, project_id, "notice:" <> trigger_key, %{
        role: "system",
        kind: "notice",
        text: notice,
        turn_id: turn_id
      })
    end

    cursor = pending |> List.last() |> Map.fetch!(:message_id)
    Commands.turn_complete(rt.gateway, project_id, turn_id, cursor, summarize(outcomes))
    :ok
  end

  defp normalize(raw, project_id, trigger_key) do
    case Action.normalize(raw, project_id, trigger_key) do
      {:ok, %Action{} = action} -> {:ok, action}
      {:error, {:invalid_action, reason}} -> {:invalid, raw, reason}
    end
  end

  defp summarize(outcomes) do
    counts = Enum.frequencies_by(outcomes, & &1.status)

    "actions=#{length(outcomes)} " <>
      Enum.map_join(Enum.sort(counts), " ", fn {status, n} -> "#{status}=#{n}" end)
  end

  defp fail_turn(project_id, rt, turn_id, attempt, code, message) do
    Commands.turn_fail(
      rt.gateway,
      project_id,
      turn_id,
      attempt,
      code,
      message,
      rt.unhealthy_after
    )

    with {:ok, %{status: :unhealthy, last_error: error}} <-
           ProjectionStore.coordinator_status(project_id) do
      Commands.append(rt.gateway, project_id, "unhealthy:" <> turn_id, %{
        role: "system",
        kind: "notice",
        text:
          "The coordinator has not responded - last error: #{error && error.message}. " <>
            "It will not retry until restarted (foreman project chat #{project_id} --restart).",
        turn_id: turn_id
      })
    end

    :ok
  end
end
