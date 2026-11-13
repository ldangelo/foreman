defmodule ForemanServer.PrRisk do
  @moduledoc """
  TRD-041: the review agent's risk judgement, parsed from the review artifact.

  The judgement is one more typed marker block in the artifact (next to the findings block of
  `Workflow.ReviewFindings`): the lines `<!-- FOREMAN_RISK_JUDGEMENT_START -->` and
  `<!-- FOREMAN_RISK_JUDGEMENT_END -->` around the JSON

      {"schema": "foreman.risk_judgement/1", "level": "LOW" | "MEDIUM" | "HIGH", "rationale": "..."}

  It is the review agent's claim, never a machine observation: the rubric (TRD-016) lets it
  only raise the level. The block is found by `ReviewFindings.extract_block/3`, so the counting
  and the one-pair rule are the findings block's (a marker line is counted only when it equals
  the marker, trailing whitespace trimmed, outside a fenced code block; a second counted block
  is `multiple_blocks` and neither level is used).

  `parse_judgement/1` answers one map with atom keys `status`, `level`,
  `rationale`, `defect` and `defect_detail`:

    * `%{status: "absent"}`: no counted block (an absent judgement is NOT a neutral level);
    * `%{status: "recorded", level, rationale}`: one valid block;
    * `%{status: "malformed", defect, defect_detail}`: any other shape. `defect` is one of
      `PrEvidence.findings_defects/0` (`multiple_blocks`, `unterminated_block`, `invalid_json`,
      `unknown_schema`, `invalid_field`, `too_large`).

  The map is bound to a head only by the event that carries it (`ReviewFindingsRecorded`).
  """

  alias ForemanServer.Workflow.ReviewFindings

  @start_marker "<!-- FOREMAN_RISK_JUDGEMENT_START -->"
  @end_marker "<!-- FOREMAN_RISK_JUDGEMENT_END -->"
  @schema "foreman.risk_judgement/1"
  @levels ~w(LOW MEDIUM HIGH)
  @keys ~w(schema level rationale)
  @max_block_bytes 4096
  @max_rationale 1000

  @type level :: String.t()
  @type judgement :: %{
          status: String.t(),
          level: level | nil,
          rationale: String.t() | nil,
          defect: String.t() | nil,
          defect_detail: String.t() | nil
        }

  @doc "The levels a judgement may name, lowest first."
  @spec levels() :: [level]
  def levels, do: @levels

  @doc "The judgement of an artifact with no block (and of an artifact that could not be read)."
  @spec absent() :: judgement
  def absent,
    do: %{status: "absent", level: nil, rationale: nil, defect: nil, defect_detail: nil}

  @doc "Parses the judgement from the artifact contents."
  @spec parse_judgement(String.t()) :: judgement
  def parse_judgement(contents) when is_binary(contents) do
    case ReviewFindings.extract_block(contents, @start_marker, @end_marker) do
      :absent -> absent()
      {:error, reason} -> malformed(reason)
      {:ok, block} -> parse_block(block)
    end
  end

  defp parse_block(block) when byte_size(block) > @max_block_bytes, do: malformed(:too_large)

  defp parse_block(block) do
    case Jason.decode(block, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{values: pairs}} -> dispatch(pairs)
      {:ok, _other} -> malformed(:unknown_schema)
      {:error, _} -> malformed(:invalid_json)
    end
  end

  defp dispatch(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))
    doc = Map.new(pairs)

    cond do
      Map.get(doc, "schema") != @schema -> malformed(:unknown_schema)
      length(keys) != length(Enum.uniq(keys)) -> malformed(:invalid_field)
      Enum.sort(keys) != Enum.sort(@keys) -> malformed(:invalid_field)
      true -> validate(doc)
    end
  end

  defp validate(%{"level" => level, "rationale" => rationale}) do
    cond do
      level not in @levels -> malformed(:invalid_field)
      not valid_rationale?(rationale) -> malformed(:invalid_field)
      true -> %{absent() | status: "recorded", level: level, rationale: rationale}
    end
  end

  # Untrusted text that reaches the event store and the PR body: bounded, not empty, no NUL, ESC,
  # CR or other C0 control character (a newline and a tab stay) and no DEL.
  defp valid_rationale?(value) do
    is_binary(value) and String.trim(value) != "" and String.length(value) <= @max_rationale and
      not Regex.match?(~r/[\x00-\x08\x0B-\x1F\x7F]/u, value)
  end

  defp malformed(reason) do
    %{
      absent()
      | status: "malformed",
        defect: Atom.to_string(reason),
        defect_detail: detail(reason)
    }
  end

  defp detail(:multiple_blocks),
    do:
      "more than one risk judgement marker pair is present; quote marker lines inside a code fence"

  defp detail(:unterminated_block),
    do: "a risk judgement marker has no matching partner, or the markers are out of order"

  defp detail(:invalid_json), do: "the risk judgement block is not valid JSON"

  defp detail(:unknown_schema),
    do: "the risk judgement block does not declare schema #{@schema}"

  defp detail(:invalid_field),
    do:
      "a risk judgement field is missing, unknown, repeated, or out of bounds (level one of " <>
        "#{Enum.join(@levels, ", ")}; rationale at most #{@max_rationale} characters)"

  defp detail(:too_large), do: "the risk judgement block is over #{@max_block_bytes} bytes"
end
