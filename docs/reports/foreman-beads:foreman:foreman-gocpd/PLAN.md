# PLAN — phase PR title from task title / first conventional subject

All paths are repository-relative. Elixir source lives under `packages/foreman_server/`.

## 1. Verdict

**Real bug, present on the current tree.**
`packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:345` is still
`title = "feat(phase): #{request.phase_name}"`. `%PhasePR.Request{}` (phase_pr.ex:53-79)
has no task field, and `RunExecutor.request_phase_pr/5` (run_executor.ex:3009-3029) builds
the request without one, so no task title can reach the title. The final AutoPR already
does this correctly (auto_pr.ex:657-700); `docs/PRD/PRD-2026-81f29bf4-autopr-task-title-body.md`
§2.2 scoped `PhasePR` out, which is why it was never fixed.

## 2. Root cause

`PhasePR.gh_pr_create/2` hard-codes the title from `request.phase_name`; the task title the
executor already resolves for AutoPR (run_executor.ex:3132-3165, `task_backed?/1` +
`task_field/2`) is never passed into the phase PR request.

## 3. Failing check first

New tests go in the existing
`packages/foreman_server/test/foreman_server/workflow/phase_pr_test.exs`
(module `ForemanServer.Workflow.PhasePRTest`), inserted before `defp runner_with_ahead/1`
(line 433). `scripted_runner/1` (line 534) already forwards `{:gh_pr_create, args}` to the
test; `request/1` (line 12) merges overrides into the struct.

First, the stubs. The existing runners have **no `git log` clause and no catch-all**, so
the new `git log` call would raise `FunctionClauseError` in tests that exist today. Add:

- phase_pr_test.exs, beside the `defp runner(...)` clauses at line 507-511:
  `defp runner("git", ["log" | _], _opts), do: {"", 0}`
- phase_pr_test.exs `scripted_runner/1` (line 534): change the head to
  `defp scripted_runner(replies, log \\ "")` and add a first clause
  `"git", ["log" | _], _opts -> {log, 0}`
- `packages/foreman_server/test/foreman_server/workflow/phase_pr_body_test.exs`
  `stub_runner/1` (lines 22-42), beside its `rev-list` clause:
  `"git", ["log" | _], _opts -> {"", 0}`

Then the helper, beside `defp answer/1` in phase_pr_test.exs:

```elixir
  defp title_arg(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--title", title] -> title
      _ -> nil
    end)
  end
```

Then the tests:

```elixir
  describe "the PR title" do
    test "is the run's task title when the run is task-backed" do
      assert {:ok, _record} =
               PhasePR.maybe_create(
                 request(%{task_title: "Fix login timeout", command_runner: scripted_runner([])})
               )

      assert_receive {:gh_pr_create, args}
      assert title_arg(args) == "Fix login timeout"
    end

    test "falls back to the first conventional-commit subject of the run's commits" do
      log = "Foreman run run-1 phase 1\nfix(auth): stop the login timeout\nchore: tidy\n"

      assert {:ok, _record} =
               PhasePR.maybe_create(request(%{command_runner: scripted_runner([], log)}))

      assert_receive {:gh_pr_create, args}
      assert title_arg(args) == "fix(auth): stop the login timeout"
    end

    test "falls back to the phase-named legacy title when no subject is conventional" do
      assert {:ok, _record} =
               PhasePR.maybe_create(
                 request(%{command_runner: scripted_runner([], "Foreman run run-1 phase 1\nwip\n")})
               )

      assert_receive {:gh_pr_create, args}
      assert title_arg(args) == "feat(phase): implement"
    end

    test "a blank task title is typed, and nothing is pushed" do
      runner = fn
        "git", ["rev-list", "--count", _], _opts -> {"1\n", 0}
        executable, args, _opts -> flunk("unexpected: #{executable} #{inspect(args)}")
      end

      assert {:error, %PhasePR.Error{reason: :task_title_invalid}} =
               PhasePR.maybe_create(request(%{task_title: "   ", command_runner: runner}))
    end
  end
```

Red before §4 (`task_title:` is not a struct key yet, so this is a `KeyError`):

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/phase_pr_test.exs'
```

## 4. Edits

**1. phase_pr.ex `Request` `defstruct` (lines 64-78).** Add `:task_title` after
`:artifact_path`. Do NOT add it to `@enforce_keys`.

**2. phase_pr.ex `validate_request/1` (lines 159-173).** Add one `cond` clause immediately
before `true -> :ok`:

```elixir
      invalid_task_title?(request) ->
        typed_error(request, :task_title_invalid, %{task_title: request.task_title})
```

and below `validate_request/1`:

```elixir
  # `nil` is "this run has no task title" (the executor omits an unset field);
  # anything else that is not a non-blank binary is a producer bug, typed before
  # the branch is published rather than silently titled (AGENTS.md §5.3).
  defp invalid_task_title?(%Request{task_title: nil}), do: false

  defp invalid_task_title?(%Request{task_title: title}),
    do: not is_binary(title) or String.trim(title) == ""
