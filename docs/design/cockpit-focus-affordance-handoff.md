# Handoff — Focus affordance: highlight the active pane, dim the inactive one

Status: Implemented in `clients/cockpit/` · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea v2)
Related: `docs/design/cockpit-task-list-gh-dash-style-handoff.md` (two tab strips), `cockpit-unified-theme-handoff.md` (tokens), `cockpit-ui-spec.md`

## 1. Objective

Make it visually obvious which of the cockpit's two focus areas is active:

- **Task list** (left) and **details** (right) — each fronted by a tab strip
  (section tabs on the left per the gh-dash-style handoff; the drill-down tabs on
  the right).
- The **active** pane is highlighted; the **inactive** pane is dimmed.

Interaction is already implemented and unchanged: focus starts in the task list;
`enter` on a task focuses details; `esc` returns focus to the task list.

## 2. Implemented behavior

- `model.go` already owns the focus state with `m.viewFocused`: startup focuses
  the task list, `enter` focuses details, and `esc` returns to the task list.
- `view.go` threads that state into the pane renderers and chooses a small
  pane-visual style set instead of post-processing rendered ANSI.
- Focused panes use the generated `border.focus` token; inactive panes use
  `border.blur` plus optional dimmed content.
- The key/status bar states `focus: tasks` or `focus: details`, so the active pane
  is visible without relying on color alone.
- Mouse click-to-focus uses native pane hit-testing in `handleMouse`; no
  `bubblezone` dependency is required.
- Detail-focused key handling preserves that ownership: task-list section
  navigation and task creation keys are ignored while the right pane is focused,
  except for explicit mouse clicks back into the task list.

## 3. Theme/config contract

- `border.focus` and `border.blur` live in `theme/tokens.yaml`; generated Go
  constants keep cockpit colors aligned with the external-theme fragments.
- `cockpit.focus.style = both|border|dim` and
  `cockpit.focus.dimInactive = true|false` control the treatment.
- `COCKPIT_FOCUS_STYLE` and `COCKPIT_FOCUS_DIM_INACTIVE` override local config.
- `NO_COLOR` still leaves a structural signal through pane frames, tab treatment,
  the focus label, and the task-list `▶` marker.

## 4. Verification completed

- Focus render tests cover task-list-focused and details-focused states.
- Config tests cover `focus.style`, `dimInactive`, and environment overrides.
- `NO_COLOR` render tests cover the task-list `▶` marker, focus labels, and
  active section/detail-tab bracket markers, confirming readable structural focus
  signals without ANSI color.

## 5. Closed non-goals

- No focus behavior change beyond the existing `enter`/`esc`/startup model.
- No ANSI post-processing for dimming; styles are chosen before rendering.
- No new mouse-zone dependency; native pane hit-testing is sufficient.
