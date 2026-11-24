# PLAN — scrub absolute local paths from PR bodies (foreman-txkmy)

## 1. Verdict

**Real bug.** Two PR-body builders interpolate an absolute filesystem path:

- `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:349`
  `if(request.artifact_path, do: "\nArtifact: #{request.artifact_path}\n", else: "")`
- `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex:720` — the identical line in
  `generated_body/1`.

`artifact_path` is built by `RunExecutor.ArtifactTemplate.resolve_path/3`
(`run_executor.ex:2492`) from `working_directory_of(state)`, the run worktree
(`/Users/<user>/.foreman/worktrees/...`), so the body carries the operator's home path.

Third leak: `ReviewFindings.finding_line/1`
(`packages/foreman_server/lib/foreman_server/workflow/review_findings.ex:337`) prints the
agent-written `f.path` verbatim; an agent that writes an absolute path leaks it the same way.

No test asserts the absence of `/Users/` in a body;
`packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs:334` asserts the leak
(`assert body =~ "Artifact: #{artifact}"`, with an absolute `artifact`).

## 2. Root cause

No scrubbing boundary between a filesystem path and the `gh pr create --body` text, and the same
raw interpolation is duplicated in both builders (AGENTS.md §5.7 wants one shared module).

## 3. Failing check first

Write the test file FIRST and run it; all four tests must fail before the edits.

Path: `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs`
Module `ForemanServer.Workflow.PrBodyPathsTest`, `use ExUnit.Case, async: true`.

Copy `stub_runner/1`, `body_arg/1`, `block/1` and `finding/1` verbatim from
`packages/foreman_server/test/foreman_server/workflow/phase_pr_body_test.exs` (the stub runner
answers `git rev-list|rev-parse|ls-remote|push` and `gh pr list`, and sends
`{:gh_pr_create_args, args}` on `gh pr create`).

Per test: `cwd = Path.join(System.tmp_dir!(), "pr-body-paths-#{System.unique_integer([:positive])}")`,
`File.mkdir_p!(Path.join(cwd, "docs/reports/x"))`, artifact at
`Path.join(cwd, "docs/reports/x/FIX_REPORT.md")`, `on_exit(fn -> File.rm_rf(cwd) end)`.

1. `"the PhasePR body names the artifact relative to the repository"` — a `%PhasePR.Request{}`
   built as in `phase_pr_body_test.exs` with `cwd: cwd, artifact_path: artifact`, then
   `PhasePR.maybe_create/1`: `assert body =~ "Artifact: docs/reports/x/FIX_REPORT.md"`,
   `refute body =~ cwd`, `refute body =~ "/Users/"`, `refute body =~ "/home/"`.
2. `"the AutoPR body names the artifact relative to the repository"` — same four assertions via
   `AutoPR.maybe_create_pr(%{run_id: "run-1", base_branch: "main", head_branch: "foreman/t/run-1",
   cwd: cwd, artifact_path: artifact, command_runner: runner})`.
3. `"an artifact outside the repository is omitted, not leaked"` — artifact in a second temp dir
   outside `cwd`: `refute body =~ "Artifact:"`, `refute body =~ "/Users/"`.
4. `"an absolute finding path is scrubbed to its basename"` — artifact contains
   `block([finding(%{"path" => "/Users/someone/wt/lib/foo.ex"})])`; on both bodies:
   `assert body =~ "…/foo.ex:12"`, `refute body =~ "/Users/"`.

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/pr_body_paths_test.exs'
```

(Deps are not fetched in a fresh run worktree; run `mix deps.get` first if Mix says so.)

## 4. Edits

### Edit 1 — new `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex`

```elixir
defmodule ForemanServer.Workflow.PrBodyPath do
  @moduledoc """
  Scrubs filesystem paths that reach a PR body.

  A PR body is public: an absolute path under the operator's home (the run
  worktree) must never appear in it. `AutoPR` and `PhasePR` render the artifact
  line through `artifact_line/2` (AGENTS.md §5.7: one implementation).

  `Path.relative_to/2` returns an absolute path unchanged when it is not under
  the base, so it is never used alone: a path outside the root is refused
  (`:outside_repo`) instead of being emitted as a plausible-looking relative one.
  """

  @doc """
  The path relative to `root`, or `:outside_repo` when no relative form exists
  (absolute and outside `root`, or no `root`). An already-relative path is
  returned unchanged: it carries no local prefix.
  """
  @spec repo_relative(String.t(), String.t() | nil) :: {:ok, String.t()} | :outside_repo
  def repo_relative(path, root) when is_binary(path) do
    cond do
      Path.type(path) == :relative ->
        {:ok, path}

      is_binary(root) and root != "" ->
        base = Path.expand(root)
        expanded = Path.expand(path)

        if String.starts_with?(expanded, base <> "/"),
          do: {:ok, Path.relative_to(expanded, base)},
          else: :outside_repo

      true ->
        :outside_repo
    end
  end

  @doc """
  The PR-body artifact line, or `""` when there is no artifact or no relative
  form for it: the line is dropped rather than leaking a local path.
  """
  @spec artifact_line(String.t() | nil, String.t() | nil) :: String.t()
  def artifact_line(path, root) when is_binary(path) do
    case repo_relative(path, root) do
      {:ok, relative} -> "\nArtifact: #{relative}\n"
      :outside_repo -> ""
    end
  end

  def artifact_line(_path, _root), do: ""

  @doc """
  A review finding's path as it may appear in a body. Findings paths are
  repository-relative by convention and pass through; an absolute one an agent
  wrote is cut to `…/<basename>`, which leaks no directory.
  """
  @spec display_path(String.t()) :: String.t()
  def display_path(path) when is_binary(path) do
    if Path.type(path) == :relative, do: path, else: "…/" <> Path.basename(path)
  end
