defmodule ForemanServer.Events.WorkerHeartbeat do
  @moduledoc "Emitted on each worker heartbeat."

  @enforce_keys [:run_id, :worker_id, :sequence]
  @type t :: %__MODULE__{
          run_id: String.t(),
          worker_id: String.t(),
          phase_id: String.t() | nil,
          session_id: String.t() | nil,
          pid: pid() | nil,
          attach: map(),
          sequence: non_neg_integer() | nil,
          observed_at: DateTime.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :worker_id,
    :phase_id,
    :session_id,
    :pid,
    :attach,
    :sequence,
    :observed_at
  ]

  @spec from_payload(map()) :: t()
  def from_payload(payload) do
    %__MODULE__{
      run_id: require_binary(payload, :run_id),
      worker_id: require_binary(payload, :worker_id),
      phase_id: get(payload, :phase_id),
      session_id: get(payload, :session_id),
      pid: get(payload, :pid),
      attach: get(payload, :attach, %{}),
      sequence: get(payload, :sequence),
      observed_at: get(payload, :observed_at)
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
end
