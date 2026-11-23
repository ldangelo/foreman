# PLAN — Extract `## PR body` from the phase artifact (foreman-2uziy)

## 1. Verdict

**Real bug (missing feature), unimplemented on this tree (HEAD `f0f3b083`).**
`phase_pr.ex:347-350` and `auto_pr.ex:715-722` each build the body by concatenation; no extractor
exists (`grep -rn "PR body" packages/foreman_server/lib packages/foreman_server/priv` → two
unrelated comments).

Two corrections to the bead, both binding:

1. **No bundled prompt asks for a `## PR body` section** — `grep -n '^##'
   packages/foreman_server/priv/defaults/workflows/prompts/*.md` shows only `Mission`, `Rounds`,
   `Review`, `Output`, `Inputs`, `Task Prompt`, `Operator progress updates`, `Carry forward…`.
   This change *honours* the convention; making prompts emit it is out of scope (§6).
2. **`RunExecutor.maybe_record_phase_pr` needs no edit** — `run_executor.ex:3001-3040` only passes
   `artifact_path:` into `%PhasePR.Request{}` (`:3027`) and builds no body. Two body builders,
   not three.

## 2. Root cause

Nothing reads the artifact for an agent-authored body, and the generated text is duplicated in
`PhasePR.gh_pr_create/2` and `AutoPR.generated_body/1`, so a one-sided fix would drift
(AGENTS.md §5.7).

## 3. Failing check first

Append to `packages/foreman_server/test/foreman_server/workflow/phase_pr_body_test.exs`, whose
`temp_artifact!/1`, `phase_body/1` and `auto_body/1` helpers already drive both PR paths against a
stubbed `command_runner`:

```elixir
  describe "an agent-written ## PR body section" do
    test "is the PR body verbatim on both paths" do
      artifact = temp_artifact!("# Report\n\n## PR body\n\nShips the thing.\n\n### Risk\n\nLow.\n")
      body = "Ships the thing.\n\n### Risk\n\nLow."

      assert phase_body(artifact) == body
      assert auto_body(artifact) == body
    end

    test "stops at the next level-2 heading" do
      artifact = temp_artifact!("## PR body\n\nOnly this.\n\n## Verification\n\nNot this.\n")
      assert phase_body(artifact) == "Only this."
    end

    test "a fenced, repeated or empty heading leaves the generated body standing" do
      for contents <- [
            "````\n## PR body\n\nfenced\n````\n",
            "## PR body\n\nfirst\n\n## PR body\n\nsecond\n",
            "## PR body\n\n   \n"
          ] do
        artifact = temp_artifact!(contents)
        assert phase_body(artifact) =~ "Foreman run `run-1` phase `repo-rules-review` complete."
        assert auto_body(artifact) =~ "Foreman run `run-1` complete."
      end
    end
  end
```

