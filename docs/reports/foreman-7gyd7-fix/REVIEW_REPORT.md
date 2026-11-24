# Repo-rules review — foreman-7gyd7-fix

## Review engine

Repository-rules reviewer (this phase): `repo-rules`, reviewing this run's own
diff against the repository's own contributor rules.

Exact diff range reviewed:

```
git diff "$FOREMAN_BASE_BRANCH"...HEAD
# FOREMAN_BASE_BRANCH=main
# local main == origin/main == 4f37fa9674237d73c4ef43515e16a76c43511416
# merge-base(origin/main, HEAD) = 1334dc59ad7d7d5b14ca721ffc5890a43668d80d
# HEAD = 0a48c32a
```

Committed diff (11 files, +375/-1): `docs/reports/foreman-7gyd7-fix/FIX_REPORT.md`,
`docs/reports/foreman-7gyd7-fix/PLAN.md`,
`docs/reports/foreman-7gyd7-fix/REVIEW_CODERABBIT_REPORT.md`,
`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`,
`packages/foreman_server/priv/defaults/workflows/prompts/{discover,fix-plan,fix,implement,verify}.md`,
`packages/foreman_server/test/foreman_server/workflow/run_executor_prompt_section_test.exs`,
`packages/foreman_server/test/foreman_server/workflow/run_executor_test.exs`.

Rules applied: the repository root contributor-guidance file `AGENTS.md` (Working
Rules, Documentation Gate, §5 Typed Boundaries, Invariants, Testing and Safety),
the CI gate in `.github/workflows/ci.yml` (line 138 runs
`cd packages/foreman_server && mix format --check-formatted`), the established
idioms of the touched files, and the doc set `CLAUDE.md`, `README.md`,
`docs/user-guide.md`, `docs/cli-reference.md`, `docs/lessons/*.md`.

**Carry-forward:** the previous phase's `docs/reports/foreman-7gyd7-fix/REVIEW_CODERABBIT_REPORT.md`
exists but contains no readable findings block — its whole content is a captured
tool-call wrapper (`<invoke "bash"><parameter name="command">cd /Users/... && grep -rn "prompt_template_assigns\|input.prompt" docs/lessons/*.md docs/user-guide.md | head -30</parameter>`),
with no `findings` array. There is therefore nothing to carry forward into this
report's findings block; the `findings` array below contains only this phase's
own findings.

## Findings

| # | Severity | File | Finding | Disposition |
| --- | --- | --- | --- | --- |
| 1 | major | `packages/foreman_server/CHANGELOG.md` | The run adds two new prompt-template keys and changes the `fix-plan` stop condition but ships no `Unreleased`/`Fixed` entry, so an operator reading the changelog cannot learn the change — and cannot learn that installed copies under `~/.foreman/workflows` stay stale until they are refreshed. | fixed |
| 2 | minor | `docs/user-guide.md` | The new `{{task.title}}` / `{{task.description}}` prompt-template keys are undocumented: §13 "Standing context" enumerates the prompt-template placeholders (`{{project_context}}`, `{{project_instructions}}`, `{{project_memory}}`) but not the two new ones, so a user writing a custom prompt template cannot discover them. | fixed |
| 3 | major | `packages/foreman_server/test/foreman_server/workflow/run_executor_test.exs` | The test the run added is not `mix format` clean, so the repository's own CI format gate (`mix format --check-formatted`, `.github/workflows/ci.yml:138`) fails on this branch. | fixed |
| 4 | minor | `packages/foreman_server/test/foreman_server/workflow/run_executor_prompt_section_test.exs` | Same format-gate failure as finding 3: the run's added assertion line is not `mix format` clean. | fixed |
| 5 | nitpick | `packages/foreman_server/test/foreman_server/workflow/run_executor_prompt_section_test.exs` | The new `render_for_test/2` helper re-implements the production renderer's section/substitution logic instead of calling it, so the test could pass while production rendering breaks. | declined |
| 6 | nitpick | `packages/foreman_server/priv/defaults/workflows/prompts/review-repo-rules.md` | The review prompts still render only `{{#section input.prompt}}`, so a description-only task still shows no description to a review phase. | declined |
| 7 | nitpick | `docs/reports/foreman-7gyd7-fix/REVIEW_CODERABBIT_REPORT.md` | The previous phase's artifact is a one-line captured tool-call wrapper rather than a report, and `FIX_REPORT.md` is likewise a one-line fragment. | declined |

## Fixed

