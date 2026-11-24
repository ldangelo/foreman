# PLAN — foreman-d6rth: document new PR title/body behaviour in docs/user-guide.md

Kata issue: `ancq`.

## 1. Verdict

**Partly already fixed; the rest describes features that do not exist.** The task text
was written against run `run-a9ee2749eb92b7d7896ed91d3155995d`, whose branch implemented
none of the four behaviours. Those behaviours landed later on `main` in PRs #957 / #959 /
#961, and two of the four were documented with them. Evidence, all on the current tree:

| Claim in the task | State now | Evidence |
| --- | --- | --- |
| "nothing documents the new PR title rule" | **Already documented** | `docs/user-guide.md:2966-2971` ("**A phase PR's title is the run's task title.**" … task title → first conventional-commit subject → legacy `feat(phase): <phase>`), matching `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex` `pr_title/1` (:368-371). Also `docs/cli-reference.md:622`. Final-AutoPR title/body rule: `docs/user-guide.md:2945-2952`. |
| "the `## PR body` convention the worker prompts already instruct agents to write" | **Does not exist** | `git grep -- "## PR body"` returns nothing: no prompt in `packages/foreman_server/priv/defaults/workflows/prompts/` mentions it, and no reader exists in `phase_pr.ex` / `auto_pr.ex`. Nothing to document. |
| "the new project body-template setting" | **Does not exist** | `git grep pr_body_template` returns nothing; `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex` `@keys` (:48-51) has no such key. Nothing to document. |
| "the absolute-path rule" | **Partly documented** | The *review-report* path rule is documented (`docs/user-guide.md:2996-2999`: link when repository-relative, else file name only, "never an absolute host path"). The *generated-body `Artifact:` line* rule (`PrBodyPath.artifact_line/2`) is **not** documented anywhere in the four gate files. |

So the only real, in-scope gap is the last row. The plan is therefore **one documentation
edit**, not the four the task asks for. Do not invent docs for `## PR body` or
`pr_body_template`: documenting a setting that does not exist is a worse defect than
the one being fixed.

## 2. Root cause

`packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex` `artifact_line/2`
(:81-90) emits `"\nArtifact: <repo-relative path>\n"` into a generated PR body, and emits
`""` when the artifact cannot be expressed relative to the repository root. Both
generated-body builders use it:

- `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex` `gh_pr_create/2` (:408-413)
- `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex` `generated_body/1` (:715-724), whose root is `body_path_root/1` (:760, worktree root then `cwd`)

The operator-visible consequence — a PR body's `Artifact:` line is repo-relative, and is
dropped entirely rather than printing a host path — appears in
`packages/foreman_server/CHANGELOG.md` only for the review-report path, and in no
documentation-gate file.

## 3. Failing check first

This is a documentation-only change; there is no behavioural test to turn red. The
verifying checks are the existing doc-gate tests, which must stay green:

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/observability/docs_test.exs'
```

(`packages/foreman_server/test/foreman_server/observability/docs_test.exs` reads all four
gate files; nothing there asserts this new wording, and no new test is warranted for one
documentation paragraph.)

Before editing, confirm the premise still holds — all three must print nothing:

```
git grep -- "## PR body" -- ':(exclude)docs/reports'
git grep "pr_body_template" -- ':(exclude)docs/reports'
grep -n "Artifact:" docs/user-guide.md docs/cli-reference.md README.md CLAUDE.md
```

The two `git grep` calls exclude `docs/reports/`: this plan quotes both strings, so an
unscoped grep matches this file once it is committed, and the stop condition would then
fire on a self-reference rather than on a real code change.

If any of them now prints a hit, the tree changed under this plan: stop and report that
instead of editing.

## 4. Edits

### Edit 1 — `docs/user-guide.md`

Insert ONE new paragraph between line 3008 and line 3010. Line 2973 starts the paragraph
`**PR bodies carry the review agent's report only when Foreman generates the body.**`,
which ends at line 3008 (`… Read from the source, not observed.`); line 3009 is blank;
line 3010 starts `**Marker lines.** Each block (the `FOREMAN_REVIEW_FINDINGS` block and
the`. Put the new paragraph after the existing blank line 3009 and add one blank line
after it, so both neighbours stay separated by exactly one blank line.

New paragraph text (verbatim, hard-wrapped like its neighbours, `…` is U+2026):

