Done. Workspace redesign complete per spec.

**Result: 143 passed** (7 workspace live-test files, incl. 3 new spec-§7 tests), warnings-as-errors clean. `mix format --check-formatted` clean on all 3 source files.

## Changes (markup + CSS only, + pure view helpers)

- **layouts.ex** — inline `<style>` replaced w/ spec token system (light default, dark `@media`), cards/chips/buttons, sticky two-col `.ws-layout` grid (→1col <1000px, order conversation→knowledge→threads), column-reverse transcript (newest-in-view, no JS), `:focus-visible`, `prefers-reduced-motion`.
- **components.ex** —
  - `info_panels/1` → 3 knowledge cards (Instructions/Memory/Files); library upload forms moved into Files card behind `Add files` `<details>`.
  - `conversation_pane/1` → composer now inside transcript card; health status chip; new `message/1` + pure helpers `sender_label/1`, `message_time/1` (truncates to whole seconds → no raw ISO in DOM; full ISO+UTC in `title`), `coordinator_chip/1`, `collapse_system?/1`.
  - `overview_pane/1` heading `Overview→Threads`; compact `thread_card` w/ status chip (`thread_chip/1`), 2-line clamped summary, `Open PR` link, all controls preserved, quiet finished/failed (`thread_quiet?/1`).
  - `tabs_pane`/`tab_body(:library)` → upload forms removed (now in Files card); list/replace unchanged.
- **project_workspace_live.ex** — header (h1, clamped goal w/ title attr, status chip, Settings secondary btn); `project_chip_kind/1`; call sites updated. No assigns/events/Overview-grouping change.

**`<details>` decision:** phoenix_live_view 1.2.8 has `JS.ignore_attributes/1` + client `ignoreAttrs` in `onBeforeElUpdated` → `open` survives re-render, so spec collapsing path used (long system msgs, Show all, Add files).

## Doc gate
No externally visible identifier (route/config/env/CLI verb/MCP tool/command/event) changed — diff is markup/CSS + pure helpers. grep of CLAUDE.md, README.md, docs/user-guide.md, docs/cli-reference.md for changed UI copy → no hits; no edits needed. Nothing under `.beads/` touched.

Changes left uncommitted (Foreman owns commit/PR). FIX_REPORT.md written to `docs/reports/foreman-coord-2982ba63f6435212/`.

Note: progress tools (`foreman_inbox_send`/`foreman_task_add_comment`) were unavailable this session.