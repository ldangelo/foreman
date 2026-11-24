# Repository-Rules Review — foreman-1lo2p-fix

## Review engine

- Reviewer: the repository-rules reviewer of the `fix` workflow, phase 4
  (`repo-rules-review`), run `run-0ca3628be4de2b477bc0f1c06bec387f`, task `1lo2p-fix`.
- Diff range reviewed: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with
  `$FOREMAN_BASE_BRANCH=main` (merge-base `ab53fed7`, branch tip `1721efcf`) —
  9 files: `FIX_REPORT.md` (root), `docs/reports/foreman-1lo2p-fix/FIX_REPORT.md`,
  `docs/reports/foreman-1lo2p-fix/PLAN.md`,
  `docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md`, `docs/user-guide.md`,
  `packages/foreman_server/CHANGELOG.md`,
  `packages/foreman_server/lib/foreman_server/vcs_adapter.ex`,
  `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex`,
  `packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs`.
  The range was re-read once more after the fixes below.
- Rules applied: the repository's own contributor guidance — `AGENTS.md` (working
  rules, typed-boundary rules §5.4/§5.4b, documentation gate, testing rules),
  `CLAUDE.md` and the `docs/lessons/` files it indexes (phase execution and PR
  mechanics, typed boundaries), the phase prompt contracts in
  `packages/foreman_server/priv/defaults/workflows/prompts/` (`review-coderabbit.md`,
  `review-repo-rules.md`, `fix.md`), plus the established patterns of the touched
  files themselves.
- Previous phase: `docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md`.
  The version committed on this branch had been rewritten to 16 lines and no longer
  contained a machine-readable findings block, so the nine CodeRabbit findings were
  recovered from the phase's own earlier commit (`856db13f`) and carried forward
  verbatim below (fixing that rewrite is finding F2).
- Progress notifications (`foreman_inbox_send`, `foreman_task_add_comment`) are not
  exposed to this phase, so no operator note or task comment was sent from it.

## Findings

### Own findings (`repo-rules`)

| # | Severity | Location | Finding | Disposition |
|---|---|---|---|---|
| F1 | major | `FIX_REPORT.md:1` (repo root) | A stray report artifact whose whole content is `Blocked: no plan found` was committed at the repository root, where the repository keeps no report files and the `fix` workflow declares its artifact path as `{task.projectReportsDir}/FIX_REPORT.md` (= `docs/reports/foreman-1lo2p-fix/FIX_REPORT.md`). It was swept in by `Git.commit_all/3` (`packages/foreman_server/lib/foreman_server/exec/git.ex:283`, `git add -A`). | fixed |
| F2 | major | `docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md:183` | The committed CodeRabbit report had been rewritten from 188 lines to 16 lines (commit `1721efcf`) and lost both machine-readable blocks, although its own prose still claimed "both raw-JSON blocks last, validated by the real parsers". `priv/defaults/workflows/prompts/review-coderabbit.md` requires the findings block and then the risk block as the last content of the file. | fixed |
| F3 | minor | `packages/foreman_server/lib/foreman_server/vcs_adapter.ex:27` | The `create_worktree` callback doc still described only the pre-change contract — it never mentioned the new `reused` key, the reuse semantics, or the `{:worktree_path_unusable, path, reason}` refusal error the implementation now returns. | fixed |
| F4 | minor | `docs/reports/foreman-1lo2p-fix/FIX_REPORT.md:1` | The fix phase's report contains only the fragment `Now writing failing-first tests:` — the run's fix outcome is undocumented, and the report is a stub rather than a report. | open — a human must write a truthful fix report; this review phase does not fabricate one |
| F5 | nitpick | `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:107` | The `reused` key has no production reader (only the `@callback` spec and the tests read it), so the AGENTS.md §5.4b rule that a boundary key must be live is not met by the code alone. | declined |
| F6 | major | `packages/foreman_server/CHANGELOG.md:7` | The branch was never rebased onto `origin/main` although the task's first (mandatory) step required it: local `main`/`origin/main` is `0b700eba` and the branch's merge-base is `ab53fed7` (10 commits behind). `git merge-tree --write-tree main HEAD` proves a real content conflict in `packages/foreman_server/CHANGELOG.md` (main added a `### Fixed` bullet in the same section). | open — rebasing rewrites the branch's committed history and Foreman owns the commits, so the operator decides |

