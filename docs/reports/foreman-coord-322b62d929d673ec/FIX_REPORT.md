# Fix Report — Project workspace layout shell (Claude Projects look)

## Root cause

Not a bug fix: a layout/styling task. The project workspace page
(`ForemanServerWeb.ProjectWorkspaceLive.render/1`, `/dashboard/projects/:id`)
rendered a bare `<header>` (name + Settings nav + notice) and a two-column
`.ws-layout` grid (chat 2fr | right column 3fr). It did not show the project
goal and had no dedicated, structured side-panel container for the upcoming
read-only panels. `ForemanServerWeb.Workspace.ProjectView` exposed only
`name`/`status`, so the goal the server already stores was not available to the
header.

## Change

- `packages/foreman_server/lib/foreman_server_web/workspace/project_view.ex` —
  `ProjectView.build/2` now also returns `goal`, read from the same normalised
  config as `name` (`config["goal"]`, handling atom- and string-keyed configs);
  blank/whitespace goals normalise to `nil`. No new command or event.
- `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex` —
  header renders the goal (`<p class="ws-goal">`) only when present; the chat is
  wrapped in a semantic main column (`<section class="ws-main-col">`); the right
  region is an `<aside class="ws-side">` holding an empty, structured
  `<section class="ws-panels">` shell for the follow-up read-only panels, with
  the existing questions/overview/tabs panes preserved unchanged.
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex` — inline
  CSS (no asset pipeline) for `.ws-header`, `.ws-goal`, `.ws-main-col`,
  `.ws-side`, `.ws-panels` and a wider main column
  (`grid-template-columns: 3fr minmax(300px, 1fr)`); the single-column
  responsive breakpoint is kept.

## Tests

- `test/foreman_server_web/workspace/project_view_test.exs` — added a case
  asserting the goal is read from either config key shape, trimmed, and that
  absent/blank goals yield `nil`.
- `test/foreman_server_web/live/project_workspace_live_test.exs` — added header
  tests (goal shown when set; no `ws-goal` paragraph when absent) and an
  accessibility/structure test asserting the `<aside class="ws-side">` +
  `<section class="ws-panels">` shell is present.

Failing-before / passing-after: the three new assertions reference markup
(`ws-goal`, `ws-side`, `ws-panels`) and the `goal` field that did not exist
before this change, so they fail on the prior tree and pass on the new one.

## Local verification

```
devbox run -- bash -c 'cd packages/foreman_server && unset DATABASE_URL && \
  MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server_web/workspace/project_view_test.exs \
  test/foreman_server_web/live/project_workspace_live_test.exs'
```

Result: `50 passed`, clean compile under `--warnings-as-errors`.
(`DATABASE_URL` is unset so the suite uses the default test DB
`postgres://postgres:postgres@localhost:55432/foreman_test` rather than the
dev-stack DB.)

Documentation gate: no externally visible identifiers (routes, config keys, env
vars, CLI verbs, MCP tools) were added, removed, or renamed — only internal CSS
class names and the internal `ProjectView.t` `goal` field. `CLAUDE.md`,
`README.md`, `docs/user-guide.md`, `docs/cli-reference.md` need no edits.

## Follow-ups

- The read-only side panels (Instructions, Memory topics, Library files, Threads
  list) that fill the empty `ws-panels` shell are a separate thread and were
  intentionally left out of scope.
- The existing questions/overview/tabs panes remain in the right `aside`
  alongside the new shell; reorganising them into the Claude-Projects panel set
  is for the follow-up panels thread.