end
```

### Edit 2 — `phase_pr.ex`

Add beside the existing aliases (after `alias ForemanServer.GitHub.PrLookup`, line 46):

```elixir
  alias ForemanServer.Workflow.PrBodyPath
```

In `gh_pr_create/2`, replace line 349 (`if(request.artifact_path, do: ...)`) with:

```elixir
        PrBodyPath.artifact_line(request.artifact_path, request.cwd) <>
```

leaving lines 348 and 350 as they are. `request.cwd` is the run worktree, the repository root the
artifact was committed into.

### Edit 3 — `auto_pr.ex`

In `generated_body/1` (lines 715-722) replace line 720 with:

```elixir
      ForemanServer.Workflow.PrBodyPath.artifact_line(artifact_path, body_path_root(context)) <>
```

(fully qualified, like `findings_section/1` at line 744 — add no alias), and add beside
`findings_section/1` at the end of the module:

```elixir
  # The artifact lives in the run WORKTREE, while `cwd` is the repository the
  # `gh` commands run in, so the worktree root is tried first; the artifact line
  # is dropped when neither yields a relative path (`PrBodyPath`).
  defp body_path_root(context),
    do: Map.get(context, :artifact_root) || Map.get(context, :cwd)
```

Add the key to the `@type context` map at line ~130, beside `optional(:artifact_path)`:

```elixir
          optional(:artifact_root) => String.t() | nil,
```

with the comment `# The repository root the artifact path is made relative to in the PR body.`

### Edit 4 — `run_executor.ex`, `auto_pr_context/2` (line 3122)

Add one key to the map so AutoPR can relativise the artifact (it sits in the worktree, while
`cwd` is the project root):

```elixir
      artifact_root: get_in(state, [:last_worktree, :worktree_path]),
```

placed after the `artifact_path:` line. `remember_worktree/2` (line 1487) stores
`worktree_path`, so the key is `nil` only when no worktree was provisioned — then
`body_path_root/1` falls back to `cwd` and, failing that, the line is dropped.

### Edit 5 — `review_findings.ex`, `finding_line/1` (line 337)

Replace `path = flatten(f.path, @listed_path)` with:

```elixir
    path = f.path |> ForemanServer.Workflow.PrBodyPath.display_path() |> flatten(@listed_path)
```

### Edit 6 — `test/foreman_server/workflow/auto_pr_test.exs`

`generated_body_at/1` passes `cwd: "/work/tree"` while the artifact is under `System.tmp_dir!()`,
so the line is now correctly dropped. Point the root at the artifact's own directory:

- line 326: `cwd: "/work/tree",` → `cwd: Path.dirname(artifact),`
- line 334: `assert body =~ "Artifact: #{artifact}"` →
  `assert body =~ "Artifact: #{Path.basename(artifact)}"`

Change nothing else in that file.

## 5. Verification

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/workflow/pr_body_paths_test.exs \
  test/foreman_server/workflow/phase_pr_body_test.exs \
  test/foreman_server/workflow/auto_pr_test.exs \
  test/foreman_server/workflow/review_findings_test.exs --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success: green, zero warnings, formatter clean.

Documentation gate (already checked, expect no edits): the diff adds one internal Elixir module
(`ForemanServer.Workflow.PrBodyPath`) and one internal AutoPR context key (`:artifact_root`); no
route, config key, env var, CLI verb, MCP tool, command or event type.
`grep -n "Artifact:" CLAUDE.md README.md docs/user-guide.md docs/cli-reference.md` returns nothing,
and `ReviewFindings.pr_section/2` keeps its arity, so `CLAUDE.md:1216` stays correct. Re-run that
grep, state the result, and edit the four files only if a hit appears.

## 6. Out of scope

- Do NOT change `ReviewFindings.pr_section/2` or `section/1` arities, the findings schema, the
  section heading, or any `Logger.warning` text (server-side logs are not published).
- Do NOT touch `ArtifactTemplate.resolve_path/3` or `completion_artifact_path/1`: the artifact path
  stored in events and state stays absolute.
- Do NOT change `PrReport.Publisher`, `PrEvidence`, `PrRisk`, or PR-comment bodies.
- Do NOT refactor `gh_pr_create/2`, `generated_body/1`, or the surrounding lookup/effect code.
- Do NOT rewrite tests in `auto_pr_test.exs` or `phase_pr_body_test.exs` beyond Edit 6.
