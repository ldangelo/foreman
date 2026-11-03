Review complete.

**Review engine:** repo-rules agent vs `AGENTS.md`; range `git diff main...HEAD` (`$FOREMAN_BASE_BRANCH=main`). CodeRabbit report had no `FOREMAN_REVIEW_FINDINGS` marker block → nothing to carry forward.

**Result:** diff already compliant. No fixes, no declines.

Checks passed:
- §5.2/5.3 — `{:error,_}` → `:error` distinct unavailable state, not `[]`; empty≠failed.
- §5.1 — `ProjectView.t()` gained `instructions: String.t()|nil`; `blank_to_nil/1` matches `is_binary`+`nil` only (non-string raises).
- No dead config: all added fields read by panels/`flatten_threads/1`.
- Contracts verified vs source: `ProjectMemory.list/1`→`[Topic]` (.name/.description), `Library.list/1`→`[Entry]` (.name/.file_count), `Overview.groups`→`%{Group=>[ThreadCard]}` (.title/.status). All CSS classes exist in `layouts.ex`.
- UI invariants: read-only, no new command/event, CSS in root layout.
- Doc gate: no externally visible identifiers (private fns, component attr, CSS, tests) → no doc edits needed.

**Verification** (DATABASE_URL/EVENTSTORE_URL unset):
- `mix test --warnings-as-errors` (2 affected files) → **54 passed**, exit 0.
- `mix format --check-formatted` (6 files) → exit 0.
- `git status` clean; fixes left uncommitted (Foreman commits).

Report written to `docs/reports/foreman-coord-e363648b60a1de0f/REVIEW_REPORT.md` w/ empty unresolved-findings block.