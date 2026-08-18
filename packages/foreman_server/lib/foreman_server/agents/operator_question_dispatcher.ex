defmodule ForemanServer.Agents.OperatorQuestionDispatcher do
  @moduledoc """
  Foreman-side dispatcher that converts a `com.foreman.operator.*`
  CloudEvent into the Foreman inbox pipeline (TRD-2026-4212be7e,
  JSI-T007 — paired with JSI-T006's subscriber).

  ## Current state

  JSI-T006 ships the bus subscriber (`OperatorQuestionSubscriber`)
  that this module is invoked from. JSI-T007's full inbox-API
  conversion lands in the next session; for now the dispatcher is
  a no-op that returns `:ok` so the bus delivery path is observable
  end-to-end without booting the inbox pipeline.

  The signature is stable: `dispatch/1` is the single entry point
  JSI-T006 calls for every incoming signal. When JSI-T007 lands,
  the body of `dispatch/1` will translate the signal's data into
  the Foreman inbox shape (`ForemanServer.Inbox.SharedInbox.ingest/1`)
  and trigger the projector's downstream.

  See also: `ForemanServer.Agents.JidoSignalTopics.foreman_operator/0`
  (topic name source of truth), `OperatorQuestionSubscriber`
  (JSI-T006 bus consumer).
  """

  require Logger

  @doc """
  Dispatch a single `com.foreman.operator.*` CloudEvent.

  JSI-T007 will fill in the inbox-API conversion. For now this
  is a no-op that logs the signal type and returns `:ok`.
  """
  @spec dispatch(struct()) :: :ok
  def dispatch(%Jido.Signal{type: type, data: data}) do
    Logger.debug("OperatorQuestionDispatcher received signal: type=#{inspect(type)} data=#{inspect(data)}")
    :ok
  end

  def dispatch(other) do
    Logger.warning(
      "OperatorQuestionDispatcher: ignoring non-Jido.Signal payload: #{inspect(other)}"
    )

    :ok
  end
end
