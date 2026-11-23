# PLAN — Review section must not be only the missing-evidence notice

## 1. Verdict

**Real bug, unimplemented.** `ForemanServer.Workflow.ReviewFindings.section/1`
(`packages/foreman_server/lib/foreman_server/workflow/review_findings.ex:309-313`) renders, for an
artifact with no findings block, only the heading plus
`"The review evidence is missing: the review artifact has no findings block. This is not a clean review. Check the review artifact.\n"`.
No report path, no run, no phase. Same for the malformed/unreadable clause (`:315-321`). The only
artifact mention in the PR body is the plain `Artifact: <abs path>` line both callers emit
(`phase_pr.ex:349`, `auto_pr.ex:720`) — outside the section, not a link, omitted when
`artifact_path` is nil. Tests locking the thin wording:
`test/foreman_server/workflow/phase_pr_body_test.exs:257-270`,
`test/foreman_server/workflow/auto_pr_test.exs:382-390`.

## 2. Root cause

`section/1` receives only the `read/1` result, so it cannot name the report or the run/phase.
`pr_section/2` has the path but throws it away after `read/1` and logging
(`review_findings.ex:254-273`). Fix: give the renderer a typed context and emit a report link plus
run/phase on the two non-recorded states.

## 3. Failing check first

Add to `packages/foreman_server/test/foreman_server/workflow/phase_pr_body_test.exs` (after the test
at line 257):

```elixir
  test "an absent block still links the review report and names the run and phase" do
    artifact = temp_artifact!("# Report\n\nNothing to report.\n")
    body = phase_body(artifact)

    assert body =~ "review evidence is missing"
    assert body =~ "Review report: ["
    assert body =~ Path.basename(artifact)
    assert body =~ "run `run-1`, phase `repo-rules-review`"
  end
```

Fails before the fix (no `Review report:` text). Command (run from the repository root):

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/phase_pr_body_test.exs'
```

If the worktree has no `deps/`, run `mix deps.get` once first (this worktree had none).

## 4. Edits

### 4.1 `packages/foreman_server/lib/foreman_server/workflow/review_findings.ex`

**(a)** After the `Record` module (ends line 98, before the blank line and `@doc` at 100), insert:

```elixir
  defmodule Context do
    @moduledoc "Where a review artifact came from: what the PR body links to and names."
    @enforce_keys [:artifact_path, :run_id, :phase_name, :repo_root]
    defstruct [:artifact_path, :run_id, :phase_name, :repo_root]

    @type t :: %__MODULE__{
            artifact_path: String.t() | nil,
            run_id: String.t(),
            phase_name: String.t() | nil,
            repo_root: String.t() | nil
          }
  end
```

**(b)** Lines 253-255, replace the spec/head/first body line:

```elixir
  @spec pr_section(Context.t(), String.t()) :: String.t()
  def pr_section(%Context{} = context, caller) when is_binary(caller) do
    result = read(context.artifact_path)
