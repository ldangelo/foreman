## Review

- Correct:
  - Duplicate attach now returns original matching event payload, not latest run projection. Evidence: `attach_bridge.ex:254-270`.
  - Multi-worker + unsupported interleaving covered. Evidence: `attach_bridge_test.exs:89-127`.
  - Terminal resume rejects before append/projection side effects. Evidence: `attach_bridge.ex:131-134`, `:146-147`; tests `attach_bridge_test.exs:247-292`.
  - Prior AC-018 paths still covered: attach ready/recent completed/stale/unsupported/replay tests in `attach_bridge_test.exs`.

- Fixed:
  - None. Review-only. No edits.

- Blocker:
  - None found in focused scope.

- Optional:
  - Output file not written. User said no edits; no-edit wins.
  - `progress.md` missing (`ENOENT`).

- Commands:
  - `git status --short` — clean.
  - `git log --oneline -8` — inspected history; target commit `81504283`.
  - `cd packages/foreman_server && mix test test/attach_bridge_test.exs` — passed, 12 tests.
  - `cd packages/foreman_server && mix test` — passed, 85 tests.