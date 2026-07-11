# Handoff — A showcase-grade cockpit: adopting the Bubble Tea ecosystem

Status: Implemented in `clients/cockpit/` with external showcase caveats · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea)
Related: `docs/design/cockpit-viewport-investigation.md` (v2 migration), `cockpit-unified-theme-handoff.md`, `cockpit-task-capabilities-handoff.md`, `cockpit-ui-spec.md`

Implementation note (2026-07-11): the cockpit ships generated keymap/help,
`textinput`/`textarea` task creation, table/reflow rendering, spinner/stopwatch
reduced-motion support, clickable section/task-row/drill-down-tab/action targets,
a metrics tab backed by `/api/v1/metrics`, a theme installer, and richer mock data.
No local cockpit feature is waiting on those libraries: native hit-testing covers
section/row/action/PR clicks, native bounded bars cover the metrics tab, and
`clients/cockpit/demo.tape` is checked in for `vhs` capture. `bubblezone` and
`ntcharts` remain intentionally unadopted until upstream ships Bubble Tea v2
builds; `harmonica` remains optional polish.

## 1. North star

Make the Foreman cockpit a **showcase, breathtaking TUI for driving agentic
development** — the app you'd screenshot to explain what Foreman is. Not chrome
for its own sake: every flourish should make the fleet of agents *more legible*
and the operator *faster*. Concretely, "breathtaking" here means:

- **At-a-glance intelligence** — live charts/sparklines of the agent fleet
  (throughput, pass/fail, phase durations, queue depth) so health reads in one
  glance, not by scanning rows.
- **Motion with meaning** — smooth, spring-based transitions (the phase rail
  advancing, panels sliding, spinners breathing) that signal state change.
- **Click or type, your choice** — every target (tabs, rows, action bar, PR
  links) is clickable *and* keyboard-driven, with a discoverable, self-
  documenting keymap.
- **One cohesive skin** — the unified theme (see the theme handoff) carried
  consistently across the cockpit and its `diffnav`/`gh dash`/`gh enhance`
  handoffs so it reads as one product.
- **A demo that sells it** — a rich mock dataset + a recorded GIF.

This replaces several hand-rolled cockpit mechanics with battle-tested components
so we get polish *and* delete code that has already caused bugs.

## 2. Hard prerequisite: Bubble Tea v2

The cockpit is migrating to Bubble Tea v2 / Go 1.26 (see the viewport handoff).
**Every library below must be adopted on v2**, and the #1 selection rule —
learned from the viewport library — is:

> Before adding any dependency, confirm it has a **v2 build** (imports
> `charm.land/bubbletea/v2` / `lipgloss/v2`, not the v1 `github.com/charmbracelet/*`).
> A v1-only component drags in a conflicting runtime and will not compile.

Charm's own `bubbles`, `lipgloss`, `glamour`, `harmonica` are first-party and
track v2. Community libs (`bubblezone`, `ntcharts`, `huh`, `stickers`) must be
verified per §5 before commitment; if one lags v2, defer it — don't fork the app
back to v1.

## 3. Component shortlist (what, why, where)

| Component | Purpose | Cockpit call-site it replaces / adds | Tier | v2? |
|-----------|---------|--------------------------------------|------|-----|
| `bubbles/v2` `key` + `help` | self-documenting keymap | replaces the hand-rolled `?` notice + `renderKeyBar` in `view.go` | 1 | first-party |
| `bubbles/v2` `textinput`/`textarea` | real text entry | replaces hand-parsed search in `TaskList`; powers add-task fields | 1 | first-party |
| `lipgloss/v2` `table` + `list` | structured static rendering | task-detail field block, PR-checks summary — replaces `padRow` columns | 1 | first-party |
| `muesli/reflow` | ANSI/Unicode wrap + truncate | replaces `clip`/`padRow`/`wrap` in `view.go` (correct width math) | 1 | framework-agnostic |
| `lrstanley/bubblezone` | mouse click zones | intentionally not adopted; native hit-testing covers tabs/rows/action-bar/PR links | 2 | v1-only at `v1.0.0` |
| `NimbleMarkets/ntcharts` | sparklines/line/bar/heatmap | intentionally not adopted; native bounded bars cover live metrics from `/api/v1/metrics` | 2 | v1-only at `v0.5.1` |
| `charmbracelet/huh` | forms | not needed; `bubbles/v2` `textinput`/`textarea` power search and add-task forms | 2 | superseded |
| `charmbracelet/harmonica` | spring animation | optional polish; current spinner/stopwatch/reduced-motion paths are first-party and deterministic | 3 | framework-agnostic |
| `bubbles/v2` `spinner` | real spinner + loading state | replaces manual `↻/↺` in `renderStatusBar`; diff-preview loading | 3 | first-party |
| `bubbles/v2` `stopwatch`/`timer` | live elapsed | live "elapsed" on RUNNING runs | 3 | first-party |
| `76creates/stickers` (optional) | flexbox layout | retire manual two-column width math (source of the blank-pane bug) | 3 | **verify** |

