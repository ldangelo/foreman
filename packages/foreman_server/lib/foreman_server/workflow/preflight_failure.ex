defmodule ForemanServer.Workflow.PreflightFailure do
  @moduledoc """
  One workflow phase's provider/model readiness verdict, as recorded on a run
  that the kickoff preflight refused.

  `RunExecutor.preflight_providers_and_models/1` collects these for every phase
  that declares a `provider:` or `models:` block and puts the list into the run's
  terminal reason as `{:provider_model_preflight_failed, [t()]}`. The struct
  exists because the tuple form this replaced carried a phase label and a bare
  reason atom only, and three of the four classes were indistinguishable from a
  fourth: `{:error, {:model_not_found, m}}` and `{:error, {:catalog_query_failed,
  _}}` both collapsed into `{:phase_model_invalid, name, provider, model,
  reason}`, so "the catalog answered: not present" (a workflow defect) read
  identically to "the catalog could not be asked" (an infrastructure defect).
  `AGENTS.md` §5.3 requires distinct codes for distinct causes.

  The fields answer the question an operator actually has, in the order they
  would ask it: which phase, which provider, which model string, which rule
  chose that string (`model_source`, a `ForemanServer.Workflow.ModelResolution`
  source: the phase's own `models.default`, or the project's `thread_model`
  filling a phase that declares none), and which class of failure. `detail` is
  the one field that is not a discriminator — it carries whatever the
  underlying check returned (the provider's install hint, or the catalog
  query's own output) and exists so the failure is diagnosable from the run
  record alone, without re-running.
  """

  @classes [
    :provider_unsupported,
    :provider_not_installed,
    :model_not_found,
    :catalog_unavailable
  ]

  @enforce_keys [:phase, :provider, :class]
  defstruct [:phase, :provider, :class, model: nil, model_source: nil, detail: nil]

  @type class ::
          :provider_unsupported
          | :provider_not_installed
          | :model_not_found
          | :catalog_unavailable

  @type t :: %__MODULE__{
          phase: String.t() | atom() | nil,
          provider: atom(),
          class: class(),
          model: String.t() | nil,
          model_source: ForemanServer.Workflow.ModelResolution.source() | nil,
          detail: term()
        }

  @doc "The failure classes this struct can carry, in the order they are checked."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc """
  Render the failure as the one-line summary a log line or run record shows.

  Deliberably distinct per class (see module doc): two classes must never
  produce identical text.
  """
  @spec summarize(t()) :: String.t()
  def summarize(%__MODULE__{} = f) do
    base =
      "phase #{inspect(f.phase)}: #{f.class} - " <>
        class_phrase(%{f | detail: nil}) <> source_clause(f)

    case f.detail do
      nil -> base
      detail -> base <> " (" <> detail_phrase(detail) <> ")"
    end
  end

  # Names where the model string came from, so the fix lands on the right
  # artifact: a workflow's `models.default` is edited in the manifest, a
  # project's `thread_model` with `foreman project update`. Omitted when no model
  # is involved or no source was recorded.
  defp source_clause(%{model: model, model_source: :phase_declared}) when is_binary(model),
    do: "; the model comes from the phase's models.default"

  defp source_clause(%{model: model, model_source: :project_thread_model})
       when is_binary(model),
       do: "; the model comes from the project's thread_model"

  defp source_clause(_failure), do: ""

  defp class_phrase(%{class: :provider_unsupported, provider: provider}),
    do: "provider #{inspect(provider)} is not a supported provider"

  defp class_phrase(%{class: :provider_not_installed, provider: provider}),
    do: "provider #{inspect(provider)} is not installed on this host"

  defp class_phrase(%{class: :model_not_found, provider: provider, model: model}),
    do: "the #{inspect(provider)} model catalog answered that #{inspect(model)} is not present"

  defp class_phrase(%{class: :catalog_unavailable, provider: provider, model: model}),
    do:
      "the #{inspect(provider)} model catalog could not answer whether #{inspect(model)} is present"

  defp class_phrase(%{class: class}),
    do: "unclassified preflight failure #{inspect(class)}"

  defp detail_phrase(detail) when is_binary(detail), do: detail
  defp detail_phrase(detail), do: inspect(detail)
end
