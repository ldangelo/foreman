# Repository-rules review — `beads:foreman:foreman-ylwq0`

## Review engine

- Reviewer: `repo-rules` — the `fix` workflow's `repo-rules-review` phase (phase 4 of this run), executed in the run's own worktree `.../run-4c8b40838270b2b29b0aeb44d96e26bc/workspace`.
- Diff range reviewed: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with `FOREMAN_BASE_BRANCH=main` ⇒ `main` = `f0f3b083`, merge-base `f0f3b083`, `HEAD` = `0b4ce57f`. The committed range contains only three report files (`PLAN.md`, `FIX_REPORT.md`, `REVIEW_CODERABBIT_REPORT.md`) and **no implementation code**.
- Rules applied: the repository root `AGENTS.md` (working rules, documentation gate, §5 typed boundaries, invariants, testing and safety) and the matching `docs/lessons/` files for the touched areas (`phase-execution-and-pr-mechanics.md`, `typed-boundaries-full.md`, `architecture-and-events.md`).
- Previous phase: `docs/reports/foreman-beads:foreman:foreman-ylwq0/REVIEW_CODERABBIT_REPORT.md` exists but carries **no machine-readable findings block** — it is a single prose line ("Branch diff vs `main` contains only report files — no implementation code. Running review round 1 anyway (per contract, the engine must run)."). There was therefore nothing to carry forward, and no previous judgement block was copied.
- Because the committed diff carried no implementation code, the bead's change was unimplemented when this phase started (the `fix` phase committed only a plan-recovery note). This phase implemented the change and reviewed its own working-tree diff against the same rules; the findings below are the review result for both the committed range and the implementation added here.

## Findings

| # | Severity | File | Finding | Disposition |
| --- | --- | --- | --- | --- |
| F1 | major | `docs/reports/foreman-beads:foreman:foreman-ylwq0/FIX_REPORT.md` | The `fix` phase committed no implementation code, so the run's diff against `main` contained only report files and the bead's origin-fetch requirement was unimplemented. | fixed |
| F2 | major | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4449` | The run worktree's base was resolved from the registered checkout's local `HEAD` instead of the fetched `origin/<base_branch>` tip the bead requires. | fixed |
| F3 | minor | `packages/foreman_server/lib/foreman_server/vcs_adapter.ex:58` | The VCS seam had no fetch operation, so the origin fetch could not be routed through the adapter abstraction the bead names. | fixed |
| F4 | minor | `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:12` | The adapter's module doc claims every operation routes through `CommandRouter` for `VcsOperation*` event emission, which the new event-less `fetch_base/3` contradicts. | fixed |
| F5 | minor | `docs/user-guide.md:119` | Operator docs still described the run base as the registered checkout's `HEAD` and said nothing about the origin fetch, its ref-only side effect, or its fallback. | fixed |
| F6 | minor | `docs/cli-reference.md:626` | The CLI reference described the run base as the registered checkout's `HEAD` without the origin-tip semantics. | fixed |
| F7 | minor | `docs/lessons/phase-execution-and-pr-mechanics.md:214` | The lesson file asserted the run worktree's `base_ref` is read from the same checkout's `HEAD`, contradicting the new origin-tip base. | fixed |
| F8 | nitpick | `packages/foreman_server/lib/foreman_server/vcs_adapter.ex:3` | The behaviour module doc enumerated the adapter operations without the new `fetch_base`. | fixed |
| F9 | minor | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4258` | Secondary registered repositories still take their base from the registered `default_branch` tip or the local `HEAD` rather than a fetched origin tip. | declined |

## Fixed

**F1 — `docs/reports/foreman-beads:foreman:foreman-ylwq0/FIX_REPORT.md`**
- What was wrong: the phase delivered a plan-recovery note instead of code; `git diff main...HEAD` held only report files, so the bead ("Implement origin fetch and origin-based run worktree") would have shipped unimplemented — this is the workflow's last phase, so nothing downstream would implement it.
- What changed: implemented the bead's change in the run's worktree (uncommitted, per the phase contract). Edits: `packages/foreman_server/lib/foreman_server/exec/git.ex` (`remote_exists?/2`), `packages/foreman_server/lib/foreman_server/vcs_adapter.ex` (`fetch_base/3` callback + `:fetch_base` operation), `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` (`fetch_base/3` implementation), `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` (origin-based base resolution), the two adapter behaviour stubs in `test/foreman_server/vcs_adapter_test.exs` and `test/foreman_server/vcs_adapter_default_test.exs`, a new `test/foreman_server/workflow/run_executor_origin_base_test.exs` (6 tests), and the documentation edits listed below.