1. **`packages/foreman_server/CHANGELOG.md`** — wrong: the run added the
   `task.title` / `task.description` prompt-template keys and reworded the
   `fix-plan` stop condition without any `Unreleased` → `Fixed` entry, so the
   change was invisible to operators and the stale-installed-copy consequence was
   unstated. Changed: inserted a bullet at the top of the `### Fixed` list under
   `## Unreleased` recording that the bundled `discover.md`, `fix-plan.md`,
   `fix.md`, `implement.md` and `verify.md` prompts now render the dispatched
   task's title and description as their own `Task Title` / `Task Description`
   sections, that `fix-plan.md` stops with `Blocked: no issue description
   supplied` only when neither a Task Prompt nor a Task Description section is
   present, that the new template keys are the empty string when the run carries
   no task, and that installed copies under `~/.foreman/workflows` stay stale
   until the operator refreshes them (`foreman init --force`, or `foreman
   workflow install`).

2. **`docs/user-guide.md`** — wrong: the two new prompt-template keys were
   undocumented; §13 "Standing context" is the only place in the repository that
   enumerates prompt-template placeholders and it listed none of them. Changed:
   extended the "**Delivery.**" paragraph of §13 with the two keys, their
   empty-string-when-absent behaviour, the bundled prompts that now render them
   as their own sections, and the pointer that a `command:` phase has no
   rendered prompt and reads the same two values from the
   `FOREMAN_TASK_TITLE` / `FOREMAN_TASK_DESCRIPTION` environment variables
   instead.

3. **`packages/foreman_server/test/foreman_server/workflow/run_executor_test.exs`** —
   wrong: the line the run added (`no_task = RunExecutor.prompt_template_assigns(...)`)
   exceeded the formatter's line width, so `mix format --check-formatted` failed
   on the branch's own file. Changed: ran `mix format` on the file; the only
   change is that one statement wrapped onto two lines. The base commit
   `1334dc59` version of the same file was already format-clean, so the
   misformatting was introduced by this run.

4. **`packages/foreman_server/test/foreman_server/workflow/run_executor_prompt_section_test.exs`** —
   wrong: same format-gate failure; the added assertion
   `assert plan_result =~ "## Task Description\n\n..."` was not formatter-clean.
   Changed: ran `mix format` on the file; the only change is that assertion
   wrapping onto two lines.

## Declined

1. **`packages/foreman_server/test/foreman_server/workflow/run_executor_prompt_section_test.exs:222`** —
   finding: the new `render_for_test/2` helper re-implements the production
   renderer's section and placeholder substitution instead of calling it, so the
   test could go green while production rendering breaks. Reason: declined —
   `RunExecutor.render_prompt_template/6` is private, so the test cannot call it
   directly, and mirroring it is this test file's own existing convention; the
   public surface (`RunExecutor.prompt_template_assigns/5`) is separately pinned
   by the test added to `run_executor_test.exs`, so the boundary that matters is
   covered directly. Fixing this would mean widening the production API for
   test convenience, outside this run's scope.

2. **`packages/foreman_server/priv/defaults/workflows/prompts/review-repo-rules.md:169`** —
   finding: the review prompts still render only `{{#section input.prompt}}`
   (same at `review-coderabbit.md:149`), so a description-only task still shows
   no description to a review phase. Reason: declined — out of scope for this
   run: the task explicitly scoped the prompt change to `discover.md`,
   `fix-plan.md`, `fix.md`, `implement.md` and `verify.md` and left the
   `review-*` prompts alone, and neither review prompt has a
   description-related stop condition that the change made wrong. Noted for the
   operator as an optional follow-up.

3. **`docs/reports/foreman-7gyd7-fix/REVIEW_CODERABBIT_REPORT.md:1`** —
   finding: the previous phase's artifact is a one-line captured tool-call
   wrapper instead of a report, and `FIX_REPORT.md` alongside it is likewise a
   one-line fragment ("Now run both test files to confirm red."). Reason:
   declined — out of scope: the task prompt forbids editing `docs/reports/`,
   and these are phase artifacts Foreman owns. The consequence for this phase is
   that no findings could be carried forward (see "Review engine").

## Verification

Commands run from the run worktree
(`/Users/ldangelo/.foreman/worktrees/foreman/7gyd7-fix/run-17de9efd71f42e1698c8d82501bd1de4/workspace`):

