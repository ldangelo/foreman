defmodule ForemanServer.Workflow.PrBodyContext do
  @moduledoc """
  Puts the project's required pull-request body headings into an AutoPR context.

  Every door that builds an AutoPR context — the run executor's completion PR,
  the `run.pr.create` executor, and a phase PR — needs the same
  settings-to-context mapping. It lives here so the doors cannot drift apart
  (AGENTS.md §5.7). Each door keeps its own source of truth for the settings:
  the run executor passes the settings it latched at run start, the command
  doors read the live project settings projection.
  """

  alias ForemanServer.ProjectSettings
  alias ForemanServer.ProjectionStore

  @doc """
  Adds the headings `settings` requires to `context`.

  A project that requires none keeps the body the task or workflow produced, so
  the key is omitted: AutoPR templates a body only when the key is present.
  Anything that is not a list of headings — a value written straight to the
  projection, past the aggregate's validation — is forwarded unchanged: AutoPR
  refuses it rather than opening an untemplated PR (AGENTS.md §5.2).
  """
  @spec put_headings(map(), ProjectSettings.t() | nil) :: map()
  def put_headings(context, %ProjectSettings{} = settings) do
    case ProjectSettings.pr_body_headings(settings) do
      {:headings, headings} -> Map.put(context, :pr_body_headings, headings)
      {:malformed, value} -> Map.put(context, :pr_body_headings, value)
      :unset -> context
    end
  end

  def put_headings(context, _settings), do: context

  @doc """
  Adds the headings the project named by `project_id` currently requires.

  Reads the live settings projection; a run whose task has no project, or a
  project the projection does not know, keeps the context unchanged.
  """
  @spec put_project_headings(map(), String.t() | nil) :: map()
  def put_project_headings(context, project_id) when is_binary(project_id) do
    context
    |> put_headings(ProjectionStore.project_settings(project_id))
  end

  def put_project_headings(context, _project_id), do: context
end
