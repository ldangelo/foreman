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

  alias ForemanServer.PrRisk.Rubric
  alias ForemanServer.Workflow.ReviewFindings
  alias ForemanServer.Workflow.ReviewFindings.Finding

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

  @max_listed_unresolved 20
  @max_listed_description 300
  @severities ~w(critical major minor nitpick)

  @doc """
  TRD-018: the content of a `PrRiskRecorded` event, built from the inputs the handler holds.
  Pure and deterministic: the same input gives the same map, and nothing reads a clock.

  `input` has `identity` (`%{run_id, project_id, task_id, pr_url, repo_id}`), `head_sha`,
  `files`, `changed_files`, `additions`, `deletions`, `base_branch`, `recorded_base` (passed
  to `Rubric.classify/1` exactly as given: a missing input is never filled in), `checks`
  (`%{status, reasons}` of `PrEvidence.evaluate_checks/2`, read without the waiver),
  `findings` (the folded `evidence.findings` record or `nil`) and `policy_version`.

  Returns `level`, `rubric_version`, `rationale`, `evidence`, `unresolved_findings`,
  `instructions`, `judgement`, `findings_digest` and `digest` (the first 16 hex characters of
  the SHA-256 of every one of those fields, the head and the identity). The level is the
  rubric's and nothing else. Every nested map is string-keyed. No free text of the review agent
  enters the map except a finding's `description`, which is cut at #{@max_listed_description}
  characters (at most #{@max_listed_unresolved} unresolved findings are listed); a judgement's
  rationale is never copied.
  """
  @spec record(map()) :: map()
  def record(%{} = input) do
    result =
      Rubric.classify(%Rubric.Inputs{
        head_sha: input.head_sha,
        files: input.files,
        changed_files: input.changed_files,
        additions: input.additions,
        deletions: input.deletions,
        checks: input.checks,
        findings: input.findings,
        base_branch: input.base_branch,
        recorded_base: input.recorded_base,
        judgement: judgement_of(input.findings)
      })

    judgement = judgement_view(input.findings)
    findings_digest = text(get(input.findings, :digest))

    content = %{
      "head_sha" => input.head_sha,
      "level" => result.level,
      "rubric_version" => result.rubric_version,
      "rationale" => Enum.map(result.rationale, &stringify/1),
      "evidence" => evidence(input, result, judgement),
      "unresolved_findings" => unresolved_findings(input.head_sha, input.findings),
      "instructions" => result.instructions,
      "judgement" => judgement,
      "findings_digest" => findings_digest
    }

    identity =
      Map.new(~w(run_id project_id task_id pr_url repo_id)a, fn key ->
        {Atom.to_string(key), get(input.identity, key)}
      end)

    %{
      level: content["level"],
      rubric_version: content["rubric_version"],
      rationale: content["rationale"],
      evidence: content["evidence"],
      unresolved_findings: content["unresolved_findings"],
      instructions: content["instructions"],
      judgement: judgement,
      findings_digest: findings_digest,
      digest: digest({content, identity})
    }
  end

  defp judgement_of(%{} = findings), do: get(findings, :judgement)
  defp judgement_of(_none), do: nil

  defp judgement_view(%{} = findings) do
    case get(findings, :judgement) do
      %{} = judgement ->
        %{
          "head_sha" => text(get(findings, :head_sha)),
          "status" => text(get(judgement, :status)),
          "level" => text(get(judgement, :level)),
          "defect" => text(get(judgement, :defect))
        }

      _none ->
        nil
    end
  end

  defp judgement_view(_none), do: nil

  defp evidence(input, result, judgement) do
    files = if is_list(input.files), do: length(input.files)

    %{
      "checks" => %{
        "status" => input.checks |> get(:status) |> text(),
        "reasons" => input.checks |> get(:reasons) |> reason_codes()
      },
      "findings" => findings_summary(input.findings, result),
      "judgement" =>
        judgement && %{"status" => judgement["status"], "level" => judgement["level"]},
      "files" => %{
        "changed" => input.changed_files,
        "listed" => files,
        "additions" => input.additions,
        "deletions" => input.deletions,
        "incomplete" => incomplete?(input.files, input.changed_files)
      },
      "sensitive_hits" => Enum.map(result.sensitive_hits, &stringify/1),
      "base_branch" => input.base_branch,
      "recorded_base" => input.recorded_base,
      "policy_version" => input.policy_version
    }
  end

  defp incomplete?(files, changed) when is_list(files) and is_integer(changed),
    do: length(files) < changed

  defp incomplete?(_files, _changed), do: true

  defp findings_summary(%{} = findings, result) do
    items = get(findings, :findings)
    items = if is_list(items), do: items, else: []

    counts =
      Map.new(@severities, fn severity ->
        {severity, Enum.count(items, &(text(get(&1, :severity)) == severity))}
      end)

    %{
      "status" => text(get(findings, :status)),
      "head_sha" => text(get(findings, :head_sha)),
      "defect" => text(get(findings, :defect)),
      "counts" => counts,
      "unresolved" =>
        result.unresolved && Map.new(result.unresolved, &{to_string(elem(&1, 0)), elem(&1, 1)})
    }
  end

  defp findings_summary(_none, _result), do: nil

  # The open findings of a record made for the head being decided. A record of another head
  # lists none: it says nothing about this head.
  defp unresolved_findings(head, %{} = findings) do
    items = get(findings, :findings)

    if get(findings, :head_sha) == head and text(get(findings, :status)) == "recorded" and
         is_list(items) do
      items
      |> Enum.filter(&unresolved?/1)
      |> Enum.take(@max_listed_unresolved)
      |> Enum.map(fn item ->
        %{
          "severity" => text(get(item, :severity)),
          "path" => text(get(item, :path)),
          "line" => get(item, :line),
          "description" => item |> get(:description) |> text() |> cut(@max_listed_description),
          "disposition" => text(get(item, :disposition)),
          "source" => text(get(item, :source))
        }
      end)
    else
      []
    end
  end

  defp unresolved_findings(_head, _none), do: []

  # One finding is unresolved when `ReviewFindings.unresolved/1` counts it: the same rule, and an
  # unknown severity or disposition counts as an open critical (as the rubric reads it).
  defp unresolved?(item) do
    finding = %Finding{
      severity: severity(text(get(item, :severity))),
      path: "",
      line: nil,
      description: "",
      disposition: disposition(text(get(item, :disposition))),
      source: ""
    }

    ReviewFindings.unresolved([finding]) |> Map.values() |> Enum.sum() > 0
  end

  defp severity("critical"), do: :critical
  defp severity("major"), do: :major
  defp severity("minor"), do: :minor
  defp severity("nitpick"), do: :nitpick
  defp severity(_other), do: :critical

  defp disposition("fixed"), do: :fixed
  defp disposition("declined"), do: :declined
  defp disposition(_other), do: :open

  defp reason_codes(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(fn reason -> reason |> get(:code) |> text() end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp reason_codes(_other), do: []

  defp stringify(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(_other), do: nil

  defp cut(nil, _max), do: nil
  defp cut(text, max), do: String.slice(text, 0, max)

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil

  # The technique of `PrObservation.digest/1`: a deterministic term hash, 16 hex characters.
  defp digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
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
