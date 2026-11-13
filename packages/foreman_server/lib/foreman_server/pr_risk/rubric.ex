defmodule ForemanServer.PrRisk.Rubric do
  @moduledoc """
  Rubric v1 (TRD-016): a pure, table-driven classification of one PR head as `"LOW"`,
  `"MEDIUM"` or `"HIGH"`. It reads no network, clock or store: every input arrives in
  `%Inputs{}` and the same inputs give the same `%Result{}`.

  The level is the maximum over all rule rows. The *machine* rules (`checks`, `files`, `lines`,
  `paths`, `sensitive_path`, `base_branch`) set the floor; the rules over what the review agent
  wrote (`findings`, `unresolved`, `judgement`, basis `"agent_claim"`) can only raise the level
  above that floor. A judgement below the floor changes nothing but its own rationale line.

  The thresholds and the sensitive-path table are those of the TRD section 11 and are v1 for
  this repository's own paths; on another repository only the machine rules that do not read
  the table apply in practice. A file renamed out of a sensitive prefix is listed under its new
  path only, so it is not seen.

  ## `%Inputs{}`

    * `head_sha` (`String.t() | nil`) - the head the decision is about. `nil` makes the
      findings and the judgement count as for another head.
    * `files` (`[%{path, additions, deletions}] | nil`) - the listed items of
      `Github.PrStatus` (`nil` when the path evidence is unavailable). Keys may be atoms or
      strings. Sensitive hits are computed from the paths here, never read from a payload.
    * `changed_files`, `additions`, `deletions` (`non_neg_integer() | nil`) - the counts of
      `Github.PrStatus`. The path list is complete only when `files` is a list, `changed_files`
      is an integer and the list is not shorter than it. A missing count is HIGH (unknown size).
    * `checks` (`%{status: :off | :eligible | :ineligible | :unknown | :waived, reasons: [r]} | nil`)
      - the check part of `PrEvidence.evaluate_checks/2`, read without the waiver. A reason `r`
      is a `PrEvidence.Reason`, a map with `:code`, an atom or a string. `nil` is `:unknown`.
    * `findings` (`map() | nil`) - the folded `evidence.findings` record of the PR: `head_sha`,
      `status` (`"recorded" | "absent" | "malformed"`), `defect` and `findings` (a list of
      finding maps with `severity` and `disposition`). `nil` is "not recorded". A record whose
      `head_sha` is not the decided head is HIGH (other head); `defect` `"legacy_format"` is
      HIGH (earlier format). Unresolved counts come from `Workflow.ReviewFindings.unresolved/1`.
    * `base_branch` (`String.t() | nil`) - the PR's base branch.
    * `recorded_base` (`String.t() | nil`) - the run's recorded base; `nil` is HIGH.
    * `judgement` (`map() | nil`) - `%{status: "recorded" | "absent" | "malformed" | "other_head",
      level: "LOW" | "MEDIUM" | "HIGH" | nil}` (the `judgement` of the folded findings record),
      with an optional `head_sha`. Without its own `head_sha` it is bound to the head of
      `findings`. `nil` is missing. Anything but a recorded level for this head is HIGH.

  Atom or string keys and atom or string status values are both read, so the live and the
  replayed fold give one answer.
  """

  alias ForemanServer.Workflow.ReviewFindings
  alias ForemanServer.Workflow.ReviewFindings.Finding

  @version "1"

  # Section 11 thresholds: the last LOW value and the last MEDIUM value (HIGH above).
  @max_low_files 10
  @max_medium_files 25
  @max_low_lines 200
  @max_medium_lines 800

  @levels ["LOW", "MEDIUM", "HIGH"]
  @rank %{"LOW" => 0, "MEDIUM" => 1, "HIGH" => 2}

  @machine_rules ["checks", "files", "lines", "paths", "sensitive_path", "base_branch"]
  @agent_rules ["findings", "unresolved", "judgement"]

  @lib "packages/foreman_server/lib/foreman_server/"

  # Section 11 sensitive-path table v1, in full repository-relative form.
  @prefix_groups [
    {"CI", [".github/workflows/"]},
    {"CI scripts", ["scripts/ci/"]},
    {"Runtime configuration", ["packages/foreman_server/config/"]},
    {"Migrations", ["packages/foreman_server/priv/repo/migrations/"]},
    {"Bundled workflows and prompts", ["packages/foreman_server/priv/defaults/workflows/"]},
    {"Merge, approval and effect code", [@lib <> "idempotency/"]},
    {"Evidence, risk and report code", [@lib <> "pr_risk/", @lib <> "pr_report/"]},
    {"Authentication and secrets", ["packages/foreman_server/lib/foreman_server_web/plugs/"]}
  ]

  @exact_groups [
    {"Merge, approval and effect code",
     Enum.map(
       [
         "aggregates/run.ex",
         "pr_gate.ex",
         "run_pr_merge.ex",
         "command_gateway.ex",
         "github/pr_merge.ex",
         "workflow/approver_authorizer.ex",
         "workflow/merge_gate.ex"
       ],
       &(@lib <> &1)
     )},
    {"Evidence, risk and report code",
     Enum.map(
       [
         "pr_evidence.ex",
         "pr_observation.ex",
         "pr_watch_fold.ex",
         "pr_risk.ex",
         "pr_report.ex",
         "aggregates/run/pr_watch.ex",
         "github/pr_status.ex",
         "workflow/review_findings.ex"
       ],
       &(@lib <> &1)
     )},
    {"Authentication and secrets",
     Enum.map(
       [
         "mcp/auth.ex",
         "mcp/policy.ex",
         "aggregates/project_secret.ex",
         "config_providers/secrets.ex"
       ],
       &(@lib <> &1)
     )}
  ]

  @base_name_groups [
    {"Instruction files", ["AGENTS.md", "CLAUDE.md"]},
    {"Dependency and build manifests",
     [
       "mix.exs",
       "mix.lock",
       "go.mod",
       "package.json",
       "package-lock.json",
       "devbox.json",
       "devbox.lock",
       "Dockerfile",
       "docker-compose.yml"
     ]}
  ]

  # Fixed reviewer text per rule: never model text.
  @instructions %{
    "checks" =>
      "Required checks are not all passing for this head (gate off, none configured, not passing, truncated or waived): read the check list before approving.",
    "files" => "The PR changes many files: confirm the change is one logical unit.",
    "lines" => "The PR changes many lines: read the whole diff, not the summary.",
    "paths" =>
      "The list of changed paths is unavailable or incomplete: read the changed files on GitHub.",
    "sensitive_path" =>
      "The PR touches a sensitive path (CI, configuration, migrations, merge or evidence code, instructions, manifests, secrets): review those files line by line.",
    "base_branch" =>
      "The PR base is not the run's recorded base, or no base is recorded: confirm the target branch.",
    "findings" =>
      "The review findings are absent, malformed, in the earlier format or for another head: the review does not vouch for this head.",
    "unresolved" => "The review reports unresolved findings: read each one before approving.",
    "judgement" =>
      "The review agent's risk judgement is missing, malformed, for another head or not LOW: treat it as a claim, not evidence."
  }

  defmodule Inputs do
    @moduledoc "The inputs of `ForemanServer.PrRisk.Rubric.classify/1` (documented there)."
    defstruct files: nil,
              changed_files: nil,
              additions: nil,
              deletions: nil,
              checks: nil,
              findings: nil,
              base_branch: nil,
              recorded_base: nil,
              judgement: nil,
              head_sha: nil

    @type t :: %__MODULE__{
            files: [map()] | nil,
            changed_files: non_neg_integer() | nil,
            additions: non_neg_integer() | nil,
            deletions: non_neg_integer() | nil,
            checks: map() | nil,
            findings: map() | nil,
            base_branch: String.t() | nil,
            recorded_base: String.t() | nil,
            judgement: map() | nil,
            head_sha: String.t() | nil
          }
  end

  defmodule Result do
    @moduledoc """
    The outcome of `classify/1`: `level`, `rubric_version`, `rationale` (one
    `%{rule, level, basis, detail}` per rule, all string-valued), the fixed `instructions` for
    the rules above LOW, the `sensitive_hits` (`[%{path, group}]`) and the `unresolved` counts
    by severity (`nil` when the findings record cannot be counted).
    """
    @derive Jason.Encoder
    defstruct [
      :level,
      :rubric_version,
      rationale: [],
      instructions: [],
      sensitive_hits: [],
      unresolved: nil
    ]

    @type t :: %__MODULE__{
            level: String.t(),
            rubric_version: String.t(),
            rationale: [
              %{rule: String.t(), level: String.t(), basis: String.t(), detail: String.t()}
            ],
            instructions: [String.t()],
            sensitive_hits: [%{path: String.t(), group: String.t()}],
            unresolved: %{atom() => non_neg_integer()} | nil
          }
  end

  @doc "The rubric version recorded with every result."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The sensitive group a repository-relative path belongs to, or `nil`."
  @spec sensitive_group(term()) :: String.t() | nil
  def sensitive_group(path) when is_binary(path) do
    base = Path.basename(path)

    cond do
      group = prefix_group(path) ->
        group

      group = exact_group(path) ->
        group

      group = base_name_group(base) ->
        group

      String.contains?(String.downcase(base), "secret") or String.starts_with?(base, ".env") ->
        "Secret-like names"

      true ->
        nil
    end
  end

  def sensitive_group(_other), do: nil

  @doc "Classify `inputs` (see the moduledoc)."
  @spec classify(Inputs.t()) :: Result.t()
  def classify(%Inputs{} = inputs) do
    hits = sensitive_hits(inputs.files)
    findings = findings_view(inputs)
    unresolved = unresolved_counts(findings)

    rules =
      [
        checks_rule(inputs.checks),
        files_rule(inputs),
        lines_rule(inputs),
        paths_rule(inputs),
        sensitive_rule(hits),
        base_rule(inputs),
        findings_rule(findings)
      ] ++
        unresolved_rule(unresolved) ++
        [judgement_rule(inputs, findings)]

    level = rules |> Enum.map(& &1.level) |> Enum.max_by(&Map.fetch!(@rank, &1))

    instructions =
      rules
      |> Enum.reject(&(&1.level == "LOW"))
      |> Enum.map(&Map.fetch!(@instructions, &1.rule))

    %Result{
      level: level,
      rubric_version: @version,
      rationale: rules,
      instructions: instructions,
      sensitive_hits: hits,
      unresolved: unresolved
    }
  end

  @doc "The rule names, machine rules first."
  @spec rules() :: [String.t()]
  def rules, do: @machine_rules ++ @agent_rules

  # -- sensitive paths --------------------------------------------------------------------

  defp sensitive_hits(files) when is_list(files) do
    files
    |> Enum.flat_map(fn file ->
      path = get(file, :path)

      case sensitive_group(path) do
        nil -> []
        group -> [%{path: path, group: group}]
      end
    end)
    |> Enum.uniq()
  end

  defp sensitive_hits(_unavailable), do: []

  defp prefix_group(path) do
    Enum.find_value(@prefix_groups, fn {group, prefixes} ->
      if Enum.any?(prefixes, &String.starts_with?(path, &1)), do: group
    end)
  end

  defp exact_group(path) do
    Enum.find_value(@exact_groups, fn {group, paths} -> if path in paths, do: group end)
  end

  defp base_name_group(base) do
    Enum.find_value(@base_name_groups, fn {group, names} -> if base in names, do: group end)
  end

  # -- machine rules ----------------------------------------------------------------------

  defp checks_rule(checks) do
    status = checks |> get(:status) |> atomize()
    codes = checks |> get(:reasons) |> reason_codes()

    case status do
      :eligible ->
        rule("checks", "LOW", "machine", "required checks all passing, not waived")

      :off ->
        rule("checks", "HIGH", "machine", "the required-checks gate is off for this project")

      :waived ->
        rule("checks", "HIGH", "machine", "required checks are waived: " <> join(codes))

      :ineligible ->
        rule("checks", "HIGH", "machine", "required checks not passing: " <> join(codes))

      _unknown ->
        rule("checks", "HIGH", "machine", "required checks could not be read: " <> join(codes))
    end
  end

  defp files_rule(inputs) do
    case file_count(inputs) do
      nil ->
        rule("files", "HIGH", "machine", "the number of changed files is unavailable")

      n when n <= @max_low_files ->
        rule("files", "LOW", "machine", "#{n} changed files (at most #{@max_low_files})")

      n when n <= @max_medium_files ->
        rule(
          "files",
          "MEDIUM",
          "machine",
          "#{n} changed files (#{@max_low_files + 1} to #{@max_medium_files})"
        )

      n ->
        rule("files", "HIGH", "machine", "#{n} changed files (more than #{@max_medium_files})")
    end
  end

  defp lines_rule(inputs) do
    case line_count(inputs) do
      nil ->
        rule("lines", "HIGH", "machine", "the number of changed lines is unavailable")

      n when n <= @max_low_lines ->
        rule(
          "lines",
          "LOW",
          "machine",
          "#{n} lines added plus deleted (at most #{@max_low_lines})"
        )

      n when n <= @max_medium_lines ->
        rule(
          "lines",
          "MEDIUM",
          "machine",
          "#{n} lines added plus deleted (#{@max_low_lines + 1} to #{@max_medium_lines})"
        )

      n ->
        rule(
          "lines",
          "HIGH",
          "machine",
          "#{n} lines added plus deleted (more than #{@max_medium_lines})"
        )
    end
  end

  defp file_count(%Inputs{changed_files: n}) when is_integer(n) and n >= 0, do: n
  defp file_count(%Inputs{files: files}) when is_list(files), do: length(files)
  defp file_count(_inputs), do: nil

  defp line_count(%Inputs{additions: a, deletions: d})
       when is_integer(a) and is_integer(d) and a >= 0 and d >= 0,
       do: a + d

  defp line_count(_inputs), do: nil

  defp paths_rule(%Inputs{files: files, changed_files: changed}) do
    cond do
      not is_list(files) ->
        rule("paths", "HIGH", "machine", "the changed-path list is unavailable")

      not (is_integer(changed) and changed >= 0) ->
        rule(
          "paths",
          "HIGH",
          "machine",
          "the changed-file count is unavailable, so the path list cannot be checked for completeness"
        )

      length(files) < changed ->
        rule(
          "paths",
          "HIGH",
          "machine",
          "the path list is incomplete: #{length(files)} of #{changed} files listed"
        )

      true ->
        rule(
          "paths",
          "LOW",
          "machine",
          "the path list is complete (#{length(files)} of #{changed})"
        )
    end
  end

  defp sensitive_rule([]),
    do: rule("sensitive_path", "LOW", "machine", "no sensitive path touched")

  defp sensitive_rule(hits) do
    detail =
      hits
      |> Enum.map_join("; ", fn %{path: path, group: group} -> "#{group}: #{path}" end)

    rule("sensitive_path", "HIGH", "machine", "sensitive path touched: " <> detail)
  end

  defp base_rule(%Inputs{recorded_base: nil}),
    do: rule("base_branch", "HIGH", "machine", "no base branch is recorded for the run")

  defp base_rule(%Inputs{base_branch: base, recorded_base: base}) when is_binary(base),
    do: rule("base_branch", "LOW", "machine", "base is the run's recorded base #{inspect(base)}")

  defp base_rule(%Inputs{base_branch: base, recorded_base: recorded}),
    do:
      rule(
        "base_branch",
        "HIGH",
        "machine",
        "base #{inspect(base)} differs from the run's recorded base #{inspect(recorded)}"
      )

  # -- findings and judgement (agent claims) -----------------------------------------------

  # {:usable, findings} | {:unusable, label, detail}
  defp findings_view(%Inputs{findings: findings, head_sha: head}) do
    cond do
      not is_map(findings) ->
        {:unusable, "missing", "no review findings are recorded"}

      get(findings, :head_sha) != head or not is_binary(head) ->
        {:unusable, "other_head", "the findings were recorded for another head"}

      true ->
        case {to_string_or_nil(get(findings, :status)), to_string_or_nil(get(findings, :defect))} do
          {"recorded", _defect} ->
            case get(findings, :findings) do
              list when is_list(list) -> {:usable, list}
              _other -> {:unusable, "malformed", "the findings record has no finding list"}
            end

          {"absent", _defect} ->
            {:unusable, "absent", "the review wrote no findings block"}

          {"malformed", "legacy_format"} ->
            {:unusable, "legacy_format", "the findings are in the earlier format"}

          {"malformed", defect} ->
            {:unusable, "malformed", "the findings block is malformed (#{defect || "unknown"})"}

          {_status, _defect} ->
            {:unusable, "malformed", "the findings record has no usable status"}
        end
    end
  end

  defp findings_rule({:usable, list}),
    do:
      rule("findings", "LOW", "agent_claim", "findings recorded for this head (#{length(list)})")

  defp findings_rule({:unusable, label, detail}),
    do: rule("findings", "HIGH", "agent_claim", "#{label}: #{detail}")

  defp unresolved_counts({:usable, list}) do
    list
    |> Enum.map(&to_finding/1)
    |> ReviewFindings.unresolved()
  end

  defp unresolved_counts(_unusable), do: nil

  defp unresolved_rule(nil), do: []

  defp unresolved_rule(%{critical: c, major: ma, minor: mi, nitpick: n}) do
    summary = "unresolved: #{c} critical, #{ma} major, #{mi} minor, #{n} nitpick"

    level =
      cond do
        c + ma > 0 -> "HIGH"
        mi > 0 -> "MEDIUM"
        true -> "LOW"
      end

    [rule("unresolved", level, "agent_claim", summary)]
  end

  # Unknown values count as an open critical finding: the closed sets are enforced on
  # recording, so this only fires on a corrupt record, and fails closed.
  defp to_finding(item) do
    %Finding{
      severity: severity(get(item, :severity)),
      path: "",
      line: nil,
      description: "",
      disposition: disposition(get(item, :disposition)),
      source: ""
    }
  end

  defp severity(v) when v in [:critical, :major, :minor, :nitpick], do: v
  defp severity("major"), do: :major
  defp severity("minor"), do: :minor
  defp severity("nitpick"), do: :nitpick
  defp severity(_other), do: :critical

  defp disposition(v) when v in [:fixed, :declined, :open], do: v
  defp disposition("fixed"), do: :fixed
  defp disposition("declined"), do: :declined
  defp disposition(_other), do: :open

  defp judgement_rule(%Inputs{judgement: judgement, head_sha: head}, findings) do
    own_head = get(judgement, :head_sha)

    cond do
      not is_map(judgement) ->
        judgement_high("missing", "no judgement is recorded")

      to_string_or_nil(get(judgement, :status)) == "other_head" ->
        judgement_high("other_head", "the judgement is for another head")

      own_head != nil and own_head != head ->
        judgement_high("other_head", "the judgement is for another head")

      own_head == nil and match?({:unusable, "other_head", _}, findings) ->
        judgement_high("other_head", "the judgement is for another head")

      own_head == nil and match?({:unusable, "missing", _}, findings) ->
        judgement_high("missing", "no judgement is recorded")

      true ->
        judged(
          to_string_or_nil(get(judgement, :status)),
          to_string_or_nil(get(judgement, :level))
        )
    end
  end

  defp judged("recorded", level) when level in @levels,
    do: rule("judgement", level, "agent_claim", "the review judged #{level}")

  defp judged("recorded", _level),
    do: judgement_high("malformed", "the judgement has no valid level")

  defp judged("absent", _level), do: judgement_high("missing", "the review wrote no judgement")
  defp judged(_status, _level), do: judgement_high("malformed", "the judgement is malformed")

  defp judgement_high(label, detail),
    do: rule("judgement", "HIGH", "agent_claim", "#{label}: #{detail}")

  # -- helpers ----------------------------------------------------------------------------

  defp rule(rule, level, basis, detail),
    do: %{rule: rule, level: level, basis: basis, detail: detail}

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil

  defp atomize(status) when is_atom(status), do: status
  defp atomize("eligible"), do: :eligible
  defp atomize("off"), do: :off
  defp atomize("waived"), do: :waived
  defp atomize("ineligible"), do: :ineligible
  defp atomize(_other), do: :unknown

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v) when is_atom(v), do: Atom.to_string(v)
  defp to_string_or_nil(v) when is_binary(v), do: v
  defp to_string_or_nil(_other), do: nil

  defp reason_codes(reasons) when is_list(reasons) do
    Enum.map(reasons, fn
      %{} = reason -> to_string_or_nil(get(reason, :code)) || "unknown"
      other -> to_string_or_nil(other) || "unknown"
    end)
  end

  defp reason_codes(_other), do: []

  defp join([]), do: "no reason recorded"
  defp join(codes), do: Enum.join(codes, ", ")
end
