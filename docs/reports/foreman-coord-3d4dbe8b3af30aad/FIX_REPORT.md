# Fix Report — four read-only workspace side panels

## Summary verdict

**No change required.** The requested work — filling the empty-hidden
`section.ws-panels` shell with four read-only panels (Instructions, Memory
topics, Library files, Threads) — is **already implemented and merged** in the
branch this run was cut from. The working tree is clean; nothing was changed.

## Root cause

Not a bug. The task prompt was written against the state after PR #815
(`c55cc050`, "Claude-Projects-style header and side-panel shell"), where
`section.ws-panels` was an empty-hidden container. That container was
subsequently filled by **PR #818 (`8630c9f3`, "feat(workspace): read-only
Instructions, Memory, Library and Threads side panels")**, which is an ancestor
of this run's HEAD (`git merge-base --is-ancestor 8630c9f3 HEAD` → true). So the
feature already exists in the code this run is working on.

## Change

None. `git status` is clean; `git diff --stat` is empty.

Existing implementation (all read-only, no new commands/events/queries):
- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex` —
  `info_panels/1` renders the four `section.ws-panel` panels: Instructions
  (`panel-instructions-title`), Memory topics (`panel-memory-title`), Library
  files (`panel-library-title`), Threads (`panel-threads-title`). Empty and
  `:error`/unavailable states handled per panel; threads flattened from the
  Overview groups.
- `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex` —
  `render/1` mounts `<Components.info_panels …>` inside `section.ws-panels`;
  `load_state/1` sources `memory_topics` (`ProjectMemory.list/1`),
  `library_entries` (`Library.list/1`), `instructions`/`goal`
  (`ProjectView.build/2`) and `overview` (`Overview.build/2`) — all data the
  server already exposes.
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex` — the
  panel CSS (`.ws-panels`, `.ws-panels:empty { display:none }`, `.ws-panel`,
  `.ws-panel h2`, `.ws-panel-list`) already lives in the root layout.

## Tests

Already present and passing in
`packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`:
- `aside.ws-side > section.ws-panels` parent/child markup contract (:1207).
- All four panel headings rendered (:1215–1216).
- Empty-data cases: "No memory topics." / "No library files." (:1238–1239).
- Threads panel list items from Overview data (:1244).
- Library panel presence/absence cases (:403–430).

No failing-before check exists because there is no defect to reproduce; the
behaviour the task asks for is the behaviour the suite already asserts.

## Local verification

```
cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server_web/live/project_workspace_live_test.exs
```
(run under `devbox run`, with `DATABASE_URL`/`EVENTSTORE_URL` unset so the test
config defaults to the foreman_test Postgres on :55432)

Result: **47 passed**, exit 0. `mix deps.get` was run first (worktree had no
fetched deps).

## Documentation gate

No externally visible identifiers were added, removed or renamed (no routes,
config keys, env vars, CLI verbs, or MCP tools). No change to `CLAUDE.md`,
`README.md`, `docs/user-guide.md`, or `docs/cli-reference.md` is warranted — no
operator-visible change was made by this run.

## Follow-ups

None. If the intent was to further modify these panels beyond PR #818, the task
prompt does not describe a delta from the current implementation; the four
read-only panels, their empty/unavailable states, the CSS, and the tests all
already satisfy the stated requirements. No pull request was opened because
there are no changes to propose.