**F2 — `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4449`**
- What was wrong: `resolve_run_base/2` resolved the run worktree's `base_ref` from the registered checkout's local `HEAD`, so a run cut from a stale checkout based its worktree on the stale commit.
- What changed: `resolve_declared_base/3` now falls through to `resolve_origin_base/2` → `fetch_origin_base/3`, which calls `VcsAdapter.run(DefaultAdapter, :fetch_base, [project_root, "origin", branch], [])` and pins the worktree to the fetched `origin/<branch>` tip. Absent cases (no `origin` remote, remote does not carry the branch, detached checkout, task `source_branch`) fall back to the local `HEAD`; any other fetch failure returns the typed error `{:error, {:origin_fetch_failed, remote, branch, reason}}` and fails the run rather than silently pinning a stale base. A declared `worktree.base` still resolves locally and is never fetched.

**F3 — `packages/foreman_server/lib/foreman_server/vcs_adapter.ex:58`**
- What was wrong: the adapter behaviour had no way to express "read a remote's tip", so the fetch had to bypass the seam the bead names.
- What changed: added `@callback fetch_base(repo_path, remote, branch) :: {:ok, String.t()} | {:ok, :no_remote_tracking} | {:error, term()}`, added `:fetch_base` to the `run/4` operation union, and added the `build_fun/2` clause that dispatches it to the module's `fetch_base/3`. The absent case is explicit (`:no_remote_tracking`), so no adapter can answer "no remote" with a plausible-looking SHA.

**F4 — `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:12`**
- What was wrong: the module doc stated that *all* operations route through `CommandRouter` for `VcsOperationStarted` → `VcsOperationCompleted`/`VcsOperationFailed`; the new `fetch_base/3` carries no operation id and emits no events.
- What changed: the doc now names the exception and its reason ("except `fetch_base/3`: it carries no operation id and emits no events, so reading a remote's tip never writes to the event store").

**F5 — `docs/user-guide.md:119`**
- What was wrong: the guide told operators the run base is the project checkout's `HEAD`; the change alters that and has an observable side effect (a fetch in the registered checkout).
- What changed: the guide now states that the base is the fetched `origin/<branch>` tip, that the fetch advances only `refs/remotes/origin/<branch>` and never touches the checkout's working tree or branch pointer, that a declared `base` is resolved locally and never fetched, that a missing `origin` remote or a remote without the branch falls back to the local `HEAD`, and that any other fetch failure fails the run. The "**Base branch.**" paragraph (line 572) gained the same base-commit sentence and the declared-`worktree.base` exception.

**F6 — `docs/cli-reference.md:626`**
- What was wrong: the CLI reference described the run base as the registered checkout's `HEAD`.
- What changed: the paragraph now states the fetched `origin/<branch>` tip as the base commit, the ref-only side effect, the declared-`worktree.base` exception, and the `HEAD` fallback.

**F7 — `docs/lessons/phase-execution-and-pr-mechanics.md:214`**
- What was wrong: the lesson asserted the run worktree's `base_ref` is read from the checkout's `HEAD` "at the same moment" the base branch is latched, "so branch name and base commit describe one repository state" — no longer true once the base commit comes from a fetch.
- What changed: the passage now names the fetched origin tip, the `resolve_run_base/2` → `resolve_origin_base/2` → `fetch_origin_base/3` path, the ref-only side effect, the `HEAD` fallback for absent remotes, the loud failure for other fetch errors, and the declared-`worktree.base` exception.

**F8 — `packages/foreman_server/lib/foreman_server/vcs_adapter.ex:3`**
- What was wrong: the module doc's operation list did not mention `fetch_base`.
- What changed: the doc now reads "Behaviour contract for VCS adapters (clone/branch/create_pr/worktree/fetch_base)."

## Declined

**F9 — `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4258` (`repo_base/1`)**
- Finding: secondary registered repositories still resolve their base from the registered `default_branch` tip, falling back to the local `HEAD`, so a multi-repo run mixes origin-derived and local bases.
- Reason: out of this run's scope. The bead targets the registered project checkout that owns the run worktree; changing secondary-repo base resolution alters multi-repo base semantics with no requirement and no test behind it, and would need its own plan and verification.

