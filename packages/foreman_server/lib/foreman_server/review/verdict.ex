defmodule ForemanServer.Review.Verdict do
  @moduledoc "The reviewer's graded judgement of a finished run against its request."

  @enforce_keys [:verdict, :summary]
  @type dimension :: :correctness | :tests | :documentation | :robustness
  @type t :: %__MODULE__{
          verdict: :met | :partially_met | :not_met | :undetermined,
          scores: %{dimension() => 1..5},
          summary: String.t(),
          gaps: [ForemanServer.Review.Gap.t()],
          error_code: atom() | nil,
          usage: ForemanServer.Usage.t() | nil,
          model: String.t() | nil,
          usage_provider: String.t() | nil
        }
  defstruct [
    :verdict,
    :summary,
    :usage,
    :model,
    :usage_provider,
    scores: %{},
    gaps: [],
    error_code: nil
  ]

  @dimensions [:correctness, :tests, :documentation, :robustness]

  @doc "JSON-ready map (string keys) of the verdict."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = v) do
    %{
      "verdict" => Atom.to_string(v.verdict),
      "scores" => Map.new(v.scores, fn {dim, score} -> {Atom.to_string(dim), score} end),
      "summary" => v.summary,
      "gaps" =>
        Enum.map(v.gaps, fn gap ->
          %{
            "title" => gap.title,
            "description" => gap.description,
            "dimension" => Atom.to_string(gap.dimension),
            "severity" => Atom.to_string(gap.severity)
          }
        end),
      "error_code" => v.error_code && Atom.to_string(v.error_code)
    }
  end

  @doc "Human-readable markdown rendering of the verdict."
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{} = v) do
    scores =
      for dim <- @dimensions, Map.has_key?(v.scores, dim) do
        "- #{dim}: #{Map.fetch!(v.scores, dim)}/5"
      end

    gaps =
      Enum.map(v.gaps, fn gap ->
        "- **#{gap.title}** (#{gap.severity}, #{gap.dimension}): #{gap.description}"
      end)

    error = if v.error_code, do: ["", "Error: `#{v.error_code}`"], else: []

    (["# Review verdict: #{v.verdict}", "", v.summary] ++
       error ++
       section("Scores", scores) ++
       section("Gaps", gaps))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp section(_title, []), do: []
  defp section(title, lines), do: ["", "## #{title}", ""] ++ lines
end
