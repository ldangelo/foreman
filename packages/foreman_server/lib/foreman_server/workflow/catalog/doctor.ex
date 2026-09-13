defmodule ForemanServer.Workflow.Catalog.Doctor do
  @moduledoc """
  Type coverage diagnostics for beads task_types mapping.

  Reports unmapped issue_types and coverage status.
  """

  alias ForemanServer.TaskProviders.BeadsAdapter

  @type unmapped_type :: String.t()
  @type coverage_report :: %{
    unmapped_types: [unmapped_type],
    covered: boolean,
    total_issue_types: non_neg_integer,
    mapped_types: non_neg_integer
  }

  @doc """
  Generate a coverage report comparing actual issue_types in beads to mapped types.

  Returns a map with unmapped types and coverage status.
  """
  def coverage_report(project_id, mapped_types_map) when is_map(mapped_types_map) do
    actual_types = get_actual_issue_types(project_id)
    mapped_types = MapSet.new(Map.keys(mapped_types_map))

    unmapped = Enum.reject(actual_types, &MapSet.member?(mapped_types, &1))

    %{
      unmapped_types: Enum.sort(unmapped),
      covered: Enum.empty?(unmapped),
      total_issue_types: Enum.count(actual_types),
      mapped_types: Enum.count(mapped_types)
    }
  end

  @doc """
  Format coverage report as ASCII tree output.
  """
  def format_ascii(report) do
    lines = [
      "Workflow Type Coverage",
      "═" <> String.duplicate("═", 20)
    ]

    lines = lines ++ format_coverage_status(report)

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
  def format_json(report) do
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

  defp coverage_percent(mapped, total) when total == 0, do: "100%"
  defp coverage_percent(mapped, total) do
    percent = div(mapped * 100, total)
    "#{percent}%"
  end

  defp get_actual_issue_types(project_id) do
    # Query all non-closed beads for their issue_types
    case BeadsAdapter.list_ready(%{database_path: project_id}, []) do
      {:ok, beads} when is_list(beads) ->
        beads
        |> Enum.map(&extract_issue_type/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  defp extract_issue_type(%{"issue_type" => type}), do: type
  defp extract_issue_type(%{issue_type: type}), do: type
  defp extract_issue_type(_), do: nil
end
