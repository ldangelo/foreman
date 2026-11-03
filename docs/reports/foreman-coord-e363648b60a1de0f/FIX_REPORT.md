# FIX_REPORT — Workspace read-only side panels

## Root cause

Not a bug fix — a scoped feature. PR 815 merged the workspace layout shell with an
empty, empty-hidden `section.ws-panels` container in
`packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex`
(`render/1`). The container was a placeholder with no content. This task fills it with
four READ-ONLY panels (Instructions, Memory topics, Library files, Threads) using only
data the server already exposes. No new commands or events.

## Change

- `lib/foreman_server_web/workspace/project_view.ex` — add an `instructions` field to
  `ProjectView.t` and `build/2`, read from the project config the same way `goal` is
  (either key shape, `blank_to_nil`). Gives the Instructions panel its text without a
  new read path.
- `lib/foreman_server_web/project_workspace_live.ex` — alias `Library` and
  `ProjectMemory`; in `load_state/1` load `memory_topics` (`ProjectMemory.list/1`) and
  `library_entries` (`Library.list/1`), each returning `[]` on `{:error, _}` (a project
  whose path is absent shows empty panels, never crashes); render
  `Components.info_panels` inside `section.ws-panels`.
- `lib/foreman_server_web/workspace/components.ex` — new read-only
  `info_panels/1` function component: Instructions text, memory topic name/description,
  library entry name + file count, and thread titles/status flattened from
  `overview.groups` in `Group.all/0` order. Display only; no `phx-click`, no mutation.
- `lib/foreman_server_web/workspace/layouts.ex` — inline CSS for `.ws-panel` /
  `.ws-panel-list` (no asset pipeline; CSS lives in the root layout).

Chat send, overview, questions, the Library/PR/Scheduled tabs, library upload and the PR
buttons are untouched and keep working: the panels are additive, read-only, and fed from
existing reads.

## Tests

- `test/foreman_server_web/workspace/project_view_test.exs` — added a test pinning
  `instructions` for either config key shape, trimmed, else `nil` (fails before the
  `ProjectView` change: the field did not exist).
- `test/foreman_server_web/live/project_workspace_live_test.exs` — new `read-only side
  panels` describe: (1) the four panels render inside the shell with their headings,
  (2) the Instructions panel shows the project's instructions text, (3) empty states for
  memory/library and a thread title listed in the Threads panel. These fail before the
  render change (the container was empty).

## Local verification

Run from the run worktree with `DATABASE_URL`/`EVENTSTORE_URL` unset so the test config
defaults to the foreman Postgres on :55432.

- `MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web/workspace/project_view_test.exs test/foreman_server_web/live/project_workspace_live_test.exs`
  → **54 passed**, exit 0.
- `mix format --check-formatted` on the six changed files → exit 0.

## Documentation gate

Externally visible identifiers added/removed/renamed: **none**. The change adds a private
function component (`Components.info_panels/1`), a `ProjectView` map field
(`instructions`) and two CSS classes (`.ws-panel`, `.ws-panel-list`) — all internal. No
routes, config keys, env vars, CLI verbs or MCP tools changed.

Grep of `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` for
`ws-panel` / `info_panels` / `side panel` / `read-only panel` → no hits. No doc edits
needed (no operator-visible surface changed).

## Follow-ups

None intentionally left undone. The read-only Library-files panel coexists with the
existing editable Library tab by design (the tab keeps upload/replace/download/remove).
