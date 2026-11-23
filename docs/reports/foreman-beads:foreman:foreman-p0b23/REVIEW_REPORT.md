# Repository-rules review — `beads:foreman:foreman-p0b23`

## Review engine

- **Reviewer:** the repository-rules reviewer (`repo-rules`), phase 4 of run `run-1d5bb343dcae0b4d55f102b84a26ad14`.
- **Diff range reviewed:** `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with `FOREMAN_BASE_BRANCH=main`; merge-base `f0f3b0839bfba157a568378500c7db9105e88d2a`, HEAD `f2ee5845` — 20 files, +1288 lines. The diff was read once, the findings below were fixed, and the diff was read once more afterwards to confirm the fixes introduce no new violation.
- **Rules applied:** the repository's own root conventions file `AGENTS.md` — §5.2 (total result handling), §5.3 (absent ≠ malformed), §5.7 (never duplicate a boundary across transports/adapters; share one module and test both variants), the documentation gate, and the "surgical changes" rule. Where `AGENTS.md` is silent, the established idiom of the touched files was used.
- **Carried-forward findings:** none. `docs/reports/foreman-beads:foreman:foreman-p0b23/REVIEW_CODERABBIT_REPORT.md` exists, but it carries **no machine-readable findings block** (zero `FOREMAN_REVIEW_FINDINGS_START` / `FOREMAN_RISK_JUDGEMENT_START` markers in it, in `FIX_REPORT.md` or in `PLAN.md`), so there was no `findings` array to copy. Its prose mentions 19 CodeRabbit findings (18 fixed, 1 declined) without path/line/severity objects; those are not carried forward as findings objects, because inventing them here would fabricate a review result. The previous phase's own work is therefore not represented in this block.
- **Scope note:** the phase's own fix set (the shared `PrBodyContext` module and the documentation corrections below) is left uncommitted in the worktree; Foreman commits it.

## Findings

| # | Severity | Location | Finding | Disposition |
| --- | --- | --- | --- | --- |
| 1 | major | `docs/user-guide.md:757` | The "Pull-request body template" prose described a heading/content mapping the code does not implement (artifact "under the last heading", extra headings "share the last block"), while `PrBody.contents_under/2` maps content to headings **positionally**. | fixed |
| 2 | minor | `docs/user-guide.md:736` | The new `pr_body_headings` settings row was separated from the settings table by a blank line, so it rendered as a headerless one-row table instead of a row of that table. | fixed |
| 3 | major | `packages/foreman_server/lib/foreman_server/pr_create.ex:216` | The project-settings → PR-context mapping was written out three times (here, in `workflow/repo_pr_context.ex`, in `workflow/run_executor.ex`), which `AGENTS.md` §5.7 forbids. | fixed |
| 4 | minor | `packages/foreman_server/lib/foreman_server/workflow/repo_pr_context.ex:89` | The comment block of the duplicated helper was glued to the previous function's comment, with no blank line between them. | fixed |
| 5 | minor | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:3131` | The run executor takes the project settings latched at run start while the command doors take the live projection — the same setting read from two sources. | declined |
| 6 | minor | `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:347` | The pull request a workflow phase opens for its own work keeps the phase's own body and does not use the new template. | declined |

## Fixed

1. **`docs/user-guide.md:757` — documentation described behaviour the diff does not have.**
   Wrong: the prose said Foreman puts "the phase artifact — with the review findings block — under the last" heading and that "with more headings than Foreman has content for, the extra headings share the last block". The implementation in `packages/foreman_server/lib/foreman_server/workflow/pr_body.ex` (`contents_under/2`) places content **positionally**: the task under the first heading, the commits under the next, the artifact under the next, any content beyond the last heading under that last heading, and a heading with no content reads `_Not recorded by Foreman._`.
   Changed: the paragraph now states the positional mapping the code implements, including "Any content beyond the last heading goes under the last heading." and the `_Not recorded by Foreman._` rule. The paragraph's claim now matches `pr_body_test.exs`, which locks the same behaviour.

2. **`docs/user-group.md` → `docs/user-guide.md:736` — the settings row was outside its table.**
   Wrong: the diff inserted a blank line between the last row of the project-settings table and the new `pr_body_headings` row, so the row rendered as a separate table with no header.
   Changed: the blank line was removed; the row now sits in the settings table (`main` has the blank line after the last row, not before it), and one blank line still separates the table from the paragraph that follows.

3. **`packages/foreman_server/lib/foreman_server/pr_create.ex:216` and two siblings — one boundary written three times.**
   Wrong: `pr_create.ex`, `workflow/repo_pr_context.ex` and `workflow/run_executor.ex` each carried their own private `put_pr_body_headings/2` (resp. `maybe_put_pr_body_headings/2`) with the same settings→context mapping. `AGENTS.md` §5.7: "Never duplicate a boundary across transports/adapters; share one module and test both variants." Three copies of the same mapping is how the doors drift.
   Changed: the mapping now lives once in a new module `ForemanServer.Workflow.PrBodyContext` (`packages/foreman_server/lib/foreman_server/workflow/pr_body_context.ex`) with `put_headings/2` (context + `%ProjectSettings{}`) and `put_project_headings/2` (context + project id, reading the live projection). The three call sites now call it and their private copies are deleted. The settings **source** stays where it was: the run executor keeps its latched `state.project_settings` (`latch_project_settings/1`, taken when the run starts), the command doors keep the live `ProjectionStore.project_settings/1` — the module's `@moduledoc` says so. The three-way semantics are unchanged: unset ⇒ the key is omitted (the body stays the task's own text), `{:headings, h}` ⇒ the key is set, `{:malformed, v}` ⇒ the value is forwarded unchanged so `PrBody.build/2` refuses it (`AGENTS.md` §5.2).

