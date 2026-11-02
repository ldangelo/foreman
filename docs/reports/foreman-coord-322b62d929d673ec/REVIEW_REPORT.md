Repo-rules review complete.

**Engine:** in-repo rules pass vs `AGENTS.md` + touched-file idioms. Range `git diff main...HEAD` (`FOREMAN_BASE_BRANCH=main`), 5 server files.

**Result:**
- Diff clean & surgical. No violations.
- §5.3: `blank_to_nil/1` raises on non-binary/non-nil goal — good.
- Typed boundary: `@type t` updated w/ `goal`. Single key convention (stringify → `config["goal"]`). No dead config. No doc-gate-visible identifiers added.
- Prev `REVIEW_CODERABBIT_REPORT.md` = prose, no findings-marker block → nothing to carry forward (2 findings already fixed that phase).

**Fixed:** none (already compliant).
**Declined:** none.

**Verification:**
- `mix test --warnings-as-errors` on `project_view_test.exs` + `project_workspace_live_test.exs` → **50 passed**, exit 0 (unset `DATABASE_URL`/`EVENTSTORE_URL`).
- `mix format --check-formatted` on 5 files → exit 0.

Report written to `docs/reports/foreman-coord-322b62d929d673ec/REVIEW_REPORT.md`, unresolved-findings block empty. Left uncommitted for Foreman.