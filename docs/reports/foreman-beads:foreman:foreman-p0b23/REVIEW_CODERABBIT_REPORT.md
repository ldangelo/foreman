# CodeRabbit review — bead foreman-p0b23

Run `run-1d5bb343dcae0b4d55f102b84a26ad14`, phase `coderabbit-review` (phase index 3).

## Review engine

CodeRabbit CLI `v0.9.6` is on `PATH`. Every round ran from the worktree root
(`/Users/ldangelo/.foreman/worktrees/foreman/foreman-p0b23/run-1d5bb343dcae0b4d55f102b84a26ad14/workspace`).

- Round 1 — `timeout 600 coderabbit review --agent --base main > .cr_round1.log 2>&1` — exit `0`
  (status `completed`, 10 findings). `--base main` is the value of `$FOREMAN_BASE_BRANCH`
  (verified set to `main`).
- Rounds 2–4 — `timeout 600 coderabbit review --agent --base "$FOREMAN_BASE_BRANCH" > .cr_roundN.log 2>&1`
  — exit `0` each round (5, 2 and 2 findings).

The engine reviews the tracked diff against the base branch. The new
`packages/foreman_server/lib/foreman_server/workflow/pr_body.ex`,
`packages/foreman_server/lib/foreman_server/workflow/pr_body/sources.ex` and the three new test files were
still untracked in every round, so they were invisible to the engine. That is the root cause of the
round-3 critical finding, which is a false positive (see **Declined**).

## Rounds

| Round | Findings received | Fixed | Declined |
| --- | --- | --- | --- |
| 1 | 10 — 2 critical, 5 major, 3 minor | 10 | 0 |
| 2 | 5 — 5 minor | 5 | 0 |
| 3 | 2 — 1 critical, 1 minor | 1 | 1 |
| 4 | 2 — 2 minor | 2 | 0 |

Round 1 reviewed the tree as the run's earlier phases left it: the project setting existed and validated,
but the PR-body builder did not compile, was not wired into AutoPR, and had no tests. All ten findings were
real defects; fixing them is what produced the current implementation (a compiling
`ForemanServer.Workflow.PrBody` / `PrBody.Sources` pair wired through `AutoPR`, `RepoPrContext`,
`RunExecutor` and `PrCreate`).

Round 2 reviewed the fixed implementation and found five smaller hardening gaps (documentation of the
phase-PR exception, schema-derived MCP keys, error propagation for a failed commit lookup, commits taken
from the resolved PR head, and malformed heading values no longer silently dropped).

Round 3 produced one false critical (the engine could not see the untracked `PrBody` module) and one
legitimate minor (a malformed heading list dropped by the fallback path in three producers), which was fixed
with a single shared typed helper.

Round 4 produced two legitimate minors: a user-guide passage that still claimed the PR body is exactly the
task description, and a bare-map result payload where AGENTS.md §5.1 asks for an `@enforce_keys` struct.
Both were fixed.

No round produced an unfixed critical or major except the declined false positive below.

## Fixed

### Round 1 — the run's earlier work did not compile and was not wired

1. `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex:40` — the heading validation
   regex interpolated the repetition count instead of matching literal `#` characters, so the server package
   failed to compile. Changed to a regex that matches one to six literal `#` characters followed by a
   non-space character.
2. `packages/foreman_server/lib/foreman_server/run/pr_body.ex:183` — the reducer callback referenced an
   unbound variable, so the module could not compile. The stale module was removed and replaced by
   `packages/foreman_server/lib/foreman_server/workflow/pr_body.ex` plus
   `packages/foreman_server/lib/foreman_server/workflow/pr_body/sources.ex`, whose reducer carries the
   remaining file list in its accumulator.
3. `packages/foreman_server/lib/foreman_server/events/project_updated.ex` — the `ProjectUpdated` event had no
   `pr_body_headings` field, so the new setting could never persist. Added the typed field and its
   application in the event's projection of the settings.
4. `packages/foreman_server/lib/foreman_server/project_settings.ex` — the `ProjectSettings` typed state had no
   `pr_body_headings` field. Added it to the struct and to the `@type t`.
5. `packages/foreman_server/lib/foreman_server/run/pr_body.ex:31` — the new builder had no caller, so the
   template was never applied to a pull request. Wired `AutoPR.templated_pr_content/3` to
   `PrBody.build/2`, and the same setting through `RepoPrContext` and `RunExecutor` so an explicitly
   requested body reaches the PR.
6. `packages/foreman_server/lib/foreman_server/run/pr_body.ex:71` — `first_usable_line/1` returned a tuple
   that leaked out of `Enum.find_value` and corrupted the rendered body. It now returns only the line.
