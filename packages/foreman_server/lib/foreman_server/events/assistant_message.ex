defmodule ForemanServer.Events.AssistantMessage do
  @moduledoc "Emitted when a worker sends an assistant (LLM) message."

  @enforce_keys [:run_id, :worker_id, :sequence]
  @type t :: %__MODULE__{
          run_id: String.t(),
          worker_id: String.t(),
          project_id: String.t() | nil,
          task_id: String.t() | nil,
          phase_id: String.t() | nil,
          output: map() | nil,
          details: map(),
          sequence: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :worker_id,
    :project_id,
    :task_id,
    :phase_id,
    :output,
    :details,
    sequence: 0
  ]

  @spec from_payload(map()) :: t()
  def from_payload(payload) do
    %__MODULE__{
      run_id: require_binary(payload, :run_id),
      worker_id: require_binary(payload, :worker_id),
      project_id: get(payload, :project_id),
      task_id: get(payload, :task_id),
      phase_id: get(payload, :phase_id),
      output: get(payload, :output),
      details: get(payload, :details, %{}),
      sequence: get(payload, :sequence, 0)
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
