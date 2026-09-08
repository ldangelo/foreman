defmodule ForemanServer.Observability.LogMetadata do
  @moduledoc """
  Builds canonical, redacted operational-log metadata.

  Fields are copied only from supplied run/workflow/phase maps. Missing values
  are omitted; this module never guesses IDs or names.
  """

  alias ForemanServer.Observability.Redactor

  @field_aliases %{
    run_id: [:run_id, "run_id"],
    task_id: [:task_id, "task_id"],
    project_id: [:project_id, "project_id"],
    workflow_name: [:workflow_name, "workflow_name", :workflow, "workflow", :name, "name"],
    phase_index: [:phase_index, "phase_index", :index, "index"],
    phase_name: [:phase_name, "phase_name", :name, "name"],
    phase_type: [:phase_type, "phase_type", :type, "type"],
    worker_id: [:worker_id, "worker_id"],
    base_branch: [:base_branch, "base_branch"],
    head_branch: [:head_branch, "head_branch"],
    branch: [:branch, "branch"],
    pr_url: [:pr_url, "pr_url"]
  }

  @spec build(map(), keyword()) :: map()
  def build(source, opts \\ []) when is_map(source) do
    base =
      @field_aliases
      |> Enum.reduce(%{}, fn {field, aliases}, acc ->
        put_present(acc, field, first_present(source, aliases))
      end)

    base
    |> merge_phase(opts[:phase])
    |> merge_context(opts[:context])
    |> merge_trace_context(opts[:trace_context])
    |> Redactor.redact_metadata()
  end

  @spec event(map(), atom() | String.t(), atom() | String.t(), map()) :: map()
  def event(source, operation, outcome, extra \\ %{}) do
    source
    |> build()
    |> Map.merge(%{operation: operation, outcome: outcome})
    |> Map.merge(extra)
    |> Redactor.redact_metadata()
  end

  defp merge_phase(metadata, nil), do: metadata

  defp merge_phase(metadata, phase) when is_map(phase) do
    Enum.reduce([:phase_index, :phase_name, :phase_type], metadata, fn field, acc ->
      put_present(acc, field, first_present(phase, @field_aliases[field]))
    end)
  end

  defp merge_phase(metadata, _), do: metadata

  defp merge_context(metadata, nil), do: metadata

  defp merge_context(metadata, context) when is_map(context) do
    context
    |> build()
    |> Map.merge(metadata, fn _k, old, _new -> old end)
  end

  defp merge_context(metadata, _), do: metadata

  defp merge_trace_context(metadata, nil), do: metadata

  defp merge_trace_context(metadata, %{trace_id: trace_id, span_id: span_id}) do
    metadata
    |> put_present(:trace_id, trace_id)
    |> put_present(:span_id, span_id)
  end

  defp merge_trace_context(metadata, _), do: metadata

  defp first_present(source, aliases) do
    Enum.find_value(aliases, fn key ->
      case Map.fetch(source, key) do
        {:ok, value} when value not in [nil, ""] -> value
        _ -> nil
      end
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