```

and inside the same function replace the two `inspect(artifact_path)` uses (lines 262 and 268) with
`inspect(context.artifact_path)`, and line 272 `section(result)` with `section(result, context)`.
Update its `@doc` (lines 247-252) to say the section also names the report and the run/phase.

**(c)** Lines 287-292, the `@spec section(` block: keep the result union as the first argument and
add a second:

```elixir
  @spec section(
          {:recorded, Record.t()}
          | :absent
          | {:malformed, reason}
          | {:error, {:unreadable, File.posix()}},
          Context.t()
        ) :: String.t()
```

**(d)** Line 293 head → `def section({:recorded, %Record{findings: findings}}, %Context{}) do`
(body unchanged; the recorded section keeps its exact current trailing text — adversarial tests
assert it ends with `Fixed: N. Declined: N (...).\n`).

**(e)** Lines 309-321, replace both non-recorded clauses with:

```elixir
  def section(:absent, %Context{} = context) do
    @section_heading <>
      "The review evidence is missing: the review artifact has no findings block. " <>
      "This is not a clean review. Check the review artifact.\n" <>
      evidence_text(context)
  end

  def section(error, %Context{} = context) do
    {defect, detail} = defect(error)

    @section_heading <>
      "The review evidence is malformed or unreadable (`#{defect}`): #{detail}. " <>
      "This is not a clean review. Check the review artifact.\n" <>
      evidence_text(context)
  end
```

**(f)** Add these private helpers next to `code_span/1` (which is defined around line 349 and is
reused here unchanged):

```elixir
  # Only a conservative path becomes a Markdown link; anything else stays an inert code span.
  @safe_location ~r{\A[A-Za-z0-9._/-]+\z}

  defp evidence_text(%Context{artifact_path: nil} = context),
    do: "\nNo review report was recorded for #{where(context)}.\n"

  defp evidence_text(%Context{} = context) do
    location = report_location(context)

    link =
      if Regex.match?(@safe_location, location),
        do: "[#{location}](#{location})",
        else: code_span(location)

    "\nReview report: #{link} (#{where(context)}).\n"
  end

  defp report_location(%Context{artifact_path: path, repo_root: root})
       when is_binary(root) and root != "",
       do: Path.relative_to(path, root)

  defp report_location(%Context{artifact_path: path}), do: path

  defp where(%Context{run_id: run_id, phase_name: nil}), do: "run `#{run_id}`"

  defp where(%Context{run_id: run_id, phase_name: phase}),
    do: "run `#{run_id}`, phase `#{phase}`"
```

### 4.2 `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex`

Line 350: `findings_section(request.artifact_path)` → `findings_section(request)`.
Lines 607-608 replace with:

```elixir
  defp findings_section(%Request{} = request),
    do:
      ForemanServer.Workflow.ReviewFindings.pr_section(
        %ForemanServer.Workflow.ReviewFindings.Context{
          artifact_path: request.artifact_path,
          run_id: request.run_id,
          phase_name: request.phase_name,
          repo_root: request.cwd
        },
        "PhasePR"
      )
```

### 4.3 `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex`

Line 721: `findings_section(artifact_path)` → `findings_section(context)` (keep line 717's
`artifact_path = Map.get(context, :artifact_path)`; it still feeds line 720's `Artifact:` line).
Lines 743-744 replace with:

```elixir
  defp findings_section(context),
    do:
      ForemanServer.Workflow.ReviewFindings.pr_section(
        %ForemanServer.Workflow.ReviewFindings.Context{
          artifact_path: Map.get(context, :artifact_path),
          run_id: Map.fetch!(context, :run_id),
          phase_name: nil,
          repo_root: Map.get(context, :cwd)
        },
        "AutoPR"
      )
```

### 4.4 Tests that must be updated (they encode the old behaviour)

1. `phase_pr_body_test.exs:181-193` ("AutoPR and PhasePR render the same section for every kind of
   block") now differs by the evidence line (PhasePR knows the phase, AutoPR does not). Keep the
   test, compare findings text only: add

   ```elixir
   defp without_evidence(section) do
     section
     |> String.split("\n")
     |> Enum.reject(&(String.starts_with?(&1, "Review report:") or
                        String.starts_with?(&1, "No review report")))
     |> Enum.join("\n")
   end
   ```

   then assert `without_evidence(section(phase_body(artifact))) == without_evidence(section(auto_body(artifact)))`.
2. `auto_pr_test.exs:382-390` — add `assert body =~ "Review report: ["` and
   ``assert body =~ "run `run-12`"``; it must not name a phase.
3. `phase_pr_body_test.exs:266-270` (nil artifact) — add
   ``assert body =~ "No review report was recorded for run `run-1`, phase `repo-rules-review`"``.
4. The adversarial tests (`phase_pr_body_test.exs:197-255`) use recorded blocks only and must stay
   unchanged; a failure there means the recorded clause was altered — revert that.

### 4.5 Documentation gate

Added identifier: `ForemanServer.Workflow.ReviewFindings.Context`; changed arity/shape:
`pr_section/2` first arg, `section/2`.

- `CLAUDE.md:1216` — after "absent, malformed and unreadable are \"not a clean review\"", append:
  "…and each also links the review report (repo-relative when under the run worktree) and names the
  run and, for a phase PR, the phase; `pr_section/2` now takes a `ReviewFindings.Context`
  (`artifact_path`, `run_id`, `phase_name`, `repo_root`)."
- `docs/user-guide.md:2986-2989` — after "named as **not a clean review**, and a warning is logged",
  add "; each of those states also links the review report and names the run (and the phase for a
  phase PR), so there is always something to open."
- `README.md`, `docs/cli-reference.md` — no hits for `ReviewFindings`, `pr_section` or the section
  wording; no edit needed (no operator-visible command, flag or env var changes).

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/workflow/phase_pr_body_test.exs \
  test/foreman_server/workflow/auto_pr_test.exs \
  test/foreman_server/workflow/review_findings_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
```

Success: all three files green with zero warnings (an unused-variable warning in `pr_section/2` or
`section/2` means an edit above was applied partially), and `mix format --check-formatted` clean.
Then run the full suite:
`devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'`.

## 6. Out of scope

- The `{:recorded, _}` section text, `unresolved_text/1`, `finding_line/1`, `code_span/1` bodies,
  and every parser/`extract_block/3` path — do not touch.
- `ForemanServer.PrReport` (`lib/foreman_server/pr_report.ex`, the risk comment) and the
  `ReviewFindingsRecorded` event/payload in `run_executor.ex:2834-2900` — the record is separate
  from the PR body text.
- No blob-URL construction, no `gh`/GitHub calls, no new config key: the link is the artifact path,
  made repo-relative against the run worktree when possible.
- Do not change the `Artifact:` line in `phase_pr.ex:349` / `auto_pr.ex:720`.
