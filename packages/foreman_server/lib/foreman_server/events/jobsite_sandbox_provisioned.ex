defmodule ForemanServer.Events.JobsiteSandboxProvisioned do
  @moduledoc "Typed event emitted when a jobsite's sandbox has been created."
  @enforce_keys [:jobsite_id, :provider, :sandbox_repo_path]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          provider: String.t(),
          sandbox_repo_path: String.t(),
          container_id: String.t() | nil,
          attempt: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:jobsite_id, :provider, :sandbox_repo_path, :container_id, :attempt]
end
