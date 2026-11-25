# CodeRabbit Review — foreman-1lo2p-fix

Phase: `coderabbit-review` (workflow `fix`), run `run-0ca3628be4de2b477bc0f1c06bec387f`.
Review target: the run worktree's working tree (earlier phases' work plus this phase's fixes), diffed
against `FOREMAN_BASE_BRANCH`.

## Review engine

- Engine: the CodeRabbit CLI, run locally against the working tree (the same engine as the GitHub PR
  bot), so findings arrived without a push.
- Command, run from the worktree root
  (`/Users/ldangelo/.foreman/worktrees/foreman/1lo2p-fix/run-0ca3628be4de2b477bc0f1c06bec387f/workspace`):

      coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"

- `FOREMAN_BASE_BRANCH=main` (verified non-empty). Merge-base of `main` and the run branch:
  `ab53fed7`. The engine confirmed `baseBranch: main` in its own review context.
- Three rounds, each command exiting `0` with `status: review_completed`:
  - round 1 — log `~/.omp/1lo2p-coderabbit-r1.log`, 2 findings, reviewed files
    `FIX_REPORT.md`, `docs/reports/foreman-1lo2p-fix/FIX_REPORT.md`,
    `docs/reports/foreman-1lo2p-fix/PLAN.md`, `packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs`
  - round 2 — log `~/.omp/1lo2p-coderabbit/round2.log`, 3 findings
  - round 3 — log `~/.omp/1lo2p-coderabbit/round3.log`, 4 findings
- Total: 9 findings (3 major, 6 minor). Every finding was triaged against the code as it stands
  now; nothing was fixed on the engine's say-so alone.

## Rounds

| Round | Findings received | Fixed | Declined |
| --- | --- | --- | --- |
| 1 | 2 (1 major, 1 minor) | 2 | 0 |
| 2 | 3 (1 major, 2 minor) | 2 | 1 |
| 3 | 4 (1 major, 3 minor) | 2 | 2 |

Round 1 asked for the behaviour the bead specifies and for the reuse test to keep an uncommitted
tracked edit; both were fixed. Round 2 added the empty-directory case, the unusable-checkout
refusal and the struct suggestion; the first two were fixed, the struct suggestion declined.
Round 3 added the checkout-owned branch read, the relative `gitdir:` pointer expansion and the
detached-base refusal; the first two were fixed, the last declined (it would re-create the bug
this bead exists to remove). Round 3 was the last round: its one major finding was declined with a
recorded reason rather than fixed, and the round produced no major or critical finding that this
phase could act on, so the review stopped there.

## Fixed

1. **`packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` — worktree reuse
   (round 1, major, "Implement worktree reuse in `VcsAdapter.Default.createworktree/3`").**
   Before reaching for `git worktree add`, `create_worktree/3` now classifies the path via
   `reuse_existing_worktree/3`:
   - nothing at the path, or an existing **empty** directory → `:create` (fresh worktree);
   - a **registered worktree already on the requested branch** → `{:ok, %{path:, base:, branch:,
     output: "", reused: true}}`, returned **without** resetting, checking out, cleaning or
     re-running the `.beads/` exclusion, so uncommitted phase work survives;
   - a registered worktree on another branch → `{:error, {:worktree_path_unusable, path,
     {:branch_mismatch, branch}}}` — the branch check stays strict;
   - a plain directory (not a registered worktree) → `{:error, {:worktree_path_unusable, path,
     :not_a_git_worktree}}`.
   `exclude_dotbeads/1` now runs only on the fresh-creation arm (`default.ex:301`), never on a
   reused worktree.

2. **`packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs` — the reuse test
   keeps an uncommitted tracked edit (round 1, minor, "Keep an uncommitted tracked edit in the
   reuse test").** The test previously committed `README.md` before the reuse call, so a tracked
   edit was no longer uncommitted when reuse ran. It now writes a new value to `README.md` after
   `ahead_sha` is recorded and asserts that value is still there after reuse (the commit and
   untracked-file assertions are kept).

3. **`packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` — a registered but
   unusable checkout is refused (round 2, major, "Reject a registered checkout that is not usable
   before reusing it").** Git keeps a worktree registered after its `gitdir` pointer is deleted
   (flagged `prunable`, a line `Git.worktree_list/1` does not surface), and the directory then
   reads as the parent checkout. `usable_checkout?/1` asks git which admin dir the path belongs to
   (`rev-parse --absolute-git-dir`) and requires it to be the one the checkout itself records
   (`recorded_admin_dir/1`); a mismatch is reported as
   `{:error, {:worktree_path_unusable, path, :worktree_checkout_broken}}` instead of being reused.
   Nothing is reset, cleaned, checked out or removed.

4. **`packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` +
   `packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs` — an empty existing
   directory stays creatable (round 2, minor, "Allow fresh creation in an empty existing
   directory").** `empty_dir?/1` (`File.ls/1` returning `{:ok, []}`) routes an empty directory to
   the fresh-creation arm, because that is what a half-finished create leaves behind and
   `git worktree add` accepts one. A non-empty unregistered directory is still refused, and a
   real-git regression test pins both cases.

5. **`packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` — the branch is read from
   the checkout, not from the registry entry (round 3, minor, "Read the checked-out branch from
   the checkout, not from the registry entry").** The registration keeps the branch it had, so a
   repointed checkout can disagree with it. `checkout_branch/1` reads the checkout's own HEAD
   (`git -C <path> symbolic-ref -q --short HEAD`, `nil` when detached) and that branch is what the
   reuse decision compares against.

6. **`packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` — relative `gitdir:`
   pointers are expanded against the checkout (round 3, minor, "Expand relative `gitdir:` pointers
   against the checkout path before canonicalizing").** `expand_gitdir/2` resolves a relative
   pointer against the directory that holds the `.git` file (`Path.expand(target,
   worktree_path)`), which is how git itself resolves it, so the admin dir stays comparable to
   git's answer. Git 2.48+ writes relative pointers when `worktree.useRelativePaths` is set.

## Declined

1. **`packages/foreman_server/lib/foreman_server/vcs_adapter.ex:43` — "Use an enforced-key struct
   for the worktree result" (round 2, minor; reported again as round 3, minor).**
   `VcsAdapter` is a behaviour whose five callbacks — `create_worktree`, `clone`, `branch`,
   `create_pr`, `clean_worktree` — all return plain maps. Introducing a struct for one of them
   makes the boundary inconsistent, and converting all five is a whole-behaviour change that this
   bead does not authorise (the bead's implementation file is
   `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex`). The contract change this
   bead does need — the `reused` key and the `{:worktree_path_unusable, path, reason}` error — is
   applied to the existing map shape and documented in the CHANGELOG and the user guide.

2. **`packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:184` — "Report the
   checkout's real base, or refuse reuse, when a detached checkout does not match the requested
   base" (round 3, major).**
   Refusing reuse whenever the checkout's HEAD differs from the requested base re-creates the very
   bug this bead removes: a relaunched run's worktree is legitimately **ahead** of the base. The
   reuse test commits "ahead of base", asserts the checkout's HEAD is that commit while
   `result.base` stays the requested base, and `docs/reports/foreman-1lo2p-fix/PLAN.md:96-97`
   fixes the reuse result to echo the requested base. No consumer reads `result.base` for the
   commit under review — `FOREMAN_SOURCE_REVISION` comes from `worktree_record.base_ref`
   (`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:5242` and `:5284`) — so
   reporting the checkout's own base instead would be a second, untested truth with no reader.
   The branch check itself was **not** relaxed: a worktree on an unrelated branch is still an
   error (`{:branch_mismatch, branch}`).

## Verification

All commands run from `packages/foreman_server` with the test database of the running
`foreman-postgres` container (`DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test`;
the shell's default `…@localhost:55434/foreman_dev` fails authentication with
`FATAL 28P01 (invalid_password) password authentication failed for user "postgres"`).

| Command | Exit | Result |
| --- | --- | --- |
| `MIX_ENV=test mix test --warnings-as-errors test/foreman_server/vcs_adapter_default_test.exs` | 0 | 31 passed |
| `MIX_ENV=test mix test --warnings-as-errors test/foreman_server/vcs_adapter_test.exs` | 0 | 8 passed |
| `MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_run_worktree_test.exs` | 0 | 55 passed |
| `MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_command_test.exs` | 0 | 23 passed |
| `MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_source_branch_test.exs` | 0 | 9 passed |
| `mix format --check-formatted lib/foreman_server/vcs_adapter.ex lib/foreman_server/vcs_adapter/default.ex test/foreman_server/vcs_adapter_default_test.exs` | 0 | formatted |

126 tests passed across the five files (the vcs adapter's own suites plus the three
`run_executor` suites that drive worktree creation). Each file was run in its own `mix test`
invocation: running all five in one invocation exceeded the 900 s wall clock in this environment
without reporting a failure, so the per-file runs are the evidence.

Regression probe for fix 6: with `expand_gitdir/2` changed to return a relative target
unresolved, `mix test test/foreman_server/vcs_adapter_default_test.exs` fails 1 of 31 with
`{:error, {:worktree_path_unusable, …, :worktree_checkout_broken}}` where the test expects
`{:ok, %{reused: true, branch: "feat/relative"}}` — the relative-pointer test really bites. The
implementation was restored afterwards and the suite passes.

### Documentation gate

Externally visible identifiers this change touches: the `reused` key in the
`VcsAdapter.create_worktree/3` success map, and the
`{:worktree_path_unusable, path, reason}` error tuple (reasons `:not_a_git_worktree`,
`{:branch_mismatch, branch}`, `:worktree_checkout_broken`). No route, CLI verb, MCP tool, env var
or config key changed.

- `CLAUDE.md` — no hit for the identifiers; no edit needed.
- `README.md` — the only `reused` hits are unrelated phase/PR records; no edit needed.
- `docs/cli-reference.md` — no hit; no CLI surface changed, so no edit needed.
- `docs/user-guide.md` — edited: one sentence in the recovery section (line 1281) describing the
  reuse and the three error shapes.
- `packages/foreman_server/CHANGELOG.md` — edited: one `Unreleased → Fixed` entry.

### State of the working tree

All fixes are left **uncommitted** for Foreman to commit. `git status --porcelain` lists exactly
five modified files — `docs/user-guide.md`,
`packages/foreman_server/CHANGELOG.md`, `packages/foreman_server/lib/foreman_server/vcs_adapter.ex`,
`packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` and
`packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs` — plus this phase's own
new report file, `docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md`.

### Operator notifications

The operator inbox note for this run was sent (`foreman_inbox_send`, status `sent`). The task Work
Log comment (`foreman_task_add_comment`) failed with `Task external_id is malformed` — the run's
provider-backed task id is not usable for that tool, so the note lives only in the run inbox.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs", "line": 301, "description": "VcsAdapter.Default.create_worktree/3 ran git worktree add unconditionally, so a relaunched run failed with git_worktree_create_failed on a worktree that already existed.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs", "line": 299, "description": "The reuse test committed README.md before the reuse call, so it no longer asserted that an uncommitted tracked edit survives reuse.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter.ex", "line": 43, "description": "The worktree result should be an enforced-key struct instead of a plain map.", "disposition": "declined", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 145, "description": "An empty but existing directory at the worktree path must still be creatable instead of refused.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 152, "description": "A worktree registration whose checkout is no longer usable must be refused before the path is reused.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter.ex", "line": 43, "description": "The worktree result should be an enforced-key struct instead of a plain map.", "disposition": "declined", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 217, "description": "The branch to compare must be read from the checkout itself rather than from the possibly stale registry entry.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 184, "description": "A detached checkout whose HEAD differs from the requested base should have its real base reported or reuse should be refused.", "disposition": "declined", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex", "line": 234, "description": "A relative gitdir pointer in the checkout must be expanded against the checkout path before the admin dir is canonicalized.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change rewrites the worktree-creation boundary in the VCS adapter: it reuses an existing registered worktree instead of failing the run, and it introduces the typed error {:worktree_path_unusable, path, reason} for every refused path. The reuse path never touches the checkout, the branch check stays strict, and 126 tests pass, but one major CodeRabbit finding was declined (base reporting for a detached checkout), so a human still owns that decision."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
