defmodule ForemanServer.Workflow.PrBody.Sources do
  @moduledoc """
  The content Foreman can put under the headings a project requires in its
  pull-request bodies.

  Every field is optional: a project may require headings Foreman has no
  content for, and the body then says so instead of carrying an empty
  section.

  `artifact_path` is printed as given, so the caller passes the path the way the
  body should name it: relative to the repository (`ForemanServer.Workflow.PrBodyPath`),
  or `nil` when the artifact has no such form. A body is public; a host path
  never belongs in it.
  """

  @typedoc "One commit of the run: its sha and its subject line."
  @type commit :: {String.t(), String.t()}

  @typedoc "The run's commits, or why Foreman could not list them."
  @type commits :: {:ok, [commit()]} | {:error, String.t()}

  @type t :: %__MODULE__{
          task_title: String.t() | nil,
          task_description: String.t() | nil,
          commits: commits(),
          artifact_path: String.t() | nil,
          artifact_section: String.t() | nil
        }

  defstruct task_title: nil,
            task_description: nil,
            commits: {:ok, []},
            artifact_path: nil,
            artifact_section: nil
end
