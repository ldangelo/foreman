# PLAN — foreman-7gyd7: fix workflow never shows the task description to the worker

Branch rebased onto `origin/main` tip `1334dc59` before this plan was written.
Paths are relative to `packages/foreman_server/` unless stated otherwise.

## 1. Verdict

**Real bug, present on the current tree.**

- `lib/foreman_server/workflow/run_executor.ex:3523` `prompt_template_assigns/5` merges these
  keys: `project_context`, `project_instructions`, `project_memory`, `artifact_path`,
  `phase_index`, `phase_name`, `project_id`, `run_id`, `task_id`, `workflow_digest`,
  `workflow_name`, `input.prompt` (`:3560`), `input.prompt_argument` (`:3561`), `repositories`,
  worktree keys. **No task title/description key exists.**
- `priv/defaults/workflows/prompts/fix-plan.md:47-51`, `fix.md:50-54`, `discover.md:44-48`,
  `implement.md:45-49`, `verify.md:44-48` each render only
  `{{#section input.prompt}} / ## Task Prompt / {{input.prompt}} / {{/section}}`.
- `fix-plan.md:15`: "If there is no Task Prompt section, STOP: write `Blocked: no issue
  description supplied` as the sole content of the artifact and exit."
- A description-only task (no `input.prompt`) therefore renders no subject section and the plan
  phase blocks. The description reaches only `command:` phases, via `plan_subject_env/1`
  (`run_executor.ex:5412`, `FOREMAN_TASK_TITLE` / `FOREMAN_TASK_DESCRIPTION`).

**Important:** the "no issue description supplied" STOP sentence is in **`fix-plan.md:15`**, not
`fix.md`. `fix.md:15`'s STOP is about a missing `PLAN.md` (`Blocked: no plan found`) and must not
be changed.

## 2. Root cause

`prompt_template_assigns/5` (`lib/foreman_server/workflow/run_executor.ex:3523-3570`) exposes no
`task.title` / `task.description` assigns, so the bundled prompts have no placeholder for the
dispatched task's own text. A prompt phase sees the subject only when the operator also supplied
`workflow_snapshot["input"]["prompt"]`.

## 3. Failing check first

Write the tests first and watch them fail on unmodified code.

**(A) `test/foreman_server/workflow/run_executor_prompt_section_test.exs`** — this file renders the
real bundled prompts through a mirrored renderer (`render_for_test/2`). Add three tests inside the
existing `describe "TRD-021: ..."` block, before the `# Internal test helper` comment. Each reuses
the assigns shape already used by the `implement.md` test at line 82 (`artifact_path`,
`phase_index`, `phase_name`, `project_id`, `run_id`, `task_id`, `workflow_digest`,
`workflow_name`, `input.prompt`, `input.prompt_argument`) plus the two new keys.

1. `"fix-plan.md renders the Task Description section for a description-only task"` —
   `content = File.read!(Path.join(@prompts_dir, "fix-plan.md"))`; assigns with
   `"input.prompt" => ""`, `"input.prompt_argument" => ""`,
   `"task.title" => "Login redirect loops"`,
   `"task.description" => "Signing in bounces between /login and /session."`. Assertions:

   ```elixir
   result = render_for_test(content, assigns)

   assert result =~ "## Task Description"
   assert result =~ "Signing in bounces between /login and /session."
   assert result =~ "## Task Title"
   assert result =~ "Login redirect loops"
   refute result =~ "## Task Prompt"
   refute result =~ "{{task.description}}"
   ```

2. `"fix-plan.md keeps the Task Prompt section when only the prompt is set"` — same file, assigns
   with `"input.prompt" => "Fix the login redirect loop"`,
   `"input.prompt_argument" => "\"Fix the login redirect loop\""`, `"task.title" => ""`,
   `"task.description" => ""`. Assertions: `assert result =~ "## Task Prompt"`,
   `assert result =~ "Fix the login redirect loop"`, `refute result =~ "## Task Description"`,
   `refute result =~ "{{input.prompt}}"`. This pins the existing behaviour.

3. `"fix.md renders the Task Description section for a description-only task"` — same as (1) but
   `fix.md`, `phase_name` `"fix"`, `artifact_path` `/tmp/FIX_REPORT.md`; assert
   `"## Task Description"` and the description text, `refute result =~ "## Task Prompt"`.

**(B) `test/foreman_server/workflow/run_executor_test.exs`** — add one test at the end of
`describe "prompt_template_assigns/4 — input.prompt keys"` (before its closing `end`, ~line 4360);
it reuses that block's `make_state/1` and `phase_spec/0`:

```elixir
    test "task.title and task.description come from the task; absent fields render empty" do
      state = make_state(%{"workflow_name" => "fix", "workflow_digest" => "abc"})
      assigns = RunExecutor.prompt_template_assigns(state, phase_spec(), 1, %{}, nil)

      assert assigns["task.title"] == ""
      assert assigns["task.description"] == ""

      with_task =
        state
        |> put_in([:task, "title"], "Login redirect loops")
        |> put_in([:task, "description"], "Signing in bounces between /login and /session.")

      assigns = RunExecutor.prompt_template_assigns(with_task, phase_spec(), 1, %{}, nil)

      assert assigns["task.title"] == "Login redirect loops"
      assert assigns["task.description"] == "Signing in bounces between /login and /session."
    end
```

