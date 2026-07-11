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

## 2. Good news — the state already exists

The model already tracks focus with `m.viewFocused` (in `model.go`):

- `viewFocused == false` → **task list focused** (default at startup).
- `enter` → `viewFocused = true` (**details focused**); `esc` → `false`.

So this is a **pure rendering enhancement** — no new focus state, no keymap
changes. Derive per-pane focus as:

```go
leftFocused  := !m.viewFocused
rightFocused :=  m.viewFocused
```

## 3. Visual treatment

Three layers, in priority order. Layer 1 is the minimum; 2 and 3 add polish.

### Layer 1 — Frame / border (always on)
- Focused pane: border uses `border.focus` (the accent, `cCyan`).
- Blurred pane: border uses `border.blur` (faint, `cDim`/`border.faint`).
- Today `leftPaneStyle` has a right border in `cPanel` and the right pane has no
  frame. Give **both** panes a frame the focus color can ride on — simplest is a
  shared vertical divider plus a 1-row top rule per pane (or a full border).
  Whichever, the focused side's frame is accent, the blurred side's is faint.

### Layer 2 — Tab-strip emphasis (always on)
- The focused pane's tab strip renders its active tab in the strong style
  (accent background / underline) and the strip label bright.
- The blurred pane's tab strip renders muted: active tab shown but in a faint
  fill, strip label dimmed — so it's unmistakable which strip is "live" when both
  are visible (important once the left section tabs land).

### Layer 3 — Content dim (config-gated, default on)
- The blurred pane's body renders with a **muted palette**: primary text →
  `text.secondary`, secondary → `text.faint`, semantic accents desaturated to
  faint. The selection highlight stays but dimmed (so you can still see where you
  are when you switch back).
- Config: `cockpit.focus.dimInactive: true|false` (default `true`) and
  `cockpit.focus.style: both | border | dim` so users can dial it back.

Keep contrast accessible: dimming lowers emphasis, it must not make the inactive
pane unreadable. Never rely on color alone — the border + tab emphasis carry the
signal for low-color terminals.

## 4. Implementation notes (where it plugs in)

- **Thread focus into the pane renderers.** `renderLeft(w, h, focused bool)` and
  `renderRight(w, focused bool)` (and their row/tab helpers) take a `focused`
  flag and choose a style set. Prefer passing a small `paneStyles` struct
  (border, text, dim variants) rather than branching on booleans everywhere.
- **Do not recolor pre-rendered ANSI.** Dimming must happen at render time by
  selecting muted styles — attempting to post-process a finished ANSI string to
  dim it is unreliable. That's why `focused` threads *into* the renderers.
- **Frame composition** lives in `renderFrame` (`view.go`), where `left` and
  `right` are styled and `JoinHorizontal`-ed. Set each pane's border color from
  its focus state there; keep the width math (`leftPaneWidth`) unchanged.
- **Focus label (cheap win).** The keybar already swaps hints on `viewFocused`;
  add an explicit `focus: tasks` / `focus: details` chip to the status or key bar
  so the state is stated as well as shown.
- **Mouse:** click-to-focus is implemented with native pane hit-testing in
  `handleMouse`, so the same visual treatment applies without `bubblezone`.

## 5. Theme tokens (single source of truth)

Add to `theme/tokens.yaml` and regenerate (`go generate`), per the theme handoff:

```yaml
border:
  focus: "#56b6c2"   # accent — active pane frame + active tab
  blur:  "#2b2f3a"   # panel/faint — inactive pane frame
```

Reuse existing `text.secondary` / `text.faint` for the Layer-3 muted palette; no
new text tokens needed. Keep everything driven from `tokens.yaml` so the focus
colors stay consistent with the rest of the theme and the external tools.

Implementation notes:

- `FocusConfig` lives under `cockpit.focus` with `style: both|border|dim` and
  `dimInactive: true|false`.
- `COCKPIT_FOCUS_STYLE` and `COCKPIT_FOCUS_DIM_INACTIVE` override local config.
- `paneVisualFor` selects focus/blur borders plus muted inactive colors; the
  keybar states `focus: tasks` or `focus: details`.


## 6. Acceptance

- At startup the **task list** is clearly highlighted and the details pane is
  dimmed; the focus label reads `tasks`.
- `enter` flips the highlight to **details** (accent frame + live tab strip,
  task list dims); `esc` flips it back. Instant, no flicker.
- With two tab strips visible, it's unambiguous which strip is active.
- `cockpit.focus.style = border` disables the content dim but keeps the frame;
  `dim` keeps dim without the accent frame; `both` (default) does both.
- Inactive pane stays readable; signal survives with color disabled
  (`NO_COLOR`) via the frame/tab treatment.
- `go build/test/vet ./...` clean.

## 7. Testing

- Unit: a `paneStyles(focused, cfg)` selector returns focus vs blur styles for
  each `focus.style` setting (table-driven).
- Render: with `viewFocused=false`, the left frame uses `border.focus` and the
  right body uses muted styles; assert the inverse for `viewFocused=true`
  (assert on the chosen style/token, not raw ANSI).
- Snapshot via `COCKPIT_DUMP` / the debug dump: confirm the focused/blurred
  treatment appears in the rendered frame for both states.

## 8. Non-goals & risks

- No change to focus *behavior* (`enter`/`esc`/startup) — visual only.
- Risk: over-dimming hurts readability — gate with `focus.style`, keep the frame
  as the primary always-on cue, and verify under `NO_COLOR`.
- Risk: threading `focused` broadly — keep it to the pane entry points
  (`renderLeft`/`renderRight`) and a `paneStyles` struct to avoid boolean sprawl.

## 9. Sequencing

1. Tokens (`border.focus`/`border.blur`) + regenerate.
2. Layer 1 (frame color from focus) + focus label — smallest, biggest clarity.
3. Layer 2 (tab-strip emphasis) — pairs with the left section tabs.
4. Layer 3 (content dim) behind `focus.style`/`dimInactive`.
5. Docs sweep (README Keys/What-it-shows, `cockpit-ui-spec.md`).
