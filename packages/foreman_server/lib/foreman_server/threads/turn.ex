defmodule ForemanServer.Threads.Turn do
  @moduledoc """
  One structured transcript turn of a thread (see `ForemanServer.Threads.Transcript`).

    * `seq` - stable 0-based ordinal over the merged, time-ordered turn list.
    * `role` - who produced it: `:agent`, `:operator` or `:system`.
    * `kind` - `:text` (agent output), `:steer` (operator steering message),
      `:status` (run/jobsite lifecycle) or `:verdict` (recorded review).
    * `text` - already-redacted turn body.
    * `at` - unix milliseconds, or `nil` when the source persisted no timestamp
      (jobsite iteration tails carry none).
    * `source` - where the turn came from: `"stdout"`, `"stderr"`, `"steer"`,
      `"run_event"`, `"review"`, `"jobsite_iteration"`, `"jobsite_output"`.
  """

  @enforce_keys [:seq, :role, :kind, :text, :source]
  defstruct [:seq, :role, :kind, :text, :at, :source]

  @type role :: :agent | :operator | :system
  @type kind :: :text | :steer | :status | :verdict
  @type t :: %__MODULE__{
          seq: non_neg_integer(),
          role: role(),
          kind: kind(),
          text: String.t(),
          at: integer() | nil,
          source: String.t()
        }

  @doc "Whitelisted string-keyed JSON shape shared by HTTP, SSE and MCP."
  @spec to_dto(t()) :: %{String.t() => term()}
  def to_dto(%__MODULE__{} = turn) do
    %{
      "seq" => turn.seq,
      "role" => Atom.to_string(turn.role),
      "kind" => Atom.to_string(turn.kind),
      "text" => turn.text,
      "at" => at_iso(turn.at),
      "source" => turn.source
    }
  end

  defp at_iso(nil), do: nil

  defp at_iso(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