4. **`packages/foreman_server/lib/foreman_server/workflow/repo_pr_context.ex:89` — glued comment.**
   Wrong: the duplicated helper's comment block ran straight into `put_task_metadata/2`'s comment with no blank line, so the two read as one comment.
   Changed: resolved with finding 3 — the helper and its comment are gone, and `put_task_metadata/2` keeps its own comment followed by a blank line.

New file `packages/foreman_server/lib/foreman_server/workflow/pr_body_context.ex` and new test `packages/foreman_server/test/foreman_server/workflow/pr_body_context_test.exs` (6 tests: headings put into the context, key omitted when the project requires none, key omitted when the settings are absent, a non-list value forwarded unchanged so the PR builder refuses it, unknown project leaves the context unchanged, a run with no project leaves the context unchanged).

## Declined

1. **`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:3131` — latched vs. live project settings.** The run executor reads the settings the run started with; `pr_create.ex` and `repo_pr_context.ex` read the live projection. Declined: the run executor's latching is deliberate (`latch_project_settings/1`, `AGENTS.md`'s "a run must not change under itself"), the duplication of the *mapping* — which was the actual §5.7 violation — is now removed, and the divergence between the two sources is documented in the shared module. Changing the run executor to a live read would be a behaviour change outside this review's scope.
2. **`packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:347` — phase pull requests keep their own body.** Declined: outside this bead's scope (the bead asks for the run's pull request), and the limitation is already stated in `docs/user-guide.md` ("A phase pull request — one a workflow phase opens for its own work — keeps that phase's own body"), so nothing is undocumented. The shared `PrBody` module was written to be reusable here later.

## Verification

All commands were run in the run's worktree with `devbox run` (Elixir 1.20.4 / OTP 28) and `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test_p0b23` (the standard `foreman_test` database is advisory-locked by another run: *"another `mix test` run already holds the database `foreman_test` (advisory lock)"*).

| Command | Exit | Result |
| --- | --- | --- |
| `MIX_ENV=test mix compile --warnings-as-errors` | 0 | "Compiling 17 files (.ex) / Generated foreman_server app", no warnings |
| `mix test --warnings-as-errors test/foreman_server/workflow/pr_body_context_test.exs test/foreman_server/workflow/pr_body_test.exs test/foreman_server/workflow/auto_pr_body_headings_test.exs test/foreman_server/pr_body_headings_setting_test.exs test/foreman_server/pr_create_test.exs test/foreman_server/workflow/run_executor_multi_repo_pr_test.exs test/foreman_server/project_settings_read_model_test.exs test/foreman_server/project_settings_replay_test.exs` | 0 | 99 tests passed (32.4s); "ProjectionLeakGuard: judged 3 of 4 modules, no run left behind" |
| `mix format --check-formatted` on the 4 edited modules, the new module, `pr_body.ex` and the new test | 0 | clean |
| `git diff --check` | 0 | no whitespace errors |
| `git diff "$FOREMAN_BASE_BRANCH"...HEAD` (second read, after the fixes) | 0 | no new violation introduced |

**Known pre-existing test hang (not caused by this diff, not fixed here):** `packages/foreman_server/test/foreman_server/workflow/auto_pr_test.exs` hangs (exit 124) on this database — with these fixes it completes 56 tests and stalls at `L#1281`; with the fixes stashed, i.e. at plain `HEAD` `f2ee5845`, it stalls earlier at `L#1221` after 53 tests, zero failures in both runs. The hang therefore predates this review's fixes, and this diff does not touch `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex`.

**Not run here:** `ask_advisor` (Anthropic oauth refresh failed — "Refresh token expired" / `invalid_grant`; the operator must re-authenticate) and `foreman_inbox_send` / `foreman_task_add_comment` (not on PATH in this phase), so no operator progress note or task Work Log comment was sent.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "docs/user-guide.md", "line": 757, "description": "The pull-request body template prose described a heading/content mapping the code does not implement (artifact under the last heading, extra headings sharing the last block) while PrBody.contents_under/2 maps content to headings positionally.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 736, "description": "A blank line separated the new pr_body_headings settings row from the project-settings table, so the row rendered as a headerless one-row table.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/pr_create.ex", "line": 216, "description": "The project-settings to PR-context mapping was written out three times (pr_create.ex, workflow/repo_pr_context.ex, workflow/run_executor.ex), which AGENTS.md 5.7 forbids.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/repo_pr_context.ex", "line": 89, "description": "The comment block of the duplicated helper was glued to the previous function's comment with no blank line between them.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/run_executor.ex", "line": 3131, "description": "The run executor reads the project settings latched at run start while the command doors read the live projection, so the same setting has two sources of truth.", "disposition": "declined", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex", "line": 347, "description": "The pull request a workflow phase opens for its own work keeps the phase's own body and does not use the new template.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The run adds an opt-in project setting that changes the body of the pull requests Foreman opens, with server-side validation, a new shared boundary module and user-facing documentation. It is additive and the default behaviour (no setting) is unchanged, but the generated text is operator-visible and touches the merge gate's input."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
