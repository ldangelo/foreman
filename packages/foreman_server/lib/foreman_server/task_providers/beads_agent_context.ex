defmodule ForemanServer.TaskProviders.BeadsAgentContext do
  @moduledoc """
  The single decoder for a bead's `agent_context` field.

  `br` 0.6.0 emits `agent_context` as a JSON-ENCODED STRING in every output
  (`br create --json`, `br show --json`, `br list --json`, `issues.jsonl`).
  Hand-built or legacy fixtures carry an object. Readers that need the value
  call `decode/1` once and consume the normalized map; they do not match the
  raw field themselves.

  Absent is not malformed (AGENTS.md 5.3): a missing / `nil` / empty-string
  field is `:absent`; a string that is not a JSON object, or any other type, is
  `{:error, :malformed}` so the caller decides how loudly to fail.

  Not every reader is meant to see a string context as a context: see the notes
  at `BeadsWatcher.foreman_tag?/1` and `BeadsOrphanJanitor` before routing them
  through this module.
  """

  @type result :: {:ok, %{optional(String.t()) => term()}} | :absent | {:error, :malformed}

  @spec decode(term()) :: result()
  def decode(nil), do: :absent
  def decode(""), do: :absent
  def decode(%{} = context), do: {:ok, context}

  def decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = context} -> {:ok, context}
      _not_a_json_object -> {:error, :malformed}
    end
  end

  def decode(_other), do: {:error, :malformed}
end