### Carried forward from the CodeRabbit phase (`coderabbit`)

| # | Severity | Location | Finding | Disposition |
|---|---|---|---|---|
| C1 | major | `packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs:301` | `VcsAdapter.Default.create_worktree/3` ran `git worktree add` unconditionally, so a relaunched run failed with `git_worktree_create_failed` on a worktree that already existed. | fixed (phase 3; verified in the current diff) |
| C2 | minor | `packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs:299` | The reuse test committed `README.md` before the reuse call, so it no longer asserted that an uncommitted tracked edit survives reuse. | fixed (phase 3; verified in the current diff) |
| C3 | minor | `packages/foreman_server/lib/foreman_server/vcs_adapter.ex:43` | The worktree result should be an enforced-key struct instead of a plain map. | declined |
| C4 | minor | `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:145` | An empty but existing directory at the worktree path must still be creatable instead of refused. | fixed (phase 3; verified in the current diff) |
| C5 | major | `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:152` | A worktree registration whose checkout is no longer usable must be refused before the path is reused. | fixed (phase 3; verified in the current diff) |
| C6 | minor | `packages/foreman_server/lib/foreman_server/vcs_adapter.ex:43` | The worktree result should be an enforced-key struct instead of a plain map. | declined |
| C7 | minor | `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:217` | The branch to compare must be read from the checkout itself rather than from the possibly stale registry entry. | fixed (phase 3; verified in the current diff) |
| C8 | major | `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:184` | A detached checkout whose HEAD differs from the requested base should have its real base reported or reuse should be refused. | declined |
| C9 | minor | `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:234` | A relative `gitdir:` pointer in the checkout must be expanded against the checkout path before the admin dir is canonicalized. | fixed (phase 3; verified in the current diff) |

### Checks that found no violation

- Error handling: the new refusal paths return typed errors
  (`{:worktree_path_unusable, path, reason}`) that `Workflow.Worktree.create/1`
  forwards to the caller (`packages/foreman_server/lib/foreman_server/workflow/worktree.ex:160-175`),
  so a refused path fails loudly instead of degrading to a generic success.
- Typed boundary: the change stays inside the existing `VcsAdapter` behaviour —
  no new untyped boundary, no duplicate boundary across transports
  (`AGENTS.md` §5.7).
- Declared-but-unread values: checked — `reused` is the only new key (F5), and the
  `### Fixed` entry and the user-guide sentence both describe behaviour the code
  implements (no dead manifest/config/enum value introduced).
- Documentation: `docs/user-guide.md:1281` and `packages/foreman_server/CHANGELOG.md:7`
  describe the new reuse, refusal and empty-directory behaviour; `CLAUDE.md`,
  `README.md` and `docs/cli-reference.md` have no hits for the new identifiers
  (`worktree_path_unusable`, `reused`), so the documentation gate needed no further
  edits.
- Not touched, per the task: `exec/git.ex`, the CLI, run reset/resume, and part 2 of
  the bead.

## Fixed

- **F1 — `FIXREPORT` artifact at the repo root (`FIX_REPORT.md`, root).** What was
  wrong: a one-line file with the content `Blocked: no plan found` was committed at
  the repository root. No report file exists at the root of `main`
  (`git ls-tree main` lists only `AGENTS.md`, `CLAUDE.md`, `.beads/`, …), the
  workflow's artifact path is `{task.projectReportsDir}/FIX_REPORT.md`
  (`packages/foreman_server/priv/defaults/workflows/fix.yaml:51`), and
  `Git.commit_all/3` (`packages/foreman_server/lib/foreman_server/exec/git.ex:283`,
  `git add -A`) swept it into the phase commit. What changed: the file was deleted
  (`git rm FIX_REPORT.md`); the run's fix report stays at
  `docs/reports/foreman-1lo2p-fix/FIX_REPORT.md`, where the workflow expects it.
