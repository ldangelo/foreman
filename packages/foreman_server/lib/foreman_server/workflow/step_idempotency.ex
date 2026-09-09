defmodule ForemanServer.Workflow.StepIdempotency do
  @moduledoc """
  Per-step idempotency key generation for the create workflow dispatcher.
  Key format: create-{task_id}-{step_name}.
  TRD-2026-4212be7e / WFD-T002 / TRD-065.
  """
  @doc "Builds the idempotency key for one step of the create workflow dispatcher."
  def key_for(task_id, step_name) do
    "create-#{task_id}-#{step_name}"
  end

  @doc "Builds `{step_name, idempotency_key}` pairs for every step in `steps`."
  def all_keys_for(task_id, steps) do
    Enum.map(steps, fn {name, _skill} -> {to_string(name), key_for(task_id, name)} end)
  end
end
