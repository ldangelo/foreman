defmodule ForemanServer.Events.JobsiteWorktreeProvisioned do
  @moduledoc "Typed event emitted when a jobsite's worktree has been created or reused."
  @enforce_keys [:jobsite_id, :path, :branch, :base_sha]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          path: String.t(),
          branch: String.t(),
          base_sha: String.t(),
          reused?: boolean() | nil
        }
  @derive Jason.Encoder
  defstruct [:jobsite_id, :path, :branch, :base_sha, :reused?]
end
