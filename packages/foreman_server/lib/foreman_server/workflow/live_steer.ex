defmodule ForemanServer.Workflow.LiveSteer do
  @moduledoc """
  Live mid-phase steering (beads foreman-s48kc, foreman-b3jtt; design in
  `docs/plans/live-steering.md`).

  A phase whose provider supports streaming input (`:claude`, `:pi`) is launched
  with the harness `live_input` provider option. A steer queued while that phase
  runs is then written into the running agent session (`deliver/2`) instead of
  pausing the run: the provider queues it and takes it at its next safe point,
  inside the same session. Everything else (other providers, no running agent,
  a session that already closed its input) keeps the pause -> resume path, which
  the caller selects on any `{:error, _}` from `deliver/2`.

  Delivery state is recorded on the run stream: `RunSteerDelivered` when written,
  `RunSteerConsumed` (`delivery: "live"`) when the agent took it,
  `RunSteerUndelivered` when the run ended first (`undeliver_pending/2`).
  """
  require Logger

  alias ForemanServer.{CommandGateway, ProjectionStore, RunControl}
  alias Jido.Harness.{Event, Run}

  @live_providers [:claude, :pi]
  @heading "## Operator message received while you were working\n\n"

  @doc "True when phases of `provider` are launched with streaming input."
  @spec enabled?(atom()) :: boolean()
  def enabled?(provider) when is_atom(provider) do
    provider in @live_providers and
      Application.get_env(:foreman_server, :live_steering, [])[:enabled] == true
  end

  @doc "Adds the harness `live_input` provider option to `driver_opts` when `provider` supports it."
  @spec put_driver_opts(keyword(), atom()) :: keyword()
  def put_driver_opts(driver_opts, provider) do
    if enabled?(provider) do
      Keyword.update(
        driver_opts,
        :provider_options,
        %{live_input: true},
        &Map.put(&1, :live_input, true)
      )
    else
      driver_opts
    end
  end

  @doc "True when `driver_opts` launch a live-input phase."
  @spec live?(keyword()) :: boolean()
  def live?(driver_opts),
    do: match?(%{live_input: true}, Keyword.get(driver_opts, :provider_options))

  @doc """
  Writes a pending steer message into `run_id`'s running agent session.

  `:ok` means the line was written and `RunSteerDelivered` recorded (not that the
  agent took it). `{:error, reason}` means nothing was delivered live (`:no_agent`,
  `:not_live`, `:input_closed`, `:not_running`, `:not_found`, `{:write_failed, _}`...).
  """
  @spec deliver(String.t(), %{message_id: String.t(), text: String.t()}) :: :ok | {:error, term()}
  def deliver(run_id, %{message_id: message_id, text: text}) do
    with {:ok, harness_run_id} <- RunControl.agent_run_id(run_id),
         :ok <- Run.send_input(harness_run_id, message_id, @heading <> text) do
      record_delivered(run_id, message_id)
    end
  end

  defp record_delivered(run_id, message_id) do
    case CommandGateway.dispatch_system(%{
           type: "run.steer.deliver",
           command_id: "live-steer:deliver:#{run_id}:#{message_id}",
           aggregate_id: "run:#{run_id}",
           payload: %{run_id: run_id, message_id: message_id, mode: "live"}
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # Written to the agent but not recorded: the consumed event still retires it.
        Logger.warning("LiveSteer #{run_id}: RunSteerDelivered not recorded: #{inspect(reason)}",
          run_id: run_id,
          operation: "live_steer.deliver"
        )

        :ok
    end
  end

  @doc """
  Follows a live harness run and records `RunSteerConsumed` the moment the
  provider takes a delivered message. Ends with the harness run.
  """
  @spec watch(String.t(), String.t()) :: {:ok, pid()}
  def watch(run_id, harness_run_id) do
    Task.start(fn ->
      case Run.stream(harness_run_id) do
        {:ok, stream} -> Enum.each(stream, &handle_event(run_id, &1))
        {:error, _reason} -> :ok
      end
    end)
  end

  defp handle_event(run_id, %Event{type: :input_accepted, payload: %{"input_id" => id}})
       when is_binary(id),
       do: consume(run_id, [id])

  defp handle_event(_run_id, _event), do: :ok

  @doc """
  Records `RunSteerConsumed` for every `:input_accepted` event of a finished harness
  run. Idempotent with `watch/2`; guarantees a consumption is recorded even if the
  watcher died.
  """
  @spec reconcile(String.t(), [Event.t()]) :: :ok
  def reconcile(run_id, events) do
    ids =
      for %Event{type: :input_accepted, payload: %{"input_id" => id}} <- events,
          is_binary(id),
          do: id

    if ids != [], do: consume(run_id, ids)
    :ok
  end

  defp consume(run_id, ids) do
    case CommandGateway.dispatch_system(%{
           type: "run.steer.consume",
           command_id: "live-steer:consume:#{run_id}:#{:erlang.phash2(ids)}",
           aggregate_id: "run:#{run_id}",
           payload: %{run_id: run_id, message_ids: ids, delivery: "live"}
         }) do
      {:ok, _} ->
        RunControl.drain_messages(run_id, ids)
        :ok

      {:error, reason} ->
        Logger.warning("LiveSteer #{run_id}: consume not recorded: #{inspect(reason)}",
          run_id: run_id,
          operation: "live_steer.consume"
        )
    end
  end

  @doc """
  Records `RunSteerUndelivered` (`reason`) for every steer still pending on a run
  that just went terminal, so a message the agent never took is never silent.
  """
  @spec undeliver_pending(String.t(), String.t()) :: :ok
  def undeliver_pending(run_id, reason) do
    case Enum.map(ProjectionStore.pending_steering(run_id), & &1.message_id) do
      [] ->
        :ok

      ids ->
        _ =
          CommandGateway.dispatch_system(%{
            type: "run.steer.undeliver",
            command_id: "live-steer:undeliver:#{run_id}:#{:erlang.phash2(ids)}",
            aggregate_id: "run:#{run_id}",
            payload: %{run_id: run_id, message_ids: ids, reason: reason}
          })

        RunControl.drain_messages(run_id, ids)
        :ok
    end
  end
end