Explicitly **not** adopting: `bubbles/viewport` (superseded by
`robinovitch61/viewport`), `wish`, `filepicker` (nvim/diffnav own files).

## 4. Showcase workstreams (grouped by the experience they deliver)

Each is independently shippable and lands after the v2 migration reaches parity.
Follow the repo TDD rule; keep the read-only-client architecture intact.

### A. Discoverable keymap (`key` + `help`) — Tier 1
Define `key.Binding`s once; render a `help` bubble (short line in the keybar,
full overlay on `?`). Removes the drift between the hand-maintained keybar and
actual bindings, and matches the idiom `viewport`/`gh-dash` already use.
Acceptance: `?` shows a complete, accurate help view generated from the bindings;
the keybar auto-summarizes.

### B. First-class input (`textinput` / `textarea`) — Tier 1
Replace the bespoke search key handling with a `textinput` for `/` search and the
`filterableviewport` filter; use `textinput`/`textarea` for add-task fields.
Acceptance: search + add-task inputs support cursor movement, edit, and paste.

### C. Structured rendering (`lipgloss` table/list + `reflow`) — Tier 1
Render the full task-detail field block and the PR checks as `lipgloss/table`;
swap `clip`/`padRow`/`wrap` for `reflow` so width math is ANSI/Unicode-correct.
Acceptance: task detail and PR checks render as aligned tables; no truncation
artifacts on wide-glyph content.

### D. Clickable everything (native hit-testing) — Tier 2
Tabs, task rows, action-bar buttons, and PR actions are routed through
cockpit-owned mouse coordinate mapping in `handleMouse`. This avoids v1-only
`bubblezone` markers while preserving keyboard parity and stable width math.
Acceptance: clicking a tab/row/action/PR does what the key does; wheel scroll
still works; no zero-width marker dependency is required.

### E. Fleet metrics (native bounded bars) — Tier 2
The top-level `metrics` view reads `GET /api/v1/metrics` and renders counters,
gauges, and phase durations as native bounded bars. Missing metrics produce a
graceful empty state; HTTP/JSON errors surface in the cockpit notice bar. Richer
time-series sparklines can wait for a v2-compatible charting library or backend
series fields.
Acceptance: a metrics view renders live metric rows on refresh; empty/missing
data states are graceful; no render-path aggregation blocks the TUI.

### F. Motion & polish (`spinner` + `stopwatch`; `harmonica` optional) — Tier 3
Use first-party Bubble Tea components for meaningful live motion: the phase rail
active glyph, status bar, diff-preview loading, and metrics loading use
`bubbles/spinner`; selected RUNNING runs show live elapsed time via `stopwatch`.
Keep motion subtle and disable-able (respect a `reducedMotion` config for
accessibility / low-power terminals). Spring panel/tab transitions via
`harmonica` remain optional polish and are not required for roadmap completion.
Acceptance: active/loading states visibly animate on the v2 renderer; motion can
be turned off; no CPU spin when idle.

### G. (Optional) layout system (`stickers`) — Tier 3
Only if it clearly simplifies the responsive two-column + bars layout; otherwise
keep `lipgloss` joins. Verify v2 + maintenance first.

