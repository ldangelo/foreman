Phase 4 (`repo-rules-review`) complete.

**Review engine:** repo-rules pass over `git diff main...HEAD` (`main` = `546e1d57`, merge-base `0988b071`, HEAD `a7b31744`; 5 files, +173/−1), reviewed against `AGENTS.md` §Working Rules / §Typed Boundaries / Documentation Gate and the CI gates in `.github/workflows/ci.yml`.

**Fixed (1, major):** `packages/foreman_server/test/foreman_server/coordinator/context_test.exs:363` — the file added by this run was not `mix format`-clean; CI runs `cd packages/foreman_server && mix format --check-formatted` (`ci.yml:136-138`), so the branch would have failed the format gate. Ran the repo's own formatter — exactly two blank lines inserted, no assertion or expectation changed. Package-wide check now exits 0.

**Declined (4):** `FIX_REPORT.md` still holds captured tool-error output (another phase's record; the git original at `91fc4f8f` describes a different code lineage — restoring it would import stale claims); phase-3 report has no machine-readable findings/risk block (its 3 prose findings re-verified and carried forward as fixed); `PLAN.md` prescribes extra `stuck`/`needs_recovery` asserts (scope growth); branch is 3 commits behind main (not this run's three-dot diff, and upstream never touches `coordinator/context.ex`).

**Doc gate:** no externally visible identifier added/removed/renamed. `card_state` appears in none of `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`; every `waiting_on_you` hit there describes the untouched `Overview.Group.classify/1` (already maps cancelled → `{:resolved, :cancelled}`). No CHANGELOG entry — the last 4 commits touching `context.ex` on `main` added none. → none of the four doc files needed edits.

**Verification:** `mix compile --warnings-as-errors` exit 0; `mix test test/foreman_server/coordinator/context_test.exs test/foreman_server/overview/group_test.exs` → 87 passed (1 property, 86 tests), exit 0; `mix format --check-formatted` (package-wide) exit 0.

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_REPORT.md` (15980 B) — 5 sections, findings block (8 findings: 1 fixed mine, 3 fixed carried `coderabbit`, 4 declined) and risk judgement `LOW`, both raw JSON between standalone marker lines, no fences anywhere; both blocks parsed with the exact required key sets.

Inbox note and task Work Log comment both sent successfully. Fix left uncommitted for Foreman to commit. `ask_advisor` remains unusable (Anthropic oauth 400 `invalid_grant` / "Refresh token expired" — operator re-auth needed).