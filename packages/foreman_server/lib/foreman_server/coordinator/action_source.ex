defmodule ForemanServer.Coordinator.ActionSource do
  @moduledoc """
  Parses a coordinator agent's reply text into a `Coordinator.Turn` (spike S1,
  outcome A: structured JSON actions parsed by Foreman).

  The LAST fenced `json` block is the contract:

      {"reply": "text for the operator", "actions": [ {"kind": "...", ...} ]}

  Strict by design: a missing block, invalid JSON, a top-level value that is not
  an object with exactly `reply` (non-blank string) and optionally `actions`
  (a list of objects) is `{:error, %Error{code: :malformed_output}}` and
  executes nothing. Whether each action is a KNOWN, well-formed action is not
  decided here: `Coordinator.Action.normalize/3` does that per action, so a bad
  action is recorded as rejected without failing the whole turn.
  """

  alias ForemanServer.Coordinator.{Error, Turn}

  @json_block ~r/```json[ \t]*\r?\n(.*?)\r?\n[ \t]*```/s
  @allowed_keys ["reply", "actions"]

  @spec parse(String.t()) :: {:ok, Turn.t()} | {:error, Error.t()}
  def parse(text) when is_binary(text) do
    with {:ok, json} <- last_block(text),
         {:ok, decoded} <- decode(json),
         {:ok, reply} <- reply(decoded),
         {:ok, actions} <- actions(decoded) do
      {:ok, %Turn{reply: reply, actions: actions}}
    end
  end

  def parse(_other), do: malformed("agent produced no text")

  defp last_block(text) do
    case Regex.scan(@json_block, text) do
      [] -> malformed("no fenced json block in the reply")
      matches -> {:ok, matches |> List.last() |> Enum.at(1)}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} ->
        {:ok, map}

      {:ok, _other} ->
        malformed("the json block is not an object")

      {:error, error} ->
        malformed("the json block is not valid JSON", %{reason: Exception.message(error)})
    end
  end

  defp reply(%{} = decoded) do
    with :ok <- known_keys(decoded) do
      case Map.get(decoded, "reply") do
        reply when is_binary(reply) ->
          if String.trim(reply) == "",
            do: malformed("reply is blank"),
            else: {:ok, String.trim(reply)}

        _ ->
          malformed("reply is missing or not a string")
      end
    end
  end

  defp known_keys(decoded) do
    case decoded |> Map.keys() |> Enum.reject(&(&1 in @allowed_keys)) do
      [] ->
        :ok

      extra ->
        malformed("unexpected keys in the json block: " <> Enum.join(Enum.sort(extra), ", "))
    end
  end

  defp actions(decoded) do
    case Map.get(decoded, "actions", []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_map/1),
          do: {:ok, list},
          else: malformed("every action must be a JSON object")

      _ ->
        malformed("actions is not a list")
    end
  end

  defp malformed(message, details \\ %{}),
    do: {:error, Error.new(:malformed_output, message, details)}
end
