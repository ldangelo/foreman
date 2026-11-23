Phase done. Repo-rules review complete.

**Range**: `FOREMAN_BASE_BRANCH=main` → `git diff main...HEAD` + working tree `git diff HEAD` (prev phase left most impl uncommitted: `run_executor.ex`, `repo_attach.ex`, `projection_store.ex`, 2 test files, doc edits).

**9 fixed / 1 declined** — critical: committed apply arm called non-existent `base_sha_payload_value/1` → branch did not compile. major: `base_sha/1` accessor claimed reader `AutoPR.resolve_base_ref/1` (doesn't exist); moduledoc claimed `FOREMAN_BASE_SHA` export (no such identifier anywhere); command payload unwhitelisted → `EventCodec.decode!/2` raises on undeclared keys. minor: dead `:base_sha` State field; unvalidated `base_sha`; malformed `repo_id` silently dropped (wrong branch attribution); committed agent-transcript `.dev/b3.txt` (removed + gitignored); junk `FIX_REPORT.md` (rewritten). Declined (nitpick): event `:sequence` never set — pre-existing vocabulary, out of scope.

**Verification** (all exit 0): `mix compile --warnings-as-errors`; `mix format --check-formatted` (8 files); narrow `mix test` 3 files → 21 passed, ProjectionLeakGuard clean; full `mix test --warnings-as-errors` → 9261 passed, 11 excluded, no warnings.

**Doc gate**: `docs/user-guide.md:1362-1367` + `docs/lessons/architecture-and-events.md:222` updated; README/cli-reference/CLAUDE.md needed none (no route/verb/env/config change; `RepoPr.finalize` context still reads only `base_branch`).

**Report**: `docs/reports/foreman-beads:foreman:foreman-i3qol/REVIEW_REPORT.md` — both blocks parse-verified via `ReviewFindings.read/1` (`status: recorded`, 10 findings, sha 1331874b…) and `PrRisk.parse_judgement/1` (`status: recorded`, LOW). Fixes left uncommitted; kata `aqkq` claimed → commented → closed with test evidence. `foreman_inbox_send`/`foreman_task_add_comment` not exposed; `ask_advisor` failed (Anthropic refresh token expired — env fault, not a review finding).