Red before the edits (assertion 1 gets the generated text):

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/phase_pr_body_test.exs'
```

## 4. Edits

### Edit 1 — expose the fence scan (`packages/foreman_server/lib/foreman_server/workflow/review_findings.ex`)

Insert immediately **above** `defp counted_markers` (`:381`). It reuses the existing private
`fence_open/1` (`:410`) and `fence_closes?/2` (`:422`), so the fence rules stay single-source.
Do **not** rewrite `counted_markers/3`, `extract_block/3` or anything else in this file.

```elixir
  @doc """
  The `{line, index}` pairs of `contents` outside every fenced code block, a
  CRLF carriage return removed (fence lines themselves are not returned).

  Public because `Workflow.PrBody` must ignore fenced headings under exactly
  the fence rules this module applies to its own markers.
  """
  @spec unfenced_lines(String.t()) :: [{String.t(), non_neg_integer()}]
  def unfenced_lines(contents) when is_binary(contents) do
    contents
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce({nil, []}, fn {raw, idx}, {fence, acc} ->
      line = String.trim_trailing(raw, "\r")

      case fence do
        nil ->
          case fence_open(line) do
            nil -> {nil, [{line, idx} | acc]}
            open -> {open, acc}
          end

        open ->
          if fence_closes?(line, open), do: {nil, acc}, else: {open, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end
```

### Edit 2 — new `packages/foreman_server/lib/foreman_server/workflow/pr_body.ex`

```elixir
defmodule ForemanServer.Workflow.PrBody do
  @moduledoc """
  The PR body an agent wrote, read from the phase artifact.

  A `## PR body` heading outside any code fence makes that section, verbatim,
  the PR body. Every other state — no heading, more than one, an empty,
  oversized or NUL-bearing section, an unreadable artifact — is `:absent` and
  the caller keeps its generated body: a PR body is prose for a human, and
  nothing here refuses a PR. One implementation for every PR-creating path
  (`PhasePR`, `AutoPR`, and so `RunExecutor` through `PhasePR`).
  """


  alias ForemanServer.Workflow.ReviewFindings

  require Logger

  @heading "## PR body"
  # GitHub refuses a longer body, and a report that big is not a PR body.
  @max_bytes 65_536

  @spec from_artifact(String.t() | nil, String.t()) :: {:ok, String.t()} | :absent
  def from_artifact(path, caller) when is_binary(caller) do
    case ReviewFindings.load(path) do
      {:ok, contents} -> extract(contents, path, caller)
      :absent -> :absent
      {:malformed, :too_large} -> ignored(caller, path, "the artifact is too large to read")
      {:error, {:unreadable, why}} -> ignored(caller, path, "unreadable: #{inspect(why)}")
    end
  end

  defp extract(contents, path, caller) do
    lines = ReviewFindings.unfenced_lines(contents)

    case Enum.filter(lines, fn {line, _idx} -> String.trim_trailing(line) == @heading end) do
      [{_line, idx}] -> section(contents, lines, idx, path, caller)
      [] -> :absent
      [_, _ | _] -> ignored(caller, path, "more than one `#{@heading}` heading")
    end
  end

  # The section runs to the next unfenced level-1 or level-2 heading (a `###`
  # subsection belongs to the body), or to the end of the file.
  defp section(contents, lines, idx, path, caller) do
    stop =
      Enum.find_value(lines, fn {line, i} ->
        if i > idx and Regex.match?(~r/^ {0,3}\#{1,2} /, line), do: i
      end)

    all = String.split(contents, "\n")

    all
    |> Enum.slice((idx + 1)..((stop || length(all)) - 1)//1)
    |> Enum.join("\n")
    |> String.trim()
    |> validate(path, caller)
  end

  defp validate(body, path, caller) do
    cond do
      body == "" -> ignored(caller, path, "the `#{@heading}` section is empty")
      byte_size(body) > @max_bytes -> ignored(caller, path, "the section is too large")
      String.contains?(body, <<0>>) -> ignored(caller, path, "the section holds a NUL byte")
      true -> {:ok, body}
    end
  end

  defp ignored(caller, path, why) do
    Logger.warning(
      "#{caller} used no PR body from #{inspect(path)}: #{why}; the generated body stands"
    )

    :absent
  end
end
```

The backslash in `~r/^ {0,3}\#{1,2} /` is **required**: an unescaped `#{` is interpolation.

### Edit 3 — `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex`

(a) After `alias …Reconcilers.PrCreate, as: PrCreateEffect` (`:49`) add
`alias ForemanServer.Workflow.PrBody`.
(b) In `gh_pr_create/2` replace the four `body = …` lines (`:347-350`) with `body = pr_body(request)`.
(c) Beside `findings_section/1` at the end of the module (`:607-608`) add:

```elixir
  defp pr_body(request) do
    case PrBody.from_artifact(request.artifact_path, "PhasePR") do
      {:ok, body} -> body
      :absent -> generated_body(request)
    end
  end

  defp generated_body(request) do
    "Foreman run `#{request.run_id}` phase `#{request.phase_name}` complete.\n" <>
      if(request.artifact_path, do: "\nArtifact: #{request.artifact_path}\n", else: "") <>
      findings_section(request.artifact_path)
  end
```

### Edit 4 — `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex`

(a) After `alias …Reconcilers.PrCreate, as: PrCreateEffect` (`:108`) add
`alias ForemanServer.Workflow.PrBody`.
(b) Replace `defp generated_body(context)` (`:715-722`) with:

```elixir
  defp generated_body(context) do
    case PrBody.from_artifact(Map.get(context, :artifact_path), "AutoPR") do
      {:ok, body} -> body
      :absent -> template_body(context)
    end
  end

  defp template_body(context) do
    run_id = Map.fetch!(context, :run_id)
    artifact_path = Map.get(context, :artifact_path)

    "Foreman run `#{run_id}` complete.\n" <>
      if(artifact_path, do: "\nArtifact: #{artifact_path}\n", else: "") <>
      findings_section(artifact_path)
  end
```

Both callers of `generated_body/1` (`absent_task_field/2` `:696`, `legacy_pr_content/1` `:724`)
stay as they are.

### Edit 5 — tests

(a) The describe block from §3.
(b) New `packages/foreman_server/test/foreman_server/workflow/pr_body_test.exs`, `async: true`,
temp files under `System.tmp_dir!()`: `{:ok, body}` for one heading; `:absent` for `nil`, no
heading, a fenced heading, two headings, a whitespace-only section, a section over 65_536 bytes,
and a section containing `<<0>>`.

### Edit 6 — documentation gate

Added identifiers: `ForemanServer.Workflow.PrBody.from_artifact/2`,
`ReviewFindings.unfenced_lines/1`, and the operator-visible `## PR body` artifact convention.
None removed or renamed.

- `docs/user-guide.md:2966` (paragraph `**PR bodies carry the review agent's report only when
  Foreman generates the body.**`): say a phase artifact may carry a single `## PR body` heading
  outside any code fence, whose section (to the next `#`/`##` heading) **is** the PR body verbatim
  — replacing the generated run/artifact/findings text — on the phase PR and the ad-hoc final
  AutoPR alike; that a repeated, fenced, empty, NUL-bearing or over-65536-byte section is ignored
  with a logged warning and the generated body stands; and that no bundled prompt writes the
  section today, so it is opt-in for operator prompts.
- `README.md:288` after `…keep the legacy generated run/artifact body`, and
  `docs/cli-reference.md:619` after the `Task-backed final AutoPRs use exact task metadata (…)`
  sentence: add `, unless the phase artifact carries a `## PR body` section, which becomes the
  body verbatim`.
- `CLAUDE.md:1216` (bullet `**Typed review findings and their record (Phase 1 PR 5).**`): one
  sentence naming `Workflow.PrBody.from_artifact/2` and `ReviewFindings.unfenced_lines/1`.

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/workflow/pr_body_test.exs \
  test/foreman_server/workflow/phase_pr_body_test.exs \
  test/foreman_server/workflow/phase_pr_test.exs \
  test/foreman_server/workflow/auto_pr_test.exs \
  test/foreman_server/workflow/review_findings_test.exs \
  test/foreman_server/workflow/run_executor_autopr_task_metadata_test.exs \
  test/foreman_server/workflow/run_executor_multi_repo_pr_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = all three exit 0, zero failures. Record the real invocation and its counts in
`FIX_REPORT.md`.

## 6. Out of scope

- **No bundled prompt or workflow-YAML edit**, and no `foreman init --force`. Making
  `review-repo-rules.md` emit `## PR body` would silently drop the `## Review findings` section
  from every phase PR, and collides with the separate open bead about that section.
- **The task-backed AutoPR body is unchanged**: `task_description` stays the body verbatim
  (`docs/user-guide.md:2946-2951`, `run_executor_autopr_task_metadata_test.exs`).
- **Do not touch** `RunExecutor` (builds no body), `counted_markers/3`/`extract_block/3`/`PrRisk`,
  the PR title `feat(phase): …`, the absolute `Artifact: …` path leak,
  `ReviewFindings.pr_section/2` wording, `repo_pr.ex` cross-linking — each is its own bead.
- No project setting, no `pr_body_template`, no new command or event.
