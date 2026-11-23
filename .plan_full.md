# PLAN — Surface "base is N commits behind origin/<base>" in ProjectRecommendations

Task `beads:foreman:foreman-qdt14` (correctness, major). All paths below are relative to the
repository root; Elixir sources live under `packages/foreman_server/`.

## 1. Verdict

**Real gap — feature missing.** `lib/foreman_server/projects/recommendations.ex` has 19
detectors (id list in the moduledoc `:18-28`, dispatch in `evaluate/1` `:102-123`); the only
branch detector is `branch_unresolved/1` (`:194-211`), which fires solely on a detached HEAD.
`lib/foreman_server/projects/recommendations/facts.ex` collects no remote-tracking fact
(`defstruct` `:124-143`), and `grep -rn "rev-list" packages/foreman_server/lib` has no hit.

## 2. Root cause

Nothing is broken; the fact is not collected. `Facts` has no probe for
`refs/heads/<b>..refs/remotes/origin/<b>` distance, and the `Facts.Probe` behaviour
(`facts.ex:26-38`) has no callback returning command *output* (`cmd/3` returns only an exit
status, which cannot carry a count). `Recommendations` has no detector for such a fact.

## 3. Failing check first

In `test/foreman_server/projects/recommendations_test.exs`, inside
`test "each detector fires on its fixture and only on it"` (the `cases` list ends line 85),
add one entry:

```elixir
{"branch.behind_origin", healthy(commits_behind_origin: 3)},
```

Red before the fix:

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/projects/recommendations_test.exs'
```

→ `** (KeyError) key :commits_behind_origin not found`. Green after edits 1–4.

## 4. Edits

### Edit 1 — `lib/foreman_server/projects/recommendations/facts.ex`

**1a. New Probe callback**, after the `cmd` callback (`:33-34`):

```elixir
    @callback cmd_out(executable :: String.t(), args :: [String.t()], timeout_ms :: pos_integer()) ::
                {:ok, {output :: binary(), exit_status :: non_neg_integer()}}
                | {:error, :timeout | :failed}
```

**1b. `Probe.System`** — implement it and express `cmd/3` through it; replace the whole
`def cmd/3` body (`:70-81`) with:

```elixir
    @impl true
    def cmd(executable, args, timeout_ms) do
      case cmd_out(executable, args, timeout_ms) do
        {:ok, {_out, status}} -> {:ok, status}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def cmd_out(executable, args, timeout_ms) do
      call(
        fn -> System.cmd(executable, args, cd: System.tmp_dir!(), stderr_to_stdout: true) end,
        timeout_ms
      )
    end
```

(`System.cmd/3` returns `{output, status}`, so `call/2` yields `{:ok, {out, status}}`.)

**1c. New fact.** In `defstruct` (`:124-143`) after `checked_out_branch: :unavailable,` add
`commits_behind_origin: :unavailable,`. In `@type t` (`:146-170`) after the
`checked_out_branch:` line add `commits_behind_origin: non_neg_integer() | :unavailable,`.

**1d. Collect it.** In `gather/3` (`:213-241`) bind the branch once above the struct
(`branch = checked_out_branch(ctx.probe, repo)`), use it for the existing
`checked_out_branch:` key, and add after it:

```elixir
      commits_behind_origin: commits_behind_origin(ctx, repo, branch),
