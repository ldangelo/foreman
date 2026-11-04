Done. CodeRabbit review phase complete.

**Engine:** `coderabbit review --agent --base "main"` → exit 0, 2 findings (both Minor).

**Round 1:** 2 fixed, 0 declined. Stopped early (no Critical/Major).

**Fixed:**
- `components.ex:228` — Search now matches library file paths (not just `entry.name`); searching `design.pdf` inside an entry no longer returns "No matches."
- `project_workspace_live.ex:747` — Projects panel no longer drops archived projects (removed `Enum.reject(&archived_project?/1)` + orphaned helper); matches task ("all projects") + user-guide ("every project").

**Verification:**
- format `--check-formatted` → exit 0
- `mix test --warnings-as-errors test/.../project_workspace_live_test.exs` → **54 passed**, exit 0
- Tests run w/ `DATABASE_URL`/`EVENTSTORE_URL` unset (preset dev creds fail auth).

Doc gate: no externally visible identifiers changed; fixes align code to already-shipped user-guide text. Fixes left uncommitted for Foreman. Report at `docs/reports/foreman-coord-9da83c229eeda4d7/REVIEW_CODERABBIT_REPORT.md` w/ empty unresolved-findings block.