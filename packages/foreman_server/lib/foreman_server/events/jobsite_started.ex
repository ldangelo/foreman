defmodule ForemanServer.Events.JobsiteStarted do
  @moduledoc "Typed event emitted when a jobsite run starts."
  @enforce_keys [:jobsite_id, :repo_path, :strategy]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          repo_path: String.t(),
          strategy: String.t(),
          branch: String.t() | nil,
          target_branch: String.t() | nil,
          base_sha: String.t() | nil,
          agent: map() | nil,
          sandbox_provider: String.t() | nil,
          sandbox_config: map() | nil,
          max_iterations: pos_integer() | nil,
          completion_signals: [String.t()] | nil,
          prompt_digest: String.t() | nil,
          name: String.t() | nil,
          started_at_ms: non_neg_integer() | nil,
          push: boolean()
        }
  @derive Jason.Encoder
  defstruct [
    :jobsite_id,
    :repo_path,
    :strategy,
    :branch,
    :target_branch,
    :base_sha,
    :agent,
    :sandbox_provider,
    :sandbox_config,
    :max_iterations,
    :completion_signals,
    :prompt_digest,
    :name,
    :started_at_ms,
    push: false
  ]
end
