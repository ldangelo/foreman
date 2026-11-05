Review complete. Report at `docs/reports/foreman-coord-2f8bdaa0b1d6b185/REVIEW_REPORT.md`.

**Result: clean — no violations, no fixes needed.**

Reviewed `git diff main...HEAD` (BASE=main confirmed). Diff: two new read-only nav panels (Jobsite, Workflows) wired into `ProjectWorkspaceLive` between Projects and Artifacts.

Checks:
- **Error handling** — `nav_workflow_runs/0` totally matches `OperatorDashboard.list_runs/0`'s `{:ok,_}|{:error,_}`; `{:error,_}`→empty state (documented glance-panel degradation, §5.2). Not hiding failure.
- **Typed boundary** — workflow rows are `RunDTO` struct; jobsite rows the projection map, matching existing nav-panel idiom.
- **Dead config/enum** — `@nav_jobsite_limit 100` is read at `project_workspace_live.ex:640`.
- **Docs** — CLAUDE.md + user-guide.md updated 4→6 panels, both new data sources named. No new externally visible identifiers (`list_jobsites/0`, `list_runs/1` pre-existed).

Verification:
- `mix test --warnings-as-errors` on `project_workspace_live_test.exs` (DATABASE_URL/EVENTSTORE_URL unset) → **58 passed**, exit 0.
- `mix format --check-formatted` (3 files) → exit 0.

Carry-forward: prev `REVIEW_CODERABBIT_REPORT.md` had **no marker block** (prose only); carried its one unresolved declined finding (global nav panels' cross-project refresh staleness, out of scope) into the unresolved block.

No code changed; nothing committed (Foreman commits the phase).