# PLAN — foreman-p0b23: project setting for required PR-body headings

## 1. Verdict

**Real bug (missing feature).** `grep -rn "pr_body_template\|pr_body_headings" --include='*.ex' --include='*.go' --include='*.md' .` → nothing.
The whitelist `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex:47-51` (`@keys`) has no such key, so `project update` answers `{:unknown_setting, ...}`.
The fallback body builder `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex:715-722` (`generated_body/1`) emits a fixed two lines plus the review-findings section; nothing is configurable.

Setting name: **`pr_body_headings`** — a list of heading lines, not a template string. The bead allows either ("or headings-list") and the acceptance sentence is about a headings list; a list reuses the `repo_allowlist` list-setting precedent end to end (repeatable CLI flag, LiveView textarea, `[String.t()] | nil`).

## 2. Root cause

Two additive gaps:
- `Aggregates.Project.Settings` has no key/validator for PR-body headings.
- `auto_pr.ex:659-672` (`pr_content/1`) has exactly two body shapes — the task description verbatim, or `generated_body/1` — and no project can shape either.

## 3. Failing check first

New `packages/foreman_server/test/foreman_server/workflow/pr_body_test.exs` (`ForemanServer.Workflow.PrBodyTest`, `use ExUnit.Case, async: true`), three tests over the new pure renderer, with
`sources = %PrBody.Sources{run_id: "run-1", task_title: "Fix the thing", task_description: "Because X.", artifact_path: nil, findings_section: "", findings_summary: nil, commits: [{"abc1234", "fix: thing"}]}`:
1. `"renders each configured heading with its source content"` — `PrBody.render(["## Summary", "## How to revert", "## Directed by"], sources)` contains `"## Summary"`, `"Because X."`, `"git revert abc1234"`, `` "Foreman run `run-1`" ``, and `:binary.match/2` index of `"## Summary"` < `"## How to revert"`.
2. `"an unknown heading carries an explicit not-recorded line, never empty"` — `PrBody.render(["## Deployment"], sources)` =~ `"## Deployment"` and =~ `"_Not recorded by Foreman._"`.
3. `"no headings renders nothing"` — `PrBody.render([], sources) == ""`.

Plus, in existing `packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs`, test `"a project's pr_body_headings shape the PR body"`: copy helper `generated_body_at/1` (auto_pr_test.exs:288-297 — stubbed `command_runner`, `run_id: "run-12"`, `head_branch: "foreman/run-12/implement"`, `base_branch: "main"`), add `pr_body_headings: ["## Summary", "## Testing"]` to the context and a stub clause `"git", ["log", "--format=%H%x09%s", "main..foreman/run-12/implement"], _opts -> {"abc1234\tfix: thing\n", 0}`; assert the captured `--body` arg =~ `"## Summary"` and =~ `"## Testing"`.

Failing-before (PrBody undefined; body has no headings):
`devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/pr_body_test.exs test/foreman_server/workflow/auto_pr_test.exs'`

Two drift tests also stay red until Edits 3 and 6 land — intended: `test/foreman_server/aggregates/project_settings_test.exs:431` and `test/foreman_server/mcp/tools_project_settings_test.exs:243`.

## 4. Edits

### Edit 1 — new `packages/foreman_server/lib/foreman_server/workflow/pr_body.ex`

One shared module so the phase-PR builder can reuse it later without a copy (AGENTS.md §5.7). Pure: no git, no file reads.

