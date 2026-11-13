defmodule ForemanServer.PrReport do
  @moduledoc """
  TRD-019: the body of the PR comment that reports one head's risk record.

  `render/2` is pure over a risk record (`PrRiskRecorded`, TRD-018: the event struct or a map of
  its fields, atom or string keys) and the project's secret values (`secrets:`, required; the
  caller resolves them with `ProjectEnvironment.fetch_secrets/1` and does not render when that
  returns an error, because `Coordinator.Redact.secrets/1` would answer `[]` and publish under
  the built-in patterns alone). It answers `{:ok, body}` or

    * `{:error, :redaction_failed}`: a listed secret value is still in the finished body
      (redaction is its own control: the whole body is scanned for every listed value);
    * `{:error, :redaction_unavailable}`: `secrets:` is missing or not a list of strings;
    * `{:error, :invalid_record}`: the record lacks a `run_id`, `head_sha` or `digest` that is
      safe to put in the marker line, or a `level` outside LOW, MEDIUM and HIGH;
    * `{:error, :report_too_large}`: the fixed part of the report alone exceeds the budget.

  The first line is the marker (`marker/3`) carrying the run, head and the record's digest; it
  is never part of a cut. The body states the level, `rubric_version`, the rationale with the
  basis of each line, the evidence (reason codes, sizes, sensitive paths), the unresolved
  findings (most severe first) and the instructions. Findings and the model judgement are
  labelled as claims an agent wrote; approval stays a human decision.

  Every free-text value (a finding's description, path and source, a rationale detail, a
  sensitive path, an instruction) is untrusted text: it passes `Coordinator.Redact.text/3` with
  the explicit list, is cut to #{500} characters and is neutralised by `neutralise/1`. Closed
  vocabulary fields (level, rule names, reason codes, counts) are only neutralised, so a secret
  that reaches one is caught by the scan and not hidden. The body is at most
  #{16_384} bytes; findings that do not fit are counted in one line.

  Production caller: none until the publisher (TRD-021).
  """

  alias ForemanServer.Coordinator.Redact

  @marker_prefix "<!-- foreman:pr-report v1 "
  @max_text 500
  @max_body_bytes 16_384
  @max_listed 20
  @zwsp "\u200B"
  @levels ~w(LOW MEDIUM HIGH)
  @severity_rank %{"critical" => 0, "major" => 1, "minor" => 2, "nitpick" => 3}

  @type error ::
          :redaction_failed | :redaction_unavailable | :invalid_record | :report_too_large

  @doc "The fixed start of the first line of every report."
  @spec marker_prefix() :: String.t()
  def marker_prefix, do: @marker_prefix

  @doc "The byte budget of a report body."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "The first line of a report for `run_id`, `head_sha` and the record's `digest`."
  @spec marker(String.t(), String.t(), String.t()) :: String.t()
  def marker(run_id, head_sha, digest)
      when is_binary(run_id) and is_binary(head_sha) and is_binary(digest) do
    @marker_prefix <> "run=#{run_id} head=#{head_sha} digest=#{digest} -->"
  end

  @doc """
  Reads the marker of a body from its FIRST line only: `{:ok, %{run_id, head_sha, digest}}`, or
  `:error` for any body whose first line is not exactly a marker.
  """
  @spec parse_marker(String.t()) ::
          {:ok, %{run_id: String.t(), head_sha: String.t(), digest: String.t()}} | :error
  def parse_marker(body) when is_binary(body) do
    [first | _rest] = String.split(body, "\n", parts: 2)

    case Regex.run(marker_line(), String.trim_trailing(first, "\r")) do
      [_line, run_id, head_sha, digest] ->
        {:ok, %{run_id: run_id, head_sha: head_sha, digest: digest}}

      nil ->
        :error
    end
  end

  @doc "Renders the report of `record`. See the module doc for the answers."
  @spec render(map(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def render(record, opts) when is_map(record) and is_list(opts) do
    with {:ok, secrets} <- secrets(opts),
         {:ok, run_id, head_sha, digest, level} <- identity(record) do
      body = build(record, run_id, head_sha, digest, level, secrets)
      finish(body, secrets)
    end
  end

  @doc """
  Makes untrusted text inert in a GitHub markdown body: `&`, `<` and `>` become entities,
  markdown control characters are backslash-escaped, line breaks become one space, control and
  invisible characters are dropped and a mention (`@`), an issue reference (`#`), a URL scheme
  (`://`) or `www.` is broken with a zero-width space.
  """
  @spec neutralise(String.t()) :: String.t()
  def neutralise(text) when is_binary(text) do
    text
    |> String.replace_invalid("")
    |> String.replace(~r/[\n\r\t\x{B}\x{C}\x{85}\x{2028}\x{2029}]+/u, " ")
    |> String.replace(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, "")
    |> String.replace(~r/[&<>\\`*_\[\]()!|~#@]|:\/\/|www\./iu, &escape/1)
  end

  defp escape("&"), do: "&amp;"
  defp escape("<"), do: "&lt;"
  defp escape(">"), do: "&gt;"
  defp escape("@"), do: "@" <> @zwsp
  defp escape("#"), do: "\\#" <> @zwsp
  defp escape("://"), do: ":" <> @zwsp <> "//"

  defp escape(<<w, w2, w3, ".">>) when w in [?w, ?W] and w2 in [?w, ?W] and w3 in [?w, ?W],
    do: <<w, w2, w3>> <> @zwsp <> "."

  defp escape(char), do: "\\" <> char

  # -- the body ---------------------------------------------------------------------------

  defp identity(record) do
    run_id = get(record, :run_id)
    head_sha = get(record, :head_sha)
    digest = get(record, :digest)
    level = get(record, :level)

    if Enum.all?([run_id, head_sha, digest], &safe_token?/1) and level in @levels do
      {:ok, run_id, head_sha, digest, level}
    else
      {:error, :invalid_record}
    end
  end

  defp safe_token, do: ~r/\A[A-Za-z0-9._:\-]+\z/

  defp marker_line,
    do:
      ~r/\A<!-- foreman:pr-report v1 run=([A-Za-z0-9._:\-]+) head=([A-Za-z0-9._:\-]+) digest=([A-Za-z0-9._:\-]+) -->\z/

  defp safe_token?(value), do: is_binary(value) and Regex.match?(safe_token(), value)

  defp secrets(opts) do
    case Keyword.fetch(opts, :secrets) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, Enum.reject(list, &(&1 == ""))},
          else: {:error, :redaction_unavailable}

      _other ->
        {:error, :redaction_unavailable}
    end
  end

  defp build(record, run_id, head_sha, digest, level, secrets) do
    closed = &neutralise(text(&1))
    free = &free_text(&1, secrets)

    head =
      [
        marker(run_id, head_sha, digest),
        "",
        "## Foreman PR risk report: #{closed.(level)}",
        "",
        "- Head: #{closed.(head_sha)}",
        "- Rubric version: #{closed.(get(record, :rubric_version))}",
        "- Report digest: #{closed.(digest)}",
        "",
        "Foreman classified this head from machine-observed facts and from claims an agent wrote " <>
          "(each line below says which). This report is advisory: approval stays a human decision.",
        "",
        "### Rationale",
        ""
      ] ++
        rationale(record, closed, free) ++
        ["", "### Evidence", ""] ++ evidence(record, closed, free)

    tail =
      ["", "### Instructions", ""] ++
        instructions(record, free) ++
        [
          "",
          "Findings and the model judgement are claims written by an agent, not proof that a check ran."
        ]

    findings = sort_findings(list(get(record, :unresolved_findings)))
    fixed = Enum.join(head ++ tail, "\n")

    findings_section(findings, byte_size(fixed), closed, free)
    |> assemble(head, tail)
  end

  defp assemble(section, head, tail),
    do: Enum.join(head ++ section ++ tail, "\n")

  defp rationale(record, closed, free) do
    lines =
      record
      |> get(:rationale)
      |> list()
      |> Enum.map(fn line ->
        "- [#{basis(get(line, :basis), closed)}] #{closed.(get(line, :rule))} " <>
          "(#{closed.(get(line, :level))}): #{free.(get(line, :detail))}"
      end)

    capped(lines, "rationale lines")
  end

  defp basis("machine", _closed), do: "machine-observed"
  defp basis("agent_claim", _closed), do: "agent-authored"
  defp basis(other, closed), do: closed.(other)

  defp evidence(record, closed, free) do
    evidence = get(record, :evidence)
    checks = get(evidence, :checks)
    findings = get(evidence, :findings)
    judgement = get(record, :judgement) || get(evidence, :judgement)
    files = get(evidence, :files)
    reasons = checks |> get(:reasons) |> list() |> Enum.map(closed)

    [
      "- Required checks: #{closed.(get(checks, :status))}" <>
        if(reasons == [],
          do: "",
          else: " (reason codes: #{Enum.join(Enum.take(reasons, @max_listed), ", ")})"
        ),
      "- Changed files: #{closed.(get(files, :changed))} " <>
        "(listed: #{closed.(get(files, :listed))}, incomplete: #{closed.(get(files, :incomplete))}), " <>
        "additions #{closed.(get(files, :additions))}, deletions #{closed.(get(files, :deletions))}",
      "- Review findings (agent-authored): #{findings_line(findings, closed)}",
      "- Model judgement (agent-authored): #{judgement_line(judgement, closed)}"
    ] ++ sensitive(get(evidence, :sensitive_hits), closed, free)
  end

  defp findings_line(%{} = findings, closed) do
    unresolved =
      case get(findings, :unresolved) do
        %{} = counts when map_size(counts) > 0 ->
          ", unresolved " <>
            (counts
             |> Enum.sort_by(fn {severity, _n} -> to_string(severity) end)
             |> Enum.map_join(", ", fn {severity, n} -> "#{closed.(severity)} #{closed.(n)}" end))

        _none ->
          ""
      end

    "status #{closed.(get(findings, :status))}" <>
      defect(get(findings, :defect), closed) <> unresolved
  end

  defp findings_line(_none, _closed), do: "no record"

  defp judgement_line(%{} = judgement, closed) do
    level = get(judgement, :level)

    "status #{closed.(get(judgement, :status))}" <>
      if(level in [nil, ""], do: "", else: ", level #{closed.(level)}") <>
      defect(get(judgement, :defect), closed)
  end

  defp judgement_line(_none, _closed), do: "none"

  defp defect(value, _closed) when value in [nil, ""], do: ""
  defp defect(value, closed), do: ", defect #{closed.(value)}"

  defp sensitive(hits, closed, free) do
    hits = list(hits)

    case hits do
      [] ->
        []

      hits ->
        shown =
          hits
          |> Enum.take(@max_listed)
          |> Enum.map(&"  - #{free.(get(&1, :path))} (#{closed.(get(&1, :group))})")

        rest = length(hits) - length(shown)

        ["- Sensitive paths touched:"] ++
          shown ++ if(rest > 0, do: ["  - and #{rest} more"], else: [])
    end
  end

  defp instructions(record, free) do
    lines = record |> get(:instructions) |> list() |> Enum.map(&"- #{free.(&1)}")
    capped(if(lines == [], do: ["- None."], else: lines), "instructions")
  end

  defp capped(lines, what) do
    case Enum.split(lines, @max_listed) do
      {shown, []} -> shown
      {shown, rest} -> shown ++ ["- and #{length(rest)} more #{what}"]
    end
  end

  # -- findings, within the byte budget -----------------------------------------------------

  defp sort_findings(findings) do
    findings
    |> Enum.with_index()
    |> Enum.sort_by(fn {finding, index} ->
      {Map.get(@severity_rank, text(get(finding, :severity)), map_size(@severity_rank)), index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp findings_section(findings, fixed_bytes, closed, free) do
    header = ["", "### Unresolved findings (agent-authored claims, not verified)", ""]
    header_bytes = byte_size(Enum.join(header, "\n")) + 1

    if findings == [] do
      header ++ ["None recorded."]
    else
      lines = Enum.map(findings, &finding_line(&1, closed, free))
      reserve = byte_size(count_line(length(lines))) + 2
      budget = @max_body_bytes - fixed_bytes - header_bytes - reserve

      {shown, _spent} =
        Enum.reduce_while(lines, {[], 0}, fn line, {acc, spent} ->
          cost = byte_size(line) + 1

          if spent + cost <= budget,
            do: {:cont, {[line | acc], spent + cost}},
            else: {:halt, {acc, spent}}
        end)

      shown = Enum.reverse(shown)
      rest = length(lines) - length(shown)
      header ++ shown ++ if(rest > 0, do: ["", count_line(rest)], else: [])
    end
  end

  defp count_line(rest), do: "#{rest} more unresolved findings are not shown here."

  defp finding_line(finding, closed, free) do
    line = get(finding, :line)
    location = free.(get(finding, :path)) <> if(is_integer(line), do: ":#{line}", else: "")
    source = get(finding, :source)

    "- #{closed.(get(finding, :severity))}, #{closed.(get(finding, :disposition))}: " <>
      "#{location}: #{free.(get(finding, :description))}" <>
      if(source in [nil, ""], do: "", else: " (source: #{free.(source)})")
  end

  # -- redaction, cut and scan --------------------------------------------------------------

  defp free_text(value, secrets) do
    raw = value |> text() |> String.replace_invalid("") |> String.slice(0, 4 * @max_text)
    raw = Redact.text(nil, raw, secrets: secrets)
    whole = neutralise(raw)

    if String.length(whole) <= @max_text, do: whole, else: cut(raw, @max_text - 1)
  end

  # The longest prefix of `raw` whose neutralised form fits in @max_text - 1 characters (the
  # length of a neutralised prefix never shrinks as the prefix grows), then the ellipsis.
  defp cut(raw, cap) do
    {_length, text} = longest_fit(raw, 0, cap, {0, ""})
    text <> "…"
  end

  defp longest_fit(_raw, low, high, best) when low > high, do: best

  defp longest_fit(raw, low, high, best) do
    mid = div(low + high, 2)
    candidate = neutralise(String.slice(raw, 0, mid))

    if String.length(candidate) <= @max_text - 1,
      do: longest_fit(raw, mid + 1, high, {mid, candidate}),
      else: longest_fit(raw, low, mid - 1, best)
  end

  defp finish(body, secrets) do
    cond do
      byte_size(body) > @max_body_bytes -> {:error, :report_too_large}
      Enum.any?(secrets, &String.contains?(body, &1)) -> {:error, :redaction_failed}
      true -> {:ok, body}
    end
  end

  # -- accessors -----------------------------------------------------------------------------

  defp list(value) when is_list(value), do: value
  defp list(_other), do: []

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp text(value), do: inspect(value)
end