## Verification

All commands ran from `packages/foreman_server` inside `devbox run`, with
`DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/foreman_test_ylwq0`, `TEST_DB_POOL_SIZE=5`, `MIX_ENV=test`.
(The inherited `DATABASE_URL` on port 55434 fails auth — `FATAL 28P01 (invalid_password)` — so the URL above is set explicitly for every run.)

| Command | Result | Exit |
| --- | --- | --- |
| `mix format --check-formatted` | clean (after formatting the new test file) | 0 |
| `mix compile --warnings-as-errors` | "Compiling 15 files (.ex)", no warnings | 0 |
| `mix test test/foreman_server/workflow/run_executor_origin_base_test.exs --warnings-as-errors` | 6 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_origin_base_test.exs test/foreman_server/vcs_adapter_test.exs test/foreman_server/vcs_adapter_default_test.exs --warnings-as-errors` | 36 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_run_worktree_test.exs --warnings-as-errors` | 55 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_followup_worktree_test.exs --warnings-as-errors` | 4 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_resume_context_test.exs --warnings-as-errors` | 7 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_multi_repo_test.exs --warnings-as-errors` | 36 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_source_branch_test.exs --warnings-as-errors` | 9 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_pr_base_branch_test.exs --warnings-as-errors` | 7 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_base_branch_env_test.exs --warnings-as-errors` | 4 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_test.exs --warnings-as-errors` | 51 passed | 0 |
| `mix test test/foreman_server/exec/git_test.exs --warnings-as-errors` | 17 passed | 0 |
| `mix test test/foreman_server/exec/worktree_test.exs --warnings-as-errors` | 10 passed | 0 |
| `mix test test/foreman_server/exec/worktree_sync_remote_test.exs --warnings-as-errors` | 14 passed | 0 |
| `mix test test/foreman_server/workflow/run_executor_origin_base_test.exs test/foreman_server/vcs_adapter_test.exs test/foreman_server/vcs_adapter_default_test.exs test/foreman_server/exec/git_test.exs --warnings-as-errors` (final re-run after the doc and moduledoc edits) | 53 passed | 0 |

New behaviour covered by `run_executor_origin_base_test.exs`: the base commit is the fetched origin tip rather than the stale local `HEAD`; the operator's checkout is untouched (symbolic ref, HEAD SHA and working-tree status unchanged; only `refs/remotes/origin/main` advances); a checkout with no `origin` remote falls back to the local `HEAD`; a remote that does not carry the branch falls back to the local `HEAD`; a declared `base` resolves locally and never fetches; a task `source_branch` keeps the local base.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-ylwq0/FIX_REPORT.md", "line": 2, "description": "The fix phase committed no implementation code, so the run's diff against main held only report files and the bead's origin-fetch requirement was unimplemented.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/workflow/run_executor.ex", "line": 4449, "description": "The run worktree's base was resolved from the registered checkout's local HEAD instead of the fetched origin/<base_branch> tip the bead requires.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter.ex", "line": 58, "description": "The VCS seam had no fetch operation, so the origin fetch could not be routed through the adapter abstraction the bead names.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 12, "description": "The adapter's module doc claims every operation emits VcsOperation events, which the new event-less fetch_base/3 contradicts.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 119, "description": "Operator docs still described the run base as the registered checkout's HEAD and omitted the origin fetch, its ref-only side effect, and its fallback.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/cli-reference.md", "line": 626, "description": "The CLI reference described the run base as the registered checkout's HEAD without the origin-tip semantics.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/lessons/phase-execution-and-pr-mechanics.md", "line": 214, "description": "The lesson file asserted the run worktree's base_ref is read from the checkout's HEAD, contradicting the new origin-tip base.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter.ex", "line": 3, "description": "The behaviour module doc enumerated the adapter operations without the new fetch_base.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/run_executor.ex", "line": 4258, "description": "Secondary registered repositories still take their base from the registered default_branch tip or the local HEAD rather than a fetched origin tip.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change alters which commit every run worktree is based on: the base becomes the fetched origin/<branch> tip instead of the checkout's local HEAD, and a fetch failure other than an absent remote now fails the run. The fetch is read-only with respect to the operator's working tree and branch pointer (only refs/remotes/origin/<branch> advances), the fallbacks are explicit, and the behaviour is covered by new tests plus the existing run-worktree, follow-up, multi-repo, source-branch and PR-base suites."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