- **F2 — the CodeRabbit report lost its machine-readable blocks
  (`docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md`).** What was wrong:
  commit `1721efcf` replaced the phase's 188-line report with a 16-line restatement
  that has no `FOREMAN_REVIEW_FINDINGS` block and no `FOREMAN_RISK_JUDGEMENT` block
  while claiming both exist ("validated by the real parsers (findings `recorded` 9,
  risk `recorded` MEDIUM, 0 fences)") — the report contradicts itself and breaks the
  `review-coderabbit.md` contract, which requires the findings block and then the
  risk block as the last content of the file. What changed: the phase's own
  contract-compliant artifact was restored from commit `856db13f`
  (`git show 856db13f:docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md`).
  The restored file carries the nine findings with their dispositions, the
  `MEDIUM` risk judgement, and the sections the rewrite had compressed
  (`### State of the working tree`, `### Operator notifications`), so no durable
  fact was lost. Validated: the findings JSON parses (9 findings, each with exactly
  `severity`, `path`, `line`, `description`, `disposition`, `source`), the risk JSON
  parses (`MEDIUM`), 0 code fences, marker lines standalone at lines 183/185 and
  186/188.
- **F3 — the `create_worktree` callback doc was stale
  (`packages/foreman_server/lib/foreman_server/vcs_adapter.ex:27`).** What was
  wrong: the `@doc` still listed only the required opts and the `:output` key, so
  the boundary promised nothing about the reuse behaviour the implementation
  added. What changed: the `@doc` now states that a registered worktree on the
  requested branch is reused with `reused: true` and an empty `:output` without
  touching the checkout (no reset, checkout or clean, so uncommitted work
  survives), that an empty directory at the path is created into with
  `reused: false`, and that a refused path returns
  `{:error, {:worktree_path_unusable, path, reason}}` with `reason` one of
  `{:branch_mismatch, branch}`, `:not_a_git_worktree`, `:worktree_checkout_broken`
  or `{:worktree_list_failed, reason}`. Documentation only — no behaviour change.

## Declined

