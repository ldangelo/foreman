defmodule ForemanServer.Workflow.Catalog.Doctor do
  @moduledoc """
  Type coverage diagnostics for beads task_types mapping.

  Reports unmapped issue_types and coverage status.
  """

  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProvider.Issue

  @enforce_keys [:unmapped_types, :covered, :total_issue_types, :mapped_types]
  defstruct [:unmapped_types, :covered, :total_issue_types, :mapped_types]

  @type t :: %__MODULE__{
          unmapped_types: [String.t()],
          covered: boolean(),
          total_issue_types: non_neg_integer(),
          mapped_types: non_neg_integer()
        }

  @doc """
  Generate a coverage report comparing actual issue_types in beads to mapped types.

  Returns `{:ok, %__MODULE__{}}`, or `{:error, reason}` when the project's
  actual issue types could not be determined (missing registration or a
  failed `list_ready/2` call) — a silent fallback to an empty set here would
  report `covered: true` for input that was undeterminable, not input that
  was actually clean.
  """
  @spec coverage_report(String.t(), %{String.t() => String.t()}) ::
          {:ok, t()} | {:error, term()}
  def coverage_report(project_id, mapped_types_map) when is_map(mapped_types_map) do
    with {:ok, actual_types} <- get_actual_issue_types(project_id) do
      mapped_types = MapSet.new(Map.keys(mapped_types_map))
      covered_types = MapSet.intersection(actual_types, mapped_types)
      unmapped = MapSet.difference(actual_types, mapped_types)

      {:ok,
       %__MODULE__{
         unmapped_types: unmapped |> MapSet.to_list() |> Enum.sort(),
         covered: Enum.empty?(unmapped),
         total_issue_types: Enum.count(actual_types),
         mapped_types: Enum.count(covered_types)
       }}
    end
  end

  @doc """
  Format coverage report as ASCII tree output.
  """
  @spec format_ascii(t()) :: String.t()
  def format_ascii(%__MODULE__{} = report) do
    lines = [
      "Workflow Type Coverage",
      "═" <> String.duplicate("═", 20)
    ]

    lines = lines ++ format_coverage_status(report)

    lines =
      if Enum.empty?(report.unmapped_types) do
        lines ++ [
          "",
          "✓ All issue_types are mapped to workflows"
        ]
      else
        lines ++ [
          "",
          "⚠ Unmapped issue_types:",
          "─ " <> String.duplicate("─", 18)
        ] ++ Enum.map(report.unmapped_types, &("  • " <> &1))
      end

    Enum.join(lines, "\n")
  end

  @doc """
  Format coverage report as JSON.
  """
  @spec format_json(t()) :: String.t()
  def format_json(%__MODULE__{} = report) do
    Jason.encode!(%{
      covered: report.covered,
      total_issue_types: report.total_issue_types,
      mapped_types: report.mapped_types,
      unmapped_types: report.unmapped_types
    })
  end

  # Private helpers

  defp format_coverage_status(report) do
    total = report.total_issue_types
    mapped = report.mapped_types

    [
      "Total issue_types: #{total}",
      "Mapped workflows: #{mapped}",
      "Coverage: #{coverage_percent(mapped, total)}"
    ]
  end

  defp coverage_percent(_mapped, total) when total == 0, do: "100%"
  defp coverage_percent(mapped, total) do
    percent = div(mapped * 100, total)
    "#{percent}%"
  end

  @spec get_actual_issue_types(String.t()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  defp get_actual_issue_types(project_id) do
    # Query all non-closed beads for their issue_types, routed through the
    # TaskProvider abstraction rather than a direct adapter alias (adapter
    # aliases are confined to lib/foreman_server/task_providers). A failed
    # lookup here is propagated, never coerced to an empty set: an empty
    # set is indistinguishable from "this project genuinely has zero
    # issues", which would make `coverage_report/2` report `covered: true`
    # for input it could not actually determine.
    with {:ok, %{provider_module: provider_module, config: config}} <-
           Registry.project_config(project_id),
         {:ok, beads} when is_list(beads) <- provider_module.list_ready(config, []) do
      types =
        beads
        |> Enum.map(&extract_issue_type/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> MapSet.new()

      {:ok, types}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_list_ready_result, other}}
    end
  end

  # `Issue.t()` (the real shape `list_ready/2` returns) has no top-level
  # `issue_type` field — `id`/`title`/`status`/`priority`/`dependencies`/
  # `dependents`/`assignee`/`description`/`notes`/`design`/`labels`/
  # `metadata` are the only fields it declares. `BeadsAdapter` writes the
  # bead's type into `metadata["issue_type"]` at create time
  # (`build_issue_from_create_payload/2`), so that is where a real issue's
  # type lives. Matching the bare struct here would silently match nothing
  # for every production issue, making `get_actual_issue_types/1` always
  # return an empty set.
  defp extract_issue_type(%Issue{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "issue_type") || Map.get(metadata, :issue_type)
  end

  defp extract_issue_type(%{"issue_type" => type}), do: type
  defp extract_issue_type(%{issue_type: type}), do: type
  defp extract_issue_type(_), do: nil
end
