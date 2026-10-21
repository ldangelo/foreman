defmodule ForemanServer.Review.Subject do
  @moduledoc "A finished run or jobsite whose archived session is to be reviewed."

  @enforce_keys [:kind, :subject_id, :repo_path, :archive_dir, :status]
  @type t :: %__MODULE__{
          kind: :run | :jobsite,
          subject_id: String.t(),
          project_id: String.t() | nil,
          repo_path: String.t(),
          archive_dir: String.t(),
          status: String.t() | atom(),
          bead_id: String.t() | nil,
          request_title: String.t() | nil,
          request_text: String.t() | nil,
          workflow_name: String.t() | nil
        }
  defstruct [
    :kind,
    :subject_id,
    :project_id,
    :repo_path,
    :archive_dir,
    :status,
    :bead_id,
    :request_title,
    :request_text,
    :workflow_name
  ]
end