7. `packages/foreman_server/lib/foreman_server/run/pr_body.ex:177` — the reducer accumulator shape did not
   match the shape matched outside it. Both sides now use the same accumulator.
8. `packages/foreman_server/lib/foreman_server/run/pr_body.ex:95` — the subject was invented rather than
   derived. The subject now comes from the task.
9. `packages/foreman_server/lib/foreman_server/run/pr_body.ex:118` — malformed heading entries produced no
   explicit error. `ForemanServer.Aggregates.Project.Settings.validate_pr_body_headings/1` now returns
   `{:error, {:pr_body_headings_entry_invalid, heading}}`, `{:error, {:pr_body_headings_too_many, count, limit}}`
   and `{:error, {:pr_body_headings_invalid, value}}`, and the aggregate rejects the command with that error.
10. `packages/foreman_server/lib/foreman_server/run/pr_body.ex:280` — an oversized body fell back to a
    placeholder that claimed the artifact had no content, and the clamp rebuilt the default headings
    instead of the configured ones while `Enum.zip/2` dropped a chunk. An oversized body is now an explicit
    `{:error, %PrBody{reason: :body_too_large, ...}}`, and the configured heading/content pairs are what is
    rendered.

### Round 2 — hardening of the implementation

11. `docs/user-guide.md:745` — the user guide did not say that a phase pull request keeps its own body and
    does not apply the project's `pr_body_headings` template. The limitation is now documented next to the
    template.
12. `packages/foreman_server/lib/foreman_server/mcp/tools.ex:2513` — the settings-update key list was
    hand-maintained beside the schema and could drift. It is now derived from the schema's own properties.
13. `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex:756` — a failed `git log` returned an
    empty commit list, indistinguishable from a repository with no commits. The lookup now returns
    `{:ok, commits}` or `{:error, detail}`, and the error is not rendered as "no commits".
14. `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex:727` — commits were collected from the
    context's head branch instead of the resolved PR head. They now come from `resolve_head_branch/1`.
15. `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex:669` — a non-list `pr_body_headings`
    value was treated as unset. It now reaches the typed `PrBody.build/2` boundary and is refused there.

### Round 3

16. `packages/foreman_server/lib/foreman_server/pr_create.ex:220` — a malformed heading list was dropped by
    the fallback in `PrCreate`, `RepoPrContext` and `RunExecutor`. All three now call one public helper,
    `ForemanServer.ProjectSettings.pr_body_headings/1`, which returns `:unset | {:headings, list} |
    {:malformed, value}`. The malformed value is forwarded into the auto-PR context, where the existing typed
    boundary refuses it (`{:error, %PrBody{reason: :invalid_headings, detail: value}}`), and
    `RunExecutor` logs that typed error at ERROR level ("auto-pr FAILED: …") instead of silently dropping the
    setting.

### Round 4

17. `docs/user-guide.md:737` — the user guide still claimed that a task-backed final body is exactly the
    task description and carries no artifact or review-finding sections. Both passages (the AutoPR section
    and the artifact section) now qualify the claim with "when the project sets no `pr_body_headings`" and
    point at **Pull-request body template**.
18. `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex:705` — the templated PR content was
    returned as a bare map. A nested `ForemanServer.Workflow.AutoPR.PrContent` struct with
    `@enforce_keys [:title, :body]` is now returned by all three producers
    (`templated_pr_content/3`, `task_or_legacy_pr_content/1`, `legacy_pr_content/1`) and pattern-matched in
    `gh_pr_create/7`.

## Declined

- `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex:699` (round 3, critical) — "Add the missing
  `ForemanServer.Workflow.PrBody` module, or `auto_pr.ex` will not compile." Declined: the finding is a false
  positive. `ForemanServer.Workflow.PrBody` and `ForemanServer.Workflow.PrBody.Sources` exist and are
  imported by `auto_pr.ex`; they were simply still untracked, and CodeRabbit reviews the tracked diff only.
  Evidence: `MIX_ENV=test mix compile --warnings-as-errors` exits `0`, and the module files are present at
  `packages/foreman_server/lib/foreman_server/workflow/pr_body.ex` and
  `packages/foreman_server/lib/foreman_server/workflow/pr_body/sources.ex`. Nothing was changed in response
  to this finding.

## Verification