```elixir
defmodule ForemanServer.Workflow.PrBody do
  @moduledoc "Renders a PR body from a project's required headings and the facts Foreman knows."

  defmodule Sources do
    @moduledoc "The facts a PR body may be built from."
    @enforce_keys [:run_id]
    @type t :: %__MODULE__{
            run_id: String.t(),
            task_title: String.t() | nil,
            task_description: String.t() | nil,
            artifact_path: String.t() | nil,
            findings_section: String.t(),
            findings_summary: String.t() | nil,
            commits: [{String.t(), String.t()}]
          }
    defstruct [:run_id, :task_title, :task_description, :artifact_path, :findings_summary,
               findings_section: "", commits: []]
  end

  @unknown "_Not recorded by Foreman._"

  @doc "Renders `headings` in order, each followed by its content. `[]` renders an empty string."
  @spec render([String.t()], Sources.t()) :: String.t()
  def render(headings, %Sources{} = sources) when is_list(headings) do
    Enum.map_join(headings, "\n", fn heading ->
      heading <> "\n\n" <> content(label(heading), sources) <> "\n"
    end)
  end

  # "## How to revert" -> "how to revert"
  defp label(heading), do: heading |> String.trim_leading("#") |> String.trim() |> String.downcase()

  defp content("summary", s),
    do: s.task_description || s.task_title || "Foreman run `#{s.run_id}` complete."

  defp content("testing", s) do
    artifact = if s.artifact_path, do: "Artifact: #{s.artifact_path}\n", else: ""

    case {artifact, String.trim(s.findings_section)} do
      {"", ""} -> "_No phase artifact was recorded for this run._"
      {a, ""} -> a <> "_The phase artifact carries no review findings block._"
      {a, f} -> a <> "\n" <> f
    end
  end

  defp content("risk", s), do: s.findings_summary || @unknown

  defp content("how to revert", %Sources{commits: []}),
    do: "_No commits were recorded for this run._"

  defp content("how to revert", %Sources{commits: commits}),
    do: Enum.map_join(commits, "\n", fn {sha, subj} -> "- `git revert #{sha}`  (#{subj})" end)

  defp content("directed by", s) do
    case s.task_title do
      nil -> "Foreman run `#{s.run_id}`."
      title -> "Foreman run `#{s.run_id}`, task #{title}."
    end
  end

  defp content(_other, _s), do: @unknown

  @doc "Puts `headings` on an AutoPR context, omitting the key when there are none (AGENTS.md §5.3)."
  @spec put_headings(map(), [String.t()] | nil) :: map()
  def put_headings(context, headings) when is_list(headings) and headings != [],
    do: Map.put(context, :pr_body_headings, headings)

  def put_headings(context, _none), do: context
end
```

### Edit 2 — `aggregates/project/settings.ex`

- After `@notification_preferences` (line 45): `@max_pr_body_headings 10` and `@pr_body_heading_regex ~r/\A\#{1,6} \S/`.
- `@keys` (47-51): append `pr_body_headings` to the last line.
- `@type key` (58-76): add `| :pr_body_headings`. `@type error` (78-115): add, before `{:unknown_setting, String.t()}`, the three tuples `{:pr_body_headings_invalid, term()}`, `{:pr_body_headings_too_many, non_neg_integer(), pos_integer()}`, `{:pr_body_heading_invalid, term()}`.
- New validator clauses after the `repo_allowlist` ones (line 316). Copy the `:repo_allowlist` clauses verbatim and rename: `nil -> {:ok, nil}`; the `is_list` clause guarded by `if length(entries) > @max_pr_body_headings, do: {:error, {:pr_body_headings_too_many, length(entries), @max_pr_body_headings}}`, else the same `Enum.reduce_while(entries, {:ok, []}, ...)` calling `heading(entry)` instead of `allowlist_entry(entry)` and halting with `{:error, {:pr_body_heading_invalid, entry}}`, then `{:ok, acc |> Enum.reverse() |> Enum.uniq()}`; catch-all `other -> {:error, {:pr_body_headings_invalid, other}}`. Plus the new entry validator:

```elixir
  # A markdown ATX heading line: bounded, single line, no control characters.
  defp heading(entry) when is_binary(entry) do
    trimmed = String.trim(entry)

    cond do
      String.length(trimmed) > @max_check_text_chars -> :error
      not Regex.match?(@pr_body_heading_regex, trimmed) -> :error
      String.match?(trimmed, ~r/[\x00-\x1f\x7f]/) -> :error
      true -> {:ok, trimmed}
    end
  end

  defp heading(_entry), do: :error
```

### Edit 3 — read model and typed event (both needed by the drift test)

- `lib/foreman_server/project_settings.ex`: add `pr_body_headings: [String.t()] | nil,` to `@type t` after `required_checks:` (line 27). `defstruct @keys` needs no change.
- `lib/foreman_server/events/project_updated.ex`: add `pr_body_headings: [String.t()] | nil,` to `@type t` and `:pr_body_headings,` to the `defstruct` list, both next to `required_checks`.

