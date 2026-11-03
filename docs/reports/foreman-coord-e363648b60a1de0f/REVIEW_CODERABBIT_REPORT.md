CodeRabbit review phase complete.

## Summary

**Base:** `main` (confirmed). **Rounds:** 2 (stopped early — round 2 had no Critical/Major).

### Round 1 — 2 findings, both fixed
- **Major** `project_workspace_live.ex:561,568` — `memory_topics/1`/`library_entries/1` mapped `{:error,_}` → `[]`, masking genuine read failures as empty. Now return `:error`; `components.ex` renders a distinct "unavailable" state w/ `is_list/1` guards; attrs widened `:list`→`:any`. Missing dirs already return `{:ok,[]}` from both stores, so empty projects still show the empty state.
- **Minor** test:1241 — `html =~ "Second PR"` also matched Overview. Scoped to `section[aria-labelledby="panel-threads-title"] ul.ws-panel-list li strong` via `has_element?/3`.

### Round 2 — 2 Minor findings
- **Fixed** FIX_REPORT.md:7 — reworded stale `[]`-on-error claim to match new `:error` behavior.
- **Declined** components.ex:80 ("rename Library files → Library entries") — "Library files" is task-required + test-asserted; renaming breaks it, per-entry counts already shown, total-file-count sum is out of scope.

### Verification
- `mix test --warnings-as-errors` (2 affected files, DB env unset) → **54 passed**, exit 0.
- `mix format --check-formatted` on 3 edited .ex/.exs → exit 0.

### Doc gate
No externally visible identifiers changed (private fns, internal attr types, CSS, test). No edits to CLAUDE.md/README.md/docs/user-guide.md/docs/cli-reference.md.

Fixes left uncommitted (Foreman commits). No `.beads/` touched. Report written w/ empty unresolved-findings block.