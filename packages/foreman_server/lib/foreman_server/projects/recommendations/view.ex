defmodule ForemanServer.Projects.Recommendations.View do
  @moduledoc """
  The one serialiser for recommendations: `GET /api/projects/:id/recommendations`
  and the `foreman_project_recommendations` MCP tool both return exactly this
  string-keyed, whitelisted shape.
  """

  alias ForemanServer.Projects.Recommendations.Recommendation

  @spec serialise(String.t(), [Recommendation.t()], DateTime.t()) :: map()
  def serialise(project_id, recommendations, now \\ DateTime.utc_now())
      when is_binary(project_id) and is_list(recommendations) do
    %{
      "project_id" => project_id,
      "generated_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "recommendations" => Enum.map(recommendations, &recommendation/1)
    }
  end

  defp recommendation(%Recommendation{} = rec) do
    %{
      "id" => rec.id,
      "severity" => Atom.to_string(rec.severity),
      "title" => rec.title,
      "detail" => rec.detail,
      "evidence" => stringify(rec.evidence),
      "fix" => fix(rec.fix)
    }
  end

  defp fix(nil), do: nil

  defp fix(%{kind: :command, type: type, payload: payload}),
    do: %{"kind" => "command", "type" => type, "payload" => stringify(payload)}

  defp fix(%{kind: :manual, text: text}), do: %{"kind" => "manual", "text" => text}

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp stringify(value), do: value
end