- `timeout 600 coderabbit review --agent --base main` (round 1) — exit `0`, 10 findings.
- `timeout 600 coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (rounds 2, 3, 4) — exit `0` each.
- `mix format` on the edited Elixir files — exit `0`, no changes.
- `MIX_ENV=test mix compile --warnings-as-errors` — exit `0`.
- Test runs (private database `foreman_test_p0b23` on `localhost:55432`; the standard `foreman_test`
  database was held by another run's advisory lock):
  - `mix test` on `workflow/auto_pr_body_headings_test.exs`, `workflow/auto_pr_test.exs`,
    `workflow/auto_pr_block_reset_resume_test.exs`, `workflow/phase_pr_body_test.exs`, `pr_body_test.exs`,
    `pr_body_headings_setting_test.exs`, `pr_create_test.exs` — 126 passed.
  - `mix test` on `workflow/run_executor_test.exs`, `workflow/run_executor_autopr_task_metadata_test.exs`,
    `workflow/run_executor_multi_repo_pr_test.exs`, `workflow/repo_pr_context_test.exs` — 74 passed.
  - Earlier in the phase, after the round-1/2 fixes: 17 passed (pr body suites), 175 passed (PR, MCP and
    settings suites), 51 passed (`workflow/run_executor_test.exs`).
- Documentation gate: `pr_body_headings` appears in `CLAUDE.md`, `docs/user-guide.md` and
  `docs/cli-reference.md`; `--pr-body-heading` and the three `pr_body_headings_*` error tuples appear in
  `docs/user-guide.md`; `README.md` lists no project settings, so it needed no edit. The new
  `ForemanServer.Workflow.AutoPR.PrContent` struct is internal and not operator-visible.

All fixes are left uncommitted for Foreman to commit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "critical", "path": "packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex", "line": 40, "description": "The heading validation regex interpolated the repetition count instead of matching literal hash characters, so the server package failed to compile.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "critical", "path": "packages/foreman_server/lib/foreman_server/run/pr_body.ex", "line": 183, "description": "The reducer callback referenced an unbound variable, so the pull-request body builder could not compile.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/events/project_updated.ex", "line": null, "description": "The ProjectUpdated event had no pr_body_headings field, so the new setting could never persist.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/project_settings.ex", "line": null, "description": "The ProjectSettings typed state had no pr_body_headings field, so the projection could not carry the setting.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/run/pr_body.ex", "line": 31, "description": "The new pull-request body builder had no caller, so the headings template was never applied to a pull request.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/run/pr_body.ex", "line": 71, "description": "first_usable_line/1 returned a tuple that leaked out of Enum.find_value and corrupted the rendered body.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/run/pr_body.ex", "line": 177, "description": "The reducer accumulator shape did not match the shape matched outside it, so the body could not be assembled.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/run/pr_body.ex", "line": 95, "description": "The subject was invented rather than derived from the task, so the pull request carried a made-up title.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/run/pr_body.ex", "line": 118, "description": "Malformed heading entries produced no explicit error, so an invalid heading list was accepted silently.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/run/pr_body.ex", "line": 280, "description": "An oversized body fell back to a placeholder claiming the artifact had no content and rebuilt the default headings instead of the configured ones.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 745, "description": "The user guide did not state that phase pull requests keep their own body and do not apply the project pr_body_headings template.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/mcp/tools.ex", "line": 2513, "description": "The settings-update key list was hand-maintained beside the schema and could drift from it.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex", "line": 756, "description": "A failed git log returned an empty commit list indistinguishable from a repository with no commits.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex", "line": 727, "description": "Commits were collected from the context head branch instead of the resolved pull-request head branch.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex", "line": 669, "description": "A non-list pr_body_headings value was silently treated as unset instead of reaching the typed PrBody boundary.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "critical", "path": "packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex", "line": 699, "description": "CodeRabbit reported that the ForemanServer.Workflow.PrBody module is missing and auto_pr.ex cannot compile, but the module exists and only the tracked diff was reviewed.", "disposition": "declined", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/pr_create.ex", "line": 220, "description": "A malformed heading list was dropped by the fallback in PrCreate, RepoPrContext and RunExecutor instead of raising or returning an error.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 737, "description": "The user guide still claimed the final pull-request body is exactly the task description and carries no artifact or review-finding sections.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex", "line": 705, "description": "The templated pull-request content was returned as a bare map instead of an enforce-keys struct.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change is additive and opt-in: a new pr_body_headings project setting that is unset by default, so existing projects keep the current exact-task-body behaviour. It does add a new module, a new typed boundary and new CLI/MCP/LiveView surfaces, and it changes how an opted-in project's pull-request body is generated, which is operator-visible. All CodeRabbit findings are fixed except one declined false positive (the engine could not see the untracked PrBody module; the package compiles clean)."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
