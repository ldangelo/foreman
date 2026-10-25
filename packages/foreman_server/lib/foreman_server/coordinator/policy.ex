defmodule ForemanServer.Coordinator.Policy do
  @moduledoc """
  What a coordinator turn is allowed to ask for, decided by code, not prompt.

  Authority matrix (`Coordinator.Authority`): an `:operator` turn may use every
  action kind; a `:machine` turn (triggered only by reports, agent-authored or
  MCP-origin messages) may only `answer`, `ask`, `propose_threads`,
  `route_followup` and `remember`. It can neither start work, approve proposals,
  forget memory, change tuning, apply a setup recommendation, add repositories nor
  schedule. This keeps machine-originated input from expanding the work envelope.

  `quote_verified?/2` is the confirmation heuristic for actions that loosen or
  extend the project (`add_repo`, `schedule`, loosening `set_tuning`): the action
  must carry the exact operator words that justify it and those words must
  appear in a trigger message authored by the operator.
  """

  alias ForemanServer.Coordinator.Action

  @machine_kinds [:answer, :ask, :propose_threads, :route_followup, :remember]

  @type ctx :: %{required(:authority) => :operator | :machine, optional(atom()) => term()}

  @doc "Action kinds a `:machine` turn may use."
  @spec machine_kinds() :: [Action.kind()]
  def machine_kinds, do: @machine_kinds

  @spec authorize(Action.t(), ctx()) ::
          :ok | {:error, {:not_permitted, Action.kind(), :machine_turn}}
  def authorize(%Action{kind: kind}, %{authority: :machine}) when kind not in @machine_kinds,
    do: {:error, {:not_permitted, kind, :machine_turn}}

  def authorize(%Action{}, %{authority: _authority}), do: :ok

  @doc "True when `quote` is a non-trivial substring of an operator-authored trigger text."
  @spec quote_verified?(term(), [String.t()]) :: boolean()
  def quote_verified?(quote, operator_texts) when is_binary(quote) and is_list(operator_texts) do
    needle = normalize(quote)

    String.length(needle) >= 3 and
      Enum.any?(operator_texts, fn text -> String.contains?(normalize(text), needle) end)
  end

  def quote_verified?(_quote, _texts), do: false

  defp normalize(text),
    do: text |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
end
