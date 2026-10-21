defmodule ForemanServer.Coordinator.Authority do
  @moduledoc """
  Who a coordinator turn acts for.

  A turn is `:operator` authority only when at least one of the messages that
  triggered it was authored by an operator through a trusted source. Reports
  (review verdicts, PR events), agent-authored messages and messages from a
  source listed in `config :foreman_server, :coordinator, untrusted_sources`
  (default `["mcp"]`: thread agents and other machines can call the MCP tool)
  give `:machine` authority, which cannot expand the project's work envelope
  (`Coordinator.Policy`).
  """

  @default_untrusted ~w(mcp)

  @type t :: :operator | :machine

  @doc "Sources whose messages never carry operator authority."
  @spec untrusted_sources() :: [String.t()]
  def untrusted_sources do
    :foreman_server
    |> Application.get_env(:coordinator, [])
    |> Keyword.get(:untrusted_sources, @default_untrusted)
  end

  @doc "Authority of a turn triggered by `messages`."
  @spec of([map()]) :: t()
  def of(messages) when is_list(messages) do
    if Enum.any?(messages, &operator_authored?/1), do: :operator, else: :machine
  end

  @doc "True when one message carries operator authority."
  @spec operator_authored?(map()) :: boolean()
  def operator_authored?(%{role: "operator", source: source}),
    do: source not in untrusted_sources()

  def operator_authored?(_message), do: false
end
