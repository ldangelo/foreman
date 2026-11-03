# FIX REPORT — project workspace visual redesign (/dashboard/projects/:id)

## 1. Root cause

Not a crash bug: the operator rejected the live page as poor UI/UX. The structure
existed but the presentation did not match the "Claude Projects" target. Problems in
the markup/CSS only (no asset pipeline, so all CSS lives in the single inline `<style>`
of the root layout `lib/foreman_server_web/workspace/layouts.ex`):

- Default dark theme, hairline boxes, small uniform text.
- Raw log dump as the main column: every message printed `system via system ·
  2026-11-01T19:36:26.399095Z`-style headers with raw ISO microsecond timestamps.
- The composer (message box) sat below the whole log, off-screen.
- Full instructions printed as a wall; dead/finished threads cluttered everything.

No command, event, route, config, env var, CLI verb or MCP tool changed. Fix is
markup + CSS plus small *pure* formatting helpers (sender label, time text, status
chips), exactly as the spec constrains.

## 2. Change

All paths under `packages/foreman_server/`.

- `lib/foreman_server_web/workspace/layouts.ex` — replaced the inline `<style>` with the
  spec token system (`:root` light default, `@media (prefers-color-scheme: dark)`),
  cards/chips/buttons, the two-column sticky `.ws-layout` grid (collapses to one column
  under 1000px in the order conversation → knowledge → threads), the column-reverse
  transcript (keeps newest in view with no JS), message/thread/tab styling,
  `:focus-visible`, and `prefers-reduced-motion`. No markup change here.
- `lib/foreman_server_web/workspace/components.ex`
  - `info_panels/1` rewritten into the three "Project knowledge" cards
    (Instructions / Memory / Files). Added pure helpers; moved the two library upload
    forms into the Files card behind an `Add files` `<details>`; added `settings_path`
    and the upload-config attrs; dropped the old `overview` attr.
  - `conversation_pane/1` rewritten: the composer now lives in the **same card** as the
    transcript; the coordinator health line uses a status chip; added a private
    `message/1` component plus pure helpers `sender_label/1`, `message_time/1`
    (truncates to whole seconds so no raw ISO microsecond string reaches the DOM;
    full ISO + "UTC" kept in the `title` attribute), `coordinator_chip/1`,
    `collapse_system?/1`.
  - `overview_pane/1` heading text `Overview → Threads` and group headings restyled
    (`ws-group-title`); each thread rendered as a compact `thread_card` with a status
    chip (`thread_chip/1`), a 2-line-clamped last-report summary, an `Open PR` link, and
    all existing controls preserved; quiet styling for finished/failed cards
    (`thread_quiet?/1`).
  - `tabs_pane/1` / `tab_body(:library)` — removed the two upload forms from the Library
    tab (now in the Files card) and dropped the now-unused upload attrs; the library
    list and per-entry replace form are unchanged.
- `lib/foreman_server_web/project_workspace_live.ex` — header rewritten (h1 project name,
  2-line-clamped goal with full text in `title`, a project status chip, Settings as a
  secondary button); `info_panels`/`tabs_pane` call sites updated for the moved upload
  forms; added pure helper `project_chip_kind/1`. No LiveView assigns, events or
  Overview grouping changed.
- `<details>` open-state decision: the installed `phoenix_live_view` 1.2.8 exposes
  `JS.ignore_attributes/1` (deps/phoenix_live_view/lib/phoenix_live_view/js.ex) and the
  client applies `ignoreAttrs` in `onBeforeElUpdated`, so a `<details open>` survives a
  re-render. The spec's collapsing path is therefore used: long system messages,
  Instructions "Show all", and Files "Add files" are `<details phx-mounted={JS.ignore_attributes("open")}>`.

## 3. Tests

Spec section-7 behaviour tests (consumer-visible only; no class names / incidental
wording pinned), in `test/foreman_server_web/live/project_workspace_live_test.exs`:

- Conversation: a posted message renders its text but the `#conversation-log` contains
  **no** raw ISO timestamp (`\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z`) and no
  `via system` / `via cli`.
- Conversation: the composer form is inside `#conversation-pane` and still sends.
- Knowledge: long instructions keep their full text (`SENTINEL_TAIL`) in the DOM.

Edited where markup moved (not behaviour):
- `project_workspace_live_test.exs` — knowledge-panel headings now `Instructions` /
  `Memory` / `Files`; empty-state strings `No memory yet. Agents save durable facts
  here.` and `No files yet.`; the thread-title assertion now targets the thread card
  (`.thread-card .thread-title`); the auth smoke assertion checks `Threads` (the renamed
  Overview heading) instead of `Overview`.
- `project_workspace_coordinator_live_test.exs` — health text is now the chip label
  `idle` / `unhealthy` instead of `Status: idle` / `Status: unhealthy`. The
  consecutive-failures and last-error assertions are unchanged and still pass.

## 4. Local verification

Run from the worktree root; env unset so tests hit the foreman Postgres, not langfuse.

- `devbox run -- bash -c 'cd packages/foreman_server && unset DATABASE_URL EVENTSTORE_URL &&
  MIX_ENV=test mix test --warnings-as-errors <7 project_workspace_*_live_test.exs files>'`
  → **143 passed** (includes the 3 new tests), exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors` → clean (only pre-existing deps
  warnings in jido_shell).
- `mix format --check-formatted` on the three changed source files → exit 0; test files
  formatted.

Doc gate: no externally visible identifier (route, config key, env var, CLI verb, MCP
tool, command/event type) added, removed or renamed — the diff is markup/CSS and pure
view helpers. `grep` of `CLAUDE.md`, `README.md`, `docs/user-guide.md`,
`docs/cli-reference.md` for the changed UI copy (`Memory topics`, `Library files`,
`panel-threads`) found no references, so none of those four files needed edits. Nothing
under `.beads/` touched.

## 5. Follow-ups

- Operator will review live screenshots before merge (per spec section 8). The
  `-webkit-line-clamp` clamps (goal, instructions, summaries) render on WebKit/Blink
  Obsidian/Chrome/Safari; behaviour and full text are unaffected on other engines.
- Progress tools (`foreman_inbox_send` / `foreman_task_add_comment`) were not available
  this session, so no interim operator notes were sent; noted here per the prompt.
