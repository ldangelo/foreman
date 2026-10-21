defmodule ForemanServer.Approvals.Deliverer do
  @moduledoc """
  Delivers an operator's tool-call decision to the agent that asked, and finishes
  the call.

  Subscribes to `ForemanServer.ProjectionStore` (no replay: a restart must not
  re-deliver history) and reacts to exactly `ToolCallApproved` and
  `ToolCallDenied`. How the decision reaches the agent is the request's recorded
  `delivery` (`ForemanServer.Approvals.Capability`):

    * `"live"` - `ForemanServer.Approvals.Live.respond/4` answers the provider
      session (`Session.respond_approval/3`). No registered session is a failed
      delivery, not a silent success.
    * `"resume_with_override"` - the decision is queued as an E6 steering message
      on the paused run (`run.steer`): an approval carries the one-phase
      `approval_mode_override` for the approved tool (`Capability.override_for/1`)
      and tells the agent to retry; a denial tells it not to use the tool. The run
      is then resumed if it is still paused.

  After an approval is delivered the call is finished (`tool.finish`,
  `outcome: "delivered"`); if delivery failed it is finished with
  `outcome: "delivery_failed: <reason>"`, so a call never sticks in `approved`
  forever and the Overview shows `:approval_delivery_failed`. A denied call is
  already terminal: a failed denial delivery is logged at `:error`.

  Every command goes through `ForemanServer.Approvals.Dispatch`, a closed list.
  """

  use GenServer

  require Logger

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.{Capability, Dispatch, Live}
  alias ForemanServer.ProjectionStore

  @decision_events %{"ToolCallApproved" => :approve, "ToolCallDenied" => :deny}

  @doc "Start the deliverer. Options: `:name`, `:gateway`, `:live` (Live server), `:session_module`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    case ProjectionStore.subscribe(replay_existing: false) do
      :ok -> {:ok, %{opts: opts}, {:continue, :recover}}
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    recover(state.opts)
    {:noreply, state}
  end

  @impl true
  def handle_info({:projection_event, event}, state) when is_map(event) do
    with decision when decision in [:approve, :deny] <- decision(event_type(event)),
         %{run_id: run_id, tool_call_id: id} when is_binary(run_id) and is_binary(id) <-
           ids(event) do
      deliver(decision, run_id, id, state.opts)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Re-deliver decisions that may have been lost while the server was down: every
  `approved` call that was never settled, and every `denied` call whose run is
  still paused. The subscription stays non-replaying; this reads the projection
  once. Safe to repeat: the steer, resume and finish commands have deterministic
  ids, so a decision that did arrive is a no-op. Returns the number attempted.
  """
  @spec recover(keyword()) :: non_neg_integer()
  def recover(opts \\ []) do
    calls =
      Enum.filter(ProjectionStore.undelivered_tool_calls(), fn
        %{status: "approved"} ->
          true

        %{status: "denied", run_id: run_id} ->
          match?(%{status: "paused"}, ProjectionStore.run(run_id))
      end)

    for %{status: status} = call <- calls do
      decision = if status == "approved", do: :approve, else: :deny
      deliver(decision, call.run_id, call.tool_call_id, opts)
    end

    length(calls)
  end

  @doc """
  Deliver one decision (public so tests and recovery can drive it without a
  subscription). Returns `:delivered` or `{:failed, reason}`.
  """
  @spec deliver(:approve | :deny, String.t(), String.t(), keyword()) ::
          :delivered | {:failed, term()}
  def deliver(decision, run_id, tool_call_id, opts \\ []) do
    gateway = Keyword.get(opts, :gateway, ForemanServer.CommandGateway)

    case ProjectionStore.tool_call(run_id, tool_call_id) do
      nil ->
        Logger.error("approvals: decision for unknown tool call #{run_id}/#{tool_call_id}")
        {:failed, :unknown_tool_call}

      call ->
        result =
          apply_decision(Capability.parse_delivery(call.delivery), decision, call, opts, gateway)

        settle(decision, call, result, gateway)
        result_tuple(result)
    end
  end

  defp apply_decision(:live, decision, call, opts, _gateway) do
    live_opts = Keyword.take(opts, [:session_module]) ++ live_server(opts)
    Live.respond(call.run_id, call.tool_call_id, decision, live_opts)
  end

  defp apply_decision(:resume_with_override, decision, call, _opts, gateway) do
    if ProjectionStore.run(call.run_id) do
      steer_and_resume(decision, call, gateway)
    else
      {:error, :unsupported_subject}
    end
  end

  defp live_server(opts) do
    case Keyword.fetch(opts, :live) do
      {:ok, server} -> [server: server]
      :error -> []
    end
  end

  defp steer_and_resume(decision, call, gateway) do
    payload =
      %{
        run_id: call.run_id,
        message_id: "approval:" <> call.tool_call_id,
        text: steer_text(decision, call),
        steered_by: "approvals",
        resume: true
      }
      |> put_override(decision, call.tool_name)

    steer = %{
      type: "run.steer",
      command_id: "approval-steer:#{call.run_id}:#{call.tool_call_id}",
      aggregate_id: "run:" <> call.run_id,
      payload: payload
    }

    with {:ok, _} <- unwrap(Dispatch.system(steer, gateway)) do
      resume_if_paused(call, gateway)
    end
  end

  # The dispatcher resumes a run it paused itself for a steer; a run already paused
  # (awaiting this very decision) is left paused by it, so resume it here.
  defp resume_if_paused(call, gateway) do
    case ProjectionStore.run(call.run_id) do
      %{status: "paused"} ->
        resume = %{
          type: "run.resume",
          command_id: "approval-resume:#{call.run_id}:#{call.tool_call_id}",
          aggregate_id: "run:" <> call.run_id,
          payload: %{run_id: call.run_id, reason: "approval_decided"}
        }

        with {:ok, _} <- unwrap(Dispatch.system(resume, gateway)), do: :ok

      _running_or_gone ->
        :ok
    end
  end

  defp put_override(payload, :approve, tool_name),
    do: Map.put(payload, :approval_mode_override, Capability.override_for(tool_name))

  defp put_override(payload, :deny, _tool_name), do: payload

  defp steer_text(:approve, %{tool_name: tool}),
    do:
      "The operator approved your use of the `#{tool}` tool. Retry what you were blocked on and continue."

  defp steer_text(:deny, %{tool_name: tool, reason: "timeout"}),
    do:
      "Nobody answered the request to use the `#{tool}` tool in time, so it was denied. Do not use it; continue without it, or say plainly what you cannot do."

  defp steer_text(:deny, %{tool_name: tool}),
    do:
      "The operator denied permission to use the `#{tool}` tool. Do not use it; continue without it, or say plainly what you cannot do."

  # An approved call is always finished (delivered or not); a denied call is
  # already terminal, so only a failure is reported.
  defp settle(:approve, call, result, gateway) do
    outcome =
      case result do
        :ok -> "delivered"
        {:error, reason} -> "delivery_failed: " <> inspect(reason)
      end

    finish = %{
      type: "tool.finish",
      command_id: "approval-finish:#{call.run_id}:#{call.tool_call_id}",
      aggregate_id: ToolCall.stream_id(call.run_id, call.tool_call_id),
      payload: %{
        run_id: call.run_id,
        tool_call_id: call.tool_call_id,
        tool_name: call.tool_name,
        outcome: outcome
      }
    }

    case Dispatch.system(finish, gateway) do
      {:ok, _} ->
        :ok

      # A recovery re-delivery of a call that was already finished.
      {:error, {:tool_call_terminal, _status}} ->
        :ok

      other ->
        Logger.error(
          "approvals: could not finish #{call.run_id}/#{call.tool_call_id}: #{inspect(other)}"
        )
    end
  end

  defp settle(:deny, call, {:error, reason}, _gateway) do
    Logger.error(
      "approvals: denial of #{call.run_id}/#{call.tool_call_id} was not delivered: #{inspect(reason)}"
    )
  end

  defp settle(:deny, _call, :ok, _gateway), do: :ok

  defp result_tuple(:ok), do: :delivered
  defp result_tuple({:error, reason}), do: {:failed, reason}

  defp unwrap({:ok, _} = ok), do: ok
  defp unwrap({:error, reason}), do: {:error, reason}
  defp unwrap({:error, reason, _detail}), do: {:error, reason}

  defp decision(type), do: Map.get(@decision_events, type)

  defp event_type(event) do
    case Map.fetch(event, :event_type) do
      {:ok, type} -> type
      :error -> Map.get(event, "event_type")
    end
  end

  defp ids(event) do
    data = Map.get(event, :data) || Map.get(event, "data") || Map.get(event, :payload) || %{}
    data = if is_struct(data), do: Map.from_struct(data), else: data

    %{
      run_id: Map.get(data, :run_id) || Map.get(data, "run_id"),
      tool_call_id: Map.get(data, :tool_call_id) || Map.get(data, "tool_call_id")
    }
  end
end
