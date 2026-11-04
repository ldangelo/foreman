# CodeRabbit Review Report — coord-9da83c229eeda4d7 / run-228766bf31e468cce274e324c8bb66b5

## Review engine

Command (from the worktree root, `$FOREMAN_BASE_BRANCH=main`):

```
coderabbit review --agent --base "main"
```

Exit 0. Engine ran to completion (`review_context` → heartbeats → 2 `finding` → `complete`).
Diff reviewed: `main...HEAD` — the workspace-nav sidebar implementation plus its
docs (`project_workspace_live.ex`, `workspace/components.ex`,
`project_workspace_live_test.exs`, `CLAUDE.md`, `docs/user-guide.md`, a PRD file).

## Rounds

- **Round 1** — 2 findings received (both `Minor`). 2 fixed, 0 declined.
- **Round 2** — not run. Round 1 fixed no `Critical`/`Major` finding (none were
  reported), so the early-stop condition was met after round 1.

## Fixed

1. **`packages/foreman_server/lib/foreman_server_web/workspace/components.ex:228`**
   — Workspace-nav Search matched only `entry.name` for library files, so
   searching for a file path inside an entry (e.g. `design.pdf` under an entry
   named `References`) returned "No matches." The user-guide the same PR added
   says Search covers "library files". Verified against current code: `file_hits`
   filtered on `nav_match?(&1.name, q)` only; `Library.Entry` carries `files ::
   [%{path, bytes, sha256}]`. Changed the filter to also match any file path:
   `&(nav_match?(&1.name, q) or Enum.any?(&1.files, fn f -> nav_match?(f.path, q) end))`.
   Result display (entry name) left unchanged — minimal, surgical fix that
   resolves the reported no-match.

2. **`packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex:747`**
   — The Projects panel ran `Enum.reject(&archived_project?/1)` over
   `ProjectStore.list/0`, dropping archived projects. The task asks for "a list
   of all projects" and the user-guide the same PR added states the panel
   "lists every project (`ProjectStore.list/0`)" — the code contradicted both.
   An operator viewing an archived project lost its own current-project link.
   Removed the `Enum.reject(&archived_project?/1)` step, removed the now-orphaned
   private `archived_project?/1` helper (its only caller), and updated the doc
   comment. (The separate `archived_project?/1` in `project_controller.ex` is
   untouched — a different module, still used there.)

## Declined

None.

## Verification

Run via devbox with `DATABASE_URL`/`EVENTSTORE_URL` unset (the preset values
point at a dev Postgres whose password auth fails; unsetting falls back to the
test config's socket Postgres).

- `cd packages/foreman_server && mix format lib/foreman_server_web/workspace/components.ex lib/foreman_server_web/project_workspace_live.ex --check-formatted`
  → exit 0.
- `cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web/live/project_workspace_live_test.exs`
  → **54 passed**, exit 0.

Documentation gate: no externally visible identifier was added, removed or
renamed (routes, config keys, env vars, CLI verbs, MCP tools, command/event
types all unchanged). Both fixes make the code match the user-guide text the
PR already shipped, so no doc edit was required.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
<!-- FOREMAN_REVIEW_FINDINGS_END -->