```

**3. phase_pr.ex `gh_pr_create/2` (line 345).** Replace
`title = "feat(phase): #{request.phase_name}"` with `title = pr_title(request)`, and add
directly above `defp gh_pr_create(request, tip) do`:

```elixir
  # The title an operator recognises: the run's task title, else the first
  # conventional-commit subject the run's own commits carry (Foreman's phase
  # commits, "Foreman run <id> phase <n>", are not conventional and never match),
  # else the phase-named legacy form. A `git log` that cannot be read only costs
  # the subject fallback: the PR is still opened, with the legacy title.
  defp pr_title(%Request{task_title: title}) when is_binary(title), do: title

  defp pr_title(request),
    do: first_conventional_subject(request) || "feat(phase): #{request.phase_name}"

  defp first_conventional_subject(request) do
    case run(request, "git", [
           "log",
           "--reverse",
           "--format=%s",
           request.base_branch <> ".." <> request.head_branch
         ]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.find(&conventional_subject?/1)

      {_output, _exit_code} ->
        nil
    end
  end

  @conventional_subject ~r/^[a-z]+(\([^()]+\))?!?: \S/
  defp conventional_subject?(subject), do: Regex.match?(@conventional_subject, subject)
```

**4. phase_pr.ex `@moduledoc` (lines 2-45).** Append before the closing `"""`:

```
  The PR title is the run's task title (`task_title`, passed by `RunExecutor` through the
  task plumbing the final `AutoPR` uses); without one it is the first conventional-commit
  subject among the run's commits, and without that `feat(phase): <phase_name>`. A
  `task_title` that is present but blank or not a binary is
  `%Error{reason: :task_title_invalid}` before anything is pushed.
```

**5. run_executor.ex `request_phase_pr/5` (lines 3019-3029).** Add one field to the struct
literal after `artifact_path: artifact_path,`:

```elixir
               task_title: phase_pr_task_title(state),
```

and add this helper directly below `defp run_head_branch(state)` (which ends at line 3050):

```elixir
  # The phase PR's title source, read through the same plumbing the final AutoPR
  # uses (`task_backed?/1` + `task_field/2`): no new channel. A run with no task,
  # or a task with no title, leaves the field nil and `PhasePR` falls back itself.
  defp phase_pr_task_title(state) do
    if task_backed?(state) do
      task_field(Map.get(state, :task) || %{}, :title)
    end
  end
```

**6. `docs/user-guide.md` line 2964** currently ends the phase-PR paragraph with
`final AutoPR; no-op records do not.` Append to that paragraph:

```
A phase PR is titled with the run's task title; a run
with no task title is titled with the first conventional-commit subject among the run's
commits, and failing that with `feat(phase): <phase>`. A task title that is present but
blank fails the phase with a typed error before anything is pushed.
```

**7. `docs/cli-reference.md` line 619** contains the sentence ``Task-backed final AutoPRs
use exact task metadata (`Task.title` as PR title, `Task.description` as PR body); ad-hoc
no-task runs keep the legacy generated run/artifact PR text.`` Insert directly after it:
``Phase PRs (`stack_pr: true`) use the task title as the PR title, falling back to the
run's first conventional-commit subject and then to `feat(phase): <phase>`.``

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && mix format'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/workflow/phase_pr_test.exs \
  test/foreman_server/workflow/phase_pr_body_test.exs \
  test/foreman_server/workflow/auto_pr_test.exs \
  test/foreman_server/pr_delivery_adversarial_keys_test.exs --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = every test passes with zero warnings, including the four new title tests.

Doc gate: no route, CLI verb, env var, config key, MCP tool or event type is added,
removed or renamed; `task_title` is a new field on the internal `PhasePR.Request` struct
only. The two operator-visible docs that describe PR titles are edited in §4.6-4.7.
`CLAUDE.md` and `README.md` contain no `feat(phase)` or phase-PR-title text (verified by
grep) and need no edit.

## 6. Out of scope

- `AutoPR` title/body resolution (auto_pr.ex:657-712): it keeps its own chain
  (task title → `feat(run): <run_id>`). Do NOT extract a shared title builder — the two
  chains differ and no shared builder exists today.
- `Workflow.Lowering.commit_message/2` (lowering.ex:144) and any commit-message format.
- `PrCreate.put_task_fields/2` (pr_create.ex:198) and `RepoPrContext.put_task_metadata/3`
  (repo_pr_context.ex:87) — already correct, leave untouched.
- PR bodies, `ReviewFindings`, effect keys, lookup/retry behaviour.
- Do not reorder `Request`'s fields, restructure `validate_request/1`'s `cond`, or edit
  adjacent doc paragraphs beyond the two sentences named above.