| Command | Exit code | Result |
| --- | --- | --- |
| `git fetch origin main && git rev-parse origin/main` | 0 | `4f37fa9674237d73c4ef43515e16a76c43511416` — identical to the local `main` |
| `git merge-base origin/main HEAD` | 0 | `1334dc59ad7d7d5b14ca721ffc5890a43668d80d` (diff base confirmed) |
| `git diff "$FOREMAN_BASE_BRANCH"...HEAD` | 0 | 11 files, +375/-1 (range reviewed) |
| `git show HEAD:packages/foreman_server/test/foreman_server/workflow/run_executor_test.exs \| (cd packages/foreman_server && mix format --check-formatted -)` | 1 | finding 3 reproduced: file not formatted (line 4380) |
| `git show 1334dc59:packages/foreman_server/test/foreman_server/workflow/run_executor_test.exs \| (cd packages/foreman_server && mix format --check-formatted -)` | 0 | base version was format-clean — the misformatting is this run's |
| `git show HEAD:packages/foreman_server/test/foreman_server/workflow/run_executor_prompt_section_test.exs \| (cd packages/foreman_server && mix format --check-formatted -)` | 1 | finding 4 reproduced: file not formatted (line 210) |
| `cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_prompt_section_test.exs test/foreman_server/workflow/run_executor_test.exs` | 0 | `Result: 62 passed` (27.8s) — before the format fixes |
| `cd packages/foreman_server && mix format test/foreman_server/workflow/run_executor_test.exs test/foreman_server/workflow/run_executor_prompt_section_test.exs` | 0 | applied the formatter to the two files the run added code to |
| `cd packages/foreman_server && mix format --check-formatted lib/foreman_server/workflow/run_executor.ex test/foreman_server/workflow/run_executor_prompt_section_test.exs test/foreman_server/workflow/run_executor_test.exs` | 0 | all three changed Elixir files are now formatter-clean |
| `cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_prompt_section_test.exs test/foreman_server/workflow/run_executor_test.exs` | 0 | `Result: 62 passed` (after the format fixes) |
| `git status --porcelain` | 0 | exactly 4 modified files, uncommitted as required: `docs/user-guide.md`, `packages/foreman_server/CHANGELOG.md`, `packages/foreman_server/test/foreman_server/workflow/run_executor_prompt_section_test.exs`, `packages/foreman_server/test/foreman_server/workflow/run_executor_test.exs` |

Documentation gate: identifiers added by this review — `{{task.title}}` and
`{{task.description}}` (prompt-template keys, documented in
`docs/user-guide.md` §13 and in `packages/foreman_server/CHANGELOG.md`).
`CLAUDE.md` and `README.md` needed no edit (they document no prompt-template
placeholder keys); `docs/cli-reference.md` needed no edit (it documents the
command-phase placeholders `{{input.prompt}}` / `{{input.prompt_argument}}` and
the task `--title` / `--description` CLI flags, all unchanged by this run);
`docs/lessons/phase-execution-and-pr-mechanics.md` already documents the
`FOREMAN_TASK_TITLE` / `FOREMAN_TASK_DESCRIPTION` export and is still accurate.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/CHANGELOG.md", "line": 7, "description": "The run adds the task.title and task.description prompt-template keys and rewords the fix-plan stop condition without an Unreleased/Fixed changelog entry, leaving operators unaware of the change and of the stale ~/.foreman/workflows copies.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 2796, "description": "The new {{task.title}} and {{task.description}} prompt-template keys are undocumented because section 13 Standing context enumerates the prompt-template placeholders without them.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/run_executor_test.exs", "line": 4380, "description": "The statement the run added exceeds the formatter line width, so the repository CI gate mix format --check-formatted fails on this branch.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/test/foreman_server/workflow/run_executor_prompt_section_test.exs", "line": 210, "description": "The assertion the run added is not mix format clean, so the repository CI format gate fails on this branch.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/test/foreman_server/workflow/run_executor_prompt_section_test.exs", "line": 222, "description": "The new render_for_test helper re-implements the production renderer logic instead of calling it, so the test could pass while production rendering breaks.", "disposition": "declined", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/priv/defaults/workflows/prompts/review-repo-rules.md", "line": 169, "description": "The review prompts still render only the input.prompt section, so a description-only task shows no description to a review phase.", "disposition": "declined", "source": "repo-rules"}, {"severity": "nitpick", "path": "docs/reports/foreman-7gyd7-fix/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "The previous phase's review artifact is a captured tool-call wrapper with no findings block, so no findings could be carried forward into this report.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change adds two prompt-template keys and edits five bundled prompt files, so a mistake reaches every agent phase of the affected workflows; the run's own tests did not format cleanly, which would have failed CI. The behaviour is additive and covered by tests, but the shipped prompts also affect installed copies under ~/.foreman/workflows that operators must refresh."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
