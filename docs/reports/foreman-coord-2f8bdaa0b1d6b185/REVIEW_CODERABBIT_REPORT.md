Done. CodeRabbit review complete.

**Engine:** `coderabbit review --agent --base "main"` → exit 0, 4 findings, 1 round.

**Fixed (2):**
- Test gap (trivial/REQ-014): added Workflows-panel count badge (`6`) + muted `awaiting_worker` status assertions, scoped to the panel.
- Unbounded jobsite list (major): `list_jobsites/0` is unbounded → added `@nav_jobsite_limit 100`, `load_state/1` now `Enum.take(..., 100)` (newest-first preserved; symmetric w/ Workflows panel's inherited 100 bound; read model unchanged per REQ-004).

**Declined (2 — same issue, major + dup minor):** cross-project refresh staleness on global panels. Real but out of this run's scope — PRD/TRD deliberately reused the existing shared refresh path and flagged modifying it as the primary regression risk; AC-012-1 only requires recompute on refresh. Surfaced in unresolved-findings block.

**Verification:**
- `mix test --warnings-as-errors test/.../project_workspace_live_test.exs` → 58 passed, exit 0
- `mix format --check-formatted` (2 changed files) → exit 0

**Doc gate:** only new identifier is private `@nav_jobsite_limit` (not externally visible). No CLAUDE.md/README.md/user-guide.md/cli-reference.md edits needed.

Fixes left uncommitted for Foreman. Report at `docs/reports/foreman-coord-2f8bdaa0b1d6b185/REVIEW_CODERABBIT_REPORT.md`.