```

**1e. The probe.** Add `alias ForemanServer.Projects.SourceBranch` to the alias block
(`:20-24`) and this after `checked_out_branch/2` (`:299-308`):

```elixir
  # How far `origin/<branch>` is ahead of the checked-out `<branch>`, read from the
  # remote-tracking ref already in the repository: no network, no fetch. `git` comes from
  # the server's own PATH; `core.fsmonitor` is cleared and the pager disabled so a hostile
  # repository config cannot make git run a program. `extensions.partialclone=` is cleared
  # as well: a non-empty value is what makes git lazily fetch a commit missing from the
  # range, so clearing it keeps the read offline. A partial clone in that state fails the
  # command and falls through to `:unavailable`, which is the honest answer, not a false
  # count. Anything unreadable (not a git
  # repository, no `refs/remotes/origin/<branch>`, unsafe branch name, timeout) is
  # `:unavailable`, and no detector reports on it.
  defp commits_behind_origin(ctx, repo, branch) when is_binary(repo) and is_binary(branch) do
    with :ok <- SourceBranch.validate(branch),
         exe when is_binary(exe) <- ctx.probe.find_executable("git"),
         :ok <- within_deadline(ctx),
         {:ok, {out, 0}} <- ctx.probe.cmd_out(exe, behind_argv(repo, branch), ctx.timeout),
         {count, ""} <- Integer.parse(String.trim(out)) do
      count
    else
      _ -> :unavailable
    end
  end

  defp commits_behind_origin(_ctx, _repo, _branch), do: :unavailable

  defp behind_argv(repo, branch) do
    [
      "--no-pager",
      "-c",
      "core.fsmonitor=",
      "-C",
      repo,
      "-c",
      "extensions.partialclone=",
      "rev-list",
      "--count",
      "refs/heads/#{branch}..refs/remotes/origin/#{branch}"
    ]
  end
```

`SourceBranch.validate/1` (`lib/foreman_server/projects/source_branch.ex:36-44`) returns
`:ok | :none | {:error, {:invalid_source_branch, v}}`; only `:ok` continues.

### Edit 2 — `lib/foreman_server/projects/recommendations.ex`

**2a.** Moduledoc id list (`:18-28`): add `` `branch.behind_origin` `` after
`` `branch.default_unresolved` ``.

**2b.** `evaluate/1` (`:102-123`): add `base_behind_origin(facts),` immediately after
`branch_unresolved(facts),`.

**2c.** Detector, right after `defp branch_unresolved(_), do: []` (`:211`):

```elixir
  # A run is cut from the branch checked out in the repo; when that branch is behind its
  # remote-tracking ref the run starts from stale code and its PR targets a stale base.
  defp base_behind_origin(%Facts{
         commits_behind_origin: behind,
         checked_out_branch: branch,
         repo_path: repo
       })
       when is_integer(behind) and behind > 0 and is_binary(branch) and is_binary(repo) do
    [
      rec(
        "branch.behind_origin",
        :warn,
        "Base branch is behind origin",
        "#{repo} is on `#{branch}`, which is #{behind} commit(s) behind " <>
          "`origin/#{branch}`. Runs cut from it start from stale code and their pull " <>
          "requests target an out-of-date base.",
        %{repo_path: repo, branch: branch, commits_behind: behind},
        manual(
          "Update the checkout: `git -C " <> sh_quote(repo) <>
            " pull --ff-only origin/#{branch}`. If the branches have diverged, reconcile " <>
            "them by hand instead: `--ff-only` never discards local commits."
        )
      )
    ]
  end

  defp base_behind_origin(_), do: []

  # POSIX single-quote wrapping. `repo` is an operator-supplied path shown inside a
  # command string the operator will paste into a shell, so it must not be able to break
  # out of its own word: wrap in single quotes and escape any embedded quote as '\\''.
  # The recommendation stays `manual`, so Foreman never runs the rendered command itself.
  defp sh_quote(path) when is_binary(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
```

### Edit 3 — the other `Facts.Probe` implementations (one line each)

The new callback makes each emit a missing-implementation warning = build failure under
`--warnings-as-errors`. Beside each existing `def cmd/3` add:

```elixir
  def cmd_out(_executable, _args, _timeout_ms), do: {:error, :failed}
```

* `test/support/recommendations_probe.ex:24`
* `test/foreman_server/projects/recommendations_facts_test.exs:18` (`HangingGh`)
* `test/foreman_server/coordinator/setup_proposer_test.exs:27` (`RaisingProbe`)
* `test/foreman_server_web/controllers/recommendations_controller_test.exs` — both `NoGh`
  (~line 21) and `Slow` (~line 39)

### Edit 4 — tests

**4a.** `test/foreman_server/projects/recommendations_test.exs`: in `healthy/1` (`:11-39`)
add `commits_behind_origin: 0,` after `checked_out_branch: "main",`; add the §3 `cases`
entry; and add beside the detached-HEAD test (`:175-180`):

```elixir
  test "behind origin names the branch and the count, and is silent otherwise" do
    [rec] = Recommendations.evaluate(healthy(commits_behind_origin: 4))
    assert rec.severity == :warn
    assert rec.detail =~ "4 commit(s) behind `origin/main`"
    assert rec.evidence == %{repo_path: "/r", branch: "main", commits_behind: 4}
    assert rec.fix.kind == :manual

    refute "branch.behind_origin" in ids(healthy(commits_behind_origin: 0))
    refute "branch.behind_origin" in ids(healthy(commits_behind_origin: :unavailable))

    refute "branch.behind_origin" in
             ids(healthy(commits_behind_origin: 2, checked_out_branch: :detached))
  end
```

**4b.** `test/foreman_server/projects/recommendations_facts_test.exs`: new test against the
real probe, in the existing `register!/3` + `@moduletag :tmp_dir` style. With
`System.cmd("git", args, cd: ..., stderr_to_stdout: true)` asserting status 0 each time,
build a bare `origin.git` (`git init -q --bare`); a `work` repo (`git init -q`,
`symbolic-ref HEAD refs/heads/main`, `config user.email`/`user.name`,
`remote add origin <origin>`); three commits `c1..c3`; `push -q -u origin main`;
`reset -q --hard HEAD~2`. Then `register!(id, repo)` and assert

```elixir
    assert {:ok, facts} = Facts.collect(id, probe_timeout_ms: 5_000)
    assert facts.checked_out_branch == "main"
    assert facts.commits_behind_origin == 2
```

Hand-verified: that `rev-list --count` invocation prints `2` for this layout, `0` once
fast-forwarded, and exits 128 (⇒ `:unavailable`) when the remote ref or the repository is
missing; `--no-pager -c core.fsmonitor=` stops a planted `core.fsmonitor`/`core.pager` from
executing, so the existing "never executes a binary planted in the repo" test
(`recommendations_facts_test.exs:65-81`) stays green.

### Edit 5 — docs (gate: new externally visible id `branch.behind_origin`)

* `docs/cli-reference.md:336` — add `` `branch.behind_origin` `` to the detector-id list,
  after `` `branch.default_unresolved` (detached HEAD in the project's repository) ``, as
  "(the checked-out branch is behind `origin/<branch>`)".
* `docs/user-guide.md:684-688` — paragraph "Two further checks:". Make it "Three further
  checks:" and add `branch.behind_origin` (the checkout is N commits behind
  `origin/<its branch>`, so runs would start from stale code).
* `CLAUDE.md`, `README.md`: **no edit needed** — neither lists detector ids
  (`grep -n recommend README.md` → only the line-39 feature bullet; `CLAUDE.md` no hit).

## 5. Verification

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/projects/recommendations_test.exs \
  test/foreman_server/projects/recommendations_facts_test.exs \
  test/foreman_server/coordinator/setup_proposer_test.exs \
  test/foreman_server_web/controllers/recommendations_controller_test.exs \
  test/foreman_server/coordinator/actions/apply_recommendation_test.exs \
  --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
```

Success = all green, zero warnings. Then the full suite:
`devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'`.

## 6. Out of scope

* No `git fetch`, no network: read the remote-tracking ref already present. The wider
  stale-base work (`base_ref_policy`, fetch-before-run, base SHA on
  `RunBaseBranchRecorded`) is other beads — do not start it here.
* No new project setting, command or event; no change to `RunExecutor`, `VcsAdapter`,
  `Exec.Git`, PR base resolution, `Recommendations.View`, the HTTP controller, the MCP tool
  or the Go CLI: a new detector flows through the existing serialiser unchanged.
* The new fix stays `:manual`, never `:command`, so `applicable?/1` keeps the coordinator
  from running `git pull` on the operator's checkout.
* Do not touch the other detectors, the `Facts` safety rules, or adjacent code style.