### Edit 4 — `workflow/auto_pr.ex`

- Add `alias ForemanServer.Workflow.PrBody` and `alias ForemanServer.Workflow.ReviewFindings` (alias block 104-108); change `findings_section/1` (743) to `ReviewFindings.pr_section(artifact_path, "AutoPR")`.
- `@type context` (127-142): add `optional(:pr_body_headings) => [String.t()],` with the same "producers omit the key rather than store nil" comment convention.
- Line 165: `pr_content(context)` → `pr_content(context, base_branch, head_branch)` (both are already bound in that `with`).
- Test seam (656-657): `def __pr_content_for_test__(context) do with {:ok, head} <- resolve_head_branch(context), do: pr_content(context, Map.fetch!(context, :base_branch), head) end`.
- `pr_content/1` (659-672) becomes `pr_content/3`. Wrap the existing body in a new outer `case Map.get(context, :pr_body_headings) do` with two arms: `[_ | _] = headings ->` returns `with {:ok, title} <- resolve_task_field(context, title, :task_title, :title), do: {:ok, %{title: title, body: headings_body(context, headings, base_branch, head_branch)}}`; `nil ->` is the current `case {title, description}` block **unchanged**. The title path and `TaskMetadataError` behaviour stay identical on both arms.
- New private helpers next to `generated_body/1` (715):

```elixir
  defp headings_body(context, headings, base_branch, head_branch) do
    artifact_path = Map.get(context, :artifact_path)

    PrBody.render(headings, %PrBody.Sources{
      run_id: Map.fetch!(context, :run_id),
      task_title: task_value(context, :task_title),
      task_description: task_value(context, :task_description),
      artifact_path: artifact_path,
      findings_section: findings_section(artifact_path),
      findings_summary: findings_summary(artifact_path),
      commits: commits(context, base_branch, head_branch)
    })
  end

  defp task_value(context, key) do
    case Map.get(context, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      _ -> nil
    end
  end

  defp findings_summary(artifact_path) do
    case ReviewFindings.read(artifact_path) do
      {:recorded, record} ->
        counts =
          record
          |> ReviewFindings.unresolved()
          |> Enum.map_join(", ", fn {severity, count} -> "#{severity}: #{count}" end)

        "Unresolved review findings — " <> counts <> "."

      _absent_or_malformed ->
        nil
    end
  end

  defp commits(context, base_branch, head_branch) do
    args = ["log", "--format=%H%x09%s", base_branch <> ".." <> head_branch]
    opts = [stderr_to_stdout: true]
    opts = if cwd = Map.get(context, :cwd), do: Keyword.put(opts, :cd, cwd), else: opts

    case run(context, "git", args, opts) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "\t", parts: 2) do
            [sha, subject] -> [{sha, subject}]
            _ -> []
          end
        end)

      {_output, _exit_code} ->
        []
    end
  end
```

`git log` runs only when headings are configured, so every existing stubbed runner keeps working.

### Edit 5 — all three context producers (miss one and the setting is invisible there)

1. `workflow/run_executor.ex:3121-3130` (`auto_pr_context/2`): append `|> PrBody.put_headings(project_setting(state, :pr_body_headings))` after `|> maybe_put_auto_pr_task_metadata(state)`; add the `PrBody` alias.
2. `workflow/repo_pr_context.ex:40-64` (`build/2`): append `|> PrBody.put_headings(project_headings(Map.get(run, :project_id)))` after `|> put_task_metadata(...)`, with a private `project_headings/1` that reads `ProjectionStore.project_settings(project_id)` and matches `%ForemanServer.ProjectSettings{pr_body_headings: headings}`, returning `nil` for a non-binary id or `nil` projection.
3. `pr_create.ex:185-189` (`open/4`): same append and the same private helper (`run` carries `project_id`).

### Edit 6 — operator surfaces