## 5. Per-library v2 verification (do before adding each)

For each Tier-2/optional lib: check its `go.mod`/tags for a `charm.land/*/v2`
dependency (or an explicitly v2-compatible release); build a throwaway spike
importing it alongside the v2 cockpit before adopting it. If it only supports v1,
park it in a "revisit when upstream ships v2" list in this doc and satisfy the
user-facing behavior natively when the behavior is small enough.

## 6. The demo (make it showcase-able)

- **Rich mock backend:** extend `NewMockClient` (`COCKPIT_BACKEND=mock`) with a
  fleet of runs across every state, realistic phase timings, messages/events,
  reports, files, PRs, and enough history to make the charts sing. This is what
  gets recorded and what CI/tests exercise.
- **Recorded GIF:** `clients/cockpit/demo.tape` drives the mock cockpit through the
  highlight reel (help overlay, PR tab, metrics tab) and can render `demo.gif`
  with `vhs demo.tape`. `vhs` remains a developer-installed tool, not a runtime
  dependency.
- Use the new v2 `tea.WithWindowSize`/`tea.WithColorProfile` options so the demo
  renders deterministically.

## 7. Acceptance (showcase bar)

- Keyboard and mouse reach every action; `?` help is complete and generated.
- The metrics view reads the fleet's health at a glance and updates live.
- Motion is smooth and can be disabled; idle CPU stays low.
- Theme is consistent across cockpit + `diffnav`/`gh dash`/`gh enhance`.
- `COCKPIT_BACKEND=mock` produces a demo-worthy screen; `demo.tape` is checked in
  for local `vhs` GIF capture.
- Every adopted lib is a verified v2 build; `go build/test/vet ./...` clean on
  Go 1.26; key/help generation, search parsing, spinner/stopwatch motion, and
  ANSI/Unicode width helpers are owned by v2-compatible components or delegate to
  `reflow` rather than bespoke terminal math.

## 8. Non-goals & risks

- **Not** a rewrite of the read-only-client architecture; charts/inputs read the
  same `/api/v1` data. No new backend endpoints beyond confirming `/metrics`.
- **v2 compatibility is the dominant risk** — a v1-only lib can't be mixed in;
  verify per §5 before committing, and keep any unverified lib out of `go.mod`.
- **Scope creep / gratuitous motion** — every effect must aid legibility; ship
  `reducedMotion` and keep it tasteful. Don't sacrifice the sub-100ms feel.
- **Performance** — charts and animation must not busy-loop; drive from the
  existing tick and cache derived series.

## 9. Suggested sequencing

1. (Prereq) v2 migration to parity — see the viewport handoff.
2. Tier 1: `key`+`help` → `textinput` → `lipgloss` table/list + `reflow`
   (each deletes hand-rolled code; low risk, immediate polish).
3. Tier 2: native hit-testing and metrics bars are implemented; revisit
   `bubblezone`/`ntcharts` only after upstream v2-compatible releases exist.
4. Tier 3: first-party spinner/stopwatch/reduced-motion paths are implemented;
   `harmonica` remains optional polish, and `stickers` remains unnecessary while
   the pane layout stays simple.
5. Demo: rich mock dataset + checked-in `clients/cockpit/demo.tape`; generated
   `demo.gif` is a local developer artifact when `vhs` is installed, not a
   committed roadmap dependency.
6. Docs sweep (README, `cockpit-ui-spec.md`, theme handoff cross-links).

Sources: [charmbracelet/bubbles](https://github.com/charmbracelet/bubbles),
[bubbles v2](https://pkg.go.dev/charm.land/bubbles/v2),
[NimbleMarkets/ntcharts](https://github.com/NimbleMarkets/ntcharts),
[lrstanley/bubblezone](https://github.com/lrstanley/bubblezone),
[charmbracelet/harmonica](https://github.com/charmbracelet/harmonica),
[charmbracelet/huh](https://github.com/charmbracelet/huh),
[muesli/reflow](https://github.com/muesli/reflow),
[charmbracelet/vhs](https://github.com/charmbracelet/vhs)
