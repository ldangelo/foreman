defmodule ForemanServer.PrReport do
  @moduledoc """
  TRD-019: the body of the PR comment that reports one head's risk record.

  `render/2` is pure over a risk record (`PrRiskRecorded`, TRD-018: the event struct or a map of
  its fields, atom or string keys) and the project's secret values (`secrets:`, required; the
  caller resolves them with `ProjectEnvironment.fetch_secrets/1` and does not render when that
  returns an error, because `Coordinator.Redact.secrets/1` would answer `[]` and publish under
  the built-in patterns alone). It answers `{:ok, body}` or

    * `{:error, :redaction_failed}`: a listed secret value is in the finished body, or in a
      closed field before it was escaped (redaction is its own control: the body is scanned
      for every listed value, for its escaped form and for the closed fields as written);
    * `{:error, :redaction_unavailable}`: `secrets:` is missing or not a list of strings;
    * `{:error, :invalid_record}`: the record lacks a `run_id`, `head_sha` or `digest` that is
      safe to put in the marker line, or a `level` outside LOW, MEDIUM and HIGH;
    * `{:error, :report_too_large}`: the fixed skeleton of the report alone exceeds the budget
      (not reachable: every closed value is cut to #{48} characters and every list is
      fitted into the budget).

  The first line is the marker (`marker/3`) carrying the run, head and the record's digest; it
  is never part of a cut. The body states the level, `rubric_version`, the rationale with the
  basis of each line, the evidence (reason codes, sizes, sensitive paths), the unresolved
  findings (most severe first) and the instructions. Findings and the model judgement are
  labelled as claims an agent wrote; approval stays a human decision.

  Every free-text value (a finding's description, path and source, a rationale detail, a
  sensitive path, an instruction) is untrusted text: it passes `Coordinator.Redact.text/3` with
  the explicit list (the whole value, then once more with invisible characters removed), is cut
  to #{500} characters and is neutralised by `neutralise/1`. Closed vocabulary fields (level,
  rule names, reason codes, counts) are only neutralised and cut to #{48} characters, so a
  secret that reaches one is caught by the scan and not hidden. The body is at most
  #{16_384} bytes (bytes, not characters): the rationale, sensitive paths, findings and
  instructions are listed in that order of the layout while they fit their share of what the
  fixed skeleton leaves, and each list that is cut ends with a count of the rest.

  Production caller: none until the publisher (TRD-021).
  """

  alias ForemanServer.Coordinator.Redact

  @marker_prefix "<!-- foreman:pr-report v1 "
  @max_text 500
  @max_body_bytes 16_384
  @max_listed 20
  @max_closed 48
  @max_token 128
  @count_reserve 120
  @hits_header "- Sensitive paths touched:"
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
      parts = parts(record, run_id, head_sha, digest, level, &closed/1, &free_text(&1, secrets))
      # The same record with every closed value as written (no escape, no cut) and no free text:
      # what the closed fields really hold, for the scan.
      raw =
        parts(record, run_id, head_sha, digest, level, &text/1, fn _value -> "" end)
        |> Map.values()
        |> List.flatten()
        |> Enum.join("\n")

      with {:ok, body} <- compose(parts), do: scan(body, raw, secrets)
    end
  end

  @doc """
  Makes untrusted text inert in a GitHub markdown body: `&`, `<` and `>` become entities,
  markdown control characters are backslash-escaped, line breaks become one space, control and
  invisible characters are dropped, and a mention (`@`), an issue reference (`#`, `GH-12`), a URL
  scheme (`://`), `www.` or an emoji shortcode (`:name:`) is broken with a zero-width space.
  """
  @spec neutralise(String.t()) :: String.t()
  def neutralise(text) when is_binary(text) do
    text
    |> String.replace_invalid("")
    |> String.replace(~r/[\n\r\t\x{B}\x{C}\x{85}\x{2028}\x{2029}]+/u, " ")
    |> String.replace(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, "")
    |> String.replace(
      ~r/[&<>\\`*_\[\]()!|~#@$]|:\/\/|www\.|gh-(?=\d)|:(?=[A-Za-z0-9_+\-]+:)/iu,
      &escape/1
    )
  end

  defp escape("&"), do: "&amp;"
  defp escape("<"), do: "&lt;"
  defp escape(">"), do: "&gt;"
  defp escape("@"), do: "@" <> @zwsp
  defp escape("#"), do: "\\#" <> @zwsp
  defp escape("://"), do: ":" <> @zwsp <> "//"
  defp escape(":"), do: ":" <> @zwsp

  defp escape(<<w, w2, w3, ".">>) when w in [?w, ?W] and w2 in [?w, ?W] and w3 in [?w, ?W],
    do: <<w, w2, w3>> <> @zwsp <> "."

  defp escape(<<g, h, "-">>) when g in [?g, ?G] and h in [?h, ?H], do: <<g, h>> <> "-" <> @zwsp

  defp escape(char), do: "\\" <> char

  # Control and invisible characters except the three whitespace controls.
  defp strip_invisible(text),
    do: String.replace(text, ~r/(?![\n\r\t])[\p{Cc}\p{Cf}]/u, "")

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

  defp safe_token?(value),
    do: is_binary(value) and byte_size(value) <= @max_token and Regex.match?(safe_token(), value)

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

  # The lines of every section, as lists. `closed` renders a closed-vocabulary value and `free`
  # an untrusted free-text value.
  defp parts(record, run_id, head_sha, digest, level, closed, free) do
    evidence = get(record, :evidence)
    findings = sort_findings(list(get(record, :unresolved_findings)))

    %{
      head: [
        marker(run_id, head_sha, digest),
        "",
        "## Foreman PR risk report: #{closed.(level)}",
        "",
        "- Head: #{closed.(head_sha)}",
        "- Rubric version: #{closed.(get(record, :rubric_version))}",
        "- Report digest: #{closed.(digest)}",
        "",
        "Foreman classified this head from machine-observed facts and from claims an agent wrote " <>
          "(each line below says which). This report is advisory: approval stays a human decision."
      ],
      rationale: rationale(record, closed, free),
      evidence: evidence(record, evidence, closed),
      hits: sensitive(get(evidence, :sensitive_hits), closed, free),
      findings: Enum.map(findings, &finding_line(&1, closed, free)),
      instructions: record |> get(:instructions) |> list() |> Enum.map(&"- #{free.(&1)}")
    }
  end

  defp compose(parts) do
    rationale_head = ["", "### Rationale", ""]
    evidence_head = ["", "### Evidence", ""]
    findings_head = ["", "### Unresolved findings (agent-authored claims, not verified)", ""]
    instructions_head = ["", "### Instructions", ""]

    footer = [
      "",
      "Findings and the model judgement are claims written by an agent, not proof that a check ran."
    ]

    # Everything that is not a list, with each list empty, plus a reserve for four count lines.
    skeleton =
      parts.head ++
        rationale_head ++
        evidence_head ++
        parts.evidence ++
        [@hits_header] ++
        findings_head ++ ["None recorded."] ++ instructions_head ++ ["- None."] ++ footer

    spare = @max_body_bytes - cost(skeleton) - 4 * @count_reserve

    if spare < 0 do
      {:error, :report_too_large}
    else
      {rationale, rationale_rest} = fit(parts.rationale, div(spare * 35, 100))
      {hits, hits_rest} = fit(parts.hits, div(spare * 10, 100))
      {instructions, instructions_rest} = fit(parts.instructions, div(spare * 15, 100))
      left = spare - cost(rationale) - cost(hits) - cost(instructions)
      {findings, findings_rest} = fit(parts.findings, left)

      body =
        Enum.join(
          parts.head ++
            rationale_head ++
            with_rest(rationale, rationale_rest, "rationale lines", "- ", "None recorded.") ++
            evidence_head ++
            parts.evidence ++
            hits_section(hits, hits_rest) ++
            findings_head ++
            with_rest(findings, findings_rest, "unresolved findings", "", "None recorded.") ++
            instructions_head ++
            with_rest(instructions, instructions_rest, "instructions", "- ", "- None.") ++
            footer,
          "\n"
        )

      {:ok, body}
    end
  end

  defp hits_section([], 0), do: []

  defp hits_section(hits, rest),
    do: [@hits_header] ++ with_rest(hits, rest, "sensitive paths", "  - ", nil)

  defp with_rest([], 0, _what, _prefix, empty), do: List.wrap(empty)
  defp with_rest(shown, 0, _what, _prefix, _empty), do: shown

  defp with_rest(shown, rest, what, prefix, _empty),
    do: shown ++ ["", "#{prefix}#{rest} more #{what} are not shown here."]

  # The longest prefix of `lines` (at most @max_listed) within `budget` bytes, and the number of
  # lines left out. Bytes, never characters.
  defp fit(lines, budget) do
    {shown, _spent} =
      lines
      |> Enum.take(@max_listed)
      |> Enum.reduce_while({[], 0}, fn line, {acc, spent} ->
        next = spent + byte_size(line) + 1
        if next <= budget, do: {:cont, {[line | acc], next}}, else: {:halt, {acc, spent}}
      end)

    shown = Enum.reverse(shown)
    {shown, length(lines) - length(shown)}
  end

  defp cost(lines), do: lines |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum()

  defp rationale(record, closed, free) do
    record
    |> get(:rationale)
    |> list()
    |> Enum.map(fn line ->
      "- [#{basis(get(line, :basis), closed)}] #{closed.(get(line, :rule))} " <>
        "(#{closed.(get(line, :level))}): #{free.(get(line, :detail))}"
    end)
  end

  defp basis("machine", _closed), do: "machine-observed"
  defp basis("agent_claim", _closed), do: "agent-authored"
  defp basis(other, closed), do: closed.(other)

  defp evidence(record, evidence, closed) do
    checks = get(evidence, :checks)
    findings = get(evidence, :findings)
    judgement = get(record, :judgement) || get(evidence, :judgement)
    files = get(evidence, :files)
    reasons = checks |> get(:reasons) |> list()
    {listed, unlisted} = Enum.split(reasons, 10)

    [
      "- Required checks: #{closed.(get(checks, :status))}" <>
        if(reasons == [],
          do: "",
          else:
            " (reason codes: #{Enum.map_join(listed, ", ", closed)}" <>
              if(unlisted == [], do: ")", else: " and #{length(unlisted)} more)")
        ),
      "- Changed files: #{closed.(get(files, :changed))} " <>
        "(listed: #{closed.(get(files, :listed))}, incomplete: #{closed.(get(files, :incomplete))}), " <>
        "additions #{closed.(get(files, :additions))}, deletions #{closed.(get(files, :deletions))}",
      "- Review findings (agent-authored): #{findings_line(findings, closed)}",
      "- Model judgement (agent-authored): #{judgement_line(judgement, closed)}"
    ]
  end

  defp findings_line(%{} = findings, closed) do
    unresolved =
      case get(findings, :unresolved) do
        %{} = counts when map_size(counts) > 0 ->
          ", unresolved " <>
            (counts
             |> Enum.sort_by(fn {severity, _n} -> to_string(severity) end)
             |> Enum.take(6)
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

  # Lines of one list: the header, then one line per path.
  defp sensitive(hits, closed, free) do
    list(hits)
    |> Enum.map(&"  - #{free.(get(&1, :path))} (#{closed.(get(&1, :group))})")
  end

  defp sort_findings(findings) do
    findings
    |> Enum.with_index()
    |> Enum.sort_by(fn {finding, index} ->
      {Map.get(@severity_rank, text(get(finding, :severity)), map_size(@severity_rank)), index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp finding_line(finding, closed, free) do
    line = get(finding, :line)
    location = free.(get(finding, :path)) <> if(is_integer(line), do: ":#{line}", else: "")
    source = get(finding, :source)

    "- #{closed.(get(finding, :severity))}, #{closed.(get(finding, :disposition))}: " <>
      "#{location}: #{free.(get(finding, :description))}" <>
      if(source in [nil, ""], do: "", else: " (source: #{free.(source)})")
  end

  # -- redaction, cut and scan --------------------------------------------------------------

  defp closed(value), do: value |> text() |> bounded(@max_closed)

  # The WHOLE value is redacted before anything is cut, and a second time with the invisible
  # characters removed (a secret with a zero-width space inside is not the listed value, but
  # neutralising would turn it into the listed value).
  defp free_text(value, secrets) do
    redacted = value |> text() |> String.replace_invalid("") |> redact(secrets)
    bounded(redacted, @max_text)
  end

  defp redact(text, secrets) do
    once = Redact.text(nil, text, secrets: secrets)
    Redact.text(nil, strip_invisible(once), secrets: secrets)
  end

  # `raw` neutralised, in at most `limit` characters: the longest prefix whose neutralised form
  # fits in `limit - 1` characters, then the ellipsis.
  defp bounded(raw, limit) do
    whole = neutralise(raw)

    if String.length(whole) <= limit do
      whole
    else
      {_length, prefix} = longest_fit(raw, 0, limit - 1, limit - 1, {0, ""})
      prefix <> "…"
    end
  end

  # Binary search: the neutralised length of a prefix never shrinks as the prefix grows.
  defp longest_fit(_raw, low, high, _max, best) when low > high, do: best

  defp longest_fit(raw, low, high, max, best) do
    mid = div(low + high, 2)
    candidate = neutralise(String.slice(raw, 0, mid))

    if String.length(candidate) <= max,
      do: longest_fit(raw, mid + 1, high, max, {mid, candidate}),
      else: longest_fit(raw, low, mid - 1, max, best)
  end

  # `body` is what would be published and `raw` the closed fields as written. A listed value, its
  # stripped form or its escaped form (neutralising rewrites `_`, `*`, `#`, `@`, ...) in either
  # is a surviving secret.
  defp scan(body, raw, secrets) do
    needles =
      secrets
      |> Enum.flat_map(&[&1, strip_invisible(&1), neutralise(&1)])
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    haystacks = [body, raw, strip_invisible(raw)]

    cond do
      byte_size(body) > @max_body_bytes ->
        {:error, :report_too_large}

      Enum.any?(needles, fn needle -> Enum.any?(haystacks, &String.contains?(&1, needle)) end) ->
        {:error, :redaction_failed}

      true ->
        {:ok, body}
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