- MCP `mcp/tools.ex`: add `pr_body_headings` to `@settings_update_keys` (2506) and to the `@schema_foreman_project_settings_update` properties next to `notification_preference` (570): `pr_body_headings: %{type: "array", items: %{type: "string"}, description: "Markdown headings the project's PR bodies must carry, e.g. [\"## Summary\", \"## Testing\"]"}`. Do **not** add it to `operator_only` in `tools_project_settings_test.exs:247` — it is a body template, not a gate.
- Go CLI `packages/foreman_cli/cmd/foreman/project.go`: (a) next to `repo-allowlist` (192) add `var prBodyHeadings repeatedFlag` + `fs.Var(&prBodyHeadings, "pr-body-headings", "Markdown heading the project's PR bodies must carry, e.g. '## Summary' (repeatable; the flags given replace the list; --clear pr_body_headings turns it off)")`; (b) next to the `repo_allowlist` payload block (290) add `if len(prBodyHeadings) > 0 { payload["pr_body_headings"] = []string(prBodyHeadings); changes++ }`; (c) add `"pr_body_headings"` to `projectSettingNames` (481-488); (d) add `--pr-body-headings` to the settings-flag list in `projectUsageText` (line 21).
- LiveView `foreman_server_web/project_settings_live.ex`: add `pr_body_headings` to `@list_fields` (63); add next to the `notification_preference` field (880) `<.field name="pr_body_headings" label="PR body headings" errors={@errors} form={@form} kind="textarea" help="One markdown heading per line, e.g. ## Summary. Foreman fills each from the task, the run's commits and the phase artifact." />`; add, next to the `invalid_repo_allowlist` clause (594), `defp error_field({:pr_body_heading_invalid, _entry}), do: :pr_body_headings` (the other two tags already match by prefix).

### Edit 7 — documentation gate

- `docs/user-guide.md`: new settings-table row after `notification_preference` (line 731): `` `pr_body_headings` | `--pr-body-headings <"## Heading">` (repeatable, at most 10) `` | markdown headings every PR body Foreman opens for this project must carry; Foreman fills `## Summary` from the task, `## Testing`/`## Risk` from the phase artifact's review findings, `## How to revert` from the run's commits, `## Directed by` from the run and task; a heading with no source carries an explicit not-recorded line; unset or `--clear pr_body_headings` keeps the current body.
- `docs/cli-reference.md`: add `--pr-body-headings` to the `foreman project update` flag line (24) and a flag-table row next to `--required-checks` (329).
- `CLAUDE.md`: line 1240 enumerates the whole `Settings.keys/0` whitelist — append `pr_body_headings`.
- `README.md`: no edit — it names no individual settings key (its only settings mentions are `required_checks` in the merge-gate paragraphs), so nothing there goes stale.

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/workflow/pr_body_test.exs test/foreman_server/workflow/auto_pr_test.exs \
  test/foreman_server/workflow/phase_pr_body_test.exs \
  test/foreman_server/aggregates/project_settings_test.exs \
  test/foreman_server/project_settings_read_model_test.exs \
  test/foreman_server/mcp/tools_project_settings_test.exs \
  test/foreman_server_web/live/project_settings_live_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
cd packages/foreman_cli && gofmt -l ./cmd/foreman && go build ./cmd/foreman && go test ./cmd/foreman
```

Then the full suite: `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'`.
Success = all green, no warnings. `project_settings_test.exs:431` and `tools_project_settings_test.exs:243` passing is the proof that the key reached the typed event and the MCP schema.

## 6. Out of scope

- `workflow/phase_pr.ex:344-362` (the phase-PR body) — leave it; `PrBody` is written so a later task can reuse it there. Do not change `phase_pr_body_test.exs` expectations.
- PR **title** logic, `legacy_pr_title/1`, `TaskMetadataError`, `validate_task_value/3`.
- `ReviewFindings` itself (its `@section_heading` and the `<!-- FOREMAN_REVIEW_FINDINGS_* -->` markers).
- Making the setting operator-only: do not touch `Coordinator.Dispatch.forbidden_setting?/1`, `refuse_clearing_operator_only/1`, the merge gate, `required_checks`, or any durable-store guard.
- A `pr_body_template` free-text/mustache setting, per-heading content overrides, or any second place to configure PR bodies.
- `AGENTS.md`, `docs/PRD/*`, `docs/TRD/*`.