```markdown
**A generated PR body carries no absolute host path.** A generated body (every phase PR,
and a final AutoPR for an ad-hoc no-task run) names the PR-creating phase's artifact on an
`Artifact:` line, and that path is always relative to the repository: the artifact is
committed on the run branch, so the relative form both resolves on GitHub and keeps the
operator's home layout (`/Users/<user>/.foreman/worktrees/…`) out of the PR. An artifact
that cannot be expressed relative to the repository root gets **no** `Artifact:` line at
all, rather than an absolute one — so a missing line means the path was outside the
repository, not that the phase produced nothing. The same rule covers the review report
linked from the `## Review findings (the review agent's report)` section above. Task-backed
final AutoPR bodies are the task description verbatim and carry no `Artifact:` line either
way.
```

Nothing else in `docs/user-guide.md` changes. In particular do NOT touch lines 2945-2952
(final AutoPR title/body), 2966-2971 (phase PR title) or 2996-2999 (review-report path):
they are correct already.

### Edit 2 — none

`CLAUDE.md`, `README.md` and `docs/cli-reference.md` need no edit. Record the reason in the
fix report (section 5 below), because the documentation gate requires the statement, not
silence:

- No externally visible identifier is added, removed or renamed by this change: it is prose
  only. `grep` for `Artifact:`, `pr_body_template` and `## PR body` in all four gate files
  returns nothing but the new paragraph.
- `CLAUDE.md:1216` already states the engineering-level rule ("PR #959: PR bodies carry no
  absolute host paths") for the review-report path; the new user-guide paragraph is the
  operator-facing counterpart and needs no second copy there.
- `docs/cli-reference.md:622` already carries the phase-PR title rule; PR body composition
  is not a CLI surface.
- `README.md:288` already carries the final-AutoPR title/body rule; the `Artifact:` line is
  below README's level of detail.

Do not add a `CHANGELOG.md` entry: `packages/foreman_server/CHANGELOG.md` already describes
the PR #959 behaviour this paragraph documents, and no code changes here.

## 5. Verification

Run, in the worktree root:

```bash
grep -n "A generated PR body carries no absolute host path" docs/user-guide.md
git diff --stat
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/observability/docs_test.exs'
cd packages/foreman_cli && go test ./cmd/foreman/ -run 'TestUserGuideUsageExampleExecutesAgainstCLI|TestUserGuideProjectExamplesExecuteAgainstCLI|TestUsageAdvertisesExactlyTheDispatchedVerbs|TestCLIReferenceDocumentsEveryDispatchedVerb|TestAgentCommandSpecsRouteToDispatchedVerbs|TestCLIReferenceNotImplementedClaimsAreAccurate' && cd -
```

Success means: the `grep` prints exactly one line; `git diff --stat` shows exactly one
changed file, `docs/user-guide.md`, with roughly `+12` lines and `-0`; both test commands
exit 0.

`mix format` is not needed (no `.ex`/`.exs` touched). The full AGENTS.md suite is not
required for a prose-only change; if the operator wants it, the working form in this
environment is the same `devbox run` command without the trailing test path (~825 s,
~9255 tests).

Write the fix report to
`docs/reports/foreman-beads:foreman:foreman-d6rth/FIX_REPORT.md` using the six sections
`packages/foreman_server/priv/defaults/workflows/prompts/fix.md` names, and state in it
that three of the four requested documentation items were NOT written, with the reasons
from section 1 above. Do not commit; Foreman commits.

## 6. Out of scope

Do not touch any of these:

- Any file under `packages/foreman_server/lib/` or `packages/foreman_server/test/`. This is
  a documentation change; no behaviour moves.
- `AGENTS.md` (rules only; it is never a doc-update target).
- `docs/PRD/*` and `docs/TRD/*` (point-in-time specs; leave their claims as written).
- `packages/foreman_server/CHANGELOG.md`.
- The review-findings / risk-judgement marker documentation at `docs/user-guide.md:3010`
  onwards.
- Implementing a `## PR body` section reader, a `pr_body_template` project setting, or any
  other code the task text assumes exists. If the operator wants those behaviours, they are
  separate beads with their own PRD/TRD, not this documentation bead.
- Rewording the already-correct paragraphs at lines 2945-2952, 2966-2971, 2996-2999.
