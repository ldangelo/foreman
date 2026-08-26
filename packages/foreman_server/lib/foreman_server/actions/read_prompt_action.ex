defmodule ForemanServer.Actions.ReadPromptAction do
  @moduledoc """
  A `Jido.Action` that returns the current prompt-body text for a given
  absolute path by delegating to `ForemanServer.Workflow.Catalog.read_prompt/1`
  (TRD-2026-4212be7e, JAF-T004).

  This action deliberately reuses the existing Foreman prompt
  infrastructure instead of inventing a second prompt loader. The
  upstream `jido` package has no `Jido.Character` or prompt-template
  API today; Foreman already has prompt-body loading and hot-reload
  via `Workflow.Catalog.read_prompt/1`. This action is the Jido.Action
  façade over that loader, so future prompt-driven agents can treat
  prompt fragments as just another tool call.

  ## Output shape

      {:ok, %{text: "# Prompt\n\nYou are helpful."}}

  ## Error propagation

  `Workflow.Catalog.read_prompt/1` returns `{:ok, text}` or
  `{:error, reason}`. This action passes the error through unchanged
  so the calling Jido agent can surface the same `:prompt_not_tracked`
  or other catalog errors.
  """

  use Jido.Action,
    name: "read_prompt",
    description: "Read the current prompt-body text for a tracked workflow prompt path",
    category: "prompt",
    tags: ["prompt", "workflow", "catalog"],
    vsn: "1.0.0",
    schema: [
      path: [type: :string, required: true, doc: "Absolute path to the tracked prompt file"]
    ],
    output_schema: [
      text: [type: :string, required: true, doc: "Prompt-body text"]
    ]

  @impl true
  def run(params, context) do
    path = params.path
    reader = Map.get(context, :catalog_reader, &ForemanServer.Workflow.Catalog.read_prompt/1)

    case reader.(path) do
      {:ok, text} ->
        {:ok, %{text: text}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
