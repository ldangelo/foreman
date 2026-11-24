Phase 4 (repo-rules-review) complete.

**Artifact**: `docs/reports/foreman-1lo2p-fix/REVIEW_REPORT.md` (174 lines) — sections Review engine / Findings / Fixed / Declined / Verification, findings block (15 entries) then risk block LAST (MEDIUM), both markers standalone, no fences. Validated by the real parsers: findings `{:recorded, 15}`, risk `MEDIUM`, fence_count 0, blocks_last true.

**Reviewed**: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` = `main`(merge-base `ab53fed7`)…`1721efcf`, 9 files, against AGENTS.md + CLAUDE.md + docs/lessons/ + bundled workflow prompts.

**Own findings (source repo-rules), 6:**
- fixed — stray root `FIX_REPORT.md` ("Blocked: no plan found") swept in by `exec/git.ex` `git add -A`; deleted (artifacts belong under `docs/reports/<task>/` per `fix.yaml:51`).
- fixed — phase-3 commit rewrote `REVIEW_CODERABBIT_REPORT.md` 188→16 lines, dropping both JSON blocks while its prose still claimed they existed; restored from `856db13f`.
- fixed — stale `create_worktree/3` `@callback` doc in `packages/foreman_server/lib/foreman_server/vcs_adapter.ex` (reused semantics + typed refusal).
- **open** — `docs/reports/foreman-1lo2p-fix/FIX_REPORT.md` is still the stub "Now writing failing-first tests:"; needs a truthful fix-phase report (operator).
- declined (nitpick) — `reused` has no production reader; key is mandated by the task contract.
- **open** — branch never rebased onto `origin/main` (the task's mandatory first step); `git merge-tree --write-tree origin/main HEAD` ⇒ `CONFLICT (content): Merge conflict in packages/foreman_server/CHANGELOG.md`. Not rebased here — that rewrites Foreman-owned phase history.

**Carried forward (source coderabbit), 9:** 5 fixed (reuse missing, README committed in test, empty-dir creatable, unusable checkout refused, branch read from checkout), 4 declined (C3/C6 enforced-key struct — all five `VcsAdapter` callbacks return plain maps; C8 detached-base refusal — would re-create the bug, no consumer reads `result.base`).

**Verification**: `mix test --warnings-as-errors` on the 4 touched test files ⇒ "Result: 98 passed", exit 0 (`DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test`); `mix format --check-formatted` on the 3 changed Elixir files ⇒ exit 0.

**Left uncommitted** (Foreman commits): `D FIX_REPORT.md`, `M docs/reports/foreman-1lo2p-fix/REVIEW_CODERABBIT_REPORT.md`, `M packages/foreman_server/lib/foreman_server/vcs_adapter.ex`, `?? docs/reports/foreman-1lo2p-fix/REVIEW_REPORT.md`.

Ops: `foreman_inbox_send` sent (`msg_ko2Nw_j5UuaqAE_cbrW1OQ`); `foreman_task_add_comment` failed with "Task external_id is malformed" (not phase-fixable). `ask_advisor` unreachable — Anthropic OAuth `invalid_grant` "Refresh token expired" — so the report is the phase's own claim, stated in the artifact. Kata issue `hshg` created, claimed, commented, closed.