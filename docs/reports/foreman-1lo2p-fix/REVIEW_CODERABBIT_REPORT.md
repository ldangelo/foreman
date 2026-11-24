Phase complete.

**Review engine** — `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (base `main`, merge-base `ab53fed7`) from the worktree root. 3 rounds, all exit 0 / `review_completed`: 9 findings (3 major, 6 minor).

**Fixed (6)**
| Finding | Change |
|---|---|
| R1-A major — reuse missing in `Default.create_worktree/3` | reuse a registered worktree on the requested branch **before** `git worktree add`; result gets `reused: true`, `output: ""` |
| R1-B minor — reuse test committed its edit | test writes `README.md` after `ahead_sha`, asserts uncommitted edit survives |
| R2-3 major — registered-but-unusable checkout reused | `usable_checkout?/1` + `recorded_admin_dir/1` → `{:worktree_path_unusable, path, :worktree_checkout_broken}` |
| R2-2 minor — empty existing dir refused | `empty_dir?/1` → fresh creation still allowed; real-git regression test |
| R3-2 minor — branch read from registry | `checkout_branch/1` = `git -C <path> symbolic-ref -q --short HEAD` |
| R3-4 minor — relative `gitdir:` pointer | `expand_gitdir/2` → `Path.expand(target, worktree_path)` |

**Declined (3)** — enforced-key struct for the worktree result (×2): all five `VcsAdapter` callbacks return plain maps; a struct for one is inconsistent and a whole-behaviour change is outside this bead's scope. Detached-base refusal (major): it would re-create the very bug this bead removes — the relaunched worktree is legitimately ahead of the base (`HEAD == ahead_sha`, `result.base == base_sha`), and no consumer reads `result.base` (`FOREMAN_SOURCE_REVISION` comes from `worktree_record.base_ref`). Branch check stays strict.

**Verification** — 126 tests pass, exit 0, per file: `vcs_adapter_default_test.exs` 31, `vcs_adapter_test.exs` 8, `workflow/run_executor_run_worktree_test.exs` 55, `workflow/run_executor_command_test.exs` 23, `workflow/run_executor_source_branch_test.exs` 9 (`--warnings-as-errors`, `DATABASE_URL=…@localhost:55432/foreman_test`); `mix format --check-formatted` clean on the 3 changed Elixir files. R3-4 regression probe: unresolved relative target ⇒ 1 of 31 fails (`:worktree_checkout_broken`), then restored.

**Doc gate** — identifiers: `reused` key, `{:worktree_path_unusable, path, reason}`. CLAUDE.md / docs/cli-reference.md: no hits, no edit; README.md hits unrelated; docs/user-guide.md:1281 + `packages/foreman_server/CHANGELOG.md` edited. No route/CLI/MCP/env/config change.

**Artifact** — `docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md`; both raw-JSON blocks last, validated by the real parsers (findings `recorded` 9, risk `recorded` MEDIUM, 0 fences).

Fixes left **uncommitted** (5 modified files + the new report) for Foreman to commit. Operator inbox note sent; the task Work Log comment failed (`Task external_id is malformed`) and is recorded in the report. `ask_advisor` unavailable — Anthropic oauth refresh expired, so no advisor verdict. Kata issue `3c19` closed with the mix test as evidence.