Failing-before command (from the repository root):

```bash
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test test/foreman_server/workflow/run_executor_prompt_section_test.exs test/foreman_server/workflow/run_executor_test.exs --warnings-as-errors'
```

Expected before the fix: the section tests fail on `assert result =~ "## Task Description"` (no
such markers in the templates) and the assigns test fails because `assigns["task.title"]` is `nil`.

## 4. Edits

**1. `lib/foreman_server/workflow/run_executor.ex`, `prompt_template_assigns/5`.** The unique
anchor is line 3560, `      "input.prompt" => input_prompt(workflow_snapshot),` (do NOT anchor on
`"task_id" =>`, which occurs twice in the file). Insert immediately **before** it:

```elixir
      # The dispatched task's own subject. `command:` phases already get this through
      # FOREMAN_TASK_TITLE / FOREMAN_TASK_DESCRIPTION (`plan_subject_env/1`); a prompt phase had
      # no channel for it, so a description-only task rendered no subject at all. Empty string,
      # never nil, so `render_sections/2` drops the section when the task has no such field.
      "task.title" => render_template_value(task_field(state.task, :title)),
      "task.description" => render_template_value(task_field(state.task, :description)),
```

`task_field/2` is the existing private helper at `:3171` (atom and string keys, `nil` for a
non-map); `render_template_value(nil)` returns `""` (`:3616`).

**2. `priv/defaults/workflows/prompts/fix-plan.md` line 15.** Replace the first two sentences:

> Produce an implementation plan for the bug or issue described under **Task Prompt** below. If there is no Task Prompt section, STOP: write `Blocked: no issue description supplied` as the sole content of the artifact and exit.

with:

> Produce an implementation plan for the bug or issue described under **Task Prompt** or **Task Description** below. If NEITHER a Task Prompt nor a Task Description section exists, STOP: write `Blocked: no issue description supplied` as the sole content of the artifact and exit.

Leave the rest of the line ("Do not guess a subject. You are running in headless mode, ...") as is.

**3. Append this block to the end of `fix-plan.md`, `fix.md`, `discover.md`, `implement.md` and
`verify.md`**, after each file's existing trailing `{{/section}}`, keeping the current
`{{#section input.prompt}}` block untouched (`discover.md`, `implement.md` and `verify.md` have no
trailing newline today — add one first):

```
{{#section task.title}}

## Task Title

{{task.title}}
{{/section}}
{{#section task.description}}

## Task Description

{{task.description}}
{{/section}}
```

Do not touch `fix.md:15` (its STOP is the `PLAN.md` one).

**4. `CHANGELOG.md`** — first bullet under `## Unreleased` → `### Fixed`:

```markdown
- **A prompt phase now sees the dispatched task's title and description.**
  `RunExecutor.prompt_template_assigns/5` exposes `task.title` and `task.description`, and the
  bundled `fix-plan.md`, `fix.md`, `discover.md`, `implement.md` and `verify.md` prompts render
  them as `## Task Title` / `## Task Description` sections. A description-only task used to render
  no subject at all (only `{{input.prompt}}` was available), so the `fix` workflow's plan phase
  blocked with `Blocked: no issue description supplied`; that STOP now fires only when neither a
  Task Prompt nor a Task Description section is present. Installed copies under
  `~/.foreman/workflows` stay stale until `foreman workflow install` is run.
```

## 5. Verification

```bash
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test test/foreman_server/workflow/run_executor_prompt_section_test.exs test/foreman_server/workflow/prompt_renderer_test.exs test/foreman_server/workflow/run_executor_test.exs test/foreman_server/agent_runtime/trd_017_test.exs --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted lib/foreman_server/workflow/run_executor.ex test/foreman_server/workflow/run_executor_prompt_section_test.exs test/foreman_server/workflow/run_executor_test.exs'
```

Success = both exit 0, zero failures, no warnings. `trd_017_test.exs` and the existing
`input.prompt` cases must stay green (they pin the prompt-only behaviour).

**Documentation gate** (surveyed; re-check after the edits). Added identifiers: template keys
`task.title`, `task.description`; prompt headings `## Task Title`, `## Task Description`. Nothing
removed or renamed. `grep -rn "input.prompt\|Task Prompt" CLAUDE.md README.md docs/user-guide.md
docs/cli-reference.md` hits only `docs/user-guide.md:129` and `:1542` (`{{input.prompt}}` as a
**command-string** placeholder) and `docs/cli-reference.md:725` (`--prompt`); none becomes wrong.
Those four files carry no prompt-placeholder list, so no doc edit is needed — state that
explicitly in the fix report.

## 6. Out of scope

- `priv/defaults/workflows/fix.yaml`, `lib/foreman_server/mcp/tools.ex`, `task.create` validation
  (option (a) only — no new validation anywhere).
- `review-*.md`, `assess.md`, `release.md` and every other bundled prompt.
- `plan_subject_env/1` / `FOREMAN_TASK_*` env plumbing (`run_executor.ex:5412`).
- `fix.md:15`'s `Blocked: no plan found` STOP.
- `.beads/` and `docs/reports/` (including this plan): no plan or report documents in the PR.
- Running the full suite; run only the narrow files above plus `mix format`.
- Refactoring `render_sections/2`, `render_template_value/1` or `task_field/2`.

PR title: `fix(workflow): render task title and description in bundled prompts`
