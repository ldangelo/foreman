# Foreman Cockpit — design docs index

The cockpit (`clients/cockpit/`) is a Go / Bubble Tea v2 TUI client for the
Elixir core. These documents capture its architecture, design, and the sequence
of enhancement handoffs. Most are **implemented**; one is **proposed**.

Convention: files are either a **Spec** (living description of intended
behavior), a **Handoff** (an implementation brief for a coding agent), or a
**Design/Investigation** (a proposal or decision record). Each doc carries its
own `Status:` line — this index summarizes and orders them.

## Start here

1. `../adr/0001-go-clients-elixir-core-runtime.md` — **ADR** (foundational). Why
   clients move to Go over an Elixir core, and the contained Node/Pi worker tier.
2. `cockpit-ui-spec.md` — **Spec** (Implemented). The living description of the
   cockpit: layout, state model, keymap, drill-down tabs, integrations. Read this
   second; everything else refines it.

## Documents

| Doc | Kind | Status | What it covers |
|-----|------|--------|----------------|
| `cockpit-ui-spec.md` | Spec | Implemented | Core layout, state model, keymap, drill-down, integrations — the source of truth for cockpit behavior. |
| `cockpit-viewport-investigation.md` | Handoff | Implemented (WS1–6) | Migrate to Bubble Tea v2 / Go 1.26 and adopt `robinovitch61/viewport`. **Foundational** — the v2 move underpins later docs. |
| `cockpit-integrations-handoff.md` | Handoff | Implemented | `diffnav` (file review), `gh dash` (repo PRs), `gh enhance` (CI), and the native `pr` drill-down tab. |
| `cockpit-unified-theme-handoff.md` | Handoff | Implemented | One design-token source (`theme/tokens.yaml`) projected into cockpit + `diffnav`/`gh dash`/`gh enhance`/`delta`/Glamour so they read as one app. |
| `cockpit-task-capabilities-handoff.md` | Handoff | Implemented | Full task detail fields, and task create/edit/approve actions. |
| `cockpit-task-list-gh-dash-style-handoff.md` | Handoff | Implemented | Task list restyled after gh-dash: section tabs (with counts), filter line, rich two-line/columnar rows, wider list. Supersedes the old grouped tree. |
| `cockpit-focus-affordance-handoff.md` | Handoff | Implemented | Highlight the active pane / dim the inactive one, driven by the existing focus state (task list ↔ details). |
| `cockpit-omp-triage-handoff.md` | Handoff | Implemented | Attach an interactive `omp` (oh-my-pi) session to a run's worktree (tmux pane or inline) with a triage brief, for failures/conflicts/CI/CodeRabbit. |
| `cockpit-showcase-components-handoff.md` | Handoff | Implemented | Adopt the Bubble Tea ecosystem (`key`/`help`, `textinput`, `lipgloss` table, `reflow`, native metrics/clicks) toward a showcase-grade TUI; records the v2-only libs (`bubblezone`, `ntcharts`) deliberately parked. |
| `cockpit-kanban-layout-design.md` | Design | **Proposed** | Refactor to top/bottom: Kanban board (Backlog/Ready/In Progress/Blocked/Done) on top, activities on the bottom. Uses `super-tui`'s `BoardPane.ts` as the proof point. |

## Dependency & reading order

```
ADR 0001 ─ architecture (Go clients over Elixir core)
   └─ cockpit-ui-spec ─ the cockpit's behavior spec
        ├─ viewport-investigation ─ v2 / Go 1.26 migration  ← prerequisite for the rest of the modern stack
        │     └─ showcase-components ─ ecosystem adoption (v2-gated)
        ├─ integrations ─ diffnav / gh dash / gh enhance / pr tab
        │     └─ unified-theme ─ one skin across cockpit + those tools
        ├─ task-capabilities ─ task detail + create/edit
        │     └─ task-list-gh-dash-style ─ section tabs + rich rows (supersedes grouped tree)
        │            └─ focus-affordance ─ active/inactive pane emphasis (assumes the two-strip model)
        └─ omp-triage ─ interactive worktree triage handoff

Proposed next:
   kanban-layout-design ─ re-arranges the task UX (task-list + focus) into a
                          top board + bottom activities; reuses rows/filter/
                          scope/viewer/focus rather than replacing them.
```

Notes:

- The **v2 migration** (`viewport-investigation`) is the load-bearing
  prerequisite: it moved the cockpit to `charm.land/bubbletea|lipgloss/v2` and
  Go 1.26, which the showcase and later work assume.
- The **task-list gh-dash restyle** established the section-tab / two-strip model
  that the **focus-affordance** doc builds on.
- The **Kanban design** (proposed) reworks the *arrangement* of the task UX
  (left/right → top/bottom, section tabs → columns) while explicitly reusing the
  shipped rows, filter grammar, project scope, viewport, focus affordance, and
  theme. It has open decisions to confirm (see its §12).

## Maintaining this index

When adding a design doc: give it a `Status:` line, add a row to the table above,
and place it in the dependency tree. When a doc is implemented, update its
`Status:` to `Implemented in clients/cockpit/` (several already read that way).
