defmodule ForemanServer.Events.WorkerExited do
  @moduledoc "Emitted when a tracked worker process exits (normal or crash)."

  @enforce_keys [:run_id, :worker_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          worker_id: String.t(),
          reason: term(),
          sequence: non_neg_integer() | nil,
          exited_at: DateTime.t()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :worker_id, :reason, :sequence, :exited_at]

  @spec from_payload(map()) :: t()
  def from_payload(payload) do
    %__MODULE__{
      run_id: require_binary(payload, :run_id),
      worker_id: require_binary(payload, :worker_id),
      reason: get(payload, :reason),
      sequence: get(payload, :sequence),
      exited_at: get_dt(payload, :exited_at)
    }
  end

  # --- Private helpers --------------------------------------------------------

  defp get(payload, atom_key, default \\ nil) do
    Map.get(payload, atom_key) || Map.get(payload, Atom.to_string(atom_key)) || default
  end

  defp require_binary(payload, atom_key) do
    value = get(payload, atom_key)
    if is_binary(value) and value != "", do: value, else: raise("missing required: #{atom_key}")
  end

  defp get_dt(payload, atom_key) do
    case get(payload, atom_key) do
      %DateTime{} = dt -> dt
      nil -> DateTime.utc_now()
      raw when is_binary(raw) -> parse_iso8601(raw)
      _ -> DateTime.utc_now()
    end
  end

  defp parse_iso8601(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, dt, _utc_offset} -> dt
      {:error, _reason} -> DateTime.utc_now()
    end
  end
end