- **F5 — `reused` has no production reader
  (`packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:107`).**
  Finding: AGENTS.md §5.4b says a boundary key is live only when something reads
  it; `reused` is read only by the `@callback` spec and by the tests. Reason for
  declining: the key is mandated by the task contract for this bead ("return
  `{:ok, %{path:, base:, branch:, output: \"\", reused: true}}`") and by the
  behaviour spec `AGENTS.md` describes, so removing it would break the agreed
  boundary; making it live is a consumer change outside this run's scope.
- **C3 / C6 — the worktree result should be an enforced-key struct
  (`packages/foreman_server/lib/foreman_server/vcs_adapter.ex:43`).** Reason: all
  five `VcsAdapter` callbacks return plain maps (`clone`, `branch`, `create_pr`,
  `clean_worktree`), so a struct for one callback is inconsistent with the
  behaviour's own established shape, and converting the whole behaviour is outside
  this bead's scope.
- **C8 — a detached checkout should report its real base or refuse reuse
  (`packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:184`).**
  Reason: refusing it would re-create the very bug this bead removes (the
  relaunched worktree is legitimately ahead of the base), and no consumer reads
  `result.base` (`FOREMAN_SOURCE_REVISION` comes from `worktree_record.base_ref`).
  The strict branch check is kept, as the task requires.
- **F4 / F6 — not declined, but not fixed here either** (see `## Findings`): the fix
  phase's stub report and the missing rebase onto `origin/main` are recorded as
  `open` for the operator, because writing the fix report truthfully is the fix
  phase's artifact and rebasing rewrites committed branch history that Foreman
  owns.

## Verification

| Command | Result |
| --- | --- |
| `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test mix test --warnings-as-errors test/foreman_server/vcs_adapter_default_test.exs test/foreman_server/vcs_adapter_test.exs test/foreman_server/workflow/run_executor_run_worktree_test.exs test/foreman_server/workflow/run_executor_followup_worktree_test.exs'` | exit 0 — `Result: 98 passed` |
| `devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted lib/foreman_server/vcs_adapter.ex lib/foreman_server/vcs_adapter/default.ex test/foreman_server/vcs_adapter_default_test.exs'` | exit 0 (no output) |
| `git merge-tree --write-tree --name-only main HEAD` | exit 1 — `CONFLICT (content): Merge conflict in packages/foreman_server/CHANGELOG.md` (evidence for F6) |
| JSON parse of the restored `REVIEW_CODERABBIT_REPORT.md` blocks (findings + risk, 0 code fences, standalone markers) | exit 0 — 9 findings, `level: MEDIUM` |
| `git diff "$FOREMAN_BASE_BRANCH"...HEAD` re-read after the fixes | no new violation: no root-level artifact left, both report files satisfy the marker/JSON contract, the only code change added by this phase is documentation |

Fixes are left uncommitted for Foreman to commit:
`git status --porcelain` → `D FIX_REPORT.md`,
`M docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md`,
`M packages/foreman_server/lib/foreman_server/vcs_adapter.ex`,
`?? docs/reports/foreman-1lo2p-fix/REVIEW_REPORT.md` (this phase's own artifact).

`ask_advisor` was consulted for a completion review and could not run — the configured
Anthropic OAuth refresh fails with `invalid_grant` ("Refresh token expired"), so no advisor
verdict backs this report.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "FIX_REPORT.md", "line": 1, "description": "A stray report artifact containing only \"Blocked: no plan found\" was committed at the repository root, where no report files live and the fix workflow writes its artifact to docs/reports/<run>/FIX_REPORT.md.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md", "line": 183, "description": "The committed CodeRabbit report had been rewritten to 16 lines and lost both machine-readable blocks its own prose claims exist, breaking the review-coderabbit.md contract that the findings block and the risk block are written last.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter.ex", "line": 27, "description": "The create_worktree callback doc still described only the pre-change contract, omitting the reused key, the reuse semantics and the new {:worktree_path_unusable, path, reason} refusal error.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-1lo2p-fix/FIX_REPORT.md", "line": 1, "description": "The fix phase report holds only the fragment \"Now writing failing-first tests:\" instead of a fix report, so the run's fix outcome is undocumented.", "disposition": "open", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 107, "description": "The reused key returned by create_worktree has no production reader, so the AGENTS.md liveness rule for boundary keys is unmet by the code alone.", "disposition": "declined", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/CHANGELOG.md", "line": 7, "description": "The branch was never rebased onto origin/main as the task required, and git merge-tree proves a content conflict in this CHANGELOG section when the branch merges with main.", "disposition": "open", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs", "line": 301, "description": "VcsAdapter.Default.create_worktree/3 ran git worktree add unconditionally, so a relaunched run failed with git_worktree_create_failed on a worktree that already existed.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs", "line": 299, "description": "The reuse test committed README.md before the reuse call, so it no longer asserted that an uncommitted tracked edit survives reuse.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter.ex", "line": 43, "description": "The worktree result should be an enforced-key struct instead of a plain map.", "disposition": "declined", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 145, "description": "An empty but existing directory at the worktree path must still be creatable instead of refused.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 152, "description": "A worktree registration whose checkout is no longer usable must be refused before the path is reused.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter.ex", "line": 43, "description": "The worktree result should be an enforced-key struct instead of a plain map.", "disposition": "declined", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 217, "description": "The branch to compare must be read from the checkout itself rather than from the possibly stale registry entry.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 184, "description": "A detached checkout whose HEAD differs from the requested base should have its real base reported or reuse should be refused.", "disposition": "declined", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 234, "description": "A relative gitdir pointer in the checkout must be expanded against the checkout path before the admin dir is canonicalized.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change moves the worktree-creation boundary in the VCS adapter: a registered worktree on the requested branch is reused instead of failing the run, and every refused path returns a typed {:worktree_path_unusable, path, reason}. The reuse path never resets, checks out or cleans the checkout, the branch check stays strict, and 98 tests pass here (126 in the CodeRabbit phase). Risk stays MEDIUM because one major CodeRabbit finding (detached-base reporting) was declined and two items remain open: the fix phase's report is a stub and the branch was never rebased onto origin/main, which conflicts in packages/foreman_server/CHANGELOG.md."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
