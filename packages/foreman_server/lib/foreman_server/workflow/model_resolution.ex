defmodule ForemanServer.Workflow.ModelResolution do
  @moduledoc """
  Which model a workflow phase is handed, and which rule chose it (PRD
  REQ-005 / REQ-006).

  The precedence is fixed, first match wins:

    1. `:phase_declared` - the phase's own `models.default`.
    2. `:project_thread_model` - the project's `thread_model` setting, and only
       for a phase that declares no model of its own (a gap-filler, never an
       override).
    3. `:provider_default` - neither is set: no model is passed and the
       provider's own default applies.

  `RunExecutor` resolves through `resolve/2` once per decision and records the
  `source` next to the `model` it hands the driver (the per-phase launch log,
  and every `PreflightFailure` the kickoff preflight raises), so "which model
  did this phase run with, and why" is answered by the record instead of being
  re-derived later from settings that may have changed since.
  """

  @enforce_keys [:model, :source]
  defstruct [:model, :source]

  @type source :: :phase_declared | :project_thread_model | :provider_default

  @type t :: %__MODULE__{model: String.t() | nil, source: source()}

  @doc """
  Apply the precedence to the phase's declared `models.default` and the
  project's `thread_model` (each `nil` when unset).
  """
  @spec resolve(declared :: String.t() | nil, project_model :: String.t() | nil) :: t()
  def resolve(declared, _project_model) when is_binary(declared),
    do: %__MODULE__{model: declared, source: :phase_declared}

  def resolve(nil, project_model) when is_binary(project_model),
    do: %__MODULE__{model: project_model, source: :project_thread_model}

  def resolve(nil, nil), do: %__MODULE__{model: nil, source: :provider_default}
end
