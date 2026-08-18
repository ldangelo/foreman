defmodule ForemanServer.JidoSignal.Topics do
  @moduledoc """
  Jido Signal topic configuration for Foreman.

  Defines the standard topics used for inter-agent and operator communication.
  These topic names are used when publishing signals via Jido.Signal.Bus.
  """

  @doc "Topic for agent command signals."
  @spec commands_topic() :: binary()
  def commands_topic, do: "foreman/commands"

  @doc "Topic for operator communication signals."
  @spec operator_topic() :: binary()
  def operator_topic, do: "foreman/operator"

  @doc "Topic for Foreman inbox messages."
  @spec inbox_topic() :: binary()
  def inbox_topic, do: "foreman/inbox"

  @doc "Topic for agent directive signals (per-agent)."
  @spec agent_directive_topic(agent_id :: binary()) :: binary()
  def agent_directive_topic(agent_id) when is_binary(agent_id) do
    "agents/#{agent_id}/directive"
  end

  @doc "Returns all standard Foreman signal topics."
  @spec all_topics() :: [binary()]
  def all_topics do
    [
      commands_topic(),
      operator_topic(),
      inbox_topic()
    ]
  end
end
