defmodule ForemanServer.Events.WorkerStarted do
  @moduledoc "Emitted when a worker process starts for a phase."

  @enforce_keys [:run_id, :worker_id, :phase_id, :adapter, :sequence]
  @type t :: %__MODULE__{
          run_id: String.t(),
          worker_id: String.t(),
          phase_id: String.t(),
          project_id: String.t() | nil,
          adapter: String.t(),
          session_id: String.t() | nil,
          prompt_path: String.t() | nil,
          tool_names: [String.t()],
          artifact_paths: [String.t()],
          prepared_env: map(),
          prepared_env_keys: [String.t()],
          stripped_env_keys: [String.t()],
          scoped_secret_keys: [String.t()],
          sequence: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :worker_id,
    :phase_id,
    :project_id,
    :adapter,
    :session_id,
    :prompt_path,
    :tool_names,
    :artifact_paths,
    :prepared_env,
    :prepared_env_keys,
    :stripped_env_keys,
    :scoped_secret_keys,
    sequence: 0
  ]

  @spec from_payload(map()) :: t()
  def from_payload(payload) do
    %__MODULE__{
      run_id: require_binary(payload, :run_id),
      worker_id: require_binary(payload, :worker_id),
      phase_id: require_binary(payload, :phase_id),
      project_id: get(payload, :project_id),
      adapter: get(payload, :adapter),
      session_id: get(payload, :session_id),
      prompt_path: get(payload, :prompt_path),
      tool_names: get(payload, :tool_names) || [],
      artifact_paths: get(payload, :artifact_paths) || [],
      prepared_env: get(payload, :prepared_env, %{}),
      prepared_env_keys: get(payload, :prepared_env_keys) || [],
      stripped_env_keys: get(payload, :stripped_env_keys) || [],
      scoped_secret_keys: get(payload, :scoped_secret_keys) || [],